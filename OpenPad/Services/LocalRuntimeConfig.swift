import Foundation

enum RunProfile: String, CaseIterable, Identifiable {
    case stable
    case balanced
    case turbo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stable: return "Estable"
        case .balanced: return "Balanceado"
        case .turbo: return "Turbo"
        }
    }
}

enum LocalRuntimeProvider: String, CaseIterable, Identifiable {
    case llamaCpp = "LLAMA_SWIFT"
    case mlx = "MLX"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .llamaCpp: return "llama.swift"
        case .mlx: return "MLX"
        }
    }
}

enum ModelPreset: String, CaseIterable, Identifiable {
    case ligero
    case balanceado
    case calidad

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ligero: return "Ligero"
        case .balanceado: return "Balanceado"
        case .calidad: return "Calidad"
        }
    }
}

struct LocalRuntimeConfig {
    static let shared = LocalRuntimeConfig()

    private enum Keys {
        static let provider = "local.runtime.provider"
        static let ollamaBaseURL = "local.ollama.baseURL"
        static let ollamaModel = "local.ollama.model"
        static let llamaBaseURL = "local.llama.baseURL"
        static let llamaModel = "local.llama.model"
        static let mlxModel = "local.mlx.model"
        static let mlxToolsModel = "local.mlx.tools.model"
        static let mlxSeparateToolsModelEnabled = "local.mlx.tools.separate.enabled"
        static let recentContextWindow = "agent.recent.context.window"
        static let runProfile = "agent.run.profile"
        static let localTemperature = "local.runtime.temperature"
        static let emergencyMemoryMode = "agent.memory.emergency.mode"
        static let mlxReasoningModel = "local.mlx.reasoning.model"
        static let mlxVisionModel = "local.mlx.vision.model"
        static let mlxAudioModel = "local.mlx.audio.model"
        static let dualPassReasoningEnabled = "agent.dualpass.reasoning.enabled"
        static let multimodalRoutingEnabled = "agent.multimodal.routing.enabled"
        static let qualityGateStrictness = "agent.qualitygate.strictness"
        static let intentRouterEnabled = "agent.intent.router.enabled"
        static let intentRouteTimeEnabled = "agent.intent.route.time.enabled"
        static let intentRouteAttachmentEnabled = "agent.intent.route.attachment.enabled"
        static let intentRouteURLEnabled = "agent.intent.route.url.enabled"
        static let intentRouteListAttachmentsEnabled = "agent.intent.route.list_attachments.enabled"
        static let selfImprovingAgentEnabled = "agent.self_improving.enabled"
        static let offlineStrictMode = "agent.offline.strict.enabled"
        static let forceAttachmentFirst = "agent.attachment.first.enabled"
        static let clawStyleMode = "agent.claw_style.enabled"
        static let rawMode = "agent.raw_mode.enabled"
        static let debugExecutionMode = "agent.debug_execution.enabled"
        static let debugVerboseMode = "agent.debug_verbose.enabled"
        static let modelPreset = "local.model.preset"
        static let modelPresetAppliedAt = "local.model.preset.applied_at"
    }

    func loadProvider() -> LocalRuntimeProvider {
        let raw = UserDefaults.standard.string(forKey: Keys.provider) ?? LocalRuntimeProvider.mlx.rawValue
        return LocalRuntimeProvider(rawValue: raw) ?? .mlx
    }

    func saveProvider(_ provider: LocalRuntimeProvider) {
        UserDefaults.standard.set(provider.rawValue, forKey: Keys.provider)
    }

    func loadOllama() -> (baseURL: String, model: String) {
        let d = UserDefaults.standard
        return (
            baseURL: d.string(forKey: Keys.ollamaBaseURL) ?? "http://127.0.0.1:11434",
            model: d.string(forKey: Keys.ollamaModel) ?? "qwen2.5:3b"
        )
    }

    func saveOllama(baseURL: String, model: String) {
        let d = UserDefaults.standard
        d.set(baseURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.ollamaBaseURL)
        d.set(model.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.ollamaModel)
    }

    func loadLlama() -> (baseURL: String, model: String) {
        let d = UserDefaults.standard
        return (
            baseURL: d.string(forKey: Keys.llamaBaseURL) ?? "http://127.0.0.1:8080",
            model: d.string(forKey: Keys.llamaModel) ?? ""
        )
    }

    func saveLlama(baseURL: String, model: String) {
        let d = UserDefaults.standard
        d.set(baseURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.llamaBaseURL)
        d.set(model.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.llamaModel)
    }

    func loadMLXModelName() -> String {
        UserDefaults.standard.string(forKey: Keys.mlxModel) ?? "mlx-community/Qwen2.5-1.5B-Instruct-4bit"
    }

    func saveMLXModelName(_ name: String) {
        UserDefaults.standard.set(name.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.mlxModel)
    }

    func loadMLXToolsModelName() -> String {
        UserDefaults.standard.string(forKey: Keys.mlxToolsModel) ?? "mlx-community/Phi-3.5-mini-instruct-4bit"
    }

    func saveMLXToolsModelName(_ name: String) {
        UserDefaults.standard.set(name.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.mlxToolsModel)
    }

    func isSeparateMLXToolsModelEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: Keys.mlxSeparateToolsModelEnabled)
    }

    func setSeparateMLXToolsModelEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Keys.mlxSeparateToolsModelEnabled)
    }

    
    func loadRunProfile() -> RunProfile {
        let raw = UserDefaults.standard.string(forKey: Keys.runProfile) ?? RunProfile.balanced.rawValue
        return RunProfile(rawValue: raw) ?? .balanced
    }

    func saveRunProfile(_ profile: RunProfile) {
        UserDefaults.standard.set(profile.rawValue, forKey: Keys.runProfile)
    }

    func loadLocalTemperature() -> Double {
        let value = UserDefaults.standard.object(forKey: Keys.localTemperature) as? Double
        return min(1.0, max(0.0, value ?? 0.2))
    }

    func saveLocalTemperature(_ value: Double) {
        UserDefaults.standard.set(min(1.0, max(0.0, value)), forKey: Keys.localTemperature)
    }

    func loadRecentContextWindow() -> Int {
        let value = UserDefaults.standard.integer(forKey: Keys.recentContextWindow)
        return value == 0 ? 10 : max(2, min(30, value))
    }

    func saveRecentContextWindow(_ value: Int) {
        UserDefaults.standard.set(max(2, min(30, value)), forKey: Keys.recentContextWindow)
    }

    func isEmergencyMemoryModeEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: Keys.emergencyMemoryMode)
    }

    func setEmergencyMemoryModeEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Keys.emergencyMemoryMode)
    }

    func loadMLXReasoningModelName() -> String {
        UserDefaults.standard.string(forKey: Keys.mlxReasoningModel) ?? ""
    }

    func saveMLXReasoningModelName(_ name: String) {
        UserDefaults.standard.set(name.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.mlxReasoningModel)
    }

    func loadMLXVisionModelName() -> String {
        UserDefaults.standard.string(forKey: Keys.mlxVisionModel) ?? ""
    }

    func saveMLXVisionModelName(_ name: String) {
        UserDefaults.standard.set(name.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.mlxVisionModel)
    }

    func loadMLXAudioModelName() -> String {
        UserDefaults.standard.string(forKey: Keys.mlxAudioModel) ?? ""
    }

    func saveMLXAudioModelName(_ name: String) {
        UserDefaults.standard.set(name.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.mlxAudioModel)
    }

    func isDualPassReasoningEnabled() -> Bool {
        UserDefaults.standard.object(forKey: Keys.dualPassReasoningEnabled) as? Bool ?? true
    }

    func setDualPassReasoningEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Keys.dualPassReasoningEnabled)
    }

    func isMultimodalRoutingEnabled() -> Bool {
        UserDefaults.standard.object(forKey: Keys.multimodalRoutingEnabled) as? Bool ?? true
    }

    func setMultimodalRoutingEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Keys.multimodalRoutingEnabled)
    }

    func loadQualityGateStrictness() -> String {
        UserDefaults.standard.string(forKey: Keys.qualityGateStrictness) ?? "balanced"
    }

    func saveQualityGateStrictness(_ value: String) {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allowed = ["relaxed", "balanced", "strict"]
        UserDefaults.standard.set(allowed.contains(clean) ? clean : "balanced", forKey: Keys.qualityGateStrictness)
    }

    func isIntentRouterEnabled() -> Bool {
        UserDefaults.standard.object(forKey: Keys.intentRouterEnabled) as? Bool ?? true
    }

    func setIntentRouterEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Keys.intentRouterEnabled)
    }

    func isIntentRouteTimeEnabled() -> Bool {
        UserDefaults.standard.object(forKey: Keys.intentRouteTimeEnabled) as? Bool ?? true
    }

    func setIntentRouteTimeEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Keys.intentRouteTimeEnabled)
    }

    func isIntentRouteAttachmentEnabled() -> Bool {
        UserDefaults.standard.object(forKey: Keys.intentRouteAttachmentEnabled) as? Bool ?? true
    }

    func setIntentRouteAttachmentEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Keys.intentRouteAttachmentEnabled)
    }

    func isIntentRouteURLEnabled() -> Bool {
        UserDefaults.standard.object(forKey: Keys.intentRouteURLEnabled) as? Bool ?? true
    }

    func setIntentRouteURLEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Keys.intentRouteURLEnabled)
    }

    func isIntentRouteListAttachmentsEnabled() -> Bool {
        UserDefaults.standard.object(forKey: Keys.intentRouteListAttachmentsEnabled) as? Bool ?? true
    }

    func setIntentRouteListAttachmentsEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Keys.intentRouteListAttachmentsEnabled)
    }

    func incrementIntentRouteMetric(_ route: String) {
        let key = "agent.intent.metric.\(route)"
        let current = UserDefaults.standard.integer(forKey: key)
        UserDefaults.standard.set(current + 1, forKey: key)
    }

    func loadIntentRouteMetric(_ route: String) -> Int {
        UserDefaults.standard.integer(forKey: "agent.intent.metric.\(route)")
    }

    func isSelfImprovingAgentEnabled() -> Bool {
        UserDefaults.standard.object(forKey: Keys.selfImprovingAgentEnabled) as? Bool ?? false
    }

    func setSelfImprovingAgentEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Keys.selfImprovingAgentEnabled)
    }

    func isOfflineStrictModeEnabled() -> Bool {
        UserDefaults.standard.object(forKey: Keys.offlineStrictMode) as? Bool ?? false
    }

    func setOfflineStrictModeEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Keys.offlineStrictMode)
    }

    func isForceAttachmentFirstEnabled() -> Bool {
        UserDefaults.standard.object(forKey: Keys.forceAttachmentFirst) as? Bool ?? true
    }

    func setForceAttachmentFirstEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Keys.forceAttachmentFirst)
    }

    func isClawStyleModeEnabled() -> Bool {
        UserDefaults.standard.object(forKey: Keys.clawStyleMode) as? Bool ?? false
    }

    func setClawStyleModeEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Keys.clawStyleMode)
    }

    func isRawModeEnabled() -> Bool {
        UserDefaults.standard.object(forKey: Keys.rawMode) as? Bool ?? false
    }

    func setRawModeEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Keys.rawMode)
    }

    func isDebugExecutionModeEnabled() -> Bool {
        UserDefaults.standard.object(forKey: Keys.debugExecutionMode) as? Bool ?? false
    }

    func setDebugExecutionModeEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Keys.debugExecutionMode)
    }

    func isDebugVerboseModeEnabled() -> Bool {
        UserDefaults.standard.object(forKey: Keys.debugVerboseMode) as? Bool ?? false
    }

    func setDebugVerboseModeEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Keys.debugVerboseMode)
    }

    func loadModelPreset() -> ModelPreset {
        let raw = UserDefaults.standard.string(forKey: Keys.modelPreset) ?? ModelPreset.balanceado.rawValue
        return ModelPreset(rawValue: raw) ?? .balanceado
    }

    func saveModelPreset(_ preset: ModelPreset) {
        UserDefaults.standard.set(preset.rawValue, forKey: Keys.modelPreset)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Keys.modelPresetAppliedAt)
    }

    func loadModelPresetAppliedAt() -> Date? {
        let ts = UserDefaults.standard.double(forKey: Keys.modelPresetAppliedAt)
        guard ts > 0 else { return nil }
        return Date(timeIntervalSince1970: ts)
    }
}
