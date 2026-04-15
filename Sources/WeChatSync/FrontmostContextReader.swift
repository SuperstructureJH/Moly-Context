import AppKit
import CryptoKit
import Foundation

enum FrontmostContextError: Error, LocalizedError {
    case noEligibleApplication
    case insufficientContent

    var errorDescription: String? {
        switch self {
        case .noEligibleApplication:
            return "No eligible frontmost app is available for context capture."
        case .insufficientContent:
            return "The frontmost window does not expose enough readable accessibility text."
        }
    }
}

struct FrontmostContextCapture {
    let appName: String
    let bundleIdentifier: String
    let windowTitle: String
    let conversationName: String
    let text: String
    let fingerprint: String
}

enum FrontmostContextReader {
    static func captureCurrent(excludingBundleIdentifiers: Set<String> = []) throws -> FrontmostContextCapture {
        guard let app = currentApplication(excludingBundleIdentifiers: excludingBundleIdentifiers) else {
            throw FrontmostContextError.noEligibleApplication
        }
        return try capture(for: app)
    }

    static func capture(for app: NSRunningApplication) throws -> FrontmostContextCapture {
        let snapshot = try AccessibilityReader.captureSnapshot(for: app, maxDepth: 10)
        let appName = normalizeLabel(app.localizedName) ?? "Unknown App"
        let bundleIdentifier = app.bundleIdentifier ?? "unknown.bundle"
        let profile = profile(for: appName, bundleIdentifier: bundleIdentifier)
        let fallbackTitle = normalizeLabel(snapshot.title) ?? appName
        let lines = meaningfulLines(from: snapshot, windowTitle: fallbackTitle, profile: profile)

        guard !lines.isEmpty else {
            throw FrontmostContextError.insufficientContent
        }

        let windowTitle = resolvedWindowTitle(
            snapshot: snapshot,
            fallbackTitle: fallbackTitle,
            lines: lines,
            profile: profile
        )
        let text = lines.joined(separator: "\n")
        let conversationName = "Context · \(appName) · \(windowTitle)"
        let fingerprint = stableHash("\(bundleIdentifier)|\(windowTitle.lowercased())|\(text.lowercased())")

        return FrontmostContextCapture(
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            windowTitle: windowTitle,
            conversationName: conversationName,
            text: text,
            fingerprint: fingerprint
        )
    }

    private static func currentApplication(excludingBundleIdentifiers: Set<String>) -> NSRunningApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        guard app.activationPolicy == .regular else { return nil }

        let bundleIdentifier = app.bundleIdentifier ?? ""
        let lowercasedName = (app.localizedName ?? "").lowercased()
        let blockedBundleIdentifiers: Set<String> = Set(excludingBundleIdentifiers).union([
            "com.apple.dock",
            "com.apple.systemuiserver",
            "com.apple.notificationcenterui",
            "com.apple.controlcenter",
        ])

        if blockedBundleIdentifiers.contains(bundleIdentifier) {
            return nil
        }

        if let weChat = ChatAppLocator.findRunningApplication(for: .weChat),
           weChat.processIdentifier == app.processIdentifier {
            return nil
        }

        if lowercasedName.contains("wechat") || lowercasedName.contains("微信") {
            return nil
        }

        return app
    }

    private static func meaningfulLines(from snapshot: WindowSnapshot, windowTitle: String, profile: ContextProfile) -> [String] {
        let candidates = snapshot.nodes.compactMap { node -> CandidateLine? in
            let normalized = normalizeText(node.text)
            guard !normalized.isEmpty else { return nil }
            guard containsMeaningfulContent(normalized) else { return nil }
            guard normalized.caseInsensitiveCompare(windowTitle) != .orderedSame else { return nil }
            guard !isStructuralNoise(normalized) else { return nil }
            guard !isChromeText(normalized, profile: profile) else { return nil }

            let score = score(for: node, text: normalized, snapshot: snapshot, profile: profile)
            guard score > 0 else { return nil }
            return CandidateLine(node: node, text: normalized, score: score)
        }

        guard !candidates.isEmpty else { return [] }

        let prioritized = candidates
            .sorted {
                if $0.score == $1.score {
                    if abs($0.node.midY - $1.node.midY) < 2 {
                        return $0.node.minX < $1.node.minX
                    }
                    return $0.node.midY < $1.node.midY
                }
                return $0.score > $1.score
            }
            .prefix(72)
            .sorted {
                if abs($0.node.midY - $1.node.midY) < 2 {
                    return $0.node.minX < $1.node.minX
                }
                return $0.node.midY < $1.node.midY
            }

        var lines: [String] = []
        var seen = Set<String>()
        var characterBudget = 0

        for candidate in prioritized {
            let key = candidate.text.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)

            lines.append(candidate.text)
            characterBudget += candidate.text.count

            if lines.count >= 36 || characterBudget >= 1500 {
                break
            }
        }

        return lines
    }

    private static func resolvedWindowTitle(
        snapshot: WindowSnapshot,
        fallbackTitle: String,
        lines: [String],
        profile: ContextProfile
    ) -> String {
        let genericTitles = Set([
            "google chrome",
            "chrome",
            "飞书",
            "lark",
            "feishu",
            "arc",
            "brave browser",
            "microsoft edge",
        ])

        if !genericTitles.contains(fallbackTitle.lowercased()) {
            return fallbackTitle
        }

        let topCandidates = lines.filter { line in
            let lower = line.lowercased()
            return !genericTitles.contains(lower) &&
                !isChromeText(line, profile: profile) &&
                !isStructuralNoise(line) &&
                line.count <= 80
        }

        return topCandidates.first ?? fallbackTitle
    }

    private static func normalizeLabel(_ text: String?) -> String? {
        guard let text else { return nil }
        let normalized = normalizeText(text)
        return normalized.isEmpty ? nil : normalized
    }

    private static func normalizeText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: .newlines)
            .map { line in
                line
                    .components(separatedBy: .whitespaces)
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func containsMeaningfulContent(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            CharacterSet.alphanumerics.contains(scalar) || (0x4E00...0x9FFF).contains(scalar.value)
        }
    }

    private static func profile(for appName: String, bundleIdentifier: String) -> ContextProfile {
        let lowerAppName = appName.lowercased()
        let lowerBundle = bundleIdentifier.lowercased()

        if lowerAppName.contains("chrome") ||
            lowerAppName.contains("arc") ||
            lowerAppName.contains("brave") ||
            lowerAppName.contains("edge") ||
            lowerAppName.contains("vivaldi") ||
            lowerAppName.contains("opera") ||
            lowerBundle.contains("chrome") ||
            lowerBundle.contains("chromium") ||
            lowerBundle.contains("arc") ||
            lowerBundle.contains("brave") ||
            lowerBundle.contains("edge") ||
            lowerBundle.contains("vivaldi") ||
            lowerBundle.contains("opera") {
            return .browser
        }

        if lowerAppName.contains("飞书") ||
            lowerAppName.contains("lark") ||
            lowerAppName.contains("feishu") ||
            lowerBundle.contains("lark") ||
            lowerBundle.contains("feishu") {
            return .lark
        }

        return .generic
    }

    private static func score(for node: TextNode, text: String, snapshot: WindowSnapshot, profile: ContextProfile) -> Int {
        let role = node.role.lowercased()
        var score = 0

        if role.contains("statictext") || role.contains("text") || role.contains("link") {
            score += 5
        }
        if role.contains("button") || role.contains("tab") {
            score -= 5
        }
        if node.width >= snapshot.width * 0.12 {
            score += 2
        }
        if text.count >= 8 {
            score += 2
        }
        if text.count >= 24 {
            score += 2
        }
        if text.count >= 64 {
            score += 1
        }

        switch profile {
        case .browser:
            if node.midY < snapshot.minY + 96 {
                score -= 6
            }
            if node.midX < snapshot.minX + (snapshot.width * 0.16) {
                score -= 4
            }
            if node.midX > snapshot.minX + (snapshot.width * 0.20),
               node.midY > snapshot.minY + 90 {
                score += 4
            }
            if text.contains("http") || text.contains("www.") || text.contains(".com") {
                score -= 2
            }
        case .lark:
            if node.midX < snapshot.minX + (snapshot.width * 0.38) {
                score -= 6
            }
            if node.midX > snapshot.minX + (snapshot.width * 0.45) {
                score += 4
            }
            if node.midY < snapshot.minY + 90 {
                score -= 2
            }
        case .generic:
            if node.midY < snapshot.minY + 70 {
                score -= 1
            }
        }

        return score
    }

    private static func isStructuralNoise(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        let lower = trimmed.lowercased()
        let exactBlocked: Set<String> = [
            "titleedgeview",
            "profileflexview",
            "profilebutton",
            "leadingflexview",
            "contentsview",
            "clientview",
            "mainwidgetdelegateview",
            "browseruserview",
            "sideedgeview",
            "tabcontensview",
            "tabbarview",
            "tabscrollview",
            "trailingflexview",
            "eventcenterview",
            "delegateview",
            "创建",
        ]

        if exactBlocked.contains(lower) {
            return true
        }

        let fragments = [
            "view",
            "delegate",
            "contents",
            "widget",
            "profile",
            "tabbar",
            "scrollview",
            "flexview",
            "multiwebview",
            "browseruser",
        ]
        if fragments.filter({ lower.contains($0) }).count >= 2 {
            return true
        }

        return false
    }

    private static func isChromeText(_ text: String, profile: ContextProfile) -> Bool {
        let lower = text.lowercased()
        let blocked: Set<String>

        switch profile {
        case .browser:
            blocked = [
                "关闭",
                "搜索标签页",
                "返回",
                "前进",
                "重新加载",
                "家",
                "查看网站信息",
                "地址和搜索栏",
                "扩展程序",
                "为此标签页添加书签",
                "已保存的标签页分组",
                "标签页分组",
                "分隔符",
                "新标签页",
                "translate",
                "search tabs",
                "back",
                "forward",
                "reload",
                "home",
                "bookmark this tab",
                "extensions",
                "address and search bar",
                "saved tab groups",
                "tab groups",
                "separator",
                "new tab",
            ]
        case .lark:
            blocked = [
                "搜索（⌘＋k）",
                "搜索（⌘+k）",
                "创建",
            ]
        case .generic:
            blocked = []
        }

        if blocked.contains(lower) {
            return true
        }

        if profile == .browser {
            if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.contains("地址和搜索") {
                return true
            }
            if lower.contains("google chrome -") || lower.contains(" - google chrome") {
                return true
            }
        }

        return false
    }

    private static func stableHash(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private enum ContextProfile {
    case generic
    case browser
    case lark
}

private struct CandidateLine {
    let node: TextNode
    let text: String
    let score: Int
}
