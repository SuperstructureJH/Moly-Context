import CryptoKit
import Foundation

struct AppStatus {
    let targetApp: TargetApp
    let accessibilityTrusted: Bool
    let targetAppRunning: Bool
    let detectedAppName: String?
    let bundleIdentifier: String?
    let processIdentifier: Int32?
    let installedPaths: [String]
    let databasePath: String
    let bundlePath: String
    let executablePath: String
    let isDevelopmentBuild: Bool
}

final class SyncEngine {
    let store: MessageStore
    let targetApp: TargetApp

    init(targetApp: TargetApp = .weChat, databasePath: String? = nil) throws {
        self.targetApp = targetApp
        self.store = try MessageStore(path: databasePath)
    }

    static func currentStatus(targetApp: TargetApp, prompt: Bool = false, openSettings: Bool = false, databasePath: String) -> AppStatus {
        let accessibilityTrusted = prompt
            ? AccessibilityReader.requestTrust()
            : AccessibilityReader.isTrusted(prompt: false)

        if openSettings {
            _ = AccessibilityReader.openAccessibilitySettings()
        }

        let runningApp = ChatAppLocator.findRunningApplication(for: targetApp)
        let bundlePath = Bundle.main.bundlePath
        let executablePath = Bundle.main.executablePath ?? ProcessInfo.processInfo.arguments.first ?? "-"
        return AppStatus(
            targetApp: targetApp,
            accessibilityTrusted: accessibilityTrusted,
            targetAppRunning: runningApp != nil,
            detectedAppName: runningApp?.localizedName,
            bundleIdentifier: runningApp?.bundleIdentifier,
            processIdentifier: runningApp?.processIdentifier,
            installedPaths: ChatAppLocator.suggestedApplicationPaths(for: targetApp),
            databasePath: databasePath,
            bundlePath: bundlePath,
            executablePath: executablePath,
            isDevelopmentBuild: bundlePath.contains("/build/") || bundlePath.contains("/Codex/")
        )
    }

    func runSyncOnce(maxDepth: Int = 10, privacyFilter: PrivacyFilter = PrivacyFilter(keywords: [])) throws -> SyncResult {
        let snapshot = try AccessibilityReader.captureSnapshot(targetApp: targetApp, maxDepth: maxDepth)
        let extracted = TranscriptExtractor.extractVisibleMessages(from: snapshot, targetApp: targetApp)
        let allowedMessages = extracted.insertedMessages.filter { !privacyFilter.shouldBlock(message: $0) }
        let inserted = try store.upsert(messages: allowedMessages)
        return SyncResult(
            conversationName: extracted.conversationName,
            capturedCount: extracted.capturedCount,
            insertedMessages: inserted,
            filteredCount: extracted.insertedMessages.count - allowedMessages.count
        )
    }

    func captureSnapshot(maxDepth: Int = 10) throws -> WindowSnapshot {
        try AccessibilityReader.captureSnapshot(targetApp: targetApp, maxDepth: maxDepth)
    }

    func extractConversationRows(from snapshot: WindowSnapshot) -> [ConversationRow] {
        TranscriptExtractor.extractConversationRows(from: snapshot, targetApp: targetApp)
    }

    func currentConversationName(from snapshot: WindowSnapshot) -> String {
        TranscriptExtractor.currentConversationName(from: snapshot, targetApp: targetApp)
    }

    @discardableResult
    func openConversation(_ row: ConversationRow) -> Bool {
        WeChatController.clickConversationRow(row, targetApp: targetApp)
    }

    func recordPreviewEvent(for row: ConversationRow, privacyFilter: PrivacyFilter = PrivacyFilter(keywords: [])) throws -> [VisibleMessage] {
        let preview = row.preview.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !preview.isEmpty else { return [] }

        let conversationName = "\(targetApp.storagePrefix) · \(row.title)"
        let message = VisibleMessage(
            conversationName: conversationName,
            direction: "in",
            senderName: nil,
            senderLabel: row.title,
            recipientLabel: "self",
            text: preview,
            fingerprint: previewFingerprint(conversationName: conversationName, preview: preview),
            source: "\(targetApp.sourceName)-preview",
            capturedAt: Date()
        )
        guard !privacyFilter.shouldBlock(message: message) else { return [] }
        return try store.upsert(messages: [message])
    }

    func recordExternalMessage(
        conversationName: String,
        senderLabel: String,
        recipientLabel: String,
        text: String,
        source: String,
        direction: String = "in",
        privacyFilter: PrivacyFilter = PrivacyFilter(keywords: [])
    ) throws -> [VisibleMessage] {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else { return [] }

        let message = VisibleMessage(
            conversationName: conversationName,
            direction: direction,
            senderName: nil,
            senderLabel: senderLabel,
            recipientLabel: recipientLabel,
            text: normalizedText,
            fingerprint: externalFingerprint(
                conversationName: conversationName,
                direction: direction,
                source: source,
                text: normalizedText
            ),
            source: source,
            capturedAt: Date()
        )
        guard !privacyFilter.shouldBlock(message: message) else { return [] }
        return try store.upsert(messages: [message])
    }

    func fetchRecentMessages(limit: Int) throws -> [StoredMessage] {
        try store.fetchRecentMessages(limit: limit)
    }

    private func previewFingerprint(conversationName: String, preview: String) -> String {
        let normalized = preview
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let input = "preview|\(conversationName)|\(normalized)"
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func externalFingerprint(conversationName: String, direction: String, source: String, text: String) -> String {
        let normalized = text
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let input = "external|\(conversationName)|\(direction)|\(source)|\(normalized)"
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
