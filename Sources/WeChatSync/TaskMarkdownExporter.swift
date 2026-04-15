import Foundation

enum TaskMarkdownExporter {
    static func export(tasks: [PlannedTask], databasePath: String) throws -> String {
        let rootURL = ExportPathResolver.markdownDirectory(databasePath: databasePath)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let outputURL = rootURL.appendingPathComponent("moly_tasks.md")
        let content = buildMarkdown(tasks: tasks)
        try content.write(to: outputURL, atomically: true, encoding: .utf8)
        return outputURL.path
    }

    private static func buildMarkdown(tasks: [PlannedTask]) -> String {
        let grouped = Dictionary(grouping: tasks, by: \.kind)
        let schedules = grouped[.schedule, default: []]
        let todos = grouped[.todo, default: []]

        return """
        # Moly Action Brief

        Updated: \(timestamp(Date()))
        Window: Last 1 hour

        Overview:
        - schedule: \(schedules.count)
        - todo: \(todos.count)

        ## Schedule

        \(render(tasks: schedules))

        ## Todo

        \(render(tasks: todos))
        """
    }

    private static func render(tasks: [PlannedTask]) -> String {
        guard !tasks.isEmpty else { return "- None\n" }

        return tasks.map { task in
            var lines = [
                "### \(task.title)",
                "- source: \(task.conversationName)",
                "- confidence: \(String(format: "%.2f", task.confidence))",
            ]
            if let dueHint = task.dueHint, !dueHint.isEmpty {
                lines.append("- due: \(dueHint)")
            }
            if !task.details.isEmpty {
                lines.append("- why: \(task.details.replacingOccurrences(of: "\n", with: " "))")
            }
            if !task.sourceMessage.isEmpty {
                lines.append("- evidence: \(task.sourceMessage.replacingOccurrences(of: "\n", with: " "))")
            }
            return lines.joined(separator: "\n")
        }
        .joined(separator: "\n\n")
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}
