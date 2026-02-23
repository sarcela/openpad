import Foundation

struct ChatSessionSummary: Identifiable, Codable {
    let id: UUID
    var title: String
    var updatedAt: Date
}

private struct ChatSessionRecord: Codable {
    let id: UUID
    var title: String
    var updatedAt: Date
    var messages: [ChatMessage]
}

@MainActor
final class OpenClawLiteChatStore {
    static let shared = OpenClawLiteChatStore()

    private let rootFolder = "OpenClawLite"
    private let chatsFile = "chats.json"

    private func docs() throws -> URL {
        guard let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw NSError(domain: "OpenClawLiteChatStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Documents no disponible"])
        }
        return url
    }

    private func fileURL() throws -> URL {
        let root = try docs().appendingPathComponent(rootFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent(chatsFile)
    }

    private func loadRecords() -> [ChatSessionRecord] {
        do {
            let url = try fileURL()
            guard FileManager.default.fileExists(atPath: url.path) else { return [] }
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([ChatSessionRecord].self, from: data)
        } catch {
            return []
        }
    }

    private func saveRecords(_ rows: [ChatSessionRecord]) {
        do {
            let data = try JSONEncoder().encode(rows)
            try data.write(to: fileURL(), options: .atomic)
        } catch {}
    }

    func loadSummaries() -> [ChatSessionSummary] {
        loadRecords()
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { .init(id: $0.id, title: $0.title, updatedAt: $0.updatedAt) }
    }

    func createSession(title: String = "Nuevo chat") -> ChatSessionSummary {
        var rows = loadRecords()
        let record = ChatSessionRecord(id: UUID(), title: title, updatedAt: Date(), messages: [])
        rows.append(record)
        saveRecords(rows)
        return .init(id: record.id, title: record.title, updatedAt: record.updatedAt)
    }

    func loadMessages(sessionId: UUID) -> [ChatMessage] {
        loadRecords().first(where: { $0.id == sessionId })?.messages ?? []
    }

    func saveMessages(sessionId: UUID, title: String?, messages: [ChatMessage]) {
        var rows = loadRecords()
        if let idx = rows.firstIndex(where: { $0.id == sessionId }) {
            rows[idx].messages = messages
            rows[idx].updatedAt = Date()
            if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                rows[idx].title = title
            } else if rows[idx].title == "Nuevo chat", let firstUser = messages.first(where: { $0.role == "user" }) {
                rows[idx].title = String(firstUser.text.prefix(40))
            }
        } else {
            let t = title ?? "Nuevo chat"
            rows.append(.init(id: sessionId, title: t, updatedAt: Date(), messages: messages))
        }
        saveRecords(rows)
    }
}
