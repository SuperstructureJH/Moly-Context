import AppKit
import ApplicationServices
import Foundation
import SwiftUI

@MainActor
final class WeChatSyncAppModel: ObservableObject {
    @Published var plannerAPIBaseURL = ""
    @Published var plannerAPIKey = ""
    @Published var plannerModelName = "gpt-4.1-mini"
    @Published var plannerStatus = "Tasks are ready to generate"
    @Published var plannedTasks: [PlannedTask] = []
    @Published var autoTaskPlanningEnabled = false {
        didSet {
            persistAutoPlannerSettings()
            configureAutoTaskPlanning()
        }
    }
    @Published var autoTaskPlanningIntervalMinutes = 10.0 {
        didSet {
            persistAutoPlannerSettings()
            configureAutoTaskPlanning()
        }
    }
    @Published var privacyKeywordDraft = ""
    @Published var privacyBlockedKeywords: [String] = []
    @Published var tasksMarkdownPath = "-"
    @Published var intentCaptureMarkdownPath = "-"
    @Published var latestMessagesMarkdownPath = "-"
    @Published var latestWeChatReviewMarkdownPath = "-"
    @Published var latestScreenshotMarkdownPath = "-"
    @Published var intentCaptureDirectoryPath = "-"
    @Published var exportRootPath = "-"
    @Published var crashReportPath = "-"
    @Published var appVersionText = "-"
    @Published var targetScope: TargetScope = .weChat
    @Published var accessibilityTrusted = false
    @Published var screenCaptureTrusted = false
    @Published var targetAppRunning = false
    @Published var detectedAppName = "Not detected"
    @Published var bundleIdentifier = "-"
    @Published var bundlePath = "-"
    @Published var executablePath = "-"
    @Published var isDevelopmentBuild = false
    @Published var installedPaths: [String] = []
    @Published var databasePath = "-"
    @Published var chromeBridgeStatus = "Starting"
    @Published var chromeExtensionPath = "-"
    @Published var enterKeySensorEnabled = false {
        didSet {
            configureEnterKeySensor()
            persistSensorSettings()
        }
    }
    @Published var isWatching = false
    @Published var intervalSeconds = 5.0
    @Published var frontmostContextEnabled = true
    @Published var foregroundAssistEnabled = true
    @Published var idleAutoOpenEnabled = false
    @Published var idleThresholdMinutes = 5.0
    @Published var currentIdleSeconds = 0.0
    @Published var pendingConversationTitles: [String] = []
    @Published var pendingConversationSummaries: [String] = []
    @Published var lastConversation = "-"
    @Published var lastSyncSummary = "No sync yet"
    @Published var lastContextSummary = "No context yet"
    @Published var lastIntentSummary = "No intent capture yet"
    @Published var intentFeedbackMessage: String?
    @Published var intentFeedbackIsError = false
    @Published var statusHeadline = "Ready"
    @Published var activityScope: TargetScope = .weChat
    @Published var activityEntries: [ActivityEntry] = []
    @Published var logText = ""
    @Published var startupError: String?

    private var workers: [TargetApp: SyncWorker] = [:]
    private var watchTask: Task<Void, Never>?
    private var workspaceObserver: NSObjectProtocol?
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var eventTap: CFMachPort?
    private var eventTapRunLoopSource: CFRunLoopSource?
    private var chromeExtensionBridge: ChromeExtensionBridge?
    private var lastObservedRowsByApp: [TargetApp: [ConversationRow]] = [:]
    private var pendingConversations: [PendingConversation] = []
    private var lastContextApplication: NSRunningApplication?
    private var lastFrontmostContextFingerprint: String?
    private var lastFrontmostContextCaptureAt: Date?
    private var lastEnterCaptureAt: Date?
    private var lastWatchSyncAt: Date?
    private var lastStatusRefreshAt: Date?
    private var autoTaskPlanningTask: Task<Void, Never>?
    private var isIntentCaptureInFlight = false
    private var intentFeedbackDismissTask: Task<Void, Never>?
    private let plannerAPIBaseURLKey = "moly.planner.api_base_url"
    private let plannerAPIKeyKey = "moly.planner.api_key"
    private let plannerModelNameKey = "moly.planner.model_name"
    private let autoTaskPlanningEnabledKey = "moly.planner.auto_enabled"
    private let autoTaskPlanningIntervalKey = "moly.planner.auto_interval_minutes"
    private let enterKeySensorEnabledKey = "moly.sensor.enter_key_capture_enabled"
    private let privacyBlockedKeywordsKey = "moly.privacy.blocked_keywords"
    private let maxActivityEntries = 240
    private let statusRefreshInterval: TimeInterval = 12
    private var watchSyncInterval: TimeInterval { max(3, intervalSeconds) }
    private var frontmostContextInterval: TimeInterval { max(6, intervalSeconds * 1.2) }

    init() {
        configureCrashReporter(rootURL: ExportPathResolver.exportRootDirectory(databasePath: databasePath))
        appVersionText = Self.resolveAppVersion()
        loadPlannerSettings()
        loadPrivacySettings()
        loadSensorSettings()
        observeWorkspaceActivation()
        rebuildWorkers()
        configureEnterKeySensor()
        configureChromeExtensionBridge()
        configureAutoTaskPlanning()
        appendLog("App initialized.")
    }

    deinit {
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
        }
        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
        }
        if let eventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapRunLoopSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        autoTaskPlanningTask?.cancel()
        chromeExtensionBridge?.stop()
    }

    func setTargetScope(_ targetScope: TargetScope) {
        guard self.targetScope != targetScope else { return }
        stopWatching()
        self.targetScope = targetScope
        lastObservedRowsByApp = [:]
        pendingConversations = []
        refreshPendingPresentation()
        appendLog("Switched target to \(targetScope.displayName).")
        refreshStatus(force: true)
    }

    func refreshStatus(prompt: Bool = false, openSettings: Bool = false, force: Bool = false) {
        if !force,
           let lastStatusRefreshAt,
           Date().timeIntervalSince(lastStatusRefreshAt) < statusRefreshInterval {
            return
        }
        let apps = targetScope.activeApps
        let statuses = apps.enumerated().map { index, app in
            SyncEngine.currentStatus(
                targetApp: app,
                prompt: prompt && index == 0,
                openSettings: openSettings && index == 0,
                databasePath: databasePath
            )
        }
        guard let primaryStatus = statuses.first else { return }

        accessibilityTrusted = statuses.allSatisfy(\.accessibilityTrusted)
        let runningCount = statuses.filter(\.targetAppRunning).count
        targetAppRunning = runningCount > 0
        detectedAppName = statuses.compactMap(\.detectedAppName).joined(separator: ", ").nilIfEmpty ?? "Not detected"
        bundleIdentifier = statuses.compactMap(\.bundleIdentifier).joined(separator: ", ").nilIfEmpty ?? "-"
        bundlePath = primaryStatus.bundlePath
        executablePath = primaryStatus.executablePath
        isDevelopmentBuild = primaryStatus.isDevelopmentBuild
        installedPaths = Array(Set(statuses.flatMap(\.installedPaths))).sorted()
        databasePath = primaryStatus.databasePath
        screenCaptureTrusted = IntentCaptureSupport.screenCapturePermissionGranted()
        latestMessagesMarkdownPath = Self.resolveLatestMessagesMarkdownPath(databasePath: databasePath)
        latestScreenshotMarkdownPath = Self.resolveLatestScreenshotMarkdownPath(databasePath: databasePath)
        intentCaptureMarkdownPath = Self.resolveLatestIntentMarkdownPath(databasePath: databasePath)

        if !accessibilityTrusted {
            statusHeadline = "Accessibility permission required"
        } else if targetAppRunning {
            statusHeadline = frontmostContextEnabled ? "Ready to sync WeChat + Context" : "Ready to sync \(targetScope.displayName)"
        } else {
            statusHeadline = frontmostContextEnabled ? "WeChat offline, context capture still available" : "Waiting for \(targetScope.displayName)"
        }

        if isDevelopmentBuild && !accessibilityTrusted {
            statusHeadline = "Grant permission to the installed app copy"
        }

        lastStatusRefreshAt = Date()
    }

    func setupPermissions() {
        appendLog("Requesting Accessibility permission and opening System Settings.")
        refreshStatus(prompt: true, openSettings: true, force: true)
        screenCaptureTrusted = IntentCaptureSupport.screenCapturePermissionGranted()
        if enterKeySensorEnabled && !screenCaptureTrusted {
            let requested = IntentCaptureSupport.requestScreenCapturePermission()
            screenCaptureTrusted = requested || IntentCaptureSupport.screenCapturePermissionGranted()
            appendLog(
                screenCaptureTrusted
                    ? "Screen Recording permission is granted."
                    : "Enable Moly Context Hub in Privacy & Security -> Screen Recording for the enter-key sensor.",
                isIntent: true
            )
        }
        if accessibilityTrusted {
            appendLog("Accessibility permission is already granted.")
        } else {
            appendLog("Enable Moly Context Hub or your terminal in Privacy & Security -> Accessibility.")
        }
    }

    func openScreenRecordingSettings() {
        let opened = AccessibilityReader.openScreenRecordingSettings()
        appendLog(opened
            ? "Opened Screen Recording settings."
            : "Could not open Screen Recording settings automatically.",
            isIntent: true)
    }

    func relaunchApp() {
        let bundleURL = Bundle.main.bundleURL
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [bundleURL.path]

        do {
            try process.run()
            appendLog("Reopening Moly Context Hub so new permissions can fully take effect.")
            NSApp.terminate(nil)
        } catch {
            appendLog("Could not relaunch the app automatically: \(error.localizedDescription)")
        }
    }

    func persistPlannerSettings() {
        let defaults = UserDefaults.standard
        defaults.set(plannerAPIBaseURL, forKey: plannerAPIBaseURLKey)
        defaults.set(plannerAPIKey, forKey: plannerAPIKeyKey)
        defaults.set(plannerModelName, forKey: plannerModelNameKey)
        defaults.set(autoTaskPlanningEnabled, forKey: autoTaskPlanningEnabledKey)
        defaults.set(autoTaskPlanningIntervalMinutes, forKey: autoTaskPlanningIntervalKey)
        appendLog("Saved planner settings.")
    }

    func addPrivacyKeyword() {
        let keyword = privacyKeywordDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }

        let normalized = PrivacyFilter.normalize(keyword)
        let existing = Set(privacyBlockedKeywords.map(PrivacyFilter.normalize))
        guard !existing.contains(normalized) else {
            privacyKeywordDraft = ""
            appendLog("Privacy filter already contains \(keyword).")
            return
        }

        privacyBlockedKeywords.append(keyword)
        privacyBlockedKeywords.sort { PrivacyFilter.normalize($0) < PrivacyFilter.normalize($1) }
        privacyKeywordDraft = ""
        persistPrivacySettings()
        refreshPendingPresentation()
        appendLog("Added privacy filter keyword: \(keyword).")
    }

    func removePrivacyKeyword(_ keyword: String) {
        let normalized = PrivacyFilter.normalize(keyword)
        privacyBlockedKeywords.removeAll { PrivacyFilter.normalize($0) == normalized }
        persistPrivacySettings()
        refreshPendingPresentation()
        appendLog("Removed privacy filter keyword: \(keyword).")
    }

    func clearPrivacyKeywords() {
        guard !privacyBlockedKeywords.isEmpty else { return }
        privacyBlockedKeywords = []
        persistPrivacySettings()
        refreshPendingPresentation()
        appendLog("Cleared all privacy filter keywords.")
    }

    func planTasksFromRecentMessages() {
        Task { [weak self] in
            await self?.performTaskPlanning()
        }
    }

    func openAccessibilitySettings() {
        let opened = AccessibilityReader.openAccessibilitySettings()
        appendLog(opened
            ? "Opened Accessibility settings."
            : "Could not open Accessibility settings automatically.")
    }

    func runSyncOnce() {
        guard !workers.isEmpty else { return }
        Task { [weak self] in
            await self?.performSyncOnce(reason: "manual")
        }
    }

    func captureFrontmostContextNow() {
        Task { [weak self] in
            await self?.captureFrontmostContext(reason: "manual")
        }
    }

    func toggleWatching() {
        isWatching ? stopWatching() : startWatching()
    }

    func revealDatabase() {
        guard databasePath != "-" else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: databasePath)])
    }

    func revealExportRoot() {
        guard exportRootPath != "-" else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: exportRootPath)])
    }

    func revealTasksMarkdown() {
        guard tasksMarkdownPath != "-" else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: tasksMarkdownPath)])
    }

    func revealLatestMessagesMarkdown() {
        guard latestMessagesMarkdownPath != "-" else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: latestMessagesMarkdownPath)])
    }

    func revealLatestWeChatReviewMarkdown() {
        guard latestWeChatReviewMarkdownPath != "-" else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: latestWeChatReviewMarkdownPath)])
    }

    func revealLatestScreenshotMarkdown() {
        guard latestScreenshotMarkdownPath != "-" else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: latestScreenshotMarkdownPath)])
    }

    func revealIntentCaptures() {
        guard intentCaptureDirectoryPath != "-" else { return }
        let latestScreenshot = Self.resolveLatestScreenshotPath(databasePath: databasePath)
        if latestScreenshot != "-" {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: latestScreenshot)])
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: intentCaptureDirectoryPath)])
    }

    func revealCrashReports() {
        if crashReportPath != "-", FileManager.default.fileExists(atPath: crashReportPath) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: crashReportPath)])
            return
        }

        let directory = ExportPathResolver.crashReportsDirectory(databasePath: databasePath)
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }

    func filePreview(at path: String, maxCharacters: Int = 5000) -> String {
        guard path != "-", FileManager.default.fileExists(atPath: path) else {
            return "No file yet."
        }
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return "Could not read file."
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxCharacters else { return trimmed }
        let endIndex = trimmed.index(trimmed.startIndex, offsetBy: maxCharacters)
        return String(trimmed[..<endIndex]) + "\n\n..."
    }

    func revealChromeExtension() {
        guard chromeExtensionPath != "-" else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: chromeExtensionPath)])
    }

    func openWeChat() {
        let workspace = NSWorkspace.shared
        var openedApps: [String] = []

        for appTarget in targetScope.activeApps {
            if let app = ChatAppLocator.findRunningApplication(for: appTarget) {
                app.activate()
                openedApps.append(appTarget.displayName)
                continue
            }

            if let path = ChatAppLocator.suggestedApplicationPaths(for: appTarget).first {
                let url = URL(fileURLWithPath: path)
                if workspace.open(url) {
                    openedApps.append(appTarget.displayName)
                }
            }
        }

        if openedApps.isEmpty {
            appendLog("Could not open the selected apps automatically.")
        } else {
            appendLog("Opened: \(openedApps.joined(separator: ", ")).")
        }
    }

    private func startWatching() {
        guard watchTask == nil else { return }
        guard !workers.isEmpty else { return }

        isWatching = true
        statusHeadline = "Watching for changes"
        lastWatchSyncAt = nil
        configureAutoTaskPlanning()
        appendLog("Started watch mode with \(Int(intervalSeconds))s interval for \(targetScope.displayName).")

        watchTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.performWatchCycle()
                let nanoseconds = UInt64(max(intervalSeconds, 1) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
            }
        }
    }

    private func stopWatching() {
        watchTask?.cancel()
        watchTask = nil
        autoTaskPlanningTask?.cancel()
        autoTaskPlanningTask = nil
        isWatching = false
        refreshStatus(force: true)
        appendLog("Stopped watch mode.")
    }

    private func performSyncOnce(reason: String) async {
        for appTarget in targetScope.activeApps {
            guard let worker = workers[appTarget] else { continue }

            do {
                let result = try await worker.runSyncOnce(maxDepth: appTarget.snapshotDepth, privacyFilter: privacyFilter)
                lastConversation = safeDisplayLabel(result.conversationName, fallback: "Filtered Conversation")
                lastSyncSummary = "\(appTarget.displayName): captured \(result.capturedCount), inserted \(result.insertedMessages.count)"
                await refreshWeChatReviewMarkdown(worker: worker)

                if result.insertedMessages.isEmpty {
                    if reason == "manual" {
                        appendLog("No new rows for \(appTarget.displayName). Conversation: \(result.conversationName)", targetApp: appTarget)
                    }
                } else {
                    appendLog("\(appTarget.displayName) \(result.conversationName): +\(result.insertedMessages.count) new message(s).", targetApp: appTarget)
                    for message in result.insertedMessages.suffix(3) {
                        appendLog("[\(message.senderLabel) -> \(message.recipientLabel)] \(message.text)", targetApp: appTarget)
                    }
                }

                if result.filteredCount > 0 {
                    appendLog("Skipped \(result.filteredCount) \(appTarget.displayName) message(s) due to privacy filters.", targetApp: appTarget)
                }
            } catch AccessibilityError.notTrusted {
                accessibilityTrusted = false
                statusHeadline = "Accessibility permission required"
                appendLog("Accessibility permission is missing.")
                if isWatching {
                    stopWatching()
                }
                break
            } catch AccessibilityError.targetAppNotRunning(let targetApp) {
                if reason == "manual" {
                    appendLog("\(targetApp.displayName) is not running.", targetApp: targetApp)
                }
            } catch AccessibilityError.noWindow {
                if reason == "manual" {
                    appendLog("No readable \(appTarget.displayName) window found. Open a conversation first.", targetApp: appTarget)
                }
            } catch {
                appendLog("\(appTarget.displayName) sync failed: \(error.localizedDescription)", targetApp: appTarget)
                if reason == "manual" {
                    statusHeadline = "Sync failed"
                }
            }
        }
        if reason == "watch" {
            lastWatchSyncAt = Date()
            refreshStatusIfNeeded()
        } else {
            refreshStatus(force: true)
        }
    }

    private func performWatchCycle() async {
        if frontmostContextEnabled, shouldCaptureFrontmostContextNow() {
            await captureFrontmostContext(reason: "watch")
        }

        var shouldRunImmediateSync = false

        for appTarget in targetScope.activeApps {
            guard let worker = workers[appTarget] else { continue }

            do {
                let snapshot = try await worker.captureSnapshot(maxDepth: appTarget.snapshotDepth)
                let rows = await worker.extractConversationRows(from: snapshot)
                let currentConversation = await worker.currentConversationName(from: snapshot)
                let changedRow = detectChangedConversation(in: rows, currentConversation: currentConversation, targetApp: appTarget)

                if let changedRow, !privacyFilter.shouldBlock(row: changedRow) {
                    await enqueuePendingConversation(changedRow, targetApp: appTarget, worker: worker)
                    shouldRunImmediateSync = true
                }

                if foregroundAssistEnabled, ChatAppLocator.isFrontmost(for: appTarget) {
                    resolvePendingIfVisible(currentConversation: currentConversation, targetApp: appTarget)
                    shouldRunImmediateSync = true
                }

                lastObservedRowsByApp[appTarget] = rows
            } catch AccessibilityError.notTrusted {
                accessibilityTrusted = false
                statusHeadline = "Accessibility permission required"
                appendLog("Accessibility permission is missing.")
                if isWatching {
                    stopWatching()
                }
                return
            } catch AccessibilityError.targetAppNotRunning {
                continue
            } catch AccessibilityError.noWindow {
                continue
            } catch {
                appendLog("\(appTarget.displayName) watch cycle failed: \(error.localizedDescription)", targetApp: appTarget)
            }
        }

        currentIdleSeconds = userIdleSeconds()

        if idleAutoOpenEnabled,
           currentIdleSeconds >= (idleThresholdMinutes * 60),
           let nextPending = pendingConversations.first,
           let worker = workers[nextPending.targetApp] {
            let clicked = await worker.openConversation(nextPending.row)
            if clicked {
                shouldRunImmediateSync = true
                appendLog("Idle auto-open \(nextPending.targetApp.displayName): \(nextPending.row.title)", targetApp: nextPending.targetApp)
                removePendingConversation(targetApp: nextPending.targetApp, title: nextPending.row.title)
                try? await Task.sleep(nanoseconds: 400_000_000)
            } else {
                appendLog("Idle auto-open failed: \(nextPending.targetApp.displayName) \(nextPending.row.title)", targetApp: nextPending.targetApp)
            }
        }

        refreshStatusIfNeeded()
        if shouldRunImmediateSync || shouldRunWatchSyncNow() {
            await performSyncOnce(reason: "watch")
        }
    }

    private func performTaskPlanning() async {
        guard let worker = workers[.weChat] else {
            plannerStatus = "Planner is waiting for message storage"
            return
        }

        plannerStatus = "Planning tasks from recent messages..."

        do {
            let existingTasks = try TaskStore.load(databasePath: databasePath)
            let cutoff = Date().addingTimeInterval(-3600)
            let recentContext = try await worker.fetchRecentMessages(limit: 420)
                .filter { $0.capturedAt >= cutoff }

            let recentMessages = recentContext.filter {
                $0.source.hasPrefix(TargetApp.weChat.sourceName)
            }
            let recentIntents = recentContext
                .filter { $0.source == "intent-screenshot" }
                .compactMap(Self.parsePlannerIntentContext(from:))

            guard !recentMessages.isEmpty || !recentIntents.isEmpty else {
                plannerStatus = "No recent context available yet"
                appendLog("Task planner found no messages to analyze.")
                return
            }

            let settings = PlannerSettings(
                apiBaseURL: plannerAPIBaseURL,
                apiKey: plannerAPIKey,
                modelName: plannerModelName
            )
            let tasks = try await TaskPlanner.planTasks(
                from: recentMessages,
                intents: recentIntents,
                settings: settings
            )

            if tasks.isEmpty {
                plannedTasks = existingTasks
                plannerStatus = settings.isConfigured
                    ? (existingTasks.isEmpty ? "No actionable schedule/todo items found" : "No new tasks · \(existingTasks.count) total")
                    : (existingTasks.isEmpty ? "No actionable items found with local heuristics" : "No new tasks · \(existingTasks.count) total")
                appendLog("Task planner did not find actionable schedule/todo items.")
                return
            }

            let mergeResult = TaskStore.merge(existing: existingTasks, incoming: tasks)
            plannedTasks = mergeResult.tasks
            try TaskStore.save(tasks: mergeResult.tasks, databasePath: databasePath)
            let exportedPath = try TaskMarkdownExporter.export(tasks: mergeResult.tasks, databasePath: databasePath)
            tasksMarkdownPath = exportedPath
            plannerStatus = mergeResult.addedCount > 0
                ? "Added \(mergeResult.addedCount) tasks · \(mergeResult.tasks.count) total"
                : "No new tasks · \(mergeResult.tasks.count) total"
            appendLog("Task planner generated \(tasks.count) schedule/todo items.")
            appendLog("Task loop now holds \(mergeResult.tasks.count) accumulated tasks.")
            appendLog("Task markdown updated: \(exportedPath)")
        } catch {
            plannerStatus = "Task planning failed"
            appendLog("Task planner failed: \(error.localizedDescription)")
        }
    }

    private func detectChangedConversation(in rows: [ConversationRow], currentConversation: String, targetApp: TargetApp) -> ConversationRow? {
        guard !rows.isEmpty else { return nil }

        let previousByTitle = Dictionary(uniqueKeysWithValues: (lastObservedRowsByApp[targetApp] ?? []).map { ($0.title, $0) })
        for row in rows {
            guard row.title != currentConversation else { continue }
            if let previous = previousByTitle[row.title] {
                if previous.signature != row.signature {
                    return row
                }
            } else {
                return row
            }
        }

        return nil
    }

    private func enqueuePendingConversation(_ row: ConversationRow, targetApp: TargetApp, worker: SyncWorker) async {
        if let index = pendingConversations.firstIndex(where: { $0.targetApp == targetApp && $0.row.title == row.title }) {
            let previous = pendingConversations[index].row
            pendingConversations[index].row = row
            refreshPendingPresentation()
            if previous.signature != row.signature {
                await recordPreviewIfNeeded(for: row, targetApp: targetApp, worker: worker)
                appendLog("Pending update: \(targetApp.displayName) \(row.title) -> \(summarizePreview(row.preview))", targetApp: targetApp)
            }
            return
        }

        pendingConversations.append(PendingConversation(targetApp: targetApp, row: row))
        refreshPendingPresentation()
        await recordPreviewIfNeeded(for: row, targetApp: targetApp, worker: worker)
        appendLog("Queued for idle sync: \(targetApp.displayName) \(row.title) -> \(summarizePreview(row.preview))", targetApp: targetApp)
    }

    private func removePendingConversation(targetApp: TargetApp, title: String) {
        pendingConversations.removeAll { $0.targetApp == targetApp && $0.row.title == title }
        refreshPendingPresentation()
    }

    private func resolvePendingIfVisible(currentConversation: String, targetApp: TargetApp) {
        guard currentConversation != "Unknown Conversation" else { return }
        guard let pending = pendingConversations.first(where: { pending in
            guard pending.targetApp == targetApp else { return false }
            return pending.row.title == currentConversation ||
                pending.row.title.contains(currentConversation) ||
                currentConversation.contains(pending.row.title)
        }) else { return }

        removePendingConversation(targetApp: targetApp, title: pending.row.title)
        appendLog("Foreground sync matched visible \(targetApp.displayName) conversation: \(currentConversation)", targetApp: targetApp)
    }

    private func userIdleSeconds() -> Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .null)
    }

    func clearActivity() {
        logText = ""
        activityEntries = []
        appendLog("Activity log cleared.")
    }

    private func refreshPendingPresentation() {
        let visiblePending = pendingConversations.filter { !privacyFilter.shouldBlock(row: $0.row) }
        pendingConversationTitles = visiblePending.map { "\($0.targetApp.displayName) · \($0.row.title)" }
        pendingConversationSummaries = visiblePending.map { pending in
            let row = pending.row
            if row.preview.isEmpty {
                return "\(pending.targetApp.displayName) · \(row.title)"
            }
            return "\(pending.targetApp.displayName) · \(row.title): \(summarizePreview(row.preview))"
        }
    }

    private func summarizePreview(_ preview: String) -> String {
        let trimmed = preview.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "(no preview)" }
        if trimmed.count <= 60 {
            return trimmed
        }
        let endIndex = trimmed.index(trimmed.startIndex, offsetBy: 60)
        return "\(trimmed[..<endIndex])..."
    }

    private func summarizeContextText(_ text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\n", with: " · ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty else { return "(no readable context)" }
        if normalized.count <= 140 {
            return normalized
        }
        let endIndex = normalized.index(normalized.startIndex, offsetBy: 140)
        return "\(normalized[..<endIndex])..."
    }

    private func summarizeIntentAnalysis(_ markdown: String) -> String {
        let lines = markdown
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var currentSection = ""
        var summaryLines: [String] = []
        var primaryIntentLines: [String] = []
        var normalizedLines: [String] = []
        var screenshotLines: [String] = []
        var accessibilityLines: [String] = []

        for line in lines {
            if line.hasPrefix("## ") {
                currentSection = line.replacingOccurrences(of: "## ", with: "")
                continue
            }

            if line.hasPrefix("- ") {
                let item = String(line.dropFirst(2))
                switch currentSection {
                case "Intent Summary":
                    summaryLines.append(item)
                case "Primary Intent":
                    primaryIntentLines.append(item)
                case "Normalized OCR":
                    normalizedLines.append(item)
                case "Screenshot OCR":
                    screenshotLines.append(item)
                case "Accessibility Context":
                    accessibilityLines.append(item)
                default:
                    break
                }
            }
        }

        var parts: [String] = []
        if !summaryLines.isEmpty {
            parts.append(summaryLines.prefix(2).joined(separator: " · "))
        }
        if !primaryIntentLines.isEmpty {
            parts.append(primaryIntentLines.prefix(2).joined(separator: " · "))
        }
        if !normalizedLines.isEmpty {
            parts.append(normalizedLines.prefix(2).joined(separator: " · "))
        }
        if !screenshotLines.isEmpty {
            parts.append(screenshotLines.prefix(2).joined(separator: " · "))
        }
        if parts.isEmpty, !accessibilityLines.isEmpty {
            parts.append(accessibilityLines.prefix(2).joined(separator: " · "))
        }

        let compact = parts.joined(separator: " | ")
        return summarizeContextText(compact.isEmpty ? markdown : compact)
    }

    private static func parsePlannerIntentContext(from message: StoredMessage) -> PlannerIntentContext? {
        let sections = message.text.components(separatedBy: "\n\n")
        let markdown = sections.dropFirst().joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !markdown.isEmpty else { return nil }

        var currentSection = ""
        var summary = ""
        var intents: [String] = []
        var followUps: [String] = []
        var normalizedOCRPreview: [String] = []
        var ocrPreview: [String] = []
        var accessibilityPreview: [String] = []

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("## ") {
                currentSection = String(line.dropFirst(3))
                continue
            }

            guard line.hasPrefix("- ") else { continue }
            let item = String(line.dropFirst(2))
            switch currentSection {
            case "Intent Summary":
                if item.lowercased() != "none" {
                    if summary.isEmpty {
                        summary = item
                    }
                }
            case "Primary Intent":
                if item.lowercased() != "none" {
                    intents.append(item)
                    if summary.isEmpty {
                        summary = item
                    }
                }
            case "Relevant Content":
                if item.lowercased() != "none" {
                    followUps.append(item)
                }
            case "Normalized OCR":
                if item.lowercased() != "none" {
                    normalizedOCRPreview.append(item)
                    if summary.isEmpty {
                        summary = item
                    }
                }
            case "Local OCR", "Screenshot OCR":
                if item.lowercased() != "none" {
                    ocrPreview.append(item)
                    if summary.isEmpty {
                        summary = item
                    }
                }
            case "Accessibility Context":
                if item.lowercased() != "none" {
                    accessibilityPreview.append(item)
                }
            default:
                break
            }
        }

        let conversationParts = message.conversationName.components(separatedBy: " · ")
        let appName = conversationParts.dropFirst().first ?? message.senderLabel
        let windowTitle = conversationParts.dropFirst(2).joined(separator: " · ").nilIfEmpty ?? message.recipientLabel

        return PlannerIntentContext(
            capturedAt: message.capturedAt,
            appName: appName,
            windowTitle: windowTitle,
            summary: summary,
            intentBullets: intents,
            followUps: followUps,
            ocrPreview: normalizedOCRPreview.isEmpty ? ocrPreview : normalizedOCRPreview,
            accessibilityPreview: accessibilityPreview
        )
    }

    private func safeDisplayLabel(_ text: String, fallback: String) -> String {
        privacyFilter.matches(text) ? fallback : text
    }

    private func captureFrontmostContext(reason: String) async {
        guard frontmostContextEnabled else { return }
        guard let worker = workers[.weChat] else { return }
        lastFrontmostContextCaptureAt = Date()

        do {
            let excluded = Set([
                Bundle.main.bundleIdentifier ?? "",
                "com.moly.contexthub",
            ])
            let fallbackApplication = lastContextApplication
            let capture = try await Task.detached(priority: .utility) {
                do {
                    return try FrontmostContextReader.captureCurrent(excludingBundleIdentifiers: excluded)
                } catch FrontmostContextError.noEligibleApplication {
                    guard let fallbackApplication else {
                        throw FrontmostContextError.noEligibleApplication
                    }
                    return try FrontmostContextReader.capture(for: fallbackApplication)
                }
            }.value
            let summary = "\(capture.appName) · \(capture.windowTitle)"
            if privacyFilter.matches(anyOf: [capture.appName, capture.windowTitle, capture.conversationName, capture.text]) {
                lastContextSummary = "Filtered context"
                appendLog("Skipped frontmost context due to privacy filters.", isContext: true)
                return
            }
            lastContextSummary = safeDisplayLabel(summary, fallback: "Filtered context")

            guard capture.fingerprint != lastFrontmostContextFingerprint else {
                if reason == "manual" {
                    appendLog("Frontmost context is unchanged for \(summary).", isContext: true)
                }
                return
            }

            let inserted = try await worker.recordExternalMessage(
                conversationName: capture.conversationName,
                senderLabel: capture.appName,
                recipientLabel: "self",
                text: capture.text,
                source: "context-accessibility",
                direction: "in",
                privacyFilter: privacyFilter
            )

            lastFrontmostContextFingerprint = capture.fingerprint

            if inserted.isEmpty {
                if reason == "manual" {
                    appendLog("Frontmost context was already stored for \(summary).", isContext: true)
                }
            } else {
                appendLog("Captured frontmost context from \(summary).", isContext: true)
                appendLog(summarizeContextText(capture.text), isContext: true)
            }
        } catch AccessibilityError.notTrusted {
            accessibilityTrusted = false
            statusHeadline = "Accessibility permission required"
            appendLog("Accessibility permission is missing.")
            if isWatching {
                stopWatching()
            }
        } catch FrontmostContextError.noEligibleApplication {
            if reason == "manual" {
                appendLog("No eligible frontmost app is available for context capture.", isContext: true)
            }
        } catch FrontmostContextError.insufficientContent {
            if reason == "manual" {
                appendLog("The frontmost window does not expose enough readable text yet.", isContext: true)
            }
        } catch AccessibilityError.noWindow {
            if reason == "manual" {
                appendLog("No readable frontmost window was found.", isContext: true)
            }
        } catch {
            appendLog("Frontmost context capture failed: \(error.localizedDescription)", isContext: true)
        }
    }

    private func appendLog(_ message: String, targetApp: TargetApp? = nil, isContext: Bool = false) {
        appendLog(message, targetApp: targetApp, isContext: isContext, isIntent: false)
    }

    private func appendLog(_ message: String, targetApp: TargetApp? = nil, isContext: Bool = false, isIntent: Bool = false) {
        guard !privacyFilter.matches(message) else { return }
        let time = timestamp()
        let line = "[\(time)] \(message)"
        CrashReporter.appendRuntime(line)
        activityEntries.append(ActivityEntry(timestamp: time, message: message, targetApp: targetApp, isContext: isContext, isIntent: isIntent))
        trimActivityBufferIfNeeded()
        logText = activityEntries
            .suffix(maxActivityEntries)
            .map { "[\($0.timestamp)] \($0.message)" }
            .joined(separator: "\n")
    }

    private func recordPreviewIfNeeded(for row: ConversationRow, targetApp: TargetApp, worker: SyncWorker) async {
        guard !privacyFilter.shouldBlock(row: row) else { return }
        do {
            let inserted = try await worker.recordPreviewEvent(for: row, privacyFilter: privacyFilter)
            guard !inserted.isEmpty else { return }
            await refreshWeChatReviewMarkdown(worker: worker)
            appendLog("Recorded preview from \(targetApp.displayName): \(row.title)", targetApp: targetApp)
        } catch {
            appendLog("Failed to record preview for \(targetApp.displayName) \(row.title): \(error.localizedDescription)", targetApp: targetApp)
        }
    }

    private func refreshWeChatReviewMarkdown(worker: SyncWorker) async {
        do {
            let messages = try await worker.fetchRecentMessages(limit: 180)
            let exportedPath = try MarkdownExporter.exportWeChatReview(messages: messages, baseDirectory: databasePath)
            latestWeChatReviewMarkdownPath = exportedPath
            latestMessagesMarkdownPath = Self.resolveLatestMessagesMarkdownPath(databasePath: databasePath)
        } catch {
            appendLog("Failed to refresh WeChat review markdown: \(error.localizedDescription)")
        }
    }

    private func rebuildWorkers() {
        var workers: [TargetApp: SyncWorker] = [:]
        do {
            for targetApp in [TargetApp.weChat] {
                workers[targetApp] = try SyncWorker(targetApp: targetApp)
            }
        } catch {
            self.startupError = error.localizedDescription
            self.workers = [:]
            appendLog("Failed to initialize store: \(error.localizedDescription)")
            return
        }

        self.workers = workers
        self.startupError = nil

        Task { [weak self] in
            guard let self, let worker = workers[.weChat] else { return }
            let path = await worker.resolvedDatabasePath
            ExportPathResolver.migrateLegacyHiddenIntentArtifacts(databasePath: path)
            self.databasePath = path
            self.exportRootPath = ExportPathResolver.exportRootDirectory(databasePath: path).path
            self.configureCrashReporter(rootURL: ExportPathResolver.exportRootDirectory(databasePath: path))
            let markdownPath = ExportPathResolver
                .markdownDirectory(databasePath: path)
                .appendingPathComponent("moly_tasks.md")
                .path
            self.tasksMarkdownPath = FileManager.default.fileExists(atPath: markdownPath) ? markdownPath : "-"
            self.intentCaptureDirectoryPath = ExportPathResolver.screenshotsRootDirectory(databasePath: path).path
            self.intentCaptureMarkdownPath = Self.resolveLatestIntentMarkdownPath(databasePath: path)
            self.latestMessagesMarkdownPath = Self.resolveLatestMessagesMarkdownPath(databasePath: path)
            self.latestWeChatReviewMarkdownPath = Self.resolveLatestWeChatReviewMarkdownPath(databasePath: path)
            self.latestScreenshotMarkdownPath = Self.resolveLatestScreenshotMarkdownPath(databasePath: path)
            self.crashReportPath = CrashReporter.latestCrashReportPath()
            self.chromeExtensionPath = Self.resolveChromeExtensionPath()
            self.plannedTasks = (try? TaskStore.load(databasePath: path)) ?? []
            self.refreshStatus(force: true)
            await self.refreshWeChatReviewMarkdown(worker: worker)
        }
    }

    private func configureCrashReporter(rootURL: URL) {
        CrashReporter.configure(exportRoot: rootURL)
        crashReportPath = CrashReporter.latestCrashReportPath()
    }

    private func configureChromeExtensionBridge() {
        chromeExtensionPath = Self.resolveChromeExtensionPath()
        let bridge = ChromeExtensionBridge(
            onPayload: { [weak self] payload in
                Task { @MainActor in
                    await self?.handleChromeExtensionPayload(payload)
                }
            },
            onStatusChange: { [weak self] status in
                Task { @MainActor in
                    self?.chromeBridgeStatus = status.displayText
                }
            }
        )
        chromeExtensionBridge = bridge
        bridge.start()
    }

    private func handleChromeExtensionPayload(_ payload: ChromeExtensionPayload) async {
        guard let worker = workers[.weChat] else { return }

        let title = payload.normalizedTitle.isEmpty ? "Untitled Page" : payload.normalizedTitle
        let hostname = payload.hostname.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? URL(string: payload.normalizedURL)?.host ?? "unknown-host"
        let conversationName = "Chrome · \(hostname) · \(title)"
        let messageText = composeChromeExtensionMessage(payload)

        if privacyFilter.matches(anyOf: [title, hostname, conversationName, payload.normalizedURL, messageText]) {
            lastContextSummary = "Filtered browser context"
            appendLog("Skipped Chrome extension capture due to privacy filters.", isContext: true)
            return
        }

        do {
            let inserted = try await worker.recordExternalMessage(
                conversationName: conversationName,
                senderLabel: payload.browserName.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Google Chrome",
                recipientLabel: "self",
                text: messageText,
                source: "chrome-extension",
                direction: "in",
                privacyFilter: privacyFilter
            )

            lastContextSummary = safeDisplayLabel("Chrome Ext · \(title)", fallback: "Filtered browser context")
            if inserted.isEmpty {
                appendLog("Chrome extension capture was already stored for \(title).", isContext: true)
            } else {
                appendLog("Received Chrome extension capture from \(title).", isContext: true)
                appendLog(summarizeContextText(messageText), isContext: true)
            }
        } catch {
            appendLog("Chrome extension capture failed: \(error.localizedDescription)", isContext: true)
        }
    }

    private func composeChromeExtensionMessage(_ payload: ChromeExtensionPayload) -> String {
        var sections: [String] = []
        sections.append("Title: \(payload.normalizedTitle)")
        sections.append("URL: \(payload.normalizedURL)")

        let reason = payload.normalizedCaptureReason
        if !reason.isEmpty {
            sections.append("Reason: \(reason)")
        }

        let metaDescription = payload.normalizedMetaDescription
        if !metaDescription.isEmpty {
            sections.append("")
            sections.append("Summary:")
            sections.append(metaDescription)
        }

        let selection = payload.normalizedSelectionText
        if !selection.isEmpty {
            sections.append("")
            sections.append("Selection:")
            sections.append(selection)
        }

        let visible = payload.normalizedVisibleText
        if !visible.isEmpty {
            sections.append("")
            sections.append("Visible:")
            sections.append(visible)
        }

        let content = payload.normalizedContentText
        if !content.isEmpty {
            sections.append("")
            sections.append("Content:")
            sections.append(content)
        }

        if !payload.capturedAt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("")
            sections.append("Captured At: \(payload.capturedAt)")
        }

        return sections.joined(separator: "\n")
    }

    private static func resolveChromeExtensionPath() -> String {
        guard let configuredPath = Bundle.main.object(forInfoDictionaryKey: "MolyChromeExtensionPath") as? String else {
            return "-"
        }
        let expandedPath = NSString(string: configuredPath).expandingTildeInPath
        return FileManager.default.fileExists(atPath: expandedPath) ? expandedPath : "-"
    }

    private static func resolveAppVersion() -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
        return build == "-" ? "v\(version)" : "v\(version) (\(build))"
    }

    private func observeWorkspaceActivation() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            guard app.activationPolicy == .regular else { return }

            let bundleIdentifier = app.bundleIdentifier ?? ""
            let lowercasedName = (app.localizedName ?? "").lowercased()
            guard bundleIdentifier != Bundle.main.bundleIdentifier else { return }
            guard !lowercasedName.contains("wechat"), !lowercasedName.contains("微信") else { return }

            Task { @MainActor [weak self] in
                self?.lastContextApplication = app
            }
        }
    }

    private func loadPlannerSettings() {
        let defaults = UserDefaults.standard
        plannerAPIBaseURL = defaults.string(forKey: plannerAPIBaseURLKey) ?? ""
        plannerAPIKey = defaults.string(forKey: plannerAPIKeyKey) ?? ""
        plannerModelName = defaults.string(forKey: plannerModelNameKey) ?? "gpt-4.1-mini"
        autoTaskPlanningEnabled = defaults.object(forKey: autoTaskPlanningEnabledKey) == nil
            ? false
            : defaults.bool(forKey: autoTaskPlanningEnabledKey)
        let savedInterval = defaults.double(forKey: autoTaskPlanningIntervalKey)
        autoTaskPlanningIntervalMinutes = savedInterval == 0 ? 10 : min(360, max(5, savedInterval))
    }

    private func persistAutoPlannerSettings() {
        let defaults = UserDefaults.standard
        defaults.set(autoTaskPlanningEnabled, forKey: autoTaskPlanningEnabledKey)
        defaults.set(autoTaskPlanningIntervalMinutes, forKey: autoTaskPlanningIntervalKey)
    }

    private func loadPrivacySettings() {
        let defaults = UserDefaults.standard
        privacyBlockedKeywords = (defaults.array(forKey: privacyBlockedKeywordsKey) as? [String] ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted { PrivacyFilter.normalize($0) < PrivacyFilter.normalize($1) }
    }

    private func persistPrivacySettings() {
        UserDefaults.standard.set(privacyBlockedKeywords, forKey: privacyBlockedKeywordsKey)
    }

    private func loadSensorSettings() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: enterKeySensorEnabledKey) == nil {
            enterKeySensorEnabled = false
        } else {
            enterKeySensorEnabled = defaults.bool(forKey: enterKeySensorEnabledKey)
        }
    }

    private func persistSensorSettings() {
        UserDefaults.standard.set(enterKeySensorEnabled, forKey: enterKeySensorEnabledKey)
    }

    private func configureAutoTaskPlanning() {
        autoTaskPlanningTask?.cancel()
        autoTaskPlanningTask = nil

        guard autoTaskPlanningEnabled, isWatching else { return }

        autoTaskPlanningTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let seconds = UInt64(max(300, autoTaskPlanningIntervalMinutes * 60) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: seconds)
                if Task.isCancelled { break }
                await self.performTaskPlanning()
            }
        }
    }

    private func configureEnterKeySensor() {
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
            self.globalKeyMonitor = nil
        }
        if let eventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapRunLoopSource, .commonModes)
            self.eventTapRunLoopSource = nil
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }

        guard enterKeySensorEnabled else { return }
        screenCaptureTrusted = IntentCaptureSupport.screenCapturePermissionGranted()
        if !screenCaptureTrusted {
            let requested = IntentCaptureSupport.requestScreenCapturePermission()
            screenCaptureTrusted = requested || IntentCaptureSupport.screenCapturePermissionGranted()
        }

        installEventTapIfPossible()
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                await self?.handleGlobalKeyEvent(event)
            }
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                await self?.handleGlobalKeyEvent(event)
            }
            return event
        }
        appendLog("Enter-key sensor is armed.", isIntent: true)
    }

    private func handleGlobalKeyEvent(_ event: NSEvent) async {
        guard enterKeySensorEnabled else { return }
        guard event.keyCode == 36 || event.keyCode == 76 else { return }

        let modifiers = event.modifierFlags.intersection([.shift, .command, .option, .control, .function])
        guard modifiers.isEmpty else { return }

        let now = Date()
        if let lastEnterCaptureAt, now.timeIntervalSince(lastEnterCaptureAt) < 1.6 {
            return
        }
        lastEnterCaptureAt = now

        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return
        }

        await performIntentCapture(trigger: "enter-key")
    }

    private func installEventTapIfPossible() {
        let mask = (1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard type == .keyDown else { return Unmanaged.passUnretained(event) }
            guard let userInfo else { return Unmanaged.passUnretained(event) }

            let model = Unmanaged<WeChatSyncAppModel>.fromOpaque(userInfo).takeUnretainedValue()
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags
            Task { @MainActor in
                await model.handleCGKeyEvent(keyCode, flags: flags)
            }
            return Unmanaged.passUnretained(event)
        }

        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: refcon
        ) else {
            appendLog("Event tap is unavailable. Falling back to NSEvent monitoring.", isIntent: true)
            return
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            appendLog("Event tap source could not be created. Falling back to NSEvent monitoring.", isIntent: true)
            return
        }

        eventTap = tap
        eventTapRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handleCGKeyEvent(_ keyCode: CGKeyCode, flags: CGEventFlags) async {
        guard enterKeySensorEnabled else { return }
        guard keyCode == 36 || keyCode == 76 else { return }
        let disallowedFlags: CGEventFlags = [
            .maskShift,
            .maskCommand,
            .maskAlternate,
            .maskControl,
            .maskSecondaryFn,
        ]
        guard flags.intersection(disallowedFlags).isEmpty else {
            return
        }

        let now = Date()
        if let lastEnterCaptureAt, now.timeIntervalSince(lastEnterCaptureAt) < 1.6 {
            return
        }
        lastEnterCaptureAt = now

        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return
        }

        appendLog("Detected enter-key via event tap in \(frontmost.localizedName ?? "Unknown App").", isIntent: true)
        await performIntentCapture(trigger: "enter-key")
    }

    private func performIntentCapture(trigger: String) async {
        guard !isIntentCaptureInFlight else { return }
        guard let worker = workers[.weChat] else { return }
        isIntentCaptureInFlight = true
        defer { isIntentCaptureInFlight = false }

        screenCaptureTrusted = IntentCaptureSupport.screenCapturePermissionGranted()
        if !screenCaptureTrusted {
            let requested = IntentCaptureSupport.requestScreenCapturePermission()
            screenCaptureTrusted = requested || IntentCaptureSupport.screenCapturePermissionGranted()
        }
        guard screenCaptureTrusted else {
            appendLog("Screen Recording permission is missing for the enter-key sensor.", isIntent: true)
            return
        }

        let excluded = Set([Bundle.main.bundleIdentifier ?? "", "com.moly.contexthub"])
        let metadata = await Task.detached(priority: .utility) {
            IntentCaptureSupport.currentAppMetadata(excludingBundleIdentifiers: excluded)
        }.value
        let normalizedIntentApp = "\(metadata.appName) \(metadata.bundleIdentifier)".lowercased()
        if normalizedIntentApp.contains("wechat") || normalizedIntentApp.contains("微信") || normalizedIntentApp.contains("xinwechat") {
            lastIntentSummary = "Skipped for WeChat"
            appendLog("Skipped enter-key screenshot for WeChat to avoid duplicate capture noise.", isIntent: true)
            return
        }
        if privacyFilter.matches(anyOf: [metadata.appName, metadata.bundleIdentifier, metadata.windowTitle, metadata.contextText]) {
            lastIntentSummary = "Filtered intent capture"
            appendLog("Skipped enter-key screenshot due to privacy filters.", isIntent: true)
            return
        }
        let timestamp = Date()
        let screenshotsDirectory = ExportPathResolver.intentScreenshotsDirectory(databasePath: databasePath, capturedAt: timestamp)
        let screenshotURL = screenshotsDirectory.appendingPathComponent(Self.intentScreenshotFileName(for: timestamp))

        do {
            let captureTarget = try await IntentCaptureSupport.captureCurrentScreen(to: screenshotURL)
            let settings = PlannerSettings(
                apiBaseURL: plannerAPIBaseURL,
                apiKey: plannerAPIKey,
                modelName: plannerModelName
            )
            if !settings.isConfigured {
                appendLog("Using local OCR for enter-key screenshot analysis.", isIntent: true)
            }
            let analysisMarkdown = try await MultimodalIntentAnalyzer.analyzeScreenshot(
                imageURL: screenshotURL,
                appName: metadata.appName,
                windowTitle: metadata.windowTitle,
                trigger: trigger,
                accessibilityContext: metadata.contextText,
                settings: settings
            )

            let record = IntentCaptureRecord(
                capturedAt: timestamp,
                appName: metadata.appName,
                bundleIdentifier: metadata.bundleIdentifier,
                windowTitle: metadata.windowTitle,
                trigger: trigger,
                screenshotPath: screenshotURL.path,
                analysisMarkdown: analysisMarkdown,
                contextText: metadata.contextText
            )
            let exportedPath = try IntentCaptureExporter.export(record: record, databasePath: databasePath)
            intentCaptureDirectoryPath = ExportPathResolver.screenshotsRootDirectory(databasePath: databasePath).path
            intentCaptureMarkdownPath = exportedPath
            latestScreenshotMarkdownPath = Self.resolveLatestScreenshotMarkdownPath(databasePath: databasePath)
            let intentSummary = summarizeIntentAnalysis(analysisMarkdown)
            lastIntentSummary = safeDisplayLabel(intentSummary, fallback: "Filtered intent capture")
            let storedOCRMarkdown = Self.screenshotOCROnlyMarkdown(from: analysisMarkdown)

            let inserted = try await worker.recordExternalMessage(
                conversationName: "Intent Sensor · \(metadata.appName) · \(metadata.windowTitle)",
                senderLabel: metadata.appName,
                recipientLabel: "self",
                text: """
                Screenshot: \(screenshotURL.path)

                \(storedOCRMarkdown)
                """,
                source: "intent-screenshot",
                direction: "in",
                privacyFilter: privacyFilter
            )

            appendLog(
                "Captured enter-key screenshot on \(captureTarget.label) from \(metadata.appName) · \(metadata.windowTitle).",
                isIntent: true
            )
            appendLog(
                "Saved screenshot: \(screenshotURL.lastPathComponent) in \(screenshotsDirectory.lastPathComponent) · \(captureTarget.label).",
                isIntent: true
            )
            if !inserted.isEmpty {
                appendLog(intentSummary, isIntent: true)
            }
        } catch {
            appendLog("Enter-key screenshot capture failed: \(error.localizedDescription)", isIntent: true)
        }
    }

    private static func intentScreenshotFileName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        return formatter.string(from: date) + ".png"
    }

    private static func resolveLatestIntentMarkdownPath(databasePath: String) -> String {
        let directory = ExportPathResolver.intentMarkdownDirectory(databasePath: databasePath)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return "-"
        }

        let latest = files
            .filter { $0.pathExtension.lowercased() == "md" }
            .sorted { left, right in
                let leftDate = (try? left.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rightDate = (try? right.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return leftDate > rightDate
            }
            .first

        return latest?.path ?? "-"
    }

    private static func resolveLatestMessagesMarkdownPath(databasePath: String) -> String {
        let directory = ExportPathResolver.markdownDirectory(databasePath: databasePath)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return "-"
        }

        let latest = files
            .filter { $0.lastPathComponent.hasPrefix("messages-") && $0.pathExtension.lowercased() == "md" }
            .sorted { left, right in
                let leftDate = (try? left.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rightDate = (try? right.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return leftDate > rightDate
            }
            .first

        return latest?.path ?? "-"
    }

    private static func resolveLatestWeChatReviewMarkdownPath(databasePath: String) -> String {
        let path = ExportPathResolver
            .markdownDirectory(databasePath: databasePath)
            .appendingPathComponent("wechat-review-latest.md")
            .path
        return FileManager.default.fileExists(atPath: path) ? path : "-"
    }

    private static func screenshotOCROnlyMarkdown(from markdown: String) -> String {
        let lines = markdown.components(separatedBy: .newlines)
        var currentSection = ""
        var normalized: [String] = []
        var captured: [String] = []

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("## ") {
                currentSection = String(line.dropFirst(3))
                continue
            }
            if currentSection == "Normalized OCR", !line.isEmpty {
                normalized.append(rawLine)
            }
            if currentSection == "Screenshot OCR", !line.isEmpty {
                captured.append(rawLine)
            }
        }

        if !normalized.isEmpty {
            return "## Normalized OCR\n" + normalized.joined(separator: "\n")
        }
        if captured.isEmpty {
            return markdown
        }

        return "## Screenshot OCR\n" + captured.joined(separator: "\n")
    }

    private static func resolveLatestScreenshotPath(databasePath: String) -> String {
        let rootDirectory = ExportPathResolver.screenshotsRootDirectory(databasePath: databasePath)
        let fileManager = FileManager.default
        guard let bucketDirectories = try? fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return "-"
        }

        var candidates: [URL] = []
        for bucketDirectory in bucketDirectories {
            let values = try? bucketDirectory.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { continue }
            if let files = try? fileManager.contentsOfDirectory(
                at: bucketDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) {
                candidates.append(contentsOf: files.filter { $0.pathExtension.lowercased() == "png" })
            }
        }

        let latest = candidates.sorted { left, right in
            let leftDate = (try? left.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rightDate = (try? right.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return leftDate > rightDate
        }.first

        return latest?.path ?? "-"
    }

    private static func resolveLatestScreenshotMarkdownPath(databasePath: String) -> String {
        let latestScreenshotPath = resolveLatestScreenshotPath(databasePath: databasePath)
        guard latestScreenshotPath != "-" else { return "-" }
        let markdownPath = URL(fileURLWithPath: latestScreenshotPath)
            .deletingPathExtension()
            .appendingPathExtension("md")
            .path
        return FileManager.default.fileExists(atPath: markdownPath) ? markdownPath : "-"
    }

    private func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }

    private func shouldRunWatchSyncNow() -> Bool {
        guard let lastWatchSyncAt else { return true }
        return Date().timeIntervalSince(lastWatchSyncAt) >= watchSyncInterval
    }

    private func shouldCaptureFrontmostContextNow() -> Bool {
        guard let lastFrontmostContextCaptureAt else { return true }
        return Date().timeIntervalSince(lastFrontmostContextCaptureAt) >= frontmostContextInterval
    }

    private func refreshStatusIfNeeded() {
        guard let lastStatusRefreshAt else {
            refreshStatus(force: true)
            return
        }

        guard Date().timeIntervalSince(lastStatusRefreshAt) >= statusRefreshInterval else {
            return
        }
        refreshStatus(force: true)
    }

    private func trimActivityBufferIfNeeded() {
        let overflow = activityEntries.count - maxActivityEntries
        guard overflow > 0 else { return }
        activityEntries.removeFirst(overflow)
    }

    var idleThresholdDisplayText: String {
        let roundedMinutes = Int(idleThresholdMinutes.rounded())
        return "\(roundedMinutes) min"
    }

    var autoTaskPlanningIntervalDisplayText: String {
        let roundedMinutes = Int(autoTaskPlanningIntervalMinutes.rounded())
        if roundedMinutes >= 60 {
            let hours = roundedMinutes / 60
            let minutes = roundedMinutes % 60
            if minutes == 0 {
                return "\(hours)h"
            }
            return "\(hours)h \(minutes)m"
        }
        return "\(roundedMinutes) min"
    }

    var privacyRuleCountText: String {
        privacyBlockedKeywords.isEmpty ? "Open" : "\(privacyBlockedKeywords.count) rules"
    }

    var filteredActivityEntries: [ActivityEntry] {
        activityEntries
            .filter { !privacyFilter.matches($0.message) }
            .reversed()
    }

    private var privacyFilter: PrivacyFilter {
        PrivacyFilter(keywords: privacyBlockedKeywords)
    }
}

private struct PendingConversation {
    let targetApp: TargetApp
    var row: ConversationRow
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

struct ActivityEntry: Identifiable {
    let id = UUID()
    let timestamp: String
    let message: String
    let targetApp: TargetApp?
    let isContext: Bool
    let isIntent: Bool
}
