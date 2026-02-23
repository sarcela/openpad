import Foundation

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
        } catch {
            // non-fatal
        }
    }

    func appendToolTrace(_ trace: [String]) {
        guard !trace.isEmpty else { return }
        do {
            let ts = ISO8601DateFormatter().string(from: Date())
            let joined = trace.prefix(6).joined(separator: " | ")
            try append("- [\(ts)] \(joined)\n", to: "TOOLS.md")
        } catch {
            // non-fatal
        }
    }

    func noteHeartbeat(_ text: String) {
        do {
            let ts = ISO8601DateFormatter().string(from: Date())
            try append("\n- \(ts): \(text)\n", to: "HEARTBEAT.md")
        } catch {
            // non-fatal
        }
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
