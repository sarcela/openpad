import Foundation

struct ContextBudget {
    let recentChars: Int
    let memoryChars: Int
    let attachmentChars: Int
}

@MainActor
final class OpenClawLiteContextManager {
    static let shared = OpenClawLiteContextManager()

    func budget(profile: RunProfile, lowPower: Bool) -> ContextBudget {
        if lowPower {
            return .init(recentChars: 1400, memoryChars: 700, attachmentChars: 500)
        }
        switch profile {
        case .stable: return .init(recentChars: 1800, memoryChars: 1000, attachmentChars: 700)
        case .balanced: return .init(recentChars: 3200, memoryChars: 1600, attachmentChars: 1200)
        case .turbo: return .init(recentChars: 5000, memoryChars: 2600, attachmentChars: 1800)
        }
    }
}
