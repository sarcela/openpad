import Foundation

struct OpenClawToolResult {
    let ok: Bool
    let output: String
}

@MainActor
final class OpenClawLiteTools {
    private let memoryDirName = "OpenClawMemory"
    private let memoryFileName = "memory.log"
    private let filesDirName = "OpenClawFiles"

    private let httpAllowlistHosts: Set<String> = [
        "docs.openclaw.ai",
        "api.github.com",
        "wttr.in"
    ]

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

        case "search_memories":
            let query = (arguments["query"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let limit = Int(arguments["limit"] ?? "5") ?? 5
            guard !query.isEmpty else {
                return .init(ok: false, output: "Missing argument: query")
            }
            do {
                let hits = try searchMemory(query: query, limit: max(1, min(10, limit)))
                if hits.isEmpty { return .init(ok: true, output: "No matches") }
                return .init(ok: true, output: hits.joined(separator: "\n"))
            } catch {
                return .init(ok: false, output: "Error searching memories: \(error.localizedDescription)")
            }

        case "read_file":
            let relativePath = (arguments["path"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !relativePath.isEmpty else { return .init(ok: false, output: "Missing argument: path") }
            do {
                let text = try readAppFile(relativePath: relativePath)
                return .init(ok: true, output: text)
            } catch {
                return .init(ok: false, output: "read_file error: \(error.localizedDescription)")
            }

        case "http_get":
            let urlString = (arguments["url"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !urlString.isEmpty else { return .init(ok: false, output: "Missing argument: url") }
            return fetchHTTP(urlString: urlString)

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

    private func searchMemory(query: String, limit: Int) throws -> [String] {
        let rows = try readMemoryLines(limit: 200)
        let tokens = Set(query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        let scored: [(Int, String)] = rows.map { row in
            let rowTokens = Set(row.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
            let score = tokens.intersection(rowTokens).count
            return (score, row)
        }
        return scored
            .filter { $0.0 > 0 }
            .sorted { $0.0 > $1.0 }
            .prefix(limit)
            .map { $0.1 }
    }

    private func readAppFile(relativePath: String) throws -> String {
        let docs = try documentsDirectory()
        let root = docs.appendingPathComponent(filesDirName, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let candidate = root.appendingPathComponent(relativePath)
        let normalizedRoot = root.standardizedFileURL.path
        let normalizedCandidate = candidate.standardizedFileURL.path
        guard normalizedCandidate.hasPrefix(normalizedRoot) else {
            throw NSError(domain: "OpenClawLiteTools", code: 2, userInfo: [NSLocalizedDescriptionKey: "Path outside sandbox"])
        }
        return try String(contentsOf: candidate, encoding: .utf8)
    }

    private func fetchHTTP(urlString: String) -> OpenClawToolResult {
        guard let url = URL(string: urlString), url.scheme == "https", let host = url.host else {
            return .init(ok: false, output: "Only https URLs are allowed")
        }
        guard httpAllowlistHosts.contains(host) else {
            return .init(ok: false, output: "Host not allowed: \(host)")
        }

        let semaphore = DispatchSemaphore(value: 0)
        var result: OpenClawToolResult = .init(ok: false, output: "Request failed")

        URLSession.shared.dataTask(with: url) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                result = .init(ok: false, output: "http_get error: \(error.localizedDescription)")
                return
            }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                result = .init(ok: false, output: "HTTP status \(http.statusCode)")
                return
            }
            let text = String(data: data ?? Data(), encoding: .utf8) ?? ""
            result = .init(ok: true, output: String(text.prefix(2000)))
        }.resume()

        _ = semaphore.wait(timeout: .now() + 12)
        return result
    }
}
