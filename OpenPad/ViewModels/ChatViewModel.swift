import Foundation
import Combine

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
    @Published var messages: [ChatMessage] = []
    @Published var inputText: String = ""
    @Published var isLoading = false
    @Published var lastRoute: String = "AUTO"
    @Published var lastReason: String = "Listo"
    @Published var routePreference: RoutePreference = .auto {
        didSet { UserDefaults.standard.set(routePreference.rawValue, forKey: Self.routePreferenceKey) }
    }

    private static let routePreferenceKey = "chat.routePreference"

    private let routing = RoutingService()
    private let localService = LocalModelService()
    private let remoteService = RemoteModelService()

    init() {
        if let saved = UserDefaults.standard.string(forKey: Self.routePreferenceKey),
           let pref = RoutePreference(rawValue: saved) {
            routePreference = pref
        } else {
            routePreference = .local
        }

        // Default local provider: MLX (privado/offline).
        if UserDefaults.standard.string(forKey: "local.runtime.provider") == nil {
            runtimeConfig.saveProvider(.mlx)
        }
    }

    func send() {
        let prompt = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isLoading else { return }

        inputText = ""
        messages.append(ChatMessage(role: "user", text: prompt))
        isLoading = true

        Task {
            let responseText = await runPipeline(prompt: prompt)
            messages.append(ChatMessage(role: "assistant", text: responseText))
            isLoading = false
        }
    }

    private func runPipeline(prompt: String) async -> String {
        let autoDecision = routing.decide(prompt: prompt)
        let primaryTarget = selectPrimaryTarget(autoTarget: autoDecision.target)
        let timeoutMs = routing.localTimeoutMs

        do {
            let text = try await run(target: primaryTarget, prompt: prompt, timeoutMs: timeoutMs)
            lastRoute = primaryTarget
            lastReason = primaryTarget == "LOCAL" ? localReason(pref: routePreference, autoReason: autoDecision.reason) : "forced_remote_or_auto"
            return text
        } catch {
            guard primaryTarget == "LOCAL" else {
                lastRoute = "REMOTE"
                lastReason = "remote_error_no_fallback"
                return "Error remoto: \(error.localizedDescription)"
            }

            // Si el usuario forzó LOCAL, NO intentamos remoto como fallback.
            if routePreference == .local {
                lastRoute = "LOCAL"
                lastReason = "forced_local_error"
                return "Error local: \(error.localizedDescription)"
            }

            do {
                let fallback = try await run(target: "REMOTE", prompt: prompt, timeoutMs: timeoutMs)
                lastRoute = "REMOTE"
                lastReason = "fallback_remote_after_local_error"
                return fallback
            } catch {
                lastRoute = "LOCAL"
                lastReason = "local_failed_and_remote_failed"
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
            return try await withTimeout(milliseconds: timeoutMs) { [self] in
                try await self.localService.runLocal(prompt: prompt)
            }
        }

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
}

struct TimeoutError: LocalizedError {
    var errorDescription: String? { "timeout" }
}
