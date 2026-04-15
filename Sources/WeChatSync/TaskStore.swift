import Foundation

enum TaskStore {
    static func load(databasePath: String) throws -> [PlannedTask] {
        let url = storageURL(databasePath: databasePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let envelope = try JSONDecoder().decode(TaskEnvelope.self, from: data)
        return envelope.tasks.sorted { $0.createdAt > $1.createdAt }
    }

    static func save(tasks: [PlannedTask], databasePath: String) throws {
        let url = storageURL(databasePath: databasePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let envelope = TaskEnvelope(tasks: tasks.sorted { $0.createdAt > $1.createdAt })
        let data = try JSONEncoder().encode(envelope)
        try data.write(to: url, options: .atomic)
    }

    static func merge(existing: [PlannedTask], incoming: [PlannedTask]) -> TaskMergeResult {
        var byFingerprint: [String: PlannedTask] = [:]

        for task in existing {
            byFingerprint[fingerprint(for: task)] = task
        }

        var addedCount = 0

        for task in incoming {
            let key = fingerprint(for: task)
            if let existingTask = byFingerprint[key] {
                byFingerprint[key] = merge(existing: existingTask, incoming: task)
            } else {
                byFingerprint[key] = task
                addedCount += 1
            }
        }

        let merged = byFingerprint.values.sorted { $0.createdAt > $1.createdAt }
        return TaskMergeResult(tasks: merged, addedCount: addedCount)
    }

    private static func merge(existing: PlannedTask, incoming: PlannedTask) -> PlannedTask {
        PlannedTask(
            id: existing.id,
            kind: existing.kind,
            title: richerText(existing.title, incoming.title),
            details: richerText(existing.details, incoming.details),
            conversationName: richerText(existing.conversationName, incoming.conversationName),
            sourceMessage: richerText(existing.sourceMessage, incoming.sourceMessage),
            dueHint: preferredDueHint(existing.dueHint, incoming.dueHint),
            confidence: max(existing.confidence, incoming.confidence),
            createdAt: existing.createdAt
        )
    }

    private static func richerText(_ lhs: String, _ rhs: String) -> String {
        lhs.count >= rhs.count ? lhs : rhs
    }

    private static func preferredDueHint(_ lhs: String?, _ rhs: String?) -> String? {
        let left = lhs?.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = rhs?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let right, !right.isEmpty { return right }
        if let left, !left.isEmpty { return left }
        return nil
    }

    private static func fingerprint(for task: PlannedTask) -> String {
        [
            task.kind.rawValue,
            normalize(task.title),
            normalize(task.conversationName),
            normalize(task.sourceMessage),
        ].joined(separator: "|")
    }

    private static func normalize(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func storageURL(databasePath: String) -> URL {
        ExportPathResolver.markdownDirectory(databasePath: databasePath)
            .appendingPathComponent("task_loop.json")
    }
}

struct TaskMergeResult {
    let tasks: [PlannedTask]
    let addedCount: Int
}

private struct TaskEnvelope: Codable {
    let tasks: [PlannedTask]
}
