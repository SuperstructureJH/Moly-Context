import Foundation

let options = CLI.parse(arguments: CommandLine.arguments)

do {
    switch options.command {
    case .help:
        CLI.printHelp()
    case .doctor:
        try runDoctor(prompt: options.promptForPermissions, openSettings: options.openSettings)
    case .setup:
        try runSetup()
    case .inspect:
        try runInspect(depth: options.depth)
    case .syncOnce:
        try runSyncOnce(databasePath: options.databasePath, verbose: options.verbose)
    case .watch:
        try runWatch(interval: options.interval, databasePath: options.databasePath, verbose: options.verbose)
    }
} catch {
    fputs("Error: \(error.localizedDescription)\n", stderr)
    exit(1)
}

private func runDoctor(prompt: Bool, openSettings: Bool) throws {
    let engine = try SyncEngine()
    let status = SyncEngine.currentStatus(
        prompt: prompt,
        openSettings: openSettings,
        databasePath: engine.store.databasePath
    )

    print("Accessibility trusted: \(status.accessibilityTrusted ? "yes" : "no")")
    print("WeChat running: \(status.weChatRunning ? "yes" : "no")")

    if let appName = status.detectedAppName {
        print("Detected app: \(appName)")
        print("Bundle ID: \(status.bundleIdentifier ?? "Unknown")")
        print("PID: \(status.processIdentifier ?? 0)")
    } else if !status.installedPaths.isEmpty {
        print("Detected app path(s):")
        for path in status.installedPaths {
            print("  \(path)")
        }
    } else {
        print("No common WeChat application path was found.")
    }

    if !status.accessibilityTrusted {
        print("")
        print("Next step:")
        print("  1. In System Settings -> Privacy & Security -> Accessibility,")
        print("     enable your terminal app or this built wechat-sync binary.")
        print("  2. If you do not see it in the list yet, run:")
        print("     bin/wechat-sync setup")
        print("  3. Then rerun:")
        print("     bin/wechat-sync doctor")
    } else {
        print("")
        print("Accessibility permission is ready.")
    }
}

private func runSetup() throws {
    let alreadyTrusted = AccessibilityReader.isTrusted(prompt: false)
    if alreadyTrusted {
        print("Accessibility permission is already granted.")
        return
    }

    let prompted = AccessibilityReader.requestTrust()
    _ = AccessibilityReader.openAccessibilitySettings()

    print("Requested Accessibility permission: \(prompted ? "already granted" : "pending approval")")
    print("System Settings should open to the Accessibility page.")
    print("If the terminal or wechat-sync binary is not listed yet, wait a moment and rerun:")
    print("  bin/wechat-sync setup")
}

private func runInspect(depth: Int) throws {
    let snapshot = try AccessibilityReader.captureSnapshot(maxDepth: depth)
    print("Window title: \(snapshot.title ?? "nil")")
    print("Window frame: x=\(snapshot.minX.rounded()), y=\(snapshot.minY.rounded()), width=\(snapshot.width.rounded()), height=\(snapshot.height.rounded())")
    print("Visible text nodes: \(snapshot.nodes.count)")
    for node in snapshot.nodes {
        let coords = "x=\(Int(node.minX)), y=\(Int(node.minY)), w=\(Int(node.width)), h=\(Int(node.height))"
        print("[\(node.role)] \(coords) -> \(node.text)")
    }
}

private func runSyncOnce(databasePath: String?, verbose: Bool) throws {
    let engine = try SyncEngine(databasePath: databasePath)
    let extracted = try engine.runSyncOnce(maxDepth: 10)

    print("Conversation: \(extracted.conversationName)")
    print("Visible messages captured: \(extracted.capturedCount)")
    print("New rows inserted: \(extracted.insertedMessages.count)")
    print("Database: \(engine.store.databasePath)")

    if verbose {
        for message in extracted.insertedMessages {
            print("[\(message.senderLabel) -> \(message.recipientLabel)] \(message.text)")
        }
    }
}

private func runWatch(interval: TimeInterval, databasePath: String?, verbose: Bool) throws {
    let engine = try SyncEngine(databasePath: databasePath)
    print("Watching WeChat every \(interval)s")
    print("Database: \(engine.store.databasePath)")

    while true {
        do {
            let extracted = try engine.runSyncOnce(maxDepth: 10)
            if !extracted.insertedMessages.isEmpty {
                print("")
                print("[\(timestamp())] \(extracted.conversationName) +\(extracted.insertedMessages.count)")
                if verbose {
                    for message in extracted.insertedMessages {
                        print("  [\(message.senderLabel) -> \(message.recipientLabel)] \(message.text)")
                    }
                }
            }
        } catch AccessibilityError.notTrusted {
            print("[\(timestamp())] Accessibility permission is missing.")
            print("Run: bin/wechat-sync setup")
            break
        } catch AccessibilityError.weChatNotRunning, AccessibilityError.noWindow {
            if verbose {
                print("[\(timestamp())] Waiting for WeChat window...")
            }
        }

        Thread.sleep(forTimeInterval: interval)
    }
}

private func timestamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter.string(from: Date())
}
