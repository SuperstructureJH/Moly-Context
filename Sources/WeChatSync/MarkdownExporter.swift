import Foundation

enum MarkdownExporter {
    static func export(messages: [VisibleMessage], baseDirectory: String) throws {
        guard !messages.isEmpty else { return }

        let rootURL = ExportPathResolver.markdownDirectory(databasePath: baseDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let grouped = Dictionary(grouping: messages, by: bucketStart(for:))
        for (bucketStartDate, bucketMessages) in grouped {
            let fileURL = rootURL.appendingPathComponent(fileName(for: bucketStartDate))
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                let header = """
                # WeChat Messages

                Window: \(bucketLabel(for: bucketStartDate))

                """
                try header.write(to: fileURL, atomically: true, encoding: .utf8)
            }

            let body = bucketMessages
                .sorted { $0.capturedAt < $1.capturedAt }
                .map(markdownBlock(for:))
                .joined(separator: "\n")

            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            if let data = body.data(using: .utf8) {
                try handle.write(contentsOf: data)
            }
        }
    }

    @discardableResult
    static func exportWeChatReview(messages: [StoredMessage], baseDirectory: String) throws -> String {
        let rootURL = ExportPathResolver.markdownDirectory(databasePath: baseDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let outputURL = rootURL.appendingPathComponent("wechat-review-latest.md")
        let wechatMessages = messages
            .filter { $0.source.hasPrefix(TargetApp.weChat.sourceName) }
            .sorted { $0.capturedAt > $1.capturedAt }

        let content = buildWeChatReviewMarkdown(messages: Array(wechatMessages.prefix(120)))
        try content.write(to: outputURL, atomically: true, encoding: .utf8)
        return outputURL.path
    }

    private static func markdownBlock(for message: VisibleMessage) -> String {
        """
        ## \(timestamp(message.capturedAt))
        - conversation: \(message.conversationName)
        - direction: \(message.direction)
        - from: \(message.senderLabel)
        - to: \(message.recipientLabel)
        - source: \(message.source)

        \(message.text)

        """
    }

    private static func bucketStart(for message: VisibleMessage) -> Date {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day, .hour], from: message.capturedAt)
        let hour = components.hour ?? 0
        let bucketHour = (hour / 2) * 2

        var normalized = DateComponents()
        normalized.year = components.year
        normalized.month = components.month
        normalized.day = components.day
        normalized.hour = bucketHour
        normalized.minute = 0
        normalized.second = 0
        return calendar.date(from: normalized) ?? message.capturedAt
    }

    private static func fileName(for bucketStartDate: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH"
        return "messages-" + formatter.string(from: bucketStartDate) + ".md"
    }

    private static func bucketLabel(for bucketStartDate: Date) -> String {
        let calendar = Calendar.current
        let bucketEndDate = calendar.date(byAdding: .hour, value: 2, to: bucketStartDate) ?? bucketStartDate

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "\(formatter.string(from: bucketStartDate)) - \(formatter.string(from: bucketEndDate))"
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private static func buildWeChatReviewMarkdown(messages: [StoredMessage]) -> String {
        var lines: [String] = [
            "# WeChat Review",
            "",
            "Updated: \(timestamp(Date()))",
            "Messages: \(messages.count)",
            "",
        ]

        if messages.isEmpty {
            lines.append("No WeChat messages yet.")
            lines.append("")
            return lines.joined(separator: "\n")
        }

        for message in messages {
            lines.append("## \(timestamp(message.capturedAt))")
            lines.append("- conversation: \(message.conversationName)")
            lines.append("- direction: \(message.direction)")
            lines.append("- from: \(message.senderLabel)")
            lines.append("- to: \(message.recipientLabel)")
            lines.append("- source: \(message.source)")
            lines.append("")
            lines.append("```text")
            lines.append(message.text)
            lines.append("```")
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }
}
