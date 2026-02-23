import Foundation

struct ChatSessionSummary: Identifiable, Codable {
    let id: UUID
    var title: String
    var updatedAt: Date
    var pinned: Bool = false
    var archived: Bool? = false
}

private struct ChatSessionRecord: Codable {
    let id: UUID
    var title: String
    var updatedAt: Date
    var pinned: Bool = false
    var archived: Bool? = false
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

    func loadSummaries(includeArchived: Bool = false) -> [ChatSessionSummary] {
        loadRecords()
            .filter { includeArchived || !($0.archived ?? false) }
            .sorted {
                if $0.pinned != $1.pinned { return $0.pinned && !$1.pinned }
                return $0.updatedAt > $1.updatedAt
            }
            .map { .init(id: $0.id, title: $0.title, updatedAt: $0.updatedAt, pinned: $0.pinned, archived: ($0.archived ?? false)) }
    }

    func createSession(title: String = "Nuevo chat") -> ChatSessionSummary {
        var rows = loadRecords()
        let record = ChatSessionRecord(id: UUID(), title: title, updatedAt: Date(), pinned: false, archived: false, messages: [])
        rows.append(record)
        saveRecords(rows)
        return .init(id: record.id, title: record.title, updatedAt: record.updatedAt, pinned: record.pinned, archived: record.archived)
    }


    func renameSession(sessionId: UUID, title: String) {
        var rows = loadRecords()
        guard let idx = rows.firstIndex(where: { $0.id == sessionId }) else { return }
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        rows[idx].title = clean
        rows[idx].updatedAt = Date()
        saveRecords(rows)
    }

    func deleteSession(sessionId: UUID) {
        var rows = loadRecords()
        rows.removeAll { $0.id == sessionId }
        saveRecords(rows)
    }

    func setPinned(sessionId: UUID, pinned: Bool) {
        var rows = loadRecords()
        guard let idx = rows.firstIndex(where: { $0.id == sessionId }) else { return }
        rows[idx].pinned = pinned
        rows[idx].updatedAt = Date()
        saveRecords(rows)
    }


    func setArchived(sessionId: UUID, archived: Bool) {
        var rows = loadRecords()
        guard let idx = rows.firstIndex(where: { $0.id == sessionId }) else { return }
        rows[idx].archived = archived
        rows[idx].updatedAt = Date()
        saveRecords(rows)
    }

    func exportSessionMarkdown(sessionId: UUID) -> String {
        guard let rec = loadRecords().first(where: { $0.id == sessionId }) else { return "" }
        var out = "# \(rec.title)

"
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short
        for m in rec.messages {
            out += "## [\(f.string(from: m.date))] \(m.role.uppercased())

\(m.text)

"
        }
        return out
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
