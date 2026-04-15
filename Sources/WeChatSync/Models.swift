import Foundation

enum TargetApp: String, CaseIterable, Identifiable {
    case weChat
    case lark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .weChat:
            return "WeChat"
        case .lark:
            return "Lark"
        }
    }

    var launchButtonTitle: String {
        "Open \(displayName)"
    }

    var statusLabel: String {
        displayName
    }

    var storagePrefix: String {
        switch self {
        case .weChat:
            return "WeChat"
        case .lark:
            return "Lark"
        }
    }

    var sourceName: String {
        rawValue
    }

    var snapshotDepth: Int {
        switch self {
        case .weChat:
            return 10
        case .lark:
            return 14
        }
    }

    var blockedWindowTitles: Set<String> {
        switch self {
        case .weChat:
            return ["wechat"]
        case .lark:
            return ["lark", "feishu", "飞书"]
        }
    }

    var blockedChromeText: [String] {
        switch self {
        case .weChat:
            return [
                "wechat",
                "search",
                "messages",
                "contacts",
                "files",
                "moments",
                "mini programs",
                "phone",
                "video",
                "emoji",
                "sticker",
                "send",
                "typing",
                "搜索",
                "通讯录",
                "文件",
                "发现",
                "看一看",
                "搜一搜",
                "视频号",
                "小程序",
            ]
        case .lark:
            return [
                "lark",
                "feishu",
                "messages",
                "contacts",
                "飞书",
                "消息",
                "云文档",
                "通讯录",
                "日历",
                "邮件",
                "视频会议",
                "搜索",
            ]
        }
    }
}

enum TargetScope: String, CaseIterable, Identifiable {
    case weChat

    var id: String { rawValue }

    var displayName: String {
        "WeChat"
    }

    var statusLabel: String {
        "WeChat"
    }

    var launchButtonTitle: String {
        "Open WeChat"
    }

    var activeApps: [TargetApp] {
        [.weChat]
    }
}

struct CommandLineOptions {
    let command: Command
    let interval: TimeInterval
    let depth: Int
    let verbose: Bool
    let databasePath: String?
    let promptForPermissions: Bool
    let openSettings: Bool
}

enum Command {
    case help
    case doctor
    case setup
    case inspect
    case syncOnce
    case watch
}

struct TextNode: Hashable {
    let role: String
    let text: String
    let minX: Double
    let minY: Double
    let width: Double
    let height: Double

    var maxX: Double { minX + width }
    var maxY: Double { minY + height }
    var midX: Double { minX + (width / 2) }
    var midY: Double { minY + (height / 2) }
}

struct WindowSnapshot {
    let title: String?
    let minX: Double
    let minY: Double
    let width: Double
    let height: Double
    let nodes: [TextNode]

    var maxX: Double { minX + width }
    var maxY: Double { minY + height }
}

struct ConversationRow: Hashable {
    let title: String
    let preview: String
    let minX: Double
    let minY: Double
    let width: Double
    let height: Double

    var midX: Double { minX + (width / 2) }
    var midY: Double { minY + (height / 2) }
    var preferredClickX: Double {
        let textLaneStart = minX + max(72, width * 0.40)
        let textLaneEnd = minX + max(width - 22, 0)
        return min(textLaneEnd, max(textLaneStart, minX + (width * 0.72)))
    }
    var signature: String {
        "\(title.lowercased())|\(preview.lowercased())"
    }
}

struct VisibleMessage {
    let conversationName: String
    let direction: String
    let senderName: String?
    let senderLabel: String
    let recipientLabel: String
    let text: String
    let fingerprint: String
    let source: String
    let capturedAt: Date
}

struct SyncResult {
    let conversationName: String
    let capturedCount: Int
    let insertedMessages: [VisibleMessage]
    let filteredCount: Int
}

struct StoredMessage {
    let conversationName: String
    let direction: String
    let senderLabel: String
    let recipientLabel: String
    let text: String
    let source: String
    let capturedAt: Date
}

struct PrivacyFilter {
    let keywords: [String]

    init(keywords: [String]) {
        self.keywords = keywords
            .map(Self.normalize)
            .filter { !$0.isEmpty }
    }

    var isEmpty: Bool {
        keywords.isEmpty
    }

    func matches(_ text: String) -> Bool {
        let normalized = Self.normalize(text)
        guard !normalized.isEmpty else { return false }
        return keywords.contains { normalized.contains($0) }
    }

    func matches(anyOf texts: [String]) -> Bool {
        texts.contains { matches($0) }
    }

    func shouldBlock(message: VisibleMessage) -> Bool {
        matches(anyOf: [
            message.conversationName,
            message.senderName ?? "",
            message.senderLabel,
            message.recipientLabel,
            message.text,
            message.source,
        ])
    }

    func shouldBlock(row: ConversationRow) -> Bool {
        matches(anyOf: [row.title, row.preview])
    }

    static func normalize(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
    }
}

enum TaskKind: String, CaseIterable, Identifiable, Codable {
    case schedule
    case todo

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .schedule:
            return "Schedule"
        case .todo:
            return "Todo"
        }
    }
}

struct PlannedTask: Identifiable, Hashable, Codable {
    let id: UUID
    let kind: TaskKind
    let title: String
    let details: String
    let conversationName: String
    let sourceMessage: String
    let dueHint: String?
    let confidence: Double
    let createdAt: Date

    init(
        id: UUID = UUID(),
        kind: TaskKind,
        title: String,
        details: String,
        conversationName: String,
        sourceMessage: String,
        dueHint: String?,
        confidence: Double,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.details = details
        self.conversationName = conversationName
        self.sourceMessage = sourceMessage
        self.dueHint = dueHint
        self.confidence = confidence
        self.createdAt = createdAt
    }
}
