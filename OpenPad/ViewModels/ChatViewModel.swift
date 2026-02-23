import Foundation
import Combine


struct OpenClawHealthCheck {
    let level: String // ok|warn
    let message: String
}

@MainActor
final class OpenClawLiteHealthService {
    static let shared = OpenClawLiteHealthService()
    private let runtime = LocalRuntimeConfig.shared
    private let lite = OpenClawLiteConfig.shared

    func runChecks(lastLatencyMs: Int, lastError: String, successCount: Int, errorCount: Int) -> [OpenClawHealthCheck] {
        var out: [OpenClawHealthCheck] = []
        if runtime.loadProvider() == .mlx {
            if !lite.isLowPowerModeEnabled() { out.append(.init(level: "warn", message: "MLX sin modo ahorro puede calentar iPad.")) }
            if runtime.isSeparateMLXToolsModelEnabled() { out.append(.init(level: "warn", message: "Modelo separado para tools aumenta riesgo de OOM.")) }
        }
        if errorCount > successCount && errorCount >= 3 { out.append(.init(level: "warn", message: "Tasa de error alta; revisa modelo o red.")) }
        if lastLatencyMs > 12000 { out.append(.init(level: "warn", message: "Latencia alta (>12s).")) }
        if !lastError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(.init(level: "warn", message: "Último error: \(String(lastError.prefix(80)))")) }
        if out.isEmpty { out.append(.init(level: "ok", message: "Sistema saludable ✅")) }
        return out
    }
}

@MainActor
final class OpenClawLiteWorkflowService {
    static let shared = OpenClawLiteWorkflowService()
    private let model = LocalModelService()
    private let tools = OpenClawLiteTools()

    func run(goal: String, recentMessages: [ChatMessage]) async -> (text: String, trace: [String]) {
        var trace: [String] = ["Workflow: analyze", "Workflow: plan", "Workflow: execute", "Workflow: verify"]
        let step = goal.lowercased().contains("http") ? "summarize_url" : "keyword_extract"
        let result: OpenClawToolResult = step == "summarize_url"
            ? await tools.execute(name: "summarize_url", arguments: ["url": extractFirstURL(goal) ?? ""])
            : await tools.execute(name: "keyword_extract", arguments: ["text": goal, "top": "10"])
        trace.append("Step \(step): \(result.ok ? "ok" : "error")")

        let prompt = "Resultado workflow para objetivo: \(goal)\n\nSalida:\n\(result.output)\n\nResponde en español con resumen final."
        let out = (try? await model.runLocal(prompt: prompt, purpose: .chat)) ?? result.output
        return (out, trace)
    }

    private func extractFirstURL(_ text: String) -> String? {
        let pattern = #"https?://[^\s\)\]\>\"]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = regex.firstMatch(in: text, options: [], range: range), let r = Range(m.range, in: text) else { return nil }
        return String(text[r])
    }
}


enum RoutePreference: String, CaseIterable, Identifiable {
    case auto = "AUTO"
    case local = "LOCAL"
    case remote = "REMOTE"

    var id: String { rawValue }
    var title: String { rawValue }
}

@MainActor
final class ChatViewModel: ObservableObject {
    private let runtimeConfig = LocalRuntimeConfig.shared
    private let chatStore = OpenClawLiteChatStore.shared
    private let healthService = OpenClawLiteHealthService.shared
    private let workflowService = OpenClawLiteWorkflowService.shared

    @Published var messages: [ChatMessage] = []
    @Published var inputText: String = ""
    @Published var isLoading = false
    @Published var lastRoute: String = "AUTO"
    @Published var lastReason: String = "Listo"
    @Published var routePreference: RoutePreference = .auto {
        didSet { UserDefaults.standard.set(routePreference.rawValue, forKey: Self.routePreferenceKey) }
    }
    @Published var toolTrace: [String] = []
    @Published var lastLatencyMs: Int = 0
    @Published var lastErrorText: String = ""
    @Published var successCount: Int = 0
    @Published var errorCount: Int = 0
    @Published var healthChecks: [OpenClawHealthCheck] = []

    @Published var chatSessions: [ChatSessionSummary] = []
    @Published var activeSessionId: UUID?

    private static let routePreferenceKey = "chat.routePreference"

    private let routing = RoutingService()
    private let remoteService = RemoteModelService()
    private let openClawLite = OpenClawLiteAgentService()

    init() {
        if let saved = UserDefaults.standard.string(forKey: Self.routePreferenceKey),
           let pref = RoutePreference(rawValue: saved) {
            routePreference = pref
        } else {
            routePreference = .local
        }

        if UserDefaults.standard.string(forKey: "local.runtime.provider") == nil {
            runtimeConfig.saveProvider(.mlx)
        }

        loadOrCreateInitialSession()
    }


    func renameChat(sessionId: UUID, title: String) {
        chatStore.renameSession(sessionId: sessionId, title: title)
        refreshSessions()
    }

    func deleteChat(sessionId: UUID) {
        chatStore.deleteSession(sessionId: sessionId)
        refreshSessions()
        if activeSessionId == sessionId {
            if let first = chatSessions.first {
                activeSessionId = first.id
                messages = chatStore.loadMessages(sessionId: first.id)
            } else {
                let s = chatStore.createSession(title: "Nuevo chat")
                refreshSessions()
                activeSessionId = s.id
                messages = []
            }
        }
    }


    func archiveChat(sessionId: UUID, archived: Bool) {
        chatStore.setArchived(sessionId: sessionId, archived: archived)
        refreshSessions()
        if archived && activeSessionId == sessionId {
            if let first = chatSessions.first {
                activeSessionId = first.id
                messages = chatStore.loadMessages(sessionId: first.id)
            } else {
                createNewChat()
            }
        }
    }

    func exportChatMarkdown(sessionId: UUID) -> String {
        chatStore.exportSessionMarkdown(sessionId: sessionId)
    }

    func togglePinChat(sessionId: UUID) {
        guard let current = chatSessions.first(where: { $0.id == sessionId }) else { return }
        chatStore.setPinned(sessionId: sessionId, pinned: !current.pinned)
        refreshSessions()
    }

    func createNewChat() {
        let session = chatStore.createSession(title: "Nuevo chat")
        refreshSessions()
        activeSessionId = session.id
        messages = []
    }

    func selectChat(sessionId: UUID) {
        activeSessionId = sessionId
        messages = chatStore.loadMessages(sessionId: sessionId)
    }

    func send() {
        let prompt = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isLoading else { return }

        inputText = ""
        messages.append(ChatMessage(role: "user", text: prompt))
        trimMessagesIfNeeded()
        persistActiveSession()
        isLoading = true

        Task {
            let responseText = await runPipeline(prompt: prompt)
            messages.append(ChatMessage(role: "assistant", text: responseText))
            trimMessagesIfNeeded()
            persistActiveSession()
            isLoading = false
        }
    }

    private func loadOrCreateInitialSession() {
        refreshSessions()
        if let first = chatSessions.first {
            activeSessionId = first.id
            messages = chatStore.loadMessages(sessionId: first.id)
        } else {
            let session = chatStore.createSession(title: "Nuevo chat")
            refreshSessions()
            activeSessionId = session.id
            messages = []
        }
    }

    func refreshSessions(includeArchived: Bool = false) {
        chatSessions = chatStore.loadSummaries(includeArchived: includeArchived)
    }

    private func persistActiveSession() {
        guard let activeSessionId else { return }
        chatStore.saveMessages(sessionId: activeSessionId, title: nil, messages: messages)
        refreshSessions()
    }

    private func runPipeline(prompt: String) async -> String {
        let started = Date()
        let autoDecision = routing.decide(prompt: prompt)
        let primaryTarget = selectPrimaryTarget(autoTarget: autoDecision.target)
        let timeoutMs = routing.localTimeoutMs

        do {
            let text = try await run(target: primaryTarget, prompt: prompt, timeoutMs: timeoutMs)
            lastRoute = primaryTarget
            lastReason = primaryTarget == "LOCAL" ? localReason(pref: routePreference, autoReason: autoDecision.reason) : "forced_remote_or_auto"
            self.lastLatencyMs = Int(Date().timeIntervalSince(started) * 1000)
            self.lastErrorText = ""
            self.successCount += 1
            refreshHealth()
            return text
        } catch {
            guard primaryTarget == "LOCAL" else {
                lastRoute = "REMOTE"
                lastReason = "remote_error_no_fallback"
                self.lastLatencyMs = Int(Date().timeIntervalSince(started) * 1000)
                self.lastErrorText = error.localizedDescription
                self.errorCount += 1
                refreshHealth()
                return "Error remoto: \(error.localizedDescription)"
            }

            if routePreference == .local {
                lastRoute = "LOCAL"
                lastReason = "forced_local_error"
                self.lastLatencyMs = Int(Date().timeIntervalSince(started) * 1000)
                self.lastErrorText = error.localizedDescription
                self.errorCount += 1
                refreshHealth()
                return "Error local: \(error.localizedDescription)"
            }

            do {
                let fallback = try await run(target: "REMOTE", prompt: prompt, timeoutMs: timeoutMs)
                lastRoute = "REMOTE"
                lastReason = "fallback_remote_after_local_error"
                self.lastLatencyMs = Int(Date().timeIntervalSince(started) * 1000)
                self.lastErrorText = ""
                self.successCount += 1
                refreshHealth()
                return fallback
            } catch {
                lastRoute = "LOCAL"
                lastReason = "local_failed_and_remote_failed"
                self.lastLatencyMs = Int(Date().timeIntervalSince(started) * 1000)
                self.lastErrorText = error.localizedDescription
                self.errorCount += 1
                refreshHealth()
                return "No pude responder (falló local y fallback remoto): \(error.localizedDescription)"
            }
        }
    }

    private func selectPrimaryTarget(autoTarget: String) -> String {
        switch routePreference {
        case .auto: return autoTarget
        case .local: return "LOCAL"
        case .remote: return "REMOTE"
        }
    }

    private func localReason(pref: RoutePreference, autoReason: String) -> String {
        switch pref {
        case .auto: return autoReason
        case .local: return "forced_local"
        case .remote: return "remote_selected"
        }
    }

    private func run(target: String, prompt: String, timeoutMs: Int) async throws -> String {
        if target == "LOCAL" {
            if prompt.lowercased().hasPrefix("/wf ") || prompt.lowercased().hasPrefix("/workflow ") {
                let goal = prompt.replacingOccurrences(of: "/workflow ", with: "", options: [.caseInsensitive]).replacingOccurrences(of: "/wf ", with: "", options: [.caseInsensitive])
                let wf = await workflowService.run(goal: goal, recentMessages: messages)
                self.toolTrace = wf.trace
                return wf.text
            }

            let output = try await openClawLite.respond(to: prompt, recentMessages: messages)
            self.toolTrace = output.trace
            return output.text
        }

        self.toolTrace = []
        return try await withTimeout(milliseconds: timeoutMs) { [self] in
            try await self.remoteService.runRemote(prompt: prompt)
        }
    }

    private func withTimeout<T: Sendable>(milliseconds: Int, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
                throw TimeoutError()
            }

            guard let first = try await group.next() else {
                throw TimeoutError()
            }
            group.cancelAll()
            return first
        }
    }

    private func refreshHealth() {
        healthChecks = healthService.runChecks(lastLatencyMs: lastLatencyMs, lastError: lastErrorText, successCount: successCount, errorCount: errorCount)
    }

    private func trimMessagesIfNeeded() {
        let maxMessages = 80
        if messages.count > maxMessages {
            messages = Array(messages.suffix(maxMessages))
        }
    }
}

struct TimeoutError: LocalizedError {
    var errorDescription: String? { "timeout" }
}
