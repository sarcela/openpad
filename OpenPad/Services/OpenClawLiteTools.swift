import Foundation

struct OpenClawToolResult {
    let ok: Bool
    let output: String
}

@MainActor
final class OpenClawLiteTools {
    private let memoryDirName = "OpenClawMemory"
    private let memoryFileName = "memory.log"

    func execute(name: String, arguments: [String: String]) -> OpenClawToolResult {
        switch name {
        case "get_time":
            let now = Date()
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZ"
            return .init(ok: true, output: formatter.string(from: now))

        case "save_memory":
            let text = (arguments["text"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                return .init(ok: false, output: "Missing argument: text")
            }
            do {
                try appendMemoryLine(text)
                return .init(ok: true, output: "Saved")
            } catch {
                return .init(ok: false, output: "Error saving memory: \(error.localizedDescription)")
            }

        case "list_memories":
            let limit = Int(arguments["limit"] ?? "10") ?? 10
            do {
                let items = try readMemoryLines(limit: max(1, min(50, limit)))
                if items.isEmpty {
                    return .init(ok: true, output: "No memories yet")
                }
                return .init(ok: true, output: items.joined(separator: "\n"))
            } catch {
                return .init(ok: false, output: "Error reading memories: \(error.localizedDescription)")
            }

        default:
            return .init(ok: false, output: "Unknown tool: \(name)")
        }
    }

    func recentMemories(limit: Int = 8) -> String {
        do {
            let items = try readMemoryLines(limit: max(1, min(50, limit)))
            if items.isEmpty { return "(sin memoria guardada)" }
            return items.joined(separator: "\n")
        } catch {
            return "(error leyendo memoria: \(error.localizedDescription))"
        }
    }

    private func documentsDirectory() throws -> URL {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw NSError(domain: "OpenClawLiteTools", code: 1, userInfo: [NSLocalizedDescriptionKey: "Documents directory unavailable"])
        }
        return docs
    }

    private func memoryFileURL() throws -> URL {
        let docs = try documentsDirectory()
        let dir = docs.appendingPathComponent(memoryDirName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(memoryFileName, isDirectory: false)
    }

    private func appendMemoryLine(_ text: String) throws {
        let fileURL = try memoryFileURL()
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(stamp)] \(text)\n"

        if FileManager.default.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            if let data = line.data(using: .utf8) {
                try handle.write(contentsOf: data)
            }
        } else {
            try line.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    private func readMemoryLines(limit: Int) throws -> [String] {
        let fileURL = try memoryFileURL()
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        let lines = text.split(separator: "\n").map(String.init)
        return Array(lines.suffix(limit))
    }
}
