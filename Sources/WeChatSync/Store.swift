import Foundation
import SQLite3

enum StoreError: Error, LocalizedError {
    case openFailed(String)
    case executeFailed(String)
    case prepareFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let message), .executeFailed(let message), .prepareFailed(let message):
            return message
        }
    }
}

final class MessageStore {
    private var database: OpaquePointer?
    let databasePath: String

    init(path: String?) throws {
        self.databasePath = MessageStore.resolveDatabasePath(customPath: path)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: databasePath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if sqlite3_open(databasePath, &database) != SQLITE_OK {
            throw StoreError.openFailed("Failed to open database at \(databasePath)")
        }

        try initializeSchema()
    }

    deinit {
        sqlite3_close(database)
    }

    func upsert(messages: [VisibleMessage]) throws -> [VisibleMessage] {
        let conversationSQL = """
        INSERT INTO conversations(name, last_seen_at)
        VALUES(?, ?)
        ON CONFLICT(name) DO UPDATE SET last_seen_at = excluded.last_seen_at;
        """

        let messageSQL = """
        INSERT INTO messages(
            conversation_name,
            direction,
            sender_name,
            sender_label,
            recipient_label,
            text,
            fingerprint,
            source,
            captured_at,
            observed_at
        )
        VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(conversation_name, fingerprint) DO NOTHING;
        """

        var inserted: [VisibleMessage] = []
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            for message in messages {
                let timestamp = iso8601(message.capturedAt)
                _ = try bindAndStep(sql: conversationSQL) { statement in
                    sqlite3_bind_text(statement, 1, message.conversationName, -1, transientDestructor)
                    sqlite3_bind_text(statement, 2, timestamp, -1, transientDestructor)
                }

                let changed = try bindAndStep(sql: messageSQL) { statement in
                    sqlite3_bind_text(statement, 1, message.conversationName, -1, transientDestructor)
                    sqlite3_bind_text(statement, 2, message.direction, -1, transientDestructor)
                    if let senderName = message.senderName {
                        sqlite3_bind_text(statement, 3, senderName, -1, transientDestructor)
                    } else {
                        sqlite3_bind_null(statement, 3)
                    }
                    sqlite3_bind_text(statement, 4, message.senderLabel, -1, transientDestructor)
                    sqlite3_bind_text(statement, 5, message.recipientLabel, -1, transientDestructor)
                    sqlite3_bind_text(statement, 6, message.text, -1, transientDestructor)
                    sqlite3_bind_text(statement, 7, message.fingerprint, -1, transientDestructor)
                    sqlite3_bind_text(statement, 8, message.source, -1, transientDestructor)
                    sqlite3_bind_text(statement, 9, timestamp, -1, transientDestructor)
                    sqlite3_bind_text(statement, 10, iso8601(Date()), -1, transientDestructor)
                }

                if changed > 0 {
                    inserted.append(message)
                }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }

        try MarkdownExporter.export(messages: inserted, baseDirectory: databasePath)
        return inserted
    }

    func fetchRecentMessages(limit: Int) throws -> [StoredMessage] {
        let sql = """
        SELECT conversation_name, direction, sender_label, recipient_label, text, source, captured_at
        FROM messages
        ORDER BY datetime(captured_at) DESC, id DESC
        LIMIT ?;
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.prepareFailed(lastErrorMessage)
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int(statement, 1, Int32(limit))

        var messages: [StoredMessage] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let conversationName = stringColumn(statement, index: 0)
            let direction = stringColumn(statement, index: 1)
            let senderLabel = stringColumn(statement, index: 2)
            let recipientLabel = stringColumn(statement, index: 3)
            let text = stringColumn(statement, index: 4)
            let source = stringColumn(statement, index: 5)
            let capturedAt = dateColumn(statement, index: 6) ?? Date()

            messages.append(
                StoredMessage(
                    conversationName: conversationName,
                    direction: direction,
                    senderLabel: senderLabel,
                    recipientLabel: recipientLabel,
                    text: text,
                    source: source,
                    capturedAt: capturedAt
                )
            )
        }

        return messages
    }

    private func initializeSchema() throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS conversations(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL UNIQUE,
                last_seen_at TEXT NOT NULL
            );
            """
        )

        try execute(
            """
            CREATE TABLE IF NOT EXISTS messages(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                conversation_name TEXT NOT NULL,
                direction TEXT NOT NULL,
                sender_name TEXT,
                sender_label TEXT NOT NULL DEFAULT '',
                recipient_label TEXT NOT NULL DEFAULT '',
                text TEXT NOT NULL,
                fingerprint TEXT NOT NULL,
                source TEXT NOT NULL,
                captured_at TEXT NOT NULL,
                observed_at TEXT NOT NULL,
                UNIQUE(conversation_name, fingerprint)
            );
            """
        )

        try ensureColumnExists(
            table: "messages",
            column: "sender_label",
            definition: "TEXT NOT NULL DEFAULT ''"
        )
        try ensureColumnExists(
            table: "messages",
            column: "recipient_label",
            definition: "TEXT NOT NULL DEFAULT ''"
        )
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw StoreError.executeFailed(lastErrorMessage)
        }
    }

    private func ensureColumnExists(table: String, column: String, definition: String) throws {
        let existingColumns = try tableColumns(table: table)
        guard !existingColumns.contains(column) else { return }
        try execute("ALTER TABLE \(table) ADD COLUMN \(column) \(definition);")
    }

    private func tableColumns(table: String) throws -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table));", -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.prepareFailed(lastErrorMessage)
        }
        defer { sqlite3_finalize(statement) }

        var columns = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let namePointer = sqlite3_column_text(statement, 1) {
                columns.insert(String(cString: namePointer))
            }
        }
        return columns
    }

    private func bindAndStep(sql: String, binder: (OpaquePointer?) -> Void) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.prepareFailed(lastErrorMessage)
        }
        defer { sqlite3_finalize(statement) }

        binder(statement)
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else {
            throw StoreError.executeFailed(lastErrorMessage)
        }
        return Int(sqlite3_changes(database))
    }

    private var lastErrorMessage: String {
        if let message = sqlite3_errmsg(database) {
            return String(cString: message)
        }
        return "Unknown SQLite error"
    }

    private static func resolveDatabasePath(customPath: String?) -> String {
        if let customPath, !customPath.isEmpty {
            return NSString(string: customPath).expandingTildeInPath
        }

        return "\(NSHomeDirectory())/Library/Application Support/WeChatSyncMVP/wechat_sync.sqlite3"
    }

    private func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func stringColumn(_ statement: OpaquePointer?, index: Int32) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: value)
    }

    private func dateColumn(_ statement: OpaquePointer?, index: Int32) -> Date? {
        let stringValue = stringColumn(statement, index: index)
        guard !stringValue.isEmpty else { return nil }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: stringValue) ?? ISO8601DateFormatter().date(from: stringValue)
    }
}

private let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
