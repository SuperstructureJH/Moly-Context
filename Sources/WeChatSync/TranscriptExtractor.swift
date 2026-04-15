import CryptoKit
import Foundation

enum TranscriptExtractor {
    static func extractVisibleMessages(from snapshot: WindowSnapshot, targetApp: TargetApp) -> SyncResult {
        let capturedAt = Date()
        let rawConversationName = resolveConversationName(snapshot: snapshot, targetApp: targetApp)
        let conversationName = scopedConversationName(rawConversationName, targetApp: targetApp)
        let layout = extractionLayout(for: targetApp)
        let regions = extractionRegions(for: snapshot, targetApp: targetApp, layout: layout)
        let contentMinX = regions.contentMinX
        let contentMaxX = regions.contentMaxX
        let contentMidX = contentMinX + ((contentMaxX - contentMinX) / 2)
        let bodyMinY = snapshot.minY + layout.bodyTopInset
        let bodyMaxY = snapshot.maxY - layout.bodyBottomInset

        let filtered = snapshot.nodes.filter { node in
            guard node.maxX > contentMinX else { return false }
            guard node.minX < contentMaxX else { return false }
            guard node.midY >= bodyMinY, node.midY <= bodyMaxY else { return false }
            guard node.width > layout.minMessageNodeWidth, node.height > layout.minMessageNodeHeight else { return false }
            guard !isStructuralNoise(node.text, targetApp: targetApp) else { return false }
            return !isChromeText(node.text, targetApp: targetApp)
        }

        let groups = groupNodes(filtered, contentMidX: contentMidX, targetApp: targetApp, groupYThreshold: layout.messageGroupYThreshold)

        let messages = groups.compactMap { group -> VisibleMessage? in
            let text = group.nodes
                .map(\.text)
                .joined(separator: "\n")
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            guard !isStructuralNoise(text, targetApp: targetApp) else { return nil }
            let direction = group.averageMidX >= contentMidX ? "out" : "in"
            let senderLabel = direction == "out" ? "self" : rawConversationName
            let recipientLabel = direction == "out" ? rawConversationName : "self"
            let fingerprint = fingerprintFor(
                conversationName: conversationName,
                direction: direction,
                text: text
            )

            return VisibleMessage(
                conversationName: conversationName,
                direction: direction,
                senderName: nil,
                senderLabel: senderLabel,
                recipientLabel: recipientLabel,
                text: text,
                fingerprint: fingerprint,
                source: "\(targetApp.sourceName)-accessibility",
                capturedAt: capturedAt
            )
        }

        if messages.isEmpty, let fallback = rawWindowFallbackMessage(
            from: snapshot,
            targetApp: targetApp,
            capturedAt: capturedAt
        ) {
            return SyncResult(
                conversationName: fallback.conversationName,
                capturedCount: 1,
                insertedMessages: [fallback],
                filteredCount: 0
            )
        }

        return SyncResult(
            conversationName: conversationName,
            capturedCount: messages.count,
            insertedMessages: messages,
            filteredCount: 0
        )
    }

    static func currentConversationName(from snapshot: WindowSnapshot, targetApp: TargetApp) -> String {
        resolveConversationName(snapshot: snapshot, targetApp: targetApp)
    }

    static func extractConversationRows(from snapshot: WindowSnapshot, targetApp: TargetApp) -> [ConversationRow] {
        let layout = extractionLayout(for: targetApp)
        let regions = extractionRegions(for: snapshot, targetApp: targetApp, layout: layout)
        let sidebarMinX = regions.sidebarMinX
        let sidebarMaxX = regions.sidebarMaxX
        let bodyMinY = snapshot.minY + layout.bodyTopInset
        let bodyMaxY = snapshot.maxY - layout.sidebarBottomInset

        let filtered = snapshot.nodes.filter { node in
            guard node.maxX > sidebarMinX else { return false }
            guard node.minX < sidebarMaxX else { return false }
            guard node.midY >= bodyMinY, node.midY <= bodyMaxY else { return false }
            guard node.width > layout.minSidebarNodeWidth, node.height > layout.minSidebarNodeHeight else { return false }
            guard !isStructuralNoise(node.text, targetApp: targetApp) else { return false }
            return !isSidebarChromeText(node.text, targetApp: targetApp)
        }

        let rows = groupSidebarRows(filtered, rowMergeThreshold: layout.sidebarRowMergeThreshold)
        let minRowWidth = targetApp == .lark ? max(110, snapshot.width * 0.11) : max(64, snapshot.width * 0.06)
        return rows.compactMap { row in
            let title = row.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            guard row.width >= minRowWidth else { return nil }
            guard !isStructuralNoise(title, targetApp: targetApp) else { return nil }
            guard title.count <= 80 else { return nil }
            if targetApp == .lark && !containsMeaningfulCharacters(title) {
                return nil
            }
            let normalizedPreview = row.preview.trimmingCharacters(in: .whitespacesAndNewlines)
            return ConversationRow(
                title: title,
                preview: isStructuralNoise(normalizedPreview, targetApp: targetApp) ? "" : normalizedPreview,
                minX: row.minX,
                minY: row.minY,
                width: row.width,
                height: row.height
            )
        }
    }

    private static func resolveConversationName(snapshot: WindowSnapshot, targetApp: TargetApp) -> String {
        if let title = snapshot.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty,
           !targetApp.blockedWindowTitles.contains(title.lowercased()) {
            return title
        }

        let layout = extractionLayout(for: targetApp)
        let regions = extractionRegions(for: snapshot, targetApp: targetApp, layout: layout)
        let contentMinX = regions.contentMinX
        let contentMaxX = regions.contentMaxX
        let headerTexts = snapshot.nodes
            .filter {
                $0.minX >= contentMinX &&
                $0.maxX <= contentMaxX &&
                $0.midY <= snapshot.minY + layout.headerMaxY
            }
            .map(\.text)
            .filter {
                !isChromeText($0, targetApp: targetApp) &&
                !isStructuralNoise($0, targetApp: targetApp) &&
                $0.count <= 60 &&
                containsMeaningfulCharacters($0)
            }

        if let header = headerTexts.first {
            return header
        }

        if targetApp == .lark {
            let larkHeaderCandidates = snapshot.nodes
                .filter {
                    $0.midX >= snapshot.minX + (snapshot.width * 0.42) &&
                    $0.midY <= snapshot.minY + max(layout.headerMaxY + 34, 116) &&
                    $0.width >= 24
                }
                .map(\.text)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter {
                    !$0.isEmpty &&
                    !isChromeText($0, targetApp: targetApp) &&
                    !isStructuralNoise($0, targetApp: targetApp) &&
                    !$0.contains("·") &&
                    $0.count <= 80 &&
                    containsMeaningfulCharacters($0)
                }

            if let fallback = larkHeaderCandidates.first {
                return fallback
            }
        }

        return "Unknown Conversation"
    }

    private static func groupNodes(_ nodes: [TextNode], contentMidX: Double, targetApp: TargetApp, groupYThreshold: Double) -> [MessageGroup] {
        let sorted = nodes.sorted {
            if abs($0.midY - $1.midY) < 4 {
                return $0.minX < $1.minX
            }
            return $0.midY < $1.midY
        }

        var groups: [MessageGroup] = []

        for node in sorted {
            let nodeDirection = node.midX >= contentMidX ? "out" : "in"
            if let lastIndex = groups.indices.last {
                let last = groups[lastIndex]
                if abs(last.averageMidY - node.midY) <= groupYThreshold, last.direction == nodeDirection {
                    groups[lastIndex].append(node)
                    continue
                }
            }

            groups.append(MessageGroup(direction: nodeDirection, nodes: [node]))
        }

        return groups.filter { group in
            let joined = group.nodes.map(\.text).joined(separator: " ")
            return !isChromeText(joined, targetApp: targetApp)
        }
    }

    private static func isChromeText(_ text: String, targetApp: TargetApp) -> Bool {
        let lower = text.lowercased()
        return targetApp.blockedChromeText.contains(where: { lower == $0 })
    }

    private static func isStructuralNoise(_ text: String, targetApp: TargetApp) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        if trimmed.contains("->") && (trimmed.contains("View") || trimmed.contains("Button")) {
            return true
        }

        let markerHits = [
            "ContentsView",
            "ClientView",
            "ProfileFlexView",
            "ProfileButton",
            "MainWidgetDelegateView",
            "BrowserUserView",
            "TabContents",
            "DelegateView",
            "WidgetDelegate",
            "BrowserView",
            "NSView",
            "AX"
        ].filter { trimmed.contains($0) }.count
        if markerHits >= 2 {
            return true
        }

        if targetApp == .lark {
            let lower = trimmed.lowercased()
            if ["创建", "create", "profile", "profilebutton", "my avatar", "我的头像"].contains(lower) {
                return true
            }
        }

        return false
    }

    private static func containsMeaningfulCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            CharacterSet.letters.contains(scalar) || (0x4E00...0x9FFF).contains(scalar.value)
        }
    }

    private static func isSidebarChromeText(_ text: String, targetApp: TargetApp) -> Bool {
        if isChromeText(text, targetApp: targetApp) {
            return true
        }

        let lower = text.lowercased()
        let blocked = targetApp == .weChat
            ? ["chat", "chats", "message", "messages", "微信"]
            : ["chat", "chats", "message", "messages", "飞书", "lark", "feishu"]
        return blocked.contains(lower)
    }

    private static func scopedConversationName(_ name: String, targetApp: TargetApp) -> String {
        "\(targetApp.storagePrefix) · \(name)"
    }

    private static func rawWindowFallbackMessage(
        from snapshot: WindowSnapshot,
        targetApp: TargetApp,
        capturedAt: Date
    ) -> VisibleMessage? {
        let rawText = rawVisibleText(from: snapshot, targetApp: targetApp)
        guard !rawText.isEmpty else { return nil }

        let conversationCoreName = resolveConversationName(snapshot: snapshot, targetApp: targetApp) == "Unknown Conversation"
            ? "Visible Window"
            : resolveConversationName(snapshot: snapshot, targetApp: targetApp)
        let conversationName = scopedConversationName(conversationCoreName, targetApp: targetApp)
        let fingerprint = fingerprintFor(
            conversationName: conversationName,
            direction: "in",
            text: rawText
        )

        return VisibleMessage(
            conversationName: conversationName,
            direction: "in",
            senderName: nil,
            senderLabel: conversationCoreName,
            recipientLabel: "self",
            text: rawText,
            fingerprint: fingerprint,
            source: "\(targetApp.sourceName)-window-fallback",
            capturedAt: capturedAt
        )
    }

    private static func rawVisibleText(from snapshot: WindowSnapshot, targetApp: TargetApp) -> String {
        let layout = extractionLayout(for: targetApp)
        let regions = extractionRegions(for: snapshot, targetApp: targetApp, layout: layout)
        let contentMinX = regions.contentMinX
        let contentMaxX = regions.contentMaxX
        let bodyMinY = snapshot.minY + layout.bodyTopInset
        let bodyMaxY = snapshot.maxY - layout.bodyBottomInset

        var seen = Set<String>()
        let lines = snapshot.nodes
            .filter {
                $0.maxX > contentMinX &&
                $0.minX < contentMaxX &&
                $0.midY >= bodyMinY &&
                $0.midY <= bodyMaxY &&
                !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                !isChromeText($0.text, targetApp: targetApp) &&
                !isStructuralNoise($0.text, targetApp: targetApp)
            }
            .sorted {
                if abs($0.midY - $1.midY) < 4 {
                    return $0.minX < $1.minX
                }
                return $0.midY < $1.midY
            }
            .compactMap { node -> String? in
                let text = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                guard !seen.contains(text) else { return nil }
                seen.insert(text)
                return text
            }

        guard !lines.isEmpty else { return "" }
        return lines.prefix(40).joined(separator: "\n")
    }

    private static func extractionRegions(for snapshot: WindowSnapshot, targetApp: TargetApp, layout: ExtractionLayout) -> ExtractionRegions {
        let fallback = ExtractionRegions(
            sidebarMinX: snapshot.minX + (snapshot.width * layout.sidebarMinRatio),
            sidebarMaxX: snapshot.minX + (snapshot.width * layout.sidebarMaxRatio),
            contentMinX: snapshot.minX + (snapshot.width * layout.contentMinRatio),
            contentMaxX: snapshot.minX + (snapshot.width * layout.contentMaxRatio)
        )

        guard targetApp == .lark else { return fallback }
        guard let dynamicRegions = dynamicLarkRegions(for: snapshot) else { return fallback }
        return dynamicRegions
    }

    private static func dynamicLarkRegions(for snapshot: WindowSnapshot) -> ExtractionRegions? {
        let candidateNodes = snapshot.nodes.filter { node in
            guard node.width > 6, node.height > 6 else { return false }
            guard node.midY >= snapshot.minY + 70, node.midY <= snapshot.maxY - 30 else { return false }
            let text = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return false }
            return !isStructuralNoise(text, targetApp: .lark)
        }

        let bands = columnBands(from: candidateNodes, gapThreshold: max(42, snapshot.width * 0.035))
        guard bands.count >= 2 else { return nil }

        let sidebarBand = bands
            .filter { $0.midXRatio(in: snapshot) >= 0.12 && $0.midXRatio(in: snapshot) <= 0.60 }
            .max { lhs, rhs in
                lhs.sidebarScore(in: snapshot) < rhs.sidebarScore(in: snapshot)
            }

        guard let sidebarBand else { return nil }

        let contentBand = bands
            .filter { $0.minX > sidebarBand.maxX + 18 }
            .max { lhs, rhs in
                lhs.contentScore(in: snapshot) < rhs.contentScore(in: snapshot)
            }

        guard let contentBand else { return nil }

        return ExtractionRegions(
            sidebarMinX: max(snapshot.minX, sidebarBand.minX - 12),
            sidebarMaxX: min(snapshot.maxX, sidebarBand.maxX + 12),
            contentMinX: max(snapshot.minX, contentBand.minX - 12),
            contentMaxX: min(snapshot.maxX, contentBand.maxX + 18)
        )
    }

    private static func extractionLayout(for targetApp: TargetApp) -> ExtractionLayout {
        switch targetApp {
        case .weChat:
            return ExtractionLayout(
                sidebarMinRatio: 0.0,
                sidebarMaxRatio: 0.23,
                contentMinRatio: 0.23,
                contentMaxRatio: 1.0,
                bodyTopInset: 70,
                bodyBottomInset: 150,
                sidebarBottomInset: 40,
                headerMaxY: 70,
                minMessageNodeWidth: 12,
                minMessageNodeHeight: 8,
                minSidebarNodeWidth: 8,
                minSidebarNodeHeight: 8,
                messageGroupYThreshold: 22,
                sidebarRowMergeThreshold: 28
            )
        case .lark:
            return ExtractionLayout(
                sidebarMinRatio: 0.18,
                sidebarMaxRatio: 0.47,
                contentMinRatio: 0.47,
                contentMaxRatio: 1.0,
                bodyTopInset: 86,
                bodyBottomInset: 88,
                sidebarBottomInset: 24,
                headerMaxY: 86,
                minMessageNodeWidth: 4,
                minMessageNodeHeight: 6,
                minSidebarNodeWidth: 4,
                minSidebarNodeHeight: 6,
                messageGroupYThreshold: 30,
                sidebarRowMergeThreshold: 36
            )
        }
    }

    private static func fingerprintFor(conversationName: String, direction: String, text: String) -> String {
        let normalized = text
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let input = "\(conversationName)|\(direction)|\(normalized)"
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private struct MessageGroup {
    let direction: String
    var nodes: [TextNode]

    var averageMidY: Double {
        nodes.map(\.midY).reduce(0, +) / Double(nodes.count)
    }

    var averageMidX: Double {
        nodes.map(\.midX).reduce(0, +) / Double(nodes.count)
    }

    mutating func append(_ node: TextNode) {
        nodes.append(node)
        nodes.sort {
            if abs($0.midY - $1.midY) < 4 {
                return $0.minX < $1.minX
            }
            return $0.midY < $1.midY
        }
    }
}

private struct SidebarRowGroup {
    var nodes: [TextNode]

    var minX: Double { nodes.map(\.minX).min() ?? 0 }
    var minY: Double { nodes.map(\.minY).min() ?? 0 }
    var width: Double { (nodes.map(\.maxX).max() ?? 0) - minX }
    var height: Double { (nodes.map(\.maxY).max() ?? 0) - minY }
    var midY: Double { nodes.map(\.midY).reduce(0, +) / Double(nodes.count) }

    var title: String {
        orderedTexts.first ?? ""
    }

    var preview: String {
        Array(orderedTexts.dropFirst()).joined(separator: " ")
    }

    mutating func append(_ node: TextNode) {
        nodes.append(node)
        nodes.sort {
            if abs($0.midY - $1.midY) < 4 {
                return $0.minX < $1.minX
            }
            return $0.midY < $1.midY
        }
    }

    private var orderedTexts: [String] {
        var seen = Set<String>()
        return nodes
            .sorted {
                if abs($0.midY - $1.midY) < 4 {
                    return $0.minX < $1.minX
                }
                return $0.midY < $1.midY
            }
            .map(\.text)
            .filter { text in
                let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalized.isEmpty else { return false }
                guard !seen.contains(normalized) else { return false }
                seen.insert(normalized)
                return true
            }
    }
}

private extension TranscriptExtractor {
    static func groupSidebarRows(_ nodes: [TextNode], rowMergeThreshold: Double) -> [SidebarRowGroup] {
        let sorted = nodes.sorted {
            if abs($0.midY - $1.midY) < 4 {
                return $0.minX < $1.minX
            }
            return $0.midY < $1.midY
        }

        var groups: [SidebarRowGroup] = []
        for node in sorted {
            if let lastIndex = groups.indices.last, abs(groups[lastIndex].midY - node.midY) <= rowMergeThreshold {
                groups[lastIndex].append(node)
            } else {
                groups.append(SidebarRowGroup(nodes: [node]))
            }
        }

        return groups.filter { group in
            !group.title.isEmpty && group.height > 10
        }
    }

    static func columnBands(from nodes: [TextNode], gapThreshold: Double) -> [ColumnBand] {
        let sorted = nodes.sorted { $0.midX < $1.midX }
        guard let first = sorted.first else { return [] }

        var bands: [[TextNode]] = [[first]]
        for node in sorted.dropFirst() {
            if let lastNode = bands[bands.count - 1].last,
               abs(node.midX - lastNode.midX) <= gapThreshold {
                bands[bands.count - 1].append(node)
            } else {
                bands.append([node])
            }
        }

        return bands
            .map(ColumnBand.init(nodes:))
            .filter { $0.nodes.count >= 6 && $0.width >= 28 && $0.heightSpan >= 180 }
    }
}

private struct ExtractionLayout {
    let sidebarMinRatio: Double
    let sidebarMaxRatio: Double
    let contentMinRatio: Double
    let contentMaxRatio: Double
    let bodyTopInset: Double
    let bodyBottomInset: Double
    let sidebarBottomInset: Double
    let headerMaxY: Double
    let minMessageNodeWidth: Double
    let minMessageNodeHeight: Double
    let minSidebarNodeWidth: Double
    let minSidebarNodeHeight: Double
    let messageGroupYThreshold: Double
    let sidebarRowMergeThreshold: Double
}

private struct ExtractionRegions {
    let sidebarMinX: Double
    let sidebarMaxX: Double
    let contentMinX: Double
    let contentMaxX: Double
}

private struct ColumnBand {
    let nodes: [TextNode]

    var minX: Double { nodes.map(\.minX).min() ?? 0 }
    var maxX: Double { nodes.map(\.maxX).max() ?? 0 }
    var width: Double { maxX - minX }
    var minY: Double { nodes.map(\.minY).min() ?? 0 }
    var maxY: Double { nodes.map(\.maxY).max() ?? 0 }
    var heightSpan: Double { maxY - minY }
    var midX: Double { minX + (width / 2) }
    var uniqueTextCount: Double { Double(Set(nodes.map(\.text)).count) }
    var averageTextLength: Double {
        guard !nodes.isEmpty else { return 0 }
        return Double(nodes.map { $0.text.count }.reduce(0, +)) / Double(nodes.count)
    }
    var longTextCount: Double {
        Double(nodes.filter { $0.text.count >= 6 }.count)
    }

    func midXRatio(in snapshot: WindowSnapshot) -> Double {
        guard snapshot.width > 0 else { return 0 }
        return (midX - snapshot.minX) / snapshot.width
    }

    func sidebarScore(in snapshot: WindowSnapshot) -> Double {
        let centerBias = 1.0 - abs(midXRatio(in: snapshot) - 0.33)
        return (uniqueTextCount * 2.0) + longTextCount + averageTextLength + (heightSpan / 60.0) + (centerBias * 10.0)
    }

    func contentScore(in snapshot: WindowSnapshot) -> Double {
        let rightBias = midXRatio(in: snapshot)
        return uniqueTextCount + (averageTextLength * 1.4) + (width / 40.0) + (heightSpan / 80.0) + (rightBias * 12.0)
    }
}
