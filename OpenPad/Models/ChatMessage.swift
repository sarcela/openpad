import Foundation

struct ChatMessage: Identifiable, Codable {
    let id: UUID
    let role: String // "user" | "assistant" | "system"
    let text: String
    let date: Date

    init(id: UUID = UUID(), role: String, text: String, date: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.date = date
    }
}
