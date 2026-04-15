import Foundation

actor SyncWorker {
    private let engine: SyncEngine

    init(targetApp: TargetApp = .weChat, databasePath: String? = nil) throws {
        self.engine = try SyncEngine(targetApp: targetApp, databasePath: databasePath)
    }

    var resolvedDatabasePath: String {
        engine.store.databasePath
    }

    func runSyncOnce(maxDepth: Int = 10, privacyFilter: PrivacyFilter = PrivacyFilter(keywords: [])) throws -> SyncResult {
        try engine.runSyncOnce(maxDepth: maxDepth, privacyFilter: privacyFilter)
    }

    func captureSnapshot(maxDepth: Int = 10) throws -> WindowSnapshot {
        try engine.captureSnapshot(maxDepth: maxDepth)
    }

    func extractConversationRows(from snapshot: WindowSnapshot) -> [ConversationRow] {
        engine.extractConversationRows(from: snapshot)
    }

    func currentConversationName(from snapshot: WindowSnapshot) -> String {
        engine.currentConversationName(from: snapshot)
    }

    @discardableResult
    func openConversation(_ row: ConversationRow) -> Bool {
        engine.openConversation(row)
    }

    func recordPreviewEvent(for row: ConversationRow, privacyFilter: PrivacyFilter = PrivacyFilter(keywords: [])) throws -> [VisibleMessage] {
        try engine.recordPreviewEvent(for: row, privacyFilter: privacyFilter)
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
        try engine.recordExternalMessage(
            conversationName: conversationName,
            senderLabel: senderLabel,
            recipientLabel: recipientLabel,
            text: text,
            source: source,
            direction: direction,
            privacyFilter: privacyFilter
        )
    }

    func fetchRecentMessages(limit: Int) throws -> [StoredMessage] {
        try engine.fetchRecentMessages(limit: limit)
    }
}
