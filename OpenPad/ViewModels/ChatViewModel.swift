import Foundation
import Combine
#if canImport(UIKit)
import UIKit
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif

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
    @Published var lastModelUsedBadge: String = ""
    @Published var lastLatencyMs: Int = 0
    @Published var lastErrorText: String = ""
    @Published var successCount: Int = 0
    @Published var errorCount: Int = 0
    @Published var healthChecks: [OpenClawHealthCheck] = []
    @Published var backgroundPaused = false
    @Published var backgroundStatus = ""
    @Published var autoResumeQueuedPrompt = true {
        didSet { UserDefaults.standard.set(autoResumeQueuedPrompt, forKey: "chat.autoResumeQueuedPrompt") }
    }

    @Published var chatSessions: [ChatSessionSummary] = []
    @Published var activeSessionId: UUID?

    private static let routePreferenceKey = "chat.routePreference"

    private var activeTask: Task<Void, Never>?
    private var inFlightPrompt: String?
    private var queuedPrompt: String?

    private let routing = RoutingService()
    private let remoteService = RemoteModelService()
    private let openClawLite = OpenClawLiteAgentService()
    private let notificationService = OpenClawLiteNotificationService.shared
    private let appMemory = AppMemoryStore.shared

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

        autoResumeQueuedPrompt = UserDefaults.standard.object(forKey: "chat.autoResumeQueuedPrompt") as? Bool ?? true
        appMemory.ensureFiles()
        appMemory.noteHeartbeat("session started")

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

        #if canImport(UIKit)
        if UIApplication.shared.applicationState != .active {
            queuedPrompt = prompt
            inputText = ""
            backgroundPaused = true
            backgroundStatus = "Queued while app is in background."
            appMemory.noteHeartbeat("queued prompt while backgrounded")
            return
        }
        #endif

        startPrompt(prompt)
    }

    private func startPrompt(_ prompt: String) {
        inputText = ""
        messages.append(ChatMessage(role: "user", text: prompt))
        trimMessagesIfNeeded()
        persistActiveSession()
        isLoading = true
        inFlightPrompt = prompt

        activeTask?.cancel()
        activeTask = Task { [weak self] in
            guard let self else { return }
            let responseText = await self.runPipeline(prompt: prompt)
            if Task.isCancelled {
                self.isLoading = false
                return
            }
            self.messages.append(ChatMessage(role: "assistant", text: responseText))
            self.trimMessagesIfNeeded()
            self.persistActiveSession()
            self.appMemory.appendInteraction(user: prompt, assistant: responseText)
            self.appMemory.appendToolTrace(self.toolTrace)
            self.notificationService.notifyAssistantReplyIfAppInBackground(responseText)
            self.isLoading = false
            self.inFlightPrompt = nil
            self.activeTask = nil
        }
    }

    func appDidEnterBackground() {
        backgroundPaused = true
        if isLoading {
            queuedPrompt = inFlightPrompt ?? queuedPrompt
            activeTask?.cancel()
            activeTask = nil
            isLoading = false
            backgroundStatus = "Paused to avoid iPad background GPU limits."
            appMemory.noteHeartbeat("paused active generation due to background")
        } else {
            backgroundStatus = "Background mode: local inference paused."
        }
    }

    func appWillEnterForeground() {
        backgroundPaused = false
        backgroundStatus = ""
        if autoResumeQueuedPrompt, let pending = queuedPrompt, !pending.isEmpty, !isLoading {
            queuedPrompt = nil
            startPrompt(pending)
            appMemory.noteHeartbeat("auto-resumed queued prompt on foreground")
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
                return "Remote error: \(error.localizedDescription)"
            }

            if routePreference == .local {
                lastRoute = "LOCAL"
                lastReason = "forced_local_error"
                self.lastLatencyMs = Int(Date().timeIntervalSince(started) * 1000)
                self.lastErrorText = error.localizedDescription
                self.errorCount += 1
                if maybeActivateEmergencyMemoryMode(from: error.localizedDescription) {
                    refreshHealth()
                    return "Local memory guard activated after a memory-pressure error. Try again; the app switched to safer limits."
                }
                refreshHealth()
                return "Local error: \(error.localizedDescription)"
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
                if maybeActivateEmergencyMemoryMode(from: error.localizedDescription) {
                    refreshHealth()
                    return "Both paths failed and memory pressure was detected. Emergency memory mode is now ON; retry with safer limits."
                }
                refreshHealth()
                return "I could not respond (local failed and remote fallback also failed): \(error.localizedDescription)"
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
            if let line = output.trace.last(where: { $0.contains("model_used=") }) {
                self.lastModelUsedBadge = line.replacingOccurrences(of: "model_used=", with: "")
            } else {
                self.lastModelUsedBadge = "LOCAL/agent"
            }
            return output.text
        }

        self.toolTrace = []
        self.lastModelUsedBadge = "REMOTE/api"
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
        let maxMessages = runtimeConfig.isEmergencyMemoryModeEnabled() ? 40 : 80
        if messages.count > maxMessages {
            messages = Array(messages.suffix(maxMessages))
        }
    }

    @discardableResult
    private func maybeActivateEmergencyMemoryMode(from errorText: String) -> Bool {
        let lower = errorText.lowercased()
        let looksLikeMemoryPressure =
            lower.contains("memory") ||
            lower.contains("out of memory") ||
            lower.contains("terminated") ||
            lower.contains("oom") ||
            lower.contains("exceeded")

        guard looksLikeMemoryPressure else { return false }
        if runtimeConfig.isEmergencyMemoryModeEnabled() { return true }

        runtimeConfig.setEmergencyMemoryModeEnabled(true)
        runtimeConfig.saveRunProfile(.stable)
        runtimeConfig.setSeparateMLXToolsModelEnabled(false)
        OpenClawLiteConfig.shared.setLowPowerModeEnabled(true)
        runtimeConfig.saveRecentContextWindow(6)

        backgroundStatus = "Emergency memory mode ON (stable profile + low-power + shorter context)."
        appMemory.noteHeartbeat("emergency memory mode activated")
        return true
    }
}

@MainActor
final class AppMemoryStore {
    static let shared = AppMemoryStore()

    private let fm = FileManager.default

    func ensureFiles() {
        do {
            let dir = try appMemoryDirectory()
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try ensureFile("SOUL.md", defaultText: "# SOUL\nBe genuinely helpful, concise when possible, and thorough when needed.\n")
            try ensureFile("IDENTITY.md", defaultText: "# IDENTITY\nName: OpenPad\nRole: Local-first iPad assistant\n")
            try ensureFile("USER.md", defaultText: "# USER\nName:\nPreferences:\n\n## Live Notes\n")
            try ensureFile("TOOLS.md", defaultText: "# TOOLS\nLocal notes and environment-specific details.\n\n## Runtime Notes\n")
            try ensureFile("HEARTBEAT.md", defaultText: "# HEARTBEAT\nKeep checks lightweight and avoid unnecessary background work.\n")
        } catch {
            // non-fatal
        }
    }

    func appendInteraction(user: String, assistant: String) {
        do {
            let ts = ISO8601DateFormatter().string(from: Date())
            let line = "- [\(ts)] user: \(String(user.prefix(180))) | assistant: \(String(assistant.prefix(220)))\n"
            try append(line, to: "USER.md")
        } catch {}
    }

    func appendToolTrace(_ trace: [String]) {
        guard !trace.isEmpty else { return }
        do {
            let ts = ISO8601DateFormatter().string(from: Date())
            let joined = trace.prefix(6).joined(separator: " | ")
            try append("- [\(ts)] \(joined)\n", to: "TOOLS.md")
        } catch {}
    }

    func noteHeartbeat(_ text: String) {
        do {
            let ts = ISO8601DateFormatter().string(from: Date())
            try append("\n- \(ts): \(text)\n", to: "HEARTBEAT.md")
        } catch {}
    }

    private func appMemoryDirectory() throws -> URL {
        let docs = try LocalModelConfig.shared.documentsDirectory()
        return docs.appendingPathComponent("OpenClawMemory/AppMemory", isDirectory: true)
    }

    private func ensureFile(_ name: String, defaultText: String) throws {
        let dir = try appMemoryDirectory()
        let file = dir.appendingPathComponent(name)
        guard !fm.fileExists(atPath: file.path) else { return }
        try defaultText.write(to: file, atomically: true, encoding: .utf8)
    }

    private func append(_ text: String, to fileName: String) throws {
        let dir = try appMemoryDirectory()
        let file = dir.appendingPathComponent(fileName)
        if fm.fileExists(atPath: file.path) {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            if let data = text.data(using: .utf8) {
                try handle.write(contentsOf: data)
            }
        } else {
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
    }
}

struct TimeoutError: LocalizedError {
    var errorDescription: String? { "timeout" }
}

@MainActor
final class OpenClawLiteNotificationService {
    static let shared = OpenClawLiteNotificationService()

    func notifyAssistantReplyIfAppInBackground(_ text: String) {
        #if canImport(UserNotifications) && canImport(UIKit)
        guard UIApplication.shared.applicationState != .active else { return }

        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }

            let content = UNMutableNotificationContent()
            content.title = "OpenPad"
            content.body = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(180))
            content.sound = .default

            let req = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.25, repeats: false)
            )
            UNUserNotificationCenter.current().add(req)
        }
        #else
        _ = text
        #endif
    }
}
