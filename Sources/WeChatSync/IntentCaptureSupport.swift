import AppKit
import ApplicationServices
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ScreenCaptureKit
import Vision

struct IntentCaptureRecord {
    let capturedAt: Date
    let appName: String
    let bundleIdentifier: String
    let windowTitle: String
    let trigger: String
    let screenshotPath: String
    let analysisMarkdown: String
    let contextText: String
}

struct IntentCaptureScreenTarget {
    let rect: CGRect
    let label: String
    let displayID: CGDirectDisplayID?
}

enum IntentCaptureError: Error, LocalizedError {
    case screenPermissionMissing
    case screenshotFailed

    var errorDescription: String? {
        switch self {
        case .screenPermissionMissing:
            return "Screen Recording permission is missing."
        case .screenshotFailed:
            return "Could not capture the current screen."
        }
    }
}

enum IntentCaptureSupport {
    static func screenCapturePermissionGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    static func requestScreenCapturePermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func captureCurrentScreen(to destinationURL: URL) async throws -> IntentCaptureScreenTarget {
        guard screenCapturePermissionGranted() else {
            throw IntentCaptureError.screenPermissionMissing
        }

        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let target = currentScreenTarget()

        if #available(macOS 14.0, *),
           let displayID = target.displayID,
           let cgImage = try await captureWithDisplayFilter(displayID: displayID) {
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            guard let data = bitmap.representation(using: .png, properties: [:]) else {
                throw IntentCaptureError.screenshotFailed
            }
            try data.write(to: destinationURL, options: .atomic)
            return target
        }

        if #available(macOS 15.2, *) {
            let cgImage = try await captureWithScreenCaptureKit(rect: target.rect)
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            guard let data = bitmap.representation(using: .png, properties: [:]) else {
                throw IntentCaptureError.screenshotFailed
            }
            try data.write(to: destinationURL, options: .atomic)
            return target
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", destinationURL.path]
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw IntentCaptureError.screenshotFailed
        }
        return target
    }

    static func optimizedImagePayloadData(from imageURL: URL, maxDimension: CGFloat = 1600) throws -> Data {
        let image = NSImage(contentsOf: imageURL)
        guard let image else {
            throw IntentCaptureError.screenshotFailed
        }

        var sourceRect = NSRect(origin: .zero, size: image.size)
        guard let sourceCGImage = image.cgImage(forProposedRect: &sourceRect, context: nil, hints: nil) else {
            throw IntentCaptureError.screenshotFailed
        }

        let width = CGFloat(sourceCGImage.width)
        let height = CGFloat(sourceCGImage.height)
        let scale = min(1, maxDimension / max(width, height))
        let targetSize = NSSize(width: max(1, floor(width * scale)), height: max(1, floor(height * scale)))

        let targetImage = NSImage(size: targetSize)
        targetImage.lockFocus()
        defer { targetImage.unlockFocus() }

        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: targetSize))

        guard let tiff = targetImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let jpegData = bitmap.representation(
                using: .jpeg,
                properties: [.compressionFactor: 0.76]
              ) else {
            throw IntentCaptureError.screenshotFailed
        }

        return jpegData
    }

    static func currentAppMetadata(excludingBundleIdentifiers: Set<String>) -> (appName: String, bundleIdentifier: String, windowTitle: String, contextText: String) {
        let fallbackApp = NSWorkspace.shared.frontmostApplication
        let fallbackName = fallbackApp?.localizedName ?? "Unknown App"
        let fallbackBundle = fallbackApp?.bundleIdentifier ?? "unknown.bundle"

        if let capture = try? FrontmostContextReader.captureCurrent(excludingBundleIdentifiers: excludingBundleIdentifiers) {
            return (
                appName: capture.appName,
                bundleIdentifier: capture.bundleIdentifier,
                windowTitle: capture.windowTitle,
                contextText: capture.text
            )
        }

        return (
            appName: fallbackName,
            bundleIdentifier: fallbackBundle,
            windowTitle: fallbackName,
            contextText: ""
        )
    }

    static func currentScreenTarget() -> IntentCaptureScreenTarget {
        if let target = currentWindowScreenTarget() {
            return target
        }

        let mouseLocation = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) {
            return IntentCaptureScreenTarget(
                rect: screen.frame,
                label: screen.localizedName.nilIfEmpty ?? displayFallbackLabel(for: screen),
                displayID: displayID(for: screen)
            )
        }

        if let mainScreen = NSScreen.main ?? NSScreen.screens.first {
            return IntentCaptureScreenTarget(
                rect: mainScreen.frame,
                label: mainScreen.localizedName.nilIfEmpty ?? displayFallbackLabel(for: mainScreen),
                displayID: displayID(for: mainScreen)
            )
        }

        let union = NSScreen.screens
            .map(\.frame)
            .reduce(CGRect.null) { partial, frame in
                partial.union(frame)
            }
        return IntentCaptureScreenTarget(
            rect: union,
            label: "Current Screen",
            displayID: nil
        )
    }

    private static func currentWindowScreenTarget() -> IntentCaptureScreenTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.activationPolicy == .regular,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return nil
        }

        guard let snapshot = try? AccessibilityReader.captureSnapshot(for: app, maxDepth: 2) else {
            return nil
        }

        let windowRect = CGRect(
            x: snapshot.minX,
            y: snapshot.minY,
            width: snapshot.width,
            height: snapshot.height
        )

        guard !windowRect.isNull, !windowRect.isEmpty, windowRect.width > 100, windowRect.height > 100 else {
            return nil
        }

        let matchedScreen =
            NSScreen.screens
                .compactMap { screen -> (NSScreen, CGFloat)? in
                    let intersection = screen.frame.intersection(windowRect)
                    guard !intersection.isNull, !intersection.isEmpty else { return nil }
                    return (screen, intersection.width * intersection.height)
                }
                .sorted { $0.1 > $1.1 }
                .first?
                .0

        guard let screen = matchedScreen else {
            return nil
        }

        let label = screen.localizedName.nilIfEmpty ?? displayFallbackLabel(for: screen)
        return IntentCaptureScreenTarget(rect: screen.frame, label: label, displayID: displayID(for: screen))
    }

    @available(macOS 15.2, *)
    private static func captureWithScreenCaptureKit(rect: CGRect) async throws -> CGImage {
        guard !rect.isNull, !rect.isEmpty else {
            throw IntentCaptureError.screenshotFailed
        }

        return try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(in: rect) { image, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let image else {
                    continuation.resume(throwing: IntentCaptureError.screenshotFailed)
                    return
                }
                continuation.resume(returning: image)
            }
        }
    }

    @available(macOS 14.0, *)
    private static func captureWithDisplayFilter(displayID: CGDirectDisplayID) async throws -> CGImage? {
        let shareableContent = try await SCShareableContent.current
        guard let display = shareableContent.displays.first(where: { $0.displayID == displayID }) else {
            return nil
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()

        return try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: image)
            }
        }
    }

    private static func displayFallbackLabel(for screen: NSScreen) -> String {
        if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return "Display \(screenNumber.intValue)"
        }
        return "Current Screen"
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(screenNumber.uint32Value)
    }
}

enum IntentCaptureExporter {
    static func export(record: IntentCaptureRecord, databasePath: String) throws -> String {
        let rootURL = ExportPathResolver.intentMarkdownDirectory(databasePath: databasePath)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let fileURL = rootURL.appendingPathComponent(fileName(for: record.capturedAt))
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            let header = """
            # Intent Sensor Captures

            Window: \(bucketLabel(for: record.capturedAt))

            """
            try header.write(to: fileURL, atomically: true, encoding: .utf8)
        }

        let body = markdownBlock(for: record)
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        if let data = body.data(using: .utf8) {
            try handle.write(contentsOf: data)
        }

        try exportSingleRecord(record: record, databasePath: databasePath)

        return fileURL.path
    }

    private static func exportSingleRecord(record: IntentCaptureRecord, databasePath: String) throws {
        let screenshotURL = URL(fileURLWithPath: record.screenshotPath)
        let singleFileURL = screenshotURL.deletingPathExtension().appendingPathExtension("md")
        let intentFileURL = screenshotURL.deletingPathExtension().appendingPathExtension("intent.md")
        let body = """
        # Intent Capture

        Captured: \(timestamp(record.capturedAt))
        App: \(record.appName)
        Bundle: \(record.bundleIdentifier)
        Window: \(record.windowTitle)
        Trigger: \(record.trigger)
        Screenshot: \(record.screenshotPath)

        ## Analysis
        \(record.analysisMarkdown)
        """

        try FileManager.default.createDirectory(
            at: singleFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try body.write(to: singleFileURL, atomically: true, encoding: .utf8)

        let intentBody = """
        # Intent Summary

        Captured: \(timestamp(record.capturedAt))
        App: \(record.appName)
        Bundle: \(record.bundleIdentifier)
        Window: \(record.windowTitle)
        Trigger: \(record.trigger)
        Screenshot: \(record.screenshotPath)

        \(intentSummaryMarkdown(from: record.analysisMarkdown))
        """
        try intentBody.write(to: intentFileURL, atomically: true, encoding: .utf8)
    }

    private static func markdownBlock(for record: IntentCaptureRecord) -> String {
        """
        ## \(timestamp(record.capturedAt))
        - app: \(record.appName)
        - bundle: \(record.bundleIdentifier)
        - window: \(record.windowTitle)
        - trigger: \(record.trigger)
        - screenshot: \(record.screenshotPath)

        ### Analysis
        \(record.analysisMarkdown)
        """
    }

    private static func fileName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH"
        return formatter.string(from: date) + ".md"
    }

    private static func bucketLabel(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:00"
        return formatter.string(from: date)
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private static func intentSummaryMarkdown(from analysisMarkdown: String) -> String {
        let sections = analysisMarkdown.components(separatedBy: .newlines)
        var currentSection = ""
        var summaryLines: [String] = []
        var primaryIntentLines: [String] = []
        var relevantContentLines: [String] = []
        var normalizedLines: [String] = []
        var screenshotLines: [String] = []
        var accessibilityLines: [String] = []

        for rawLine in sections {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("## ") {
                currentSection = String(line.dropFirst(3))
                continue
            }

            guard line.hasPrefix("- ") else { continue }
            switch currentSection {
            case "Intent Summary":
                summaryLines.append(rawLine)
            case "Primary Intent":
                primaryIntentLines.append(rawLine)
            case "Relevant Content":
                relevantContentLines.append(rawLine)
            case "Normalized OCR":
                normalizedLines.append(rawLine)
            case "Screenshot OCR":
                screenshotLines.append(rawLine)
            case "Accessibility Context":
                accessibilityLines.append(rawLine)
            default:
                break
            }
        }

        var blocks: [String] = []
        if !summaryLines.isEmpty {
            blocks.append("## Intent Summary\n" + summaryLines.joined(separator: "\n"))
        }
        if !primaryIntentLines.isEmpty {
            blocks.append("## Primary Intent\n" + primaryIntentLines.joined(separator: "\n"))
        }
        if !relevantContentLines.isEmpty {
            blocks.append("## Relevant Content\n" + relevantContentLines.joined(separator: "\n"))
        }
        if !normalizedLines.isEmpty {
            blocks.append("## Normalized OCR\n" + normalizedLines.joined(separator: "\n"))
        } else if !screenshotLines.isEmpty {
            blocks.append("## Normalized OCR\n" + screenshotLines.joined(separator: "\n"))
        } else {
            blocks.append("## Normalized OCR\n- None")
        }

        if !accessibilityLines.isEmpty {
            blocks.append("## Accessibility Context\n" + accessibilityLines.joined(separator: "\n"))
        }

        return blocks.joined(separator: "\n\n")
    }
}

enum MultimodalIntentAnalyzer {
    static func analyzeScreenshot(
        imageURL: URL,
        appName: String,
        windowTitle: String,
        trigger: String,
        accessibilityContext: String,
        settings: PlannerSettings
    ) async throws -> String {
        let localFallback = try await Task.detached(priority: .utility) {
            try LocalScreenshotAnalyzer.analyzeScreenshot(
                imageURL: imageURL,
                appName: appName,
                windowTitle: windowTitle,
                trigger: trigger,
                accessibilityContext: accessibilityContext
            )
        }.value

        guard settings.isConfigured else {
            return localFallback
        }

        do {
            let visionSummary = try await RemoteVisionIntentRefiner.refine(
                imageURL: imageURL,
                localMarkdown: localFallback,
                appName: appName,
                windowTitle: windowTitle,
                trigger: trigger,
                settings: settings
            )
            return localFallback + "\n\n" + visionSummary
        } catch {
            let fallbackSection = (try? await OCRTextRefiner.refine(
                localMarkdown: localFallback,
                appName: appName,
                windowTitle: windowTitle,
                trigger: trigger,
                settings: settings
            )) ?? ""
            let mergedFallback = mergeNormalizedSection(into: localFallback, normalizedSection: fallbackSection)
            let suffix = "_Local OCR was used because multimodal screenshot understanding failed._"
            return mergedFallback + "\n\n" + suffix
        }
    }

    private static func normalizedBaseURL(_ url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("/v1") {
            return trimmed
        }
        if trimmed.hasSuffix("/") {
            return trimmed + "v1"
        }
        return trimmed + "/v1"
    }
    private static func mergeNormalizedSection(into localMarkdown: String, normalizedSection: String) -> String {
        let trimmed = normalizedSection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return localMarkdown }

        if localMarkdown.contains("## Accessibility Context") {
            return localMarkdown.replacingOccurrences(
                of: "\n\n## Accessibility Context",
                with: "\n\n\(trimmed)\n\n## Accessibility Context"
            )
        }
        return localMarkdown + "\n\n" + trimmed
    }
}

enum LocalScreenshotAnalyzer {
    private static let ciContext = CIContext(options: nil)

    static func analyzeScreenshot(
        imageURL: URL,
        appName: String,
        windowTitle: String,
        trigger: String,
        accessibilityContext: String
    ) throws -> String {
        let ocrLines = try recognizedTextLines(from: imageURL)
        let contextLines = accessibilityContext
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let cleanedOCRLines = deduplicated(lines: ocrLines).filter { !$0.isNoiseLine }
        let cleanedContextLines = deduplicated(lines: contextLines).filter { !$0.isNoiseLine }
        let ocrPreview = cleanedOCRLines.map { "- \($0)" }.joined(separator: "\n").nilIfEmpty ?? "- None"
        let accessibilityPreview = cleanedContextLines.prefix(6).map { "- \($0)" }.joined(separator: "\n").nilIfEmpty

        var sections = ["## Screenshot OCR\n\(ocrPreview)"]
        if let accessibilityPreview {
            sections.append("## Accessibility Context\n\(accessibilityPreview)")
        }
        return sections.joined(separator: "\n\n")
    }

    private static func recognizedTextLines(from imageURL: URL) throws -> [String] {
        guard let image = NSImage(contentsOf: imageURL) else {
            return []
        }

        var rect = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            return []
        }

        var mergedLines: [String] = []

        for candidateImage in preparedOCRImages(from: cgImage) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.customWords = ["ChatGPT", "Codex", "Moly", "微信", "飞书", "MiniMax", "GitHub"]
            request.minimumTextHeight = 0.006

            let handler = VNImageRequestHandler(cgImage: candidateImage, options: [:])
            try handler.perform([request])

            let observations = request.results ?? []
            let lines = observations
                .compactMap { $0.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            mergedLines.append(contentsOf: lines)
        }

        return deduplicated(lines: mergedLines)
    }

    private static func inferredFollowUps(from lines: [String]) -> [String] {
        let patterns = [
            "todo", "待办", "follow up", "follow-up", "回复", "联系", "提醒", "会议", "日程", "schedule", "截止", "deadline", "tomorrow", "明天", "today", "今天"
        ]

        return lines
            .filter { line in
                let lowered = line.lowercased()
                return patterns.contains { lowered.contains($0) }
            }
            .prefix(4)
            .map { $0 }
    }

    private static func deduplicated(lines: [String]) -> [String] {
        var seen = Set<String>()
        return lines.filter { line in
            let normalized = line.lowercased()
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, !seen.contains(normalized) else { return false }
            seen.insert(normalized)
            return true
        }
    }

    private static func preparedOCRImages(from cgImage: CGImage) -> [CGImage] {
        var images: [CGImage] = [cgImage]
        if let enhanced = enhanceOCRImage(cgImage) {
            images.append(enhanced)
        }
        return images
    }

    private static func enhanceOCRImage(_ cgImage: CGImage) -> CGImage? {
        let input = CIImage(cgImage: cgImage)
        let grayscale = CIFilter.colorControls()
        grayscale.inputImage = input
        grayscale.saturation = 0
        grayscale.contrast = 1.45
        grayscale.brightness = 0.03

        let sharpen = CIFilter.sharpenLuminance()
        sharpen.inputImage = grayscale.outputImage
        sharpen.sharpness = 0.5

        guard let output = sharpen.outputImage?
            .transformed(by: CGAffineTransform(scaleX: 2.2, y: 2.2)) else {
            return nil
        }

        return ciContext.createCGImage(output, from: output.extent.integral)
    }
}

private enum RemoteVisionIntentRefiner {
    static func refine(
        imageURL: URL,
        localMarkdown: String,
        appName: String,
        windowTitle: String,
        trigger: String,
        settings: PlannerSettings
    ) async throws -> String {
        guard let url = URL(string: normalizedBaseURL(settings.apiBaseURL) + "/chat/completions") else {
            throw URLError(.badURL)
        }

        let imageData = try IntentCaptureSupport.optimizedImagePayloadData(from: imageURL)
        let imageBase64 = imageData.base64EncodedString()

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")

        let payload = VisionChatCompletionRequest(
            model: settings.modelName,
            temperature: 0.15,
            messages: [
                VisionMessage(
                    role: "system",
                    content: [.text(systemPrompt)]
                ),
                VisionMessage(
                    role: "user",
                    content: [
                        .text(buildPrompt(
                            localMarkdown: localMarkdown,
                            appName: appName,
                            windowTitle: windowTitle,
                            trigger: trigger
                        )),
                        .imageURL("data:image/jpeg;base64,\(imageBase64)")
                    ]
                )
            ]
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            throw URLError(.badServerResponse)
        }

        let completion = try JSONDecoder().decode(VisionChatCompletionResponse.self, from: data)
        let content = completion.choices.first?.message.flattenedContent.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        guard let content else {
            throw URLError(.cannotParseResponse)
        }
        return content
    }

    private static var systemPrompt: String {
        """
        You are a screenshot intent understanding assistant.
        Vision is primary. OCR is only auxiliary evidence.
        Ignore sidebars, chat history lists, browser chrome, bookmarks, menu bars, and app shell noise unless they are the main focus.
        Focus on the main content area, the newest visible response, and the input area around where Return was likely pressed.
        Do not create tasks directly.
        Output markdown only.
        """
    }

    private static func buildPrompt(localMarkdown: String, appName: String, windowTitle: String, trigger: String) -> String {
        """
        这是用户在 macOS 上按下回车时截到的一张屏幕图。

        你的目标不是做 OCR，而是优先根据图片本身理解用户当时正在推进什么。

        规则：
        - 以图片主内容为准
        - 下面附带的 OCR 只是辅助，如果 OCR 和图片冲突，以图片为准
        - 忽略左侧历史聊天、导航栏、菜单栏、浏览器书签栏、系统状态栏等外围干扰
        - 优先关注屏幕中间主内容区、最新一轮对话、输入框附近
        - 不要直接生成 todo / schedule
        - 只做“当前界面在讨论什么 / 用户此刻最可能在推进什么”的整理

        输出格式固定为：
        ## Intent Summary
        - 1 句，概括当前界面在讨论什么

        ## Primary Intent
        - 1-3 条，说明用户此刻最可能在推进的目标

        ## Relevant Content
        - 2-5 条，摘出和主目标最相关的正文内容或结论

        已知信息：
        - App: \(appName)
        - Window: \(windowTitle)
        - Trigger: \(trigger)

        OCR 辅助信息：
        \(localMarkdown)
        """
    }

    private static func normalizedBaseURL(_ url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("/v1") { return trimmed }
        if trimmed.hasSuffix("/") { return trimmed + "v1" }
        return trimmed + "/v1"
    }
}

private enum OCRTextRefiner {
    static func refine(
        localMarkdown: String,
        appName: String,
        windowTitle: String,
        trigger: String,
        settings: PlannerSettings
    ) async throws -> String {
        guard let url = URL(string: normalizedBaseURL(settings.apiBaseURL) + "/chat/completions") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")

        let payload = OCRCleanupRequest(
            model: settings.modelName,
            temperature: 0.1,
            messages: [
                OCRCleanupMessage(role: "system", content: systemPrompt),
                OCRCleanupMessage(
                    role: "user",
                    content: buildPrompt(
                        localMarkdown: localMarkdown,
                        appName: appName,
                        windowTitle: windowTitle,
                        trigger: trigger
                    )
                )
            ]
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            throw URLError(.badServerResponse)
        }

        let completion = try JSONDecoder().decode(OCRCleanupResponse.self, from: data)
        let content = completion.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        guard let content else {
            throw URLError(.cannotParseResponse)
        }
        return content
    }

    private static var systemPrompt: String {
        """
        You are an OCR cleanup assistant.
        Your job is to reorganize noisy screenshot OCR into readable original text.
        Do not infer tasks, todos, or schedules.
        Do not summarize business meaning.
        Do not add facts not present in the OCR.
        Keep only the most meaningful visible content, remove browser chrome/UI noise, merge broken lines into natural Chinese paragraphs.
        Output markdown only.
        """
    }

    private static func buildPrompt(localMarkdown: String, appName: String, windowTitle: String, trigger: String) -> String {
        """
        请把下面这份截图 OCR 原始结果整理成更可读的原始文本。

        要求：
        - 只做 OCR 清洗与重组，不做任务判断，不做待办/日程提取
        - 去掉明显的 UI 噪声：菜单栏、工具栏、书签栏、应用壳层、重复标题、孤立数字、乱码碎片
        - 把明显属于同一段的换行重新拼成自然段
        - 尽量保留用户真正正在看或正在输入/输出的正文内容
        - 如果同时有多块内容，优先保留最核心的 1-3 块正文
        - 不要编造没有出现在 OCR 里的句子
        - 输出格式固定为：
          ## Normalized OCR
          - 第一段
          - 第二段
          - 第三段

        已知信息：
        - App: \(appName)
        - Window: \(windowTitle)
        - Trigger: \(trigger)

        原始 OCR markdown：
        \(localMarkdown)
        """
    }

    private static func normalizedBaseURL(_ url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("/v1") { return trimmed }
        if trimmed.hasSuffix("/") { return trimmed + "v1" }
        return trimmed + "/v1"
    }
}

private struct OCRCleanupRequest: Encodable {
    let model: String
    let temperature: Double
    let messages: [OCRCleanupMessage]
}

private struct OCRCleanupMessage: Encodable {
    let role: String
    let content: String
}

private struct OCRCleanupResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: Message
    }

    struct Message: Decodable {
        let content: String
    }
}

private struct VisionChatCompletionRequest: Encodable {
    let model: String
    let temperature: Double
    let messages: [VisionMessage]
}

private struct VisionMessage: Encodable {
    let role: String
    let content: [VisionContentPart]
}

private struct VisionImagePayload: Encodable {
    let url: String
    let detail: String
}

private struct VisionContentPart: Encodable {
    let type: String
    let text: String?
    let imageURL: VisionImagePayload?

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case imageURL = "image_url"
    }

    static func text(_ value: String) -> VisionContentPart {
        VisionContentPart(type: "text", text: value, imageURL: nil)
    }

    static func imageURL(_ value: String) -> VisionContentPart {
        VisionContentPart(type: "image_url", text: nil, imageURL: VisionImagePayload(url: value, detail: "high"))
    }
}

private struct VisionChatCompletionResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: Message
    }

    struct Message: Decodable {
        let content: VisionMessageContent

        var flattenedContent: String {
            switch content {
            case .string(let value):
                return value
            case .parts(let parts):
                return parts.compactMap(\.text).joined(separator: "\n")
            }
        }
    }
}

private enum VisionMessageContent: Decodable {
    case string(String)
    case parts([VisionMessageContentPart])

    init(from decoder: Decoder) throws {
        let singleValue = try decoder.singleValueContainer()
        if let string = try? singleValue.decode(String.self) {
            self = .string(string)
            return
        }
        self = .parts(try singleValue.decode([VisionMessageContentPart].self))
    }
}

private struct VisionMessageContentPart: Decodable {
    let type: String?
    let text: String?
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var isNoiseLine: Bool {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count < 2 { return true }
        let noisyFragments = [
            "chrome", "google chrome", "finder", "window", "tab", "toolbar", "sidebar",
            "back", "forward", "reload", "search", "url", "address", "bookmark"
        ]
        let lowered = trimmed.lowercased()
        if noisyFragments.contains(where: { lowered == $0 }) {
            return true
        }
        return false
    }
}
