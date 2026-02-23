import Foundation
#if canImport(PDFKit)
import PDFKit
#endif
#if canImport(Vision)
import Vision
#endif
#if canImport(UIKit)
import UIKit
#endif

struct OpenClawLiteConfig {
    static let shared = OpenClawLiteConfig()

    private enum Keys {
        static let httpAllowlistHosts = "openclawlite.http.allowlist.hosts"
        static let braveApiKey = "openclawlite.brave.api.key"
        static let internetOpenAccess = "openclawlite.internet.open.access"
        static let mlxDownloadedModels = "openclawlite.mlx.downloaded.models"
        static let automationLoopEnabled = "openclawlite.automation.loop.enabled"
        static let lowPowerMode = "openclawlite.low.power.mode"
        static let autodevEnabled = "openclawlite.autodev.enabled"
        static let disabledTools = "openclawlite.disabled.tools"
    }

    private let defaultHosts = ["docs.openclaw.ai", "api.github.com", "wttr.in"]

    func loadAllowlistHosts() -> [String] {
        let raw = UserDefaults.standard.string(forKey: Keys.httpAllowlistHosts)
        let source = (raw?.isEmpty == false) ? raw! : defaultHosts.joined(separator: "\n")
        return source
            .split(whereSeparator: { $0 == "\n" || $0 == "," || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }

    func saveAllowlistHosts(_ hostsText: String) {
        UserDefaults.standard.set(hostsText, forKey: Keys.httpAllowlistHosts)
    }

    func allowlistHostsText() -> String {
        loadAllowlistHosts().joined(separator: "\n")
    }

    func loadBraveApiKey() -> String {
        UserDefaults.standard.string(forKey: Keys.braveApiKey) ?? ""
    }

    func saveBraveApiKey(_ key: String) {
        UserDefaults.standard.set(key.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.braveApiKey)
    }

    func isInternetOpenAccessEnabled() -> Bool {
        if UserDefaults.standard.object(forKey: Keys.internetOpenAccess) == nil { return true }
        return UserDefaults.standard.bool(forKey: Keys.internetOpenAccess)
    }

    func setInternetOpenAccessEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Keys.internetOpenAccess)
    }

    func loadDownloadedMLXModels() -> [String] {
        UserDefaults.standard.stringArray(forKey: Keys.mlxDownloadedModels) ?? []
    }

    func isAutomationLoopEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: Keys.automationLoopEnabled)
    }

    func setAutomationLoopEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Keys.automationLoopEnabled)
    }

    func isLowPowerModeEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: Keys.lowPowerMode)
    }

    func setLowPowerModeEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Keys.lowPowerMode)
    }

    func isAutodevEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: Keys.autodevEnabled)
    }

    func setAutodevEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Keys.autodevEnabled)
    }

    func isToolEnabled(_ name: String) -> Bool {
        let disabled = Set(UserDefaults.standard.stringArray(forKey: Keys.disabledTools) ?? [])
        return !disabled.contains(name)
    }

    func setToolEnabled(_ name: String, enabled: Bool) {
        var disabled = Set(UserDefaults.standard.stringArray(forKey: Keys.disabledTools) ?? [])
        if enabled { disabled.remove(name) } else { disabled.insert(name) }
        UserDefaults.standard.set(Array(disabled).sorted(), forKey: Keys.disabledTools)
    }

    func loadDisabledTools() -> [String] {
        UserDefaults.standard.stringArray(forKey: Keys.disabledTools) ?? []
    }

    func availableToolNames() -> [String] {
        [
            "get_time", "save_memory", "list_memories", "search_memories", "clear_memories",
            "read_file", "write_file", "append_file", "delete_file", "list_files", "file_exists",
            "calendar_today", "summarize_url", "http_get", "brave_search", "calculate", "make_uuid"
        ]
    }

    func markMLXModelDownloaded(_ modelId: String) {
        let clean = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        var rows = Set(loadDownloadedMLXModels())
        rows.insert(clean)
        UserDefaults.standard.set(Array(rows).sorted(), forKey: Keys.mlxDownloadedModels)
    }

    func unmarkMLXModelDownloaded(_ modelId: String) {
        let clean = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        var rows = Set(loadDownloadedMLXModels())
        rows.remove(clean)
        UserDefaults.standard.set(Array(rows).sorted(), forKey: Keys.mlxDownloadedModels)
    }
}

struct OpenClawToolResult {
    let ok: Bool
    let output: String
}

@MainActor
final class OpenClawLiteTools {
    private let memoryDirName = "OpenClawMemory"
    private let memoryFileName = "memory.log"
    private let filesDirName = "OpenClawFiles"
    private let config = OpenClawLiteConfig.shared

    func execute(name: String, arguments: [String: String]) async -> OpenClawToolResult {
        if !config.isToolEnabled(name) {
            return .init(ok: false, output: "Tool deshabilitada en Settings: \(name)")
        }

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

        case "clear_memories":
            do {
                try clearMemories()
                return .init(ok: true, output: "Memories cleared")
            } catch {
                return .init(ok: false, output: "Error clearing memories: \(error.localizedDescription)")
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

        case "write_file":
            let relativePath = (arguments["path"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let text = arguments["text"] ?? ""
            guard !relativePath.isEmpty else { return .init(ok: false, output: "Missing argument: path") }
            do {
                try writeAppFile(relativePath: relativePath, text: text)
                return .init(ok: true, output: "Wrote file: \(relativePath)")
            } catch {
                return .init(ok: false, output: "write_file error: \(error.localizedDescription)")
            }

        case "list_files":
            let subdir = (arguments["path"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                let rows = try listAppFiles(relativePath: subdir)
                return .init(ok: true, output: rows.isEmpty ? "No files" : rows.joined(separator: "\n"))
            } catch {
                return .init(ok: false, output: "list_files error: \(error.localizedDescription)")
            }

        case "http_get":
            let urlString = (arguments["url"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let allowDirect = (arguments["allow_host"] ?? "false").lowercased() == "true"
            guard !urlString.isEmpty else { return .init(ok: false, output: "Missing argument: url") }
            return await fetchHTTP(urlString: urlString, allowDirectHostBypass: allowDirect)

        case "brave_search":
            let query = (arguments["query"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return .init(ok: false, output: "Missing argument: query") }
            let count = Int(arguments["count"] ?? "5") ?? 5
            return await braveSearch(query: query, count: max(1, min(10, count)))

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


    func readAttachmentSnippet(fileName: String, maxChars: Int = 4000) -> String {
        let clean = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return "" }

        let lower = clean.lowercased()
        let isImage = ["jpg", "jpeg", "png", "heic", "webp"].contains { lower.hasSuffix("." + $0) }

        do {
            let docs = try documentsDirectory()
            let url = docs.appendingPathComponent("OpenClawFiles/Attachments", isDirectory: true).appendingPathComponent(clean)

            if isImage {
                let data = try Data(contentsOf: url)
                if !config.isLowPowerModeEnabled() {
                    let ocr = extractTextFromImageData(data)
                    if !ocr.isEmpty {
                        return String(ocr.prefix(maxChars))
                    }
                } else {
                    return "(OCR omitido en modo ahorro de energía)"
                }
            }

            let text = try String(contentsOf: url, encoding: .utf8)
            return String(text.prefix(maxChars))
        } catch {
            return ""
        }
    }

    func listAllMemories() -> [String] {
        (try? readMemoryLines(limit: 500)) ?? []
    }

    func clearAllMemoriesForUI() throws {
        try clearMemories()
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

    private func clearMemories() throws {
        let fileURL = try memoryFileURL()
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    private func extractTextFromImageData(_ data: Data) -> String {
        #if canImport(Vision) && canImport(UIKit)
        guard let image = UIImage(data: data), let cg = image.cgImage else { return "" }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do {
            try handler.perform([request])
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            return lines.joined(separator: "\n")
        } catch {
            return ""
        }
        #else
        return ""
        #endif
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
        let candidate = try sandboxedFileURL(relativePath: relativePath)
        return try String(contentsOf: candidate, encoding: .utf8)
    }

    private func writeAppFile(relativePath: String, text: String) throws {
        let candidate = try sandboxedFileURL(relativePath: relativePath)
        let parent = candidate.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try text.write(to: candidate, atomically: true, encoding: .utf8)
    }

    private func listAppFiles(relativePath: String) throws -> [String] {
        let docs = try documentsDirectory()
        let root = docs.appendingPathComponent(filesDirName, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dir = relativePath.isEmpty ? root : try sandboxedFileURL(relativePath: relativePath)
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        return files.map { $0.lastPathComponent }.sorted()
    }

    private func sandboxedFileURL(relativePath: String) throws -> URL {
        let docs = try documentsDirectory()
        let root = docs.appendingPathComponent(filesDirName, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let candidate = root.appendingPathComponent(relativePath)
        let normalizedRoot = root.standardizedFileURL.path
        let normalizedCandidate = candidate.standardizedFileURL.path
        guard normalizedCandidate.hasPrefix(normalizedRoot) else {
            throw NSError(domain: "OpenClawLiteTools", code: 2, userInfo: [NSLocalizedDescriptionKey: "Path outside sandbox"])
        }
        return candidate
    }

    private func fetchHTTP(urlString: String, allowDirectHostBypass: Bool = false) async -> OpenClawToolResult {
        guard let url = normalizedURL(from: urlString) else {
            return .init(ok: false, output: "URL inválida")
        }

        let openAccess = config.isInternetOpenAccessEnabled()
        let host = (url.host ?? "").lowercased()
        let allowedHosts = Set(config.loadAllowlistHosts())
        if !openAccess && !allowedHosts.contains(host) && !allowDirectHostBypass {
            return .init(ok: false, output: "Host no permitido: \(host). Activa acceso abierto o agrega el dominio en Settings.")
        }

        var result = await fetchURLWithRetries(url)
        if result.ok { return result }

        // Plan B: alterna host www/non-www antes de rendirse.
        if let alt = alternateURLVariant(for: url), alt != url {
            result = await fetchURLWithRetries(alt)
        }
        return result
    }

    private func appFileExists(relativePath: String) -> Bool {
        do {
            let url = try sandboxedFileURL(relativePath: relativePath)
            return FileManager.default.fileExists(atPath: url.path)
        } catch {
            return false
        }
    }

    private func appendAppFile(relativePath: String, text: String) throws {
        let url = try sandboxedFileURL(relativePath: relativePath)
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            if let data = text.data(using: .utf8) {
                try handle.write(contentsOf: data)
            }
        } else {
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func deleteAppFile(relativePath: String) throws {
        let url = try sandboxedFileURL(relativePath: relativePath)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func todayString() -> String {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .medium
        f.locale = .current
        f.timeZone = .current
        return f.string(from: Date())
    }

    private func summarizeText(_ text: String) -> String {
        let clean = text.replacingOccurrences(of: "


", with: "

")
        if clean.count <= 900 { return clean }
        let start = String(clean.prefix(550))
        let end = String(clean.suffix(300))
        return "Resumen rápido (extractivo):

\(start)

[...]

\(end)"
    }

    private func evaluateMath(_ expression: String) -> String {
        let allowed = CharacterSet(charactersIn: "0123456789+-*/(). ")
        if expression.rangeOfCharacter(from: allowed.inverted) != nil || expression.count > 120 {
            return "Expresión inválida"
        }
        let exp = NSExpression(format: expression)
        if let value = exp.expressionValue(with: nil, context: nil) as? NSNumber {
            return value.stringValue
        }
        return "No pude calcular"
    }

    private func normalizedURL(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let u = URL(string: trimmed), ["http", "https"].contains(u.scheme?.lowercased() ?? "") {
            return u
        }
        return URL(string: "https://" + trimmed)
    }

    private func alternateURLVariant(for url: URL) -> URL? {
        guard var comp = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = comp.host else { return nil }
        if host.hasPrefix("www.") {
            comp.host = String(host.dropFirst(4))
        } else {
            comp.host = "www." + host
        }
        return comp.url
    }

    private func fetchURLWithRetries(_ url: URL) async -> OpenClawToolResult {
        await self.withNetworkRetries(attempts: self.config.isLowPowerModeEnabled() ? 2 : 3, initialDelayMs: 500) {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    return .init(ok: false, output: "HTTP status \(http.statusCode)")
                }

                let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
                if contentType.contains("application/pdf") || url.pathExtension.lowercased() == "pdf" {
                    let text = self.extractPDFText(from: data)
                    return .init(ok: true, output: text)
                }

                let text = String(data: data, encoding: .utf8) ?? ""
                return .init(ok: true, output: String(text.prefix(6000)))
            } catch {
                return .init(ok: false, output: "http_get error: \(error.localizedDescription)")
            }
        }
    }

    private func braveSearch(query: String, count: Int) async -> OpenClawToolResult {
        let key = config.loadBraveApiKey()
        guard !key.isEmpty else {
            return .init(ok: false, output: "Brave API key no configurada")
        }

        var comp = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")
        comp?.queryItems = [
            .init(name: "q", value: query),
            .init(name: "count", value: String(count))
        ]
        guard let url = comp?.url else {
            return .init(ok: false, output: "URL inválida para Brave")
        }

        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(key, forHTTPHeaderField: "X-Subscription-Token")

        return await self.withNetworkRetries(attempts: self.config.isLowPowerModeEnabled() ? 2 : 3, initialDelayMs: 500) {
            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    let body = String(data: data, encoding: .utf8) ?? ""
                    return .init(ok: false, output: "Brave HTTP \(http.statusCode): \(body.prefix(300))")
                }
                return .init(ok: true, output: self.formatBraveResults(from: data))
            } catch {
                return .init(ok: false, output: "brave_search error: \(error.localizedDescription)")
            }
        }
    }

    private func withNetworkRetries(attempts: Int, initialDelayMs: UInt64, operation: @escaping () async -> OpenClawToolResult) async -> OpenClawToolResult {
        var delay = initialDelayMs
        var last = OpenClawToolResult(ok: false, output: "Sin intento")

        for i in 0..<max(1, attempts) {
            let result = await operation()
            last = result
            if result.ok { return result }
            if i < attempts - 1 {
                try? await Task.sleep(nanoseconds: delay * 1_000_000)
                delay = min(delay * 2, 2500)
            }
        }
        return last
    }

    private func extractPDFText(from data: Data) -> String {
        #if canImport(PDFKit)
        guard let doc = PDFDocument(data: data) else { return "PDF descargado, pero no pude leer su contenido." }
        let maxPages = min(doc.pageCount, 8)
        var chunks: [String] = []
        for i in 0..<maxPages {
            if let pageText = doc.page(at: i)?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !pageText.isEmpty {
                chunks.append("[Página \(i + 1)]\n\(pageText)")
            }
        }
        if chunks.isEmpty { return "PDF descargado, sin texto extraíble." }
        return String(chunks.joined(separator: "\n\n").prefix(5000))
        #else
        return "PDF descargado, pero este build no incluye PDFKit para extraer texto."
        #endif
    }

    private func formatBraveResults(from data: Data) -> String {
        guard let decoded = try? JSONDecoder().decode(BraveSearchResponse.self, from: data) else {
            return String(data: data, encoding: .utf8).map { String($0.prefix(3000)) } ?? "Sin resultados"
        }

        let items = decoded.web?.results ?? []
        if items.isEmpty { return "Sin resultados" }

        return items.prefix(8).enumerated().map { idx, row in
            let title = row.title ?? "Sin título"
            let url = row.url ?? ""
            let desc = row.description ?? ""
            return "\(idx + 1). \(title)\n\(url)\n\(desc)"
        }.joined(separator: "\n\n")
    }
}

private struct BraveSearchResponse: Codable {
    let web: BraveWebResults?
}

private struct BraveWebResults: Codable {
    let results: [BraveWebResult]?
}

private struct BraveWebResult: Codable {
    let title: String?
    let url: String?
    let description: String?
}
