import SwiftUI

@main
struct WeChatSyncDesktopApp: App {
    @StateObject private var model = WeChatSyncAppModel()

    init() {
        NSApplication.shared.applicationIconImage = AppIconFactory.makeAppIcon()
        NSApp.appearance = NSAppearance(named: .aqua)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 920, minHeight: 720)
                .preferredColorScheme(.light)
        }
        .windowResizability(.contentSize)
    }
}

private struct ContentView: View {
    @ObservedObject var model: WeChatSyncAppModel
    @State private var showingSettings = false
    @State private var showingRawFeed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                heroPanel
                outputsPanel
            }
            .padding(22)
        }
        .background(appBackground.ignoresSafeArea())
        .sheet(isPresented: $showingSettings) {
            SettingsSheet(model: model)
                .frame(minWidth: 560, minHeight: 420)
        }
    }

    private var appBackground: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.97, green: 0.98, blue: 0.96),
                    Color(red: 0.92, green: 0.95, blue: 0.98)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [
                    Color(red: 0.99, green: 0.83, blue: 0.72).opacity(0.35),
                    .clear
                ],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 360
            )

            RadialGradient(
                colors: [
                    Color(red: 0.67, green: 0.82, blue: 1.0).opacity(0.28),
                    .clear
                ],
                center: .bottomLeading,
                startRadius: 10,
                endRadius: 320
            )
        }
    }

    private var heroPanel: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 18) {
                HStack(spacing: 14) {
                    MolyLogoMark()
                        .frame(width: 72, height: 72)
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .fill(Color.white.opacity(0.78))
                        )

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Moly Context Hub")
                            .font(.system(size: 34, weight: .semibold, design: .rounded))
                        Text(model.isWatching ? "Listening in the background" : "Ready to start")
                            .font(.system(size: 16, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 0)

                HStack(spacing: 10) {
                    Text("v\(model.appVersionText)")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)

                    secondaryButton("Settings") {
                        showingSettings = true
                    }
                }
            }

            VStack(alignment: .leading, spacing: 14) {
                Text(heroCopy)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 760, alignment: .leading)

                HStack(spacing: 12) {
                    primaryButton(model.isWatching ? "Stop Monitoring" : "Start Monitoring") {
                        model.toggleWatching()
                    }

                    if requiresSetup {
                        Text("Permissions need setup")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color.orange.opacity(0.10))
                            )
                    }
                }
            }
        }
        .padding(24)
        .background(panelBackground(opacity: 0.7))
    }

    private var outputsPanel: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Outputs")
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                        Text("Moly first surfaces the outcomes that matter, then keeps the raw capture stream available below when you want to review it.")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                    statusPill("New", "\(recentResultTasks.count)", tint: .mint)
                    statusPill("Tasks", "\(model.plannedTasks.count)", tint: .green)
                    statusPill("Status", model.plannerStatus, tint: .orange)
                    secondaryButton("Refresh Results") {
                        model.planTasksFromRecentMessages()
                    }
                }

                newResultsContent
                tasksContent
                researchContent
                rawFeedContent
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } label: {
            Label("Results", systemImage: "checklist")
        }
    }

    private var newResultsContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading("New Results", subtitle: "The most recent items Moly has confidently pulled out of your context.")

            if recentResultTasks.isEmpty {
                emptyStateCard("No new confirmed results yet.", tint: .mint)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(recentResultTasks) { task in
                        resultHighlightCard(task)
                    }
                }
            }
        }
    }

    private var tasksContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeading("Confirmed Results", subtitle: "Stable schedules and todos stay here until you clear or act on them.")

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    taskColumn(title: "Schedule", kind: .schedule, tint: .blue)
                    taskColumn(title: "Todo", kind: .todo, tint: .green)
                }
                .padding(12)
            }
            .frame(maxWidth: .infinity, minHeight: 420, maxHeight: 420)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.black.opacity(0.035))
            )
        }
    }

    private var researchContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading("Research", subtitle: "A place for future research briefs and web/deep research outputs.")

            emptyStateCard("No research briefs yet.", tint: .purple)
        }
    }

    private var rawFeedContent: some View {
        DisclosureGroup(isExpanded: $showingRawFeed) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if recentActivityEntries.isEmpty {
                        Text("No raw activity yet.")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .padding(14)
                    } else {
                        ForEach(recentActivityEntries) { entry in
                            ActivityRow(entry: entry)
                        }
                    }
                }
                .padding(12)
            }
            .frame(maxWidth: .infinity, minHeight: 260, maxHeight: 260)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.black.opacity(0.035))
            )
            .padding(.top, 8)
        } label: {
            sectionHeading("Raw Feed", subtitle: "The rolling source capture stays here for review and debugging.")
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.54))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.black.opacity(0.05), lineWidth: 1)
        )
    }

    private var requiresSetup: Bool {
        !model.accessibilityTrusted || !model.screenCaptureTrusted
    }

    private var heroCopy: String {
        if requiresSetup {
            return "Grant permissions once, then start monitoring. Everything else stays out of your way."
        }
        return "Start it, let it quietly collect in the background, and only look at the results when you need them."
    }

    private func taskColumn(title: String, kind: TaskKind, tint: Color) -> some View {
        let tasks = model.plannedTasks.filter { $0.kind == kind }

        return VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)

            if tasks.isEmpty {
                Text("No items")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.white.opacity(0.5))
                    )
            } else {
                ForEach(tasks) { task in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(task.title)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                        Text(task.conversationName)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                        if let dueHint = task.dueHint, !dueHint.isEmpty {
                            Text(dueHint)
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(tint)
                        }
                        Text(task.details)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(4)
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(tint.opacity(0.12))
                    )
                }
            }
        }
    }

    private var recentResultTasks: [PlannedTask] {
        let cutoff = Date().addingTimeInterval(-48 * 3600)
        let recent = model.plannedTasks
            .filter { $0.createdAt >= cutoff }
            .sorted { $0.createdAt > $1.createdAt }
        if !recent.isEmpty {
            return Array(recent.prefix(4))
        }
        return Array(model.plannedTasks.sorted { $0.createdAt > $1.createdAt }.prefix(4))
    }

    private var recentActivityEntries: [ActivityEntry] {
        Array(model.filteredActivityEntries.prefix(20))
    }

    private func resultHighlightCard(_ task: PlannedTask) -> some View {
        let tint: Color = task.kind == .schedule ? .blue : .green

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(task.kind.displayName.uppercased())
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule(style: .continuous)
                            .fill(tint.opacity(0.16))
                    )
                    .foregroundStyle(tint)

                Text(relativeDateText(task.createdAt))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)

                Spacer()
            }

            Text(task.title)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)

            if let dueHint = task.dueHint, !dueHint.isEmpty {
                Text(dueHint)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(tint)
            }

            Text(task.details)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(tint.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(tint.opacity(0.10), lineWidth: 1)
        )
    }

    private func sectionHeading(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
            Text(subtitle)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }

    private func emptyStateCard(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(tint.opacity(0.08))
            )
    }

    private func relativeDateText(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    @ViewBuilder
    private func setupStatusCard(
        title: String,
        subtitle: String,
        isReady: Bool,
        showsAction: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let content = HStack(spacing: 10) {
            Circle()
                .fill(isReady ? Color.green : Color.orange)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                Text(subtitle)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(isReady ? .primary : Color.orange)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showsAction {
                compactChevronButton()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill((isReady ? Color.green : Color.orange).opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke((isReady ? Color.green : Color.orange).opacity(0.10), lineWidth: 1)
        )

        if showsAction {
            Button(action: action) {
                content
            }
            .buttonStyle(.plain)
        } else {
            content
        }
    }

    private func statusPill(_ label: String, _ value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(tint.opacity(0.9))
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Capsule(style: .continuous)
                .fill(tint.opacity(0.14))
        )
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .padding(.horizontal, 22)
            .padding(.vertical, 13)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.black.opacity(0.92))
            )
            .foregroundStyle(.white)
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.74))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.black.opacity(0.06), lineWidth: 1)
            )
            .foregroundStyle(.primary)
    }

    private func compactChevronButton() -> some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 13, weight: .bold))
            .frame(width: 42, height: 42)
            .contentShape(Circle())
            .background(
                Circle()
                    .fill(Color.white.opacity(0.84))
            )
            .overlay(
                Circle()
                    .stroke(Color.black.opacity(0.05), lineWidth: 1)
            )
            .foregroundStyle(.primary)
    }

    private func panelBackground(opacity: Double) -> some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(Color.white.opacity(opacity))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.black.opacity(0.05), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.04), radius: 18, x: 0, y: 10)
    }

    private func statusCapsule(_ label: String, _ value: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
            Text("\(label): \(value)")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.64))
        )
    }
}

private struct SignalWaveView: View {
    let tint: Color
    let amplitude: Double
    let isActive: Bool
    let signalText: String

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isActive)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 5) {
                ForEach(0..<24, id: \.self) { index in
                    let value = barHeight(index: index, phase: phase)
                    RoundedRectangle(cornerRadius: 999, style: .continuous)
                        .fill(tint.opacity(barOpacity(index: index)))
                        .frame(width: 5, height: value)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func barHeight(index: Int, phase: TimeInterval) -> CGFloat {
        let base = 6.0
        let seed = contentSeed(index: index)
        let wave = (sin(phase * 5.8 + Double(index) * 0.42 + seed * 8.0) + 1) / 2
        let ripple = (sin(phase * 2.6 + Double(index) * 0.14 + seed * 17.0) + 1) / 2
        let intensity = isActive ? amplitude : 0.15
        let contour = 0.55 + seed * 0.9
        return CGFloat(base + (wave * 0.72 + ripple * 0.28) * (10 + 24 * intensity) * contour)
    }

    private func barOpacity(index: Int) -> Double {
        let seed = contentSeed(index: index)
        return 0.34 + seed * 0.56
    }

    private func contentSeed(index: Int) -> Double {
        let bytes = Array(signalText.utf8)
        guard !bytes.isEmpty else { return 0.35 }
        let byte = bytes[index % bytes.count]
        return Double(byte) / 255.0
    }
}

private struct FlowLayout<Item: Identifiable, Content: View>: View {
    let spacing: CGFloat
    let lineSpacing: CGFloat
    let items: [Item]
    let content: (Item) -> Content

    init(spacing: CGFloat, lineSpacing: CGFloat, items: [Item], @ViewBuilder content: @escaping (Item) -> Content) {
        self.spacing = spacing
        self.lineSpacing = lineSpacing
        self.items = items
        self.content = content
    }

    var body: some View {
        GeometryReader { proxy in
            generateContent(in: proxy)
        }
        .frame(minHeight: 32)
    }

    private func generateContent(in geometry: GeometryProxy) -> some View {
        var width = CGFloat.zero
        var height = CGFloat.zero

        return ZStack(alignment: .topLeading) {
            ForEach(items) { item in
                content(item)
                    .alignmentGuide(.leading) { dimension in
                        if abs(width - dimension.width) > geometry.size.width {
                            width = 0
                            height -= dimension.height + lineSpacing
                        }
                        let result = width
                        if item.id == items.last?.id {
                            width = 0
                        } else {
                            width -= dimension.width + spacing
                        }
                        return result
                    }
                    .alignmentGuide(.top) { dimension in
                        let result = height
                        if item.id == items.last?.id {
                            height = 0
                        }
                        return result
                    }
            }
        }
    }
}

private struct ActivityRow: View {
    let entry: ActivityEntry
    var isFeatured = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(entry.timestamp)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                tagView
                Spacer(minLength: 0)
            }

            Text(entry.message)
                .font(.system(size: isFeatured ? 13 : 12, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(isFeatured ? 2 : 3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .padding(.leading, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(backgroundTint.opacity(isFeatured ? 0.20 : 0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(backgroundTint.opacity(isFeatured ? 0.22 : 0.08), lineWidth: 1)
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 999, style: .continuous)
                .fill(backgroundTint)
                .frame(width: 5)
                .padding(.vertical, 12)
                .padding(.leading, 12)
        }
    }

    private var backgroundTint: Color {
        if entry.isContext {
            return .indigo
        }
        if entry.isIntent {
            return .pink
        }
        guard let targetApp = entry.targetApp else { return .gray }
        return appTint(for: targetApp)
    }

    private var tagView: some View {
        Group {
            if entry.isContext {
                activityTag("CONTEXT", tint: .indigo)
            } else if entry.isIntent {
                activityTag("INTENT", tint: .pink)
            } else if let targetApp = entry.targetApp {
                activityTag(targetApp.displayName.uppercased(), tint: appTint(for: targetApp))
            } else {
                activityTag("SYSTEM", tint: .gray)
            }
        }
    }

    private func activityTag(_ label: String, tint: Color) -> some View {
        Text(label)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.18))
            )
            .foregroundStyle(tint)
    }

    private func appTint(for targetApp: TargetApp) -> Color {
        switch targetApp {
        case .weChat:
            return Color(red: 0.14, green: 0.64, blue: 0.31)
        case .lark:
            return Color(red: 0.15, green: 0.45, blue: 0.96)
        }
    }
}

private struct SettingsSheet: View {
    @ObservedObject var model: WeChatSyncAppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Settings")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                Spacer()
                Button("Done") {
                    dismiss()
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    settingsSection("Setup") {
                        HStack {
                            Button("Open Accessibility") {
                                model.setupPermissions()
                            }
                            Button("Open Screen Recording") {
                                model.openScreenRecordingSettings()
                            }
                            Button("Open Export Root") {
                                model.revealExportRoot()
                            }
                        }
                        Text("Use this area for first-time setup. Permissions do not need to stay on the home screen once they are granted.")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }

                    settingsSection("Capture Controls") {
                        Toggle("Foreground Assist", isOn: $model.foregroundAssistEnabled)
                        Toggle("Idle Auto-Open", isOn: $model.idleAutoOpenEnabled)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Watch Interval: \(Int(model.intervalSeconds))s")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                            Slider(value: $model.intervalSeconds, in: 2...30, step: 1)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Idle Threshold: \(model.idleThresholdDisplayText)")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                            Slider(value: $model.idleThresholdMinutes, in: 1...30, step: 1)
                        }
                    }

                    settingsSection("Planner API") {
                        TextField("Base URL", text: $model.plannerAPIBaseURL)
                            .textFieldStyle(.roundedBorder)
                        SecureField("API Key", text: $model.plannerAPIKey)
                            .textFieldStyle(.roundedBorder)
                        TextField("Model", text: $model.plannerModelName)
                            .textFieldStyle(.roundedBorder)
                        Toggle("Auto Plan Tasks", isOn: $model.autoTaskPlanningEnabled)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Auto Plan Interval: \(model.autoTaskPlanningIntervalDisplayText)")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                            Slider(value: $model.autoTaskPlanningIntervalMinutes, in: 5...360, step: 5)
                        }
                        HStack {
                            Button("Save Planner Settings") {
                                model.persistPlannerSettings()
                            }
                            Button("Plan Tasks Now") {
                                model.planTasksFromRecentMessages()
                            }
                            Button("Reveal Tasks Markdown") {
                                model.revealTasksMarkdown()
                            }
                        }
                        Text("If these fields are empty, Moly falls back to local heuristics. Enter Screenshot also reuses this API for multimodal extraction.")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }

                    settingsSection("Privacy Filter") {
                        Text("Keywords or contact names entered here are blocked before storage, markdown export, task planning, and screenshot intent analysis.")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)

                        HStack(spacing: 10) {
                            TextField("Add keyword or contact name", text: $model.privacyKeywordDraft)
                                .textFieldStyle(.roundedBorder)
                            Button("Add") {
                                model.addPrivacyKeyword()
                            }
                            .disabled(model.privacyKeywordDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            Button("Clear All") {
                                model.clearPrivacyKeywords()
                            }
                            .disabled(model.privacyBlockedKeywords.isEmpty)
                        }

                        if model.privacyBlockedKeywords.isEmpty {
                            Text("No privacy filters yet.")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                        } else {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(model.privacyBlockedKeywords, id: \.self) { keyword in
                                    HStack {
                                        Text(keyword)
                                            .font(.system(size: 12, weight: .medium, design: .rounded))
                                        Spacer()
                                        Button("Remove") {
                                            model.removePrivacyKeyword(keyword)
                                        }
                                        .buttonStyle(.borderless)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(Color.red.opacity(0.08))
                                    )
                                }
                            }
                        }
                    }

                    settingsSection("Storage") {
                        settingsBlock("Database", value: model.databasePath)
                        settingsBlock("Export Root", value: model.exportRootPath)
                        settingsBlock("Tasks Markdown", value: model.tasksMarkdownPath)
                        settingsBlock("Intent Markdown", value: model.intentCaptureMarkdownPath)
                        settingsBlock("Screenshot Folder", value: model.intentCaptureDirectoryPath)
                        settingsBlock("Crash Report", value: model.crashReportPath)
                        settingsBlock("Chrome Extension", value: model.chromeExtensionPath)
                        settingsBlock("Bundle Path", value: model.bundlePath)
                        settingsBlock("Executable Path", value: model.executablePath)

                        if !model.installedPaths.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Detected install paths")
                                    .font(.headline)
                                ForEach(model.installedPaths, id: \.self) { path in
                                    Text(path)
                                        .font(.system(size: 11, design: .monospaced))
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }

                    if model.isDevelopmentBuild {
                        Text("This app is running from a development build path. Accessibility permissions are more reliable when the app is installed to a stable location such as /Applications.")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(20)
        .background(Color.white.opacity(0.96))
    }

    private func settingsBlock(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.03))
        )
    }
}
