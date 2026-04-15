import Foundation

enum ExportPathResolver {
    static func exportRootDirectory(databasePath: String) -> URL {
        if let configured = overrideRootDirectory() {
            return configured
        }
        return defaultRootDirectory()
    }

    static func markdownDirectory(databasePath: String) -> URL {
        exportRootDirectory(databasePath: databasePath)
            .appendingPathComponent("markdown", isDirectory: true)
    }

    static func intentCaptureRootDirectory(databasePath: String) -> URL {
        exportRootDirectory(databasePath: databasePath)
            .appendingPathComponent("intent-captures", isDirectory: true)
    }

    static func screenshotsRootDirectory(databasePath: String) -> URL {
        exportRootDirectory(databasePath: databasePath)
            .appendingPathComponent("screenshots", isDirectory: true)
    }

    static func logsDirectory(databasePath: String) -> URL {
        exportRootDirectory(databasePath: databasePath)
            .appendingPathComponent("logs", isDirectory: true)
    }

    static func crashReportsDirectory(databasePath: String) -> URL {
        exportRootDirectory(databasePath: databasePath)
            .appendingPathComponent("crash-reports", isDirectory: true)
    }

    static func intentScreenshotsDirectory(databasePath: String, capturedAt: Date) -> URL {
        screenshotsRootDirectory(databasePath: databasePath)
            .appendingPathComponent(screenshotBucketName(for: capturedAt), isDirectory: true)
    }

    static func intentMarkdownDirectory(databasePath: String) -> URL {
        intentCaptureRootDirectory(databasePath: databasePath)
            .appendingPathComponent("markdown", isDirectory: true)
    }

    private static func overrideRootDirectory() -> URL? {
        if let configuredPath = Bundle.main.object(forInfoDictionaryKey: "MolyExportRootPath") as? String {
            let expanded = NSString(string: configuredPath).expandingTildeInPath
            let trimmed = expanded.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return URL(fileURLWithPath: trimmed, isDirectory: true)
            }
        }
        return nil
    }

    private static func defaultRootDirectory() -> URL {
        if let applicationSupportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return applicationSupportDirectory.appendingPathComponent("Moly Context Hub", isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Moly Context Hub", isDirectory: true)
    }

    private static func screenshotBucketName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH"
        return formatter.string(from: date)
    }

    static func migrateLegacyHiddenIntentArtifacts(databasePath: String) {
        let fileManager = FileManager.default
        let currentRoot = exportRootDirectory(databasePath: databasePath)
        try? fileManager.createDirectory(at: currentRoot, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: markdownDirectory(databasePath: databasePath), withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: intentCaptureRootDirectory(databasePath: databasePath), withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: screenshotsRootDirectory(databasePath: databasePath), withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: intentMarkdownDirectory(databasePath: databasePath), withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: logsDirectory(databasePath: databasePath), withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: crashReportsDirectory(databasePath: databasePath), withIntermediateDirectories: true)

        for legacyRoot in legacyRootDirectories(databasePath: databasePath) {
            guard legacyRoot.path != currentRoot.path else { continue }
            mergeDirectoryContents(
                from: legacyRoot.appendingPathComponent("markdown", isDirectory: true),
                to: currentRoot.appendingPathComponent("markdown", isDirectory: true)
            )
            mergeDirectoryContents(
                from: legacyRoot.appendingPathComponent("screenshots", isDirectory: true),
                to: currentRoot.appendingPathComponent("screenshots", isDirectory: true)
            )
            mergeDirectoryContents(
                from: legacyRoot.appendingPathComponent("intent-captures", isDirectory: true),
                to: currentRoot.appendingPathComponent("intent-captures", isDirectory: true)
            )
        }

        let screenshotsRoot = screenshotsRootDirectory(databasePath: databasePath)
        if let bucketDirectories = try? fileManager.contentsOfDirectory(
            at: screenshotsRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            for bucketDirectory in bucketDirectories {
                guard let values = try? bucketDirectory.resourceValues(forKeys: [.isDirectoryKey]),
                      values.isDirectory == true else {
                    continue
                }
                if let hiddenFiles = try? fileManager.contentsOfDirectory(
                    at: bucketDirectory,
                    includingPropertiesForKeys: [.contentModificationDateKey],
                    options: [.skipsSubdirectoryDescendants]
                ) {
                    for fileURL in hiddenFiles where fileURL.lastPathComponent.hasPrefix(".") && fileURL.pathExtension.lowercased() == "png" {
                        let modifiedAt = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                        let targetURL = bucketDirectory.appendingPathComponent(legacyIntentScreenshotFileName(for: modifiedAt))
                        if !fileManager.fileExists(atPath: targetURL.path) {
                            try? fileManager.moveItem(at: fileURL, to: targetURL)
                        }
                    }
                }
            }
        }

        let legacyScreenshotRoot = intentCaptureRootDirectory(databasePath: databasePath)
            .appendingPathComponent("screenshots", isDirectory: true)
        if let legacyFiles = try? fileManager.contentsOfDirectory(
            at: legacyScreenshotRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for fileURL in legacyFiles {
                let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
                guard values?.isDirectory != true else { continue }
                let modifiedAt = values?.contentModificationDate ?? Date()
                let targetDirectory = intentScreenshotsDirectory(databasePath: databasePath, capturedAt: modifiedAt)
                try? fileManager.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
                let targetURL = targetDirectory.appendingPathComponent(legacyIntentScreenshotFileName(for: modifiedAt))
                if !fileManager.fileExists(atPath: targetURL.path) {
                    try? fileManager.moveItem(at: fileURL, to: targetURL)
                }
            }
        }

        let intentMarkdownRoot = intentMarkdownDirectory(databasePath: databasePath)
        if let hiddenFiles = try? fileManager.contentsOfDirectory(
            at: intentMarkdownRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsSubdirectoryDescendants]
        ) {
            for fileURL in hiddenFiles where fileURL.lastPathComponent.hasPrefix(".") && fileURL.pathExtension.lowercased() == "md" {
                let modifiedAt = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                let targetURL = intentMarkdownRoot.appendingPathComponent(legacyIntentMarkdownFileName(for: modifiedAt))
                if !fileManager.fileExists(atPath: targetURL.path) {
                    try? fileManager.moveItem(at: fileURL, to: targetURL)
                }
            }
        }
    }

    private static func legacyIntentScreenshotFileName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        return "intent-" + formatter.string(from: date) + ".png"
    }

    private static func legacyIntentMarkdownFileName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH"
        return "intent-" + formatter.string(from: date) + ".md"
    }

    private static func legacyRootDirectories(databasePath: String) -> [URL] {
        var roots: [URL] = []

        let databaseRoot = URL(fileURLWithPath: databasePath, isDirectory: false).deletingLastPathComponent()
        roots.append(databaseRoot)

        if let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            roots.append(documentsDirectory.appendingPathComponent("Moly Context Hub", isDirectory: true))
        } else {
            roots.append(
                URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                    .appendingPathComponent("Documents", isDirectory: true)
                    .appendingPathComponent("Moly Context Hub", isDirectory: true)
            )
        }

        if let legacyConfiguredPath = Bundle.main.object(forInfoDictionaryKey: "MolyMarkdownExportPath") as? String {
            let expanded = NSString(string: legacyConfiguredPath).expandingTildeInPath
            let trimmed = expanded.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                roots.append(URL(fileURLWithPath: trimmed, isDirectory: true).deletingLastPathComponent())
            }
        }

        var uniqueRoots: [URL] = []
        for root in roots {
            if !uniqueRoots.contains(where: { $0.path == root.path }) {
                uniqueRoots.append(root)
            }
        }
        return uniqueRoots
    }

    private static func mergeDirectoryContents(from source: URL, to destination: URL) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: source.path) else { return }

        try? fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        guard let enumerator = fileManager.enumerator(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for case let itemURL as URL in enumerator {
            let relativePath = itemURL.path.replacingOccurrences(of: source.path + "/", with: "")
            let destinationURL = destination.appendingPathComponent(relativePath)
            let values = try? itemURL.resourceValues(forKeys: [.isDirectoryKey])

            if values?.isDirectory == true {
                try? fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
                continue
            }

            try? fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard !fileManager.fileExists(atPath: destinationURL.path) else { continue }
            try? fileManager.moveItem(at: itemURL, to: destinationURL)
        }
    }
}
