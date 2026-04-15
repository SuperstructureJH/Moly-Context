import Foundation

struct PlannerSettings {
    let apiBaseURL: String
    let apiKey: String
    let modelName: String

    var isConfigured: Bool {
        !apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct PlannerIntentContext {
    let capturedAt: Date
    let appName: String
    let windowTitle: String
    let summary: String
    let intentBullets: [String]
    let followUps: [String]
    let ocrPreview: [String]
    let accessibilityPreview: [String]
}

private enum PlannerCandidateType {
    case scheduleSignal
    case todoRequest
    case selfCommitment
}

private struct PlannerCandidate {
    let capturedAt: Date
    let type: PlannerCandidateType
    let conversationName: String
    let senderLabel: String
    let recipientLabel: String
    let text: String
    let dueHint: String?
    let reason: String
}

private struct PlannerContextNote {
    let capturedAt: Date
    let appName: String
    let windowTitle: String
    let lines: [String]
}

enum TaskPlanner {
    static func planTasks(
        from messages: [StoredMessage],
        intents: [PlannerIntentContext],
        settings: PlannerSettings
    ) async throws -> [PlannedTask] {
        let cleanedMessages = sanitize(messages: messages)
        let cleanedIntents = sanitize(intents: intents)
        let candidates = extractCandidates(from: cleanedMessages)
        let contextNotes = extractContextNotes(from: cleanedIntents)

        guard !candidates.isEmpty else { return [] }

        if settings.isConfigured {
            do {
                return try await planTasksWithAPI(candidates: candidates, contextNotes: contextNotes, settings: settings)
            } catch {
                return heuristicTasks(from: candidates)
            }
        }

        return heuristicTasks(from: candidates)
    }

    private static func planTasksWithAPI(
        candidates: [PlannerCandidate],
        contextNotes: [PlannerContextNote],
        settings: PlannerSettings
    ) async throws -> [PlannedTask] {
        guard let url = URL(string: normalizedBaseURL(settings.apiBaseURL) + "/chat/completions") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")

        let payload = ChatCompletionRequest(
            model: settings.modelName,
            temperature: 0.2,
            responseFormat: ResponseFormat(type: "json_object"),
            messages: [
                ChatMessage(role: "system", content: systemPrompt),
                ChatMessage(role: "user", content: buildUserPrompt(candidates: candidates, contextNotes: contextNotes)),
            ]
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            throw URLError(.badServerResponse)
        }

        let completion = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        let content = completion.choices.first?.message.content ?? ""
        let responseData = Data(content.utf8)
        let planned = try JSONDecoder().decode(PlannerResponse.self, from: responseData)
        let tasks = planned.tasks.map { item in
            PlannedTask(
                kind: item.kind,
                title: item.title,
                details: item.details,
                conversationName: item.conversationName,
                sourceMessage: item.sourceMessage,
                dueHint: item.dueHint,
                confidence: item.confidence
            )
        }
        return postProcess(tasks)
    }

    private static func heuristicTasks(from candidates: [PlannerCandidate]) -> [PlannedTask] {
        var tasks: [PlannedTask] = []
        var seen = Set<String>()

        for candidate in candidates {
            let kind = candidate.type == .scheduleSignal ? TaskKind.schedule : .todo
            let title = heuristicTitle(for: candidate)
            let fingerprint = "\(kind.rawValue)|\(candidate.conversationName)|\(title)"
            guard !seen.contains(fingerprint) else { continue }
            seen.insert(fingerprint)
            tasks.append(
                PlannedTask(
                    kind: kind,
                    title: title,
                    details: candidate.reason,
                    conversationName: candidate.conversationName,
                    sourceMessage: "\(candidate.senderLabel) -> \(candidate.recipientLabel): \(candidate.text)",
                    dueHint: candidate.dueHint,
                    confidence: candidate.type == .scheduleSignal ? 0.68 : 0.64
                )
            )
        }

        return Array(postProcess(tasks).prefix(8))
    }

    private static func extractCandidates(from messages: [StoredMessage]) -> [PlannerCandidate] {
        messages.compactMap { message in
            let text = compactSentence(message.text, maxLength: 200)
            let normalized = normalizeTaskText(text)
            guard !text.isEmpty else { return nil }
            guard !looksLikePreviewNoise(text) else { return nil }
            guard !looksLikeCasualChat(normalized) else { return nil }

            let sender = message.senderLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            let recipient = message.recipientLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            let isFromSelf = normalizeTaskText(sender) == "self" || sender.contains("我说")
            let dueHint = extractDateHint(from: text)

            if looksLikeScheduleCandidate(normalized, dueHint: dueHint) {
                return PlannerCandidate(
                    capturedAt: message.capturedAt,
                    type: .scheduleSignal,
                    conversationName: message.conversationName,
                    senderLabel: sender,
                    recipientLabel: recipient,
                    text: text,
                    dueHint: dueHint,
                    reason: "消息里出现了明确会议/发生时间/约定信息。"
                )
            }

            if !isFromSelf, looksLikeIncomingRequest(normalized) {
                return PlannerCandidate(
                    capturedAt: message.capturedAt,
                    type: .todoRequest,
                    conversationName: message.conversationName,
                    senderLabel: sender,
                    recipientLabel: recipient,
                    text: text,
                    dueHint: dueHint,
                    reason: "对方明确提出了需要我处理、回复、确认或安排的动作。"
                )
            }

            if isFromSelf, looksLikeSelfCommitment(normalized) {
                return PlannerCandidate(
                    capturedAt: message.capturedAt,
                    type: .selfCommitment,
                    conversationName: message.conversationName,
                    senderLabel: sender,
                    recipientLabel: recipient,
                    text: text,
                    dueHint: dueHint,
                    reason: "我在对话里明确承诺了稍后去做一件事。"
                )
            }

            return nil
        }
    }

    private static func extractContextNotes(from intents: [PlannerIntentContext]) -> [PlannerContextNote] {
        intents.compactMap { intent in
            let identity = "\(intent.appName) · \(intent.windowTitle)"
            guard !looksLikeToolingNoise(identity) else { return nil }

            let lines = intent.ocrPreview
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .filter { !looksLikeOCRGarbage($0) }
                .filter { !looksLikeAccessibilityNoise($0) }
                .prefix(5)

            guard !lines.isEmpty else { return nil }

            return PlannerContextNote(
                capturedAt: intent.capturedAt,
                appName: intent.appName,
                windowTitle: intent.windowTitle,
                lines: Array(lines)
            )
        }
    }

    private static func compactTitle(from text: String) -> String {
        let compact = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if compact.count <= 48 {
            return compact
        }
        let endIndex = compact.index(compact.startIndex, offsetBy: 48)
        return String(compact[..<endIndex]) + "..."
    }

    private static func extractDateHint(from text: String) -> String? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        let range = NSRange(location: 0, length: text.utf16.count)
        guard let match = detector?.firstMatch(in: text, options: [], range: range) else {
            let keywords = ["今天", "明天", "后天", "本周", "下周", "今晚", "下午", "上午"]
            return keywords.first(where: { text.contains($0) })
        }

        guard let date = match.date else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private static func buildUserPrompt(candidates: [PlannerCandidate], contextNotes: [PlannerContextNote]) -> String {
        let candidateLines = candidates.prefix(60).map { candidate in
            let typeLabel: String
            switch candidate.type {
            case .scheduleSignal:
                typeLabel = "schedule_signal"
            case .todoRequest:
                typeLabel = "todo_request"
            case .selfCommitment:
                typeLabel = "self_commitment"
            }
            return """
            [\(timestamp(candidate.capturedAt))] [\(typeLabel)] [\(candidate.conversationName)] \(candidate.senderLabel) -> \(candidate.recipientLabel): \(candidate.text)
            """
        }

        let noteLines = contextNotes.prefix(12).map { note in
            return """
            [\(timestamp(note.capturedAt))] [\(note.appName) · \(note.windowTitle)]
            \(note.lines.map { "- \($0)" }.joined(separator: "\n"))
            """
        }

        return """
        当前时间：\(timestamp(Date()))

        你是 Moly Context Hub 的个人执行助手。请基于最近 1 小时的“候选动作”与“上下文备注”，只提取真正值得执行的事项，只保留两类：
        1. schedule: 需要关注的日程、会议、时间节点、约定
        2. todo: 需要跟进、处理、提交、确认、回复的事项

        重要规则：
        - 宁缺毋滥，没有明确行动价值就不要输出
        - 候选动作已经是经过预筛选的“可能值得执行”的句子，请优先依据“谁对谁说了什么”来判断
        - 上下文备注只是辅助理解，不允许单独把 OCR 文本直接变成任务
        - 只有出现下面这些情形才允许输出 todo：
          1) 别人明确请求我做一件事
          2) 我明确承诺稍后去做一件事
          3) 出现明确的待回复、待确认、待安排、待发送、待提交、待跟进
        - 只有出现下面这些情形才允许输出 schedule：
          1) 出现明确的会议时间、日期、时间段
          2) 出现明确约定见面、出行、截止时间
        - 忽略聊天列表预览、未读数、置顶、头像、表情、系统 UI 文本、搜索词碎片
        - 忽略终端、shell、代码编辑器中的开发噪声，除非出现非常明确且完整的行动承诺
        - 忽略纯闲聊、感叹、情绪表达、日常状态同步、吐槽、寒暄、资讯标题，除非里面明确带有要做的事
        - 如果一句话只是描述现状、发表意见、吐槽、转述消息，而没有形成明确动作，不要输出
        - 优先保留“和我本人有关、我需要处理、我需要参加、我需要回复”的事项
        - 如果同一件事在消息和截图里都出现，合并成一条
        - 必须先判断“是否真的需要生成 schedule 或 todo”，如果不需要就不要输出
        - schedule 只有在出现明确的会议、约定、时间安排、出行时间点时才输出
        - todo 只有在出现明确动作承诺、待处理请求、待回复、待转发、待安排、待提交时才输出
        - 不要把“明天上班”“我周日不在”“哈哈哈哈”“行”“客气啦”这种自然聊天判成任务
        - 不要把单独的时间戳、日期行、链接标题、会议号本身输出成任务
        - title 必须改写成非常简短的人类动作标题，例如“回复蔡斯扬关于进 app 的问题”、“参加明天 11:00 腾讯会议”
        - details 用 1 句话解释为什么它是 task
        - conversationName 填最可信的来源
        - sourceMessage 只保留最关键的证据句，不要塞长段噪声；如果证据句太长，请先提炼
        - dueHint 没有明确时间就写空字符串
        - 最多输出 6 条，宁少勿滥
        - 如果没有高质量事项，宁可返回空数组

        输出 JSON，格式:
        {
          "tasks": [
            {
              "kind": "schedule" | "todo",
              "title": "短标题",
              "details": "简短说明",
              "conversationName": "来源会话",
              "sourceMessage": "原消息摘要",
              "dueHint": "时间提示，没有就写空字符串",
              "confidence": 0.0-1.0
            }
          ]
        }

        如果没有可信任务，返回 {"tasks": []}。

        最近 1 小时候选动作:
        \(candidateLines.isEmpty ? "- None" : candidateLines.joined(separator: "\n"))

        最近 1 小时上下文备注（仅辅助理解，不可单独成任务）:
        \(noteLines.isEmpty ? "- None" : noteLines.joined(separator: "\n\n"))
        """
    }

    private static var systemPrompt: String {
        """
        You extract only high-confidence actionable schedule/todo items from pre-filtered candidate actions plus optional context notes.
        Treat OCR/context notes as supporting evidence only, never as standalone tasks.
        Classify conservatively. Casual conversation, OCR fragments, status updates, and draft content are not tasks.
        Return only valid JSON.
        Be conservative: if the evidence is weak, output no task.
        """
    }

    private static func normalizedBaseURL(_ url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("/v1") {
            return trimmed
        }
        if trimmed.hasSuffix("/") {
            return trimmed + "v1"
        }
        return trimmed + "/v1"
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private static func sanitize(messages: [StoredMessage]) -> [StoredMessage] {
        messages.filter { message in
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= 4 else { return false }
            guard !looksLikePreviewNoise(text) else { return false }
            guard !looksLikeToolingNoise(message.conversationName + " " + text) else { return false }
            return true
        }
    }

    private static func sanitize(intents: [PlannerIntentContext]) -> [PlannerIntentContext] {
        intents.filter { intent in
            let identity = "\(intent.appName) \(intent.windowTitle)"
            guard !looksLikeToolingNoise(identity) else { return false }
            let meaningfulOCR = intent.ocrPreview.filter { !looksLikeOCRGarbage($0) }
            let meaningfulAccessibility = intent.accessibilityPreview.filter { !looksLikeAccessibilityNoise($0) }
            let hasMeaningfulSummary = !intent.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                !looksLikeOCRGarbage(intent.summary)
            return hasMeaningfulSummary || !meaningfulAccessibility.isEmpty || !meaningfulOCR.isEmpty
        }
    }

    private static func looksLikePreviewNoise(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let noiseTokens = [
            "置顶", "未读消息", "账户头像", "聊天文件", "[表情]", "[语音]", "语音通话", "视频通话",
            "search", "messages", "contacts", "profilebutton", "profileflexview"
        ]
        if noiseTokens.contains(where: { lowered.contains($0.lowercased()) }) {
            return true
        }
        let commaCount = text.filter { $0 == "," || $0 == "，" }.count
        return commaCount >= 4 && text.count < 80
    }

    private static func looksLikeSchedule(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let scheduleSignals = ["明天", "后天", "今天", "本周", "下周", "点", "会议", "开会", "日程", "腾讯会议", "call", "meeting"]
        return scheduleSignals.contains { lowered.contains($0.lowercased()) }
    }

    private static func looksLikeScheduleCandidate(_ normalized: String, dueHint: String?) -> Bool {
        if dueHint?.isEmpty == false && looksLikeConcreteSchedule(normalized) {
            return true
        }
        let strongerSignals = ["会议", "开会", "腾讯会议", "meeting", "call", "约在", "约好", "聚餐", "拜访", "见面"]
        return strongerSignals.contains { normalized.contains(normalizeTaskText($0)) } && dueHint?.isEmpty == false
    }

    private static func looksLikeIncomingRequest(_ normalized: String) -> Bool {
        let directSignals = [
            "帮我", "帮忙", "麻烦你", "麻烦您", "请你", "请您", "你看看", "你帮我",
            "回复", "确认", "安排", "发我", "转发", "跟进", "提交", "处理", "提醒我", "记得"
        ]
        if directSignals.contains(where: { normalized.contains(normalizeTaskText($0)) }) {
            return true
        }
        let softerSignals = ["需要你", "需要您", "辛苦", "劳烦", "得看", "得处理"]
        return softerSignals.contains { normalized.contains(normalizeTaskText($0)) }
    }

    private static func looksLikeSelfCommitment(_ normalized: String) -> Bool {
        let commitmentSignals = [
            "我来", "我去", "我帮你", "我帮您", "我安排", "我处理", "我回复", "我发你",
            "我发您", "我提交", "我跟进", "我晚点", "我稍后", "我一会", "我回头"
        ]
        return commitmentSignals.contains { normalized.contains(normalizeTaskText($0)) }
    }

    private static func heuristicTitle(for candidate: PlannerCandidate) -> String {
        switch candidate.type {
        case .scheduleSignal:
            return compactTitle(from: candidate.text)
        case .todoRequest:
            return compactTitle(from: "处理：\(candidate.text)")
        case .selfCommitment:
            return compactTitle(from: "跟进：\(candidate.text)")
        }
    }

    private static func postProcess(_ tasks: [PlannedTask]) -> [PlannedTask] {
        var seen = Set<String>()
        return tasks.compactMap { task in
            guard isCredible(task) else { return nil }
            let normalizedKey = "\(task.kind.rawValue)|\(normalizeTaskText(task.title))|\(normalizeTaskText(task.sourceMessage))"
            guard !seen.contains(normalizedKey) else { return nil }
            seen.insert(normalizedKey)
            return sanitize(task)
        }
    }

    private static func sanitize(_ task: PlannedTask) -> PlannedTask {
        PlannedTask(
            id: task.id,
            kind: task.kind,
            title: compactTitle(from: task.title),
            details: compactSentence(task.details, maxLength: 120),
            conversationName: task.conversationName,
            sourceMessage: normalizedSentence(task.sourceMessage),
            dueHint: task.dueHint,
            confidence: task.confidence,
            createdAt: task.createdAt
        )
    }

    private static func isCredible(_ task: PlannedTask) -> Bool {
        let title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let evidence = task.sourceMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = normalizeTaskText([title, evidence, task.details].joined(separator: " "))

        guard !title.isEmpty, !evidence.isEmpty else { return false }
        guard task.confidence >= 0.6 else { return false }
        guard !looksLikeBareTimestamp(title), !looksLikeBareTimestamp(evidence) else { return false }
        guard !looksLikeCasualChat(normalized) else { return false }
        guard !looksLikePreviewNoise(normalized) else { return false }

        switch task.kind {
        case .schedule:
            return task.dueHint?.isEmpty == false || looksLikeConcreteSchedule(normalized)
        case .todo:
            return looksLikeActionableTodo(normalized)
        }
    }

    private static func looksLikeBareTimestamp(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.range(of: #"^\d{4}年\d{1,2}月\d{1,2}日(\s+\d{1,2}:\d{2})?$"#, options: .regularExpression) != nil {
            return true
        }
        if trimmed.range(of: #"^\d{4}-\d{2}-\d{2}(\s+\d{2}:\d{2})?$"#, options: .regularExpression) != nil {
            return true
        }
        return trimmed.range(of: #"^\d{1,2}:\d{2}$"#, options: .regularExpression) != nil
    }

    private static func looksLikeCasualChat(_ text: String) -> Bool {
        let casualSignals = [
            "哈哈", "呵呵", "行", "好的", "客气", "喝水", "下班过去", "tmd", "上班",
            "太好了", "不在", "那喝的挺多", "你那个", "刮沙尘暴", "有要"
        ]
        return casualSignals.contains { text.contains(normalizeTaskText($0)) }
    }

    private static func looksLikeConcreteSchedule(_ text: String) -> Bool {
        let signals = ["会议", "开会", "meeting", "腾讯会议", "约", "约定", "几点", "日程", "11:00", "12:00"]
        return signals.contains { text.contains(normalizeTaskText($0)) }
    }

    private static func looksLikeActionableTodo(_ text: String) -> Bool {
        let signals = [
            "安排", "回复", "发我", "转发", "跟进", "联系", "提交", "处理", "确认",
            "我帮你安排", "需要转发", "找我", "发我一下", "安排一下"
        ]
        if signals.contains(where: { text.contains(normalizeTaskText($0)) }) {
            return true
        }
        let strongerSignals = [
            "麻烦你", "请你", "帮我", "帮忙", "你看看", "记得", "需要你", "待回复", "待确认"
        ]
        return strongerSignals.contains { text.contains(normalizeTaskText($0)) }
    }

    private static func looksLikeToolingNoise(_ text: String) -> Bool {
        let normalized = normalizeTaskText(text)
        let tokens = [
            "终端", "zsh", "bash", "terminal", "codex", "claude code", "cursor",
            "xcode", "visual studio code", "vscode", "molyprddemo", "80×24"
        ]
        return tokens.contains { normalized.contains(normalizeTaskText($0)) }
    }

    private static func looksLikeOCRGarbage(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        let cjkCount = trimmed.unicodeScalars.filter { (0x4E00...0x9FFF).contains(Int($0.value)) }.count
        let asciiLetterCount = trimmed.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        let symbolCount = trimmed.unicodeScalars.filter {
            !CharacterSet.alphanumerics.contains($0) && !CharacterSet.whitespaces.contains($0)
        }.count

        if trimmed.count <= 3 { return true }
        if symbolCount >= max(4, trimmed.count / 3) { return true }
        if cjkCount == 0 && asciiLetterCount < 4 { return true }
        return false
    }

    private static func looksLikeAccessibilityNoise(_ text: String) -> Bool {
        let normalized = normalizeTaskText(text)
        if normalized.count < 2 { return true }
        let tokens = [
            "messenger-chat", "发送给", "chat with chatgpt", "ask anything",
            "在 google 中搜索", "书签", "top100 ai", "aitools by me"
        ]
        return tokens.contains { normalized.contains(normalizeTaskText($0)) }
    }

    private static func normalizeTaskText(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func compactSentence(_ text: String, maxLength: Int) -> String {
        let compact = normalizedSentence(text)
        guard compact.count > maxLength else { return compact }
        let index = compact.index(compact.startIndex, offsetBy: maxLength)
        return String(compact[..<index]) + "..."
    }

    private static func normalizedSentence(_ text: String) -> String {
        let compact = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return compact
    }
}

private struct ChatCompletionRequest: Encodable {
    let model: String
    let temperature: Double
    let responseFormat: ResponseFormat
    let messages: [ChatMessage]

    enum CodingKeys: String, CodingKey {
        case model
        case temperature
        case responseFormat = "response_format"
        case messages
    }
}

private struct ResponseFormat: Encodable {
    let type: String
}

private struct ChatMessage: Encodable {
    let role: String
    let content: String
}

private struct ChatCompletionResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: ChoiceMessage
    }

    struct ChoiceMessage: Decodable {
        let content: String
    }
}

private struct PlannerResponse: Decodable {
    let tasks: [PlannerTask]
}

private struct PlannerTask: Decodable {
    let kind: TaskKind
    let title: String
    let details: String
    let conversationName: String
    let sourceMessage: String
    let dueHint: String?
    let confidence: Double
}
