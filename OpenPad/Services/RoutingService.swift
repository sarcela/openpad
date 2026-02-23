import Foundation

struct RoutingDecision {
    let target: String // "LOCAL" | "REMOTE"
    let reason: String
}

final class RoutingService {
    // Perfil v1
    let localTimeoutMs = 30_000
    let promptTokensThreshold = 1400
    let toolsThreshold = 2
    let runtimeThresholdSec = 25

    func estimateTokens(_ text: String) -> Int {
        max(1, text.count / 4) // aproximación simple
    }

    func decide(prompt: String, plannedTools: Int = 0, estimatedRuntimeSec: Int = 5) -> RoutingDecision {
        let tokens = estimateTokens(prompt)

        if tokens > promptTokensThreshold {
            return .init(target: "REMOTE", reason: "prompt_tokens_gt_1400")
        }
        if plannedTools > toolsThreshold {
            return .init(target: "REMOTE", reason: "tool_calls_planned_gt_2")
        }
        if estimatedRuntimeSec > runtimeThresholdSec {
            return .init(target: "REMOTE", reason: "estimated_runtime_gt_25s")
        }
        return .init(target: "LOCAL", reason: "default_local")
    }
}
