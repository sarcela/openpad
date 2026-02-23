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
            "get_time", "calendar_today",
            "save_memory", "list_memories", "search_memories", "clear_memories",
            "read_file", "write_file", "append_file", "delete_file", "list_files", "file_exists",
            "read_attachment", "list_attachments",
            "http_get", "summarize_url", "brave_search",
            "calculate", "make_uuid", "json_parse", "csv_preview", "markdown_toc", "diff_text",
            "regex_extract", "base64_encode", "base64_decode", "url_encode", "url_decode",
            "json_path", "csv_filter", "html_to_text", "keyword_extract", "chunk_text",
            "extract_code_blocks", "lint_markdown", "table_to_bullets", "normalize_whitespace",
            "word_count", "text_stats", "extract_emails", "extract_urls", "analyze_attachment"
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
    private let runtimeConfig = LocalRuntimeConfig.shared

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
                let hits = try await searchMemory(query: query, limit: max(1, min(10, limit)))
                if hits.isEmpty { return .init(ok: true, output: "No matches") }
                return .init(ok: true, output: hits.joined(separator: "\n"))
            } catch {
                return .init(ok: false, output: "Error searching memories: \(error.localizedDescription)")
            }

        case "clear_memories":
            guard isDestructiveConfirmed(arguments) else {
                return .init(ok: false, output: "clear_memories requires explicit confirmation: confirm=YES")
            }
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

        case "file_exists":
            let relativePath = (arguments["path"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !relativePath.isEmpty else { return .init(ok: false, output: "Missing argument: path") }
            return .init(ok: true, output: appFileExists(relativePath: relativePath) ? "true" : "false")

        case "append_file":
            let relativePath = (arguments["path"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let text = arguments["text"] ?? ""
            guard !relativePath.isEmpty else { return .init(ok: false, output: "Missing argument: path") }
            do {
                try appendAppFile(relativePath: relativePath, text: text)
                return .init(ok: true, output: "Appended file: \(relativePath)")
            } catch {
                return .init(ok: false, output: "append_file error: \(error.localizedDescription)")
            }

        case "delete_file":
            guard isDestructiveConfirmed(arguments) else {
                return .init(ok: false, output: "delete_file requires explicit confirmation: confirm=YES")
            }
            let relativePath = (arguments["path"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !relativePath.isEmpty else { return .init(ok: false, output: "Missing argument: path") }
            do {
                try deleteAppFile(relativePath: relativePath)
                return .init(ok: true, output: "Deleted file: \(relativePath)")
            } catch {
                return .init(ok: false, output: "delete_file error: \(error.localizedDescription)")
            }

        case "list_attachments":
            do {
                let rows = try listAttachments()
                return .init(ok: true, output: rows.isEmpty ? "No attachments" : rows.joined(separator: "\n"))
            } catch {
                return .init(ok: false, output: "list_attachments error: \(error.localizedDescription)")
            }

        case "read_attachment":
            var fileName = (arguments["fileName"] ?? arguments["name"] ?? arguments["path"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            fileName = fileName.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`[](){}<>.,;:"))
            if fileName.isEmpty, let latest = try? listAttachments().first {
                fileName = latest
            }
            guard !fileName.isEmpty else { return .init(ok: false, output: "Missing argument: fileName (and no attachments available)") }
            let maxChars = Int(arguments["maxChars"] ?? arguments["max_chars"] ?? "4000") ?? 4000
            let snippet = readAttachmentSnippet(fileName: fileName, maxChars: max(300, min(16000, maxChars)))
            if snippet.isEmpty {
                let available = (try? listAttachments().prefix(5).joined(separator: ", ")) ?? "none"
                return .init(ok: false, output: "Attachment not found or could not be read: \(fileName). Available attachments: \(available)")
            }
            return .init(ok: true, output: snippet)

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

        case "calendar_today":
            return .init(ok: true, output: todayString())

        case "summarize_url":
            let urlString = (arguments["url"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !urlString.isEmpty else { return .init(ok: false, output: "Missing argument: url") }
            let fetched = await fetchHTTP(urlString: urlString, allowDirectHostBypass: true)
            guard fetched.ok else { return fetched }
            return .init(ok: true, output: summarizeText(fetched.output))

        case "calculate":
            let expression = (arguments["expression"] ?? arguments["expr"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !expression.isEmpty else { return .init(ok: false, output: "Missing argument: expression") }
            return .init(ok: true, output: evaluateMath(expression))

        case "make_uuid":
            return .init(ok: true, output: UUID().uuidString)

        case "json_parse":
            let text = arguments["text"] ?? ""
            guard !text.isEmpty else { return .init(ok: false, output: "Missing argument: text") }
            return .init(ok: true, output: jsonPrettyInfo(text))

        case "csv_preview":
            let text = arguments["text"] ?? ""
            guard !text.isEmpty else { return .init(ok: false, output: "Missing argument: text") }
            let maxRows = Int(arguments["max_rows"] ?? arguments["rows"] ?? "10") ?? 10
            return .init(ok: true, output: csvPreview(text: text, maxRows: max(1, min(100, maxRows))))

        case "markdown_toc":
            let text = arguments["text"] ?? ""
            guard !text.isEmpty else { return .init(ok: false, output: "Missing argument: text") }
            return .init(ok: true, output: markdownTOC(text))

        case "diff_text":
            let oldText = arguments["old"] ?? arguments["old_text"] ?? ""
            let newText = arguments["new"] ?? arguments["new_text"] ?? ""
            guard !oldText.isEmpty || !newText.isEmpty else { return .init(ok: false, output: "Missing argument: old/new text") }
            return .init(ok: true, output: simpleDiff(old: oldText, new: newText))

        case "regex_extract":
            let pattern = arguments["pattern"] ?? ""
            let text = arguments["text"] ?? ""
            guard !pattern.isEmpty, !text.isEmpty else { return .init(ok: false, output: "Missing argument: pattern/text") }
            return .init(ok: true, output: regexExtract(pattern: pattern, text: text))

        case "base64_encode":
            let text = arguments["text"] ?? ""
            guard let data = text.data(using: .utf8) else { return .init(ok: false, output: "Invalid text") }
            return .init(ok: true, output: data.base64EncodedString())

        case "base64_decode":
            let text = (arguments["text"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = Data(base64Encoded: text), let decoded = String(data: data, encoding: .utf8) else {
                return .init(ok: false, output: "Invalid base64")
            }
            return .init(ok: true, output: decoded)

        case "url_encode":
            let text = arguments["text"] ?? ""
            return .init(ok: true, output: text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text)

        case "url_decode":
            let text = arguments["text"] ?? ""
            return .init(ok: true, output: text.removingPercentEncoding ?? text)

        case "json_path":
            let text = arguments["text"] ?? ""
            let path = arguments["path"] ?? ""
            guard !text.isEmpty, !path.isEmpty else { return .init(ok: false, output: "Missing argument: text/path") }
            return .init(ok: true, output: jsonPath(text: text, path: path))

        case "csv_filter":
            let text = arguments["text"] ?? ""
            let contains = arguments["contains"] ?? arguments["query"] ?? ""
            guard !text.isEmpty else { return .init(ok: false, output: "Missing argument: text") }
            return .init(ok: true, output: csvFilter(text: text, contains: contains))

        case "html_to_text":
            let html = arguments["html"] ?? arguments["text"] ?? ""
            guard !html.isEmpty else { return .init(ok: false, output: "Missing argument: html") }
            return .init(ok: true, output: htmlToText(html))

        case "keyword_extract":
            let text = arguments["text"] ?? ""
            guard !text.isEmpty else { return .init(ok: false, output: "Missing argument: text") }
            let top = Int(arguments["top"] ?? "10") ?? 10
            return .init(ok: true, output: keywordExtract(text: text, top: max(1, min(50, top))))

        case "chunk_text":
            let text = arguments["text"] ?? ""
            guard !text.isEmpty else { return .init(ok: false, output: "Missing argument: text") }
            let size = Int(arguments["size"] ?? "1200") ?? 1200
            return .init(ok: true, output: chunkText(text: text, size: max(120, min(8000, size))))

        case "extract_code_blocks":
            let text = arguments["text"] ?? ""
            guard !text.isEmpty else { return .init(ok: false, output: "Missing argument: text") }
            return .init(ok: true, output: extractCodeBlocks(text))

        case "lint_markdown":
            let text = arguments["text"] ?? ""
            guard !text.isEmpty else { return .init(ok: false, output: "Missing argument: text") }
            return .init(ok: true, output: lintMarkdown(text))

        case "table_to_bullets":
            let text = arguments["text"] ?? ""
            guard !text.isEmpty else { return .init(ok: false, output: "Missing argument: text") }
            return .init(ok: true, output: tableToBullets(text))

        case "normalize_whitespace":
            let text = arguments["text"] ?? ""
            guard !text.isEmpty else { return .init(ok: false, output: "Missing argument: text") }
            return .init(ok: true, output: normalizeWhitespace(text))

        case "word_count":
            let text = arguments["text"] ?? ""
            guard !text.isEmpty else { return .init(ok: false, output: "Missing argument: text") }
            let words = text.split { !$0.isLetter && !$0.isNumber }.count
            return .init(ok: true, output: "words: \(words)")

        case "text_stats":
            let text = arguments["text"] ?? ""
            guard !text.isEmpty else { return .init(ok: false, output: "Missing argument: text") }
            return .init(ok: true, output: textStats(text))

        case "extract_emails":
            let text = arguments["text"] ?? ""
            guard !text.isEmpty else { return .init(ok: false, output: "Missing argument: text") }
            return .init(ok: true, output: extractEmails(from: text))

        case "extract_urls":
            let text = arguments["text"] ?? ""
            guard !text.isEmpty else { return .init(ok: false, output: "Missing argument: text") }
            return .init(ok: true, output: extractURLs(from: text))

        case "analyze_attachment":
            var fileName = (arguments["fileName"] ?? arguments["name"] ?? arguments["path"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            fileName = fileName.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`[](){}<>.,;:"))
            let maxChars = Int(arguments["maxChars"] ?? arguments["max_chars"] ?? "6000") ?? 6000

            // If missing fileName, try latest attachment automatically.
            if fileName.isEmpty {
                if let latest = try? listAttachments().first {
                    fileName = latest
                }
            }
            guard !fileName.isEmpty else { return .init(ok: false, output: "Missing argument: fileName (and no attachments available)") }

            var snippet = readAttachmentSnippet(fileName: fileName, maxChars: max(500, min(20000, maxChars)))
            var usedFile = fileName

            // Fallback: if named file fails, try latest attachment.
            if snippet.isEmpty, let latest = try? listAttachments().first, latest.lowercased() != fileName.lowercased() {
                let alt = readAttachmentSnippet(fileName: latest, maxChars: max(500, min(20000, maxChars)))
                if !alt.isEmpty {
                    snippet = alt
                    usedFile = latest
                }
            }

            guard !snippet.isEmpty else {
                let available = (try? listAttachments().prefix(5).joined(separator: ", ")) ?? "none"
                return .init(ok: false, output: "Attachment not found or unreadable: \(fileName). Available attachments: \(available)")
            }

            let keywords = keywordExtract(text: snippet, top: 12)
            let summary = summarizeText(snippet)
            return .init(ok: true, output: "[attachment:\(usedFile)]\n\n\(summary)\n\n[top keywords]\n\(keywords)")

        default:
            return .init(ok: false, output: "Unknown tool: \(name)")
        }
    }

    func recentMemories(limit: Int = 8) -> String {
        do {
            let items = try readMemoryLines(limit: max(1, min(50, limit)))
            if items.isEmpty { return "(no stored memory)" }
            return items.joined(separator: "\n")
        } catch {
            return "(error reading memory: \(error.localizedDescription))"
        }
    }


    func listAttachments() throws -> [String] {
        let docs = try documentsDirectory()
        let dir = docs.appendingPathComponent("OpenClawFiles/Attachments", isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        let items = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
        let sorted = items.sorted { a, b in
            let ad = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let bd = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return ad > bd
        }
        return sorted.map { $0.lastPathComponent }
    }

    func readAttachmentSnippet(fileName: String, maxChars: Int = 4000) -> String {
        let clean = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return "" }

        let lower = clean.lowercased()
        let isImage = ["jpg", "jpeg", "png", "heic", "webp"].contains { lower.hasSuffix("." + $0) }
        let isPDF = lower.hasSuffix(".pdf")

        do {
            let docs = try documentsDirectory()
            let dir = docs.appendingPathComponent("OpenClawFiles/Attachments", isDirectory: true)
            let url = try resolveAttachmentURL(fileName: clean, in: dir)
            let data = try Data(contentsOf: url)

            if isImage {
                if !config.isLowPowerModeEnabled() {
                    let ocr = extractTextFromImageData(data)
                    if !ocr.isEmpty {
                        return "[extractor:vision_ocr file:\(url.lastPathComponent)]\n" + String(ocr.prefix(maxChars))
                    }
                    return "[extractor:vision_ocr file:\(url.lastPathComponent)] (Image has no OCR-detectable text)"
                }
                return "[extractor:vision_ocr file:\(url.lastPathComponent)] (OCR skipped in low-power mode)"
            }

            if isPDF {
                let pdfText = extractTextFromPDFData(data)
                if !pdfText.isEmpty {
                    return "[extractor:pdfkit file:\(url.lastPathComponent)]\n" + String(pdfText.prefix(maxChars))
                }
                return "[extractor:pdfkit file:\(url.lastPathComponent)] (PDF has no extractable text; it may be image-scanned)"
            }

            if let text = decodeTextData(data) {
                return "[extractor:text_decode file:\(url.lastPathComponent)]\n" + String(text.prefix(maxChars))
            }

            return "[extractor:binary file:\(url.lastPathComponent)] (Adjunto binario no textual: \(clean))"
        } catch {
            return ""
        }
    }

    private func resolveAttachmentURL(fileName: String, in dir: URL) throws -> URL {
        let exact = dir.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: exact.path) { return exact }

        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        guard !items.isEmpty else {
            throw NSError(domain: "OpenClawLiteTools", code: 404, userInfo: [NSLocalizedDescriptionKey: "Attachments directory empty"])
        }

        let target = fileName.lowercased()
        if let byExactCaseInsensitive = items.first(where: { $0.lastPathComponent.lowercased() == target }) {
            return byExactCaseInsensitive
        }

        let stem = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent.lowercased()
        if !stem.isEmpty {
            if let byContains = items.first(where: {
                let n = $0.lastPathComponent.lowercased()
                return n.contains(stem)
            }) {
                return byContains
            }
        }

        throw NSError(domain: "OpenClawLiteTools", code: 404, userInfo: [NSLocalizedDescriptionKey: "Attachment not found: \(fileName)"])
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

    private func extractTextFromPDFData(_ data: Data) -> String {
        #if canImport(PDFKit)
        guard let pdf = PDFDocument(data: data) else { return "" }
        var chunks: [String] = []
        for i in 0..<pdf.pageCount {
            if let pageText = pdf.page(at: i)?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !pageText.isEmpty {
                chunks.append(pageText)
            }
        }
        return chunks.joined(separator: "\n\n")
        #else
        _ = data
        return ""
        #endif
    }

    private func decodeTextData(_ data: Data) -> String? {
        if let utf8 = String(data: data, encoding: .utf8), !utf8.isEmpty { return utf8 }
        if let utf16 = String(data: data, encoding: .utf16), !utf16.isEmpty { return utf16 }
        if let latin1 = String(data: data, encoding: .isoLatin1), !latin1.isEmpty { return latin1 }
        if let win = String(data: data, encoding: .windowsCP1252), !win.isEmpty { return win }
        return nil
    }

    private func searchMemory(query: String, limit: Int) async throws -> [String] {
        let rows = try readMemoryLines(limit: 300)
        let qTokens = normalizedTokens(query)
        if qTokens.isEmpty { return [] }

        let qEmbedding = await embeddingVector(for: query, allowRemote: true)

        var scored: [(Double, String)] = []
        scored.reserveCapacity(rows.count)

        for row in rows {
            let rTokens = normalizedTokens(row)
            let overlap = Double(qTokens.intersection(rTokens).count)
            let denom = Double(max(1, qTokens.union(rTokens).count))
            let jaccard = overlap / denom

            // Semantic embedding: query may come from real backend; rows use local vectors for stable cost.
            let semantic = cosineSimilarity(qEmbedding, await embeddingVector(for: row, allowRemote: false))

            // Bonus por frase parcial.
            let phraseBonus = row.lowercased().contains(query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)) ? 0.20 : 0.0

            let score = (semantic * 0.60) + (jaccard * 0.40) + phraseBonus
            scored.append((score, row))
        }

        return scored
            .filter { $0.0 > 0.08 }
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
            return .init(ok: false, output: "Invalid URL")
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


    private func isDestructiveConfirmed(_ arguments: [String: String]) -> Bool {
        let v = (arguments["confirm"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return v == "YES" || v == "TRUE"
    }

    private struct EmbeddingCacheEntry: Codable {
        let key: String
        let backend: String
        let model: String
        let dims: Int
        let vector: [Double]
        let updatedAt: TimeInterval
    }

    private func normalizedTokens(_ text: String) -> Set<String> {
        let stop: Set<String> = ["de","la","el","y","en","a","que","los","las","un","una","por","para","con","the","and","for","to","of","in","on","is","are","it"]
        let raw = text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let cleaned = raw.map { token -> String in
            var t = token
            for suf in ["mente","ciones","cion","ados","adas","ado","ada","ing","ed","es","s"] {
                if t.count > 4 && t.hasSuffix(suf) {
                    t = String(t.dropLast(suf.count))
                    break
                }
            }
            return t
        }
        return Set(cleaned.filter { $0.count > 2 && !stop.contains($0) })
    }

    private func embeddingVector(for text: String, allowRemote: Bool) async -> [Double] {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return [] }

        let remoteModel = runtimeConfig.loadOllama().model.trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteKey = embeddingCacheKey(backend: "ollama", model: remoteModel, text: clean)
        let localKey = embeddingCacheKey(backend: "local_hash", model: "v1", text: clean)

        if allowRemote,
           !remoteModel.isEmpty,
           let cached = cachedEmbedding(for: remoteKey),
           !cached.isEmpty {
            return cached
        }

        if let cachedLocal = cachedEmbedding(for: localKey), !cachedLocal.isEmpty {
            if allowRemote {
                // still try remote for better semantic quality if available.
                if let remote = await remoteEmbeddingFromOllama(text: clean) {
                    saveCachedEmbedding(remote, key: remoteKey, backend: "ollama", model: remoteModel)
                    return remote
                }
            }
            return cachedLocal
        }

        if allowRemote, let remote = await remoteEmbeddingFromOllama(text: clean) {
            saveCachedEmbedding(remote, key: remoteKey, backend: "ollama", model: remoteModel)
            return remote
        }

        let local = localEmbedding(clean)
        saveCachedEmbedding(local, key: localKey, backend: "local_hash", model: "v1")
        return local
    }

    private func localEmbedding(_ text: String, dimensions: Int = 256) -> [Double] {
        var vec = Array(repeating: 0.0, count: dimensions)
        let tokens = normalizedTokens(text)
        if tokens.isEmpty { return vec }

        for token in tokens {
            var hasher = Hasher()
            hasher.combine(token)
            let h = hasher.finalize()
            let idx = Int(UInt(bitPattern: h) % UInt(dimensions))

            var signHasher = Hasher()
            signHasher.combine(token + "_sign")
            let sign = (signHasher.finalize() % 2 == 0) ? 1.0 : -1.0
            vec[idx] += sign
        }

        let norm = sqrt(vec.reduce(0.0) { $0 + ($1 * $1) })
        if norm > 0 {
            vec = vec.map { $0 / norm }
        }
        return vec
    }

    private func remoteEmbeddingFromOllama(text: String) async -> [Double]? {
        let cfg = runtimeConfig.loadOllama()
        let base = cfg.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = URL(string: base), !cfg.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else { return nil }

        let endpoints = ["/api/embed", "/api/embeddings"]
        for endpoint in endpoints {
            guard let url = URL(string: endpoint, relativeTo: baseURL) else { continue }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 8
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let payload: [String: Any] = [
                "model": cfg.model,
                "input": cleanText,
                "prompt": cleanText
            ]
            req.httpBody = try? JSONSerialization.data(withJSONObject: payload)

            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { continue }

                if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let e = obj["embedding"] as? [Double], !e.isEmpty {
                        return normalizeEmbedding(e)
                    }
                    if let arr = obj["embeddings"] as? [[Double]], let first = arr.first, !first.isEmpty {
                        return normalizeEmbedding(first)
                    }
                }
            } catch {
                continue
            }
        }

        return nil
    }

    private func normalizeEmbedding(_ v: [Double]) -> [Double] {
        let norm = sqrt(v.reduce(0.0) { $0 + ($1 * $1) })
        guard norm > 0 else { return v }
        return v.map { $0 / norm }
    }

    private func embeddingCacheKey(backend: String, model: String, text: String) -> String {
        let normalized = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(backend)|\(model)|\(stableHash(normalized))"
    }

    private func stableHash(_ text: String) -> String {
        // FNV-1a 64-bit deterministic hash.
        var hash: UInt64 = 14695981039346656037
        for b in text.utf8 {
            hash ^= UInt64(b)
            hash = hash &* 1099511628211
        }
        return String(hash, radix: 16)
    }

    private func embeddingCacheURL() throws -> URL {
        let docs = try documentsDirectory()
        let dir = docs.appendingPathComponent(memoryDirName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("embedding_cache.json")
    }

    private func loadEmbeddingCache() -> [EmbeddingCacheEntry] {
        do {
            let url = try embeddingCacheURL()
            guard FileManager.default.fileExists(atPath: url.path) else { return [] }
            let data = try Data(contentsOf: url)
            return (try? JSONDecoder().decode([EmbeddingCacheEntry].self, from: data)) ?? []
        } catch {
            return []
        }
    }

    private func saveEmbeddingCache(_ rows: [EmbeddingCacheEntry]) {
        do {
            let url = try embeddingCacheURL()
            let data = try JSONEncoder().encode(rows)
            try data.write(to: url, options: .atomic)
        } catch {
            // best-effort cache; ignore errors.
        }
    }

    private func cachedEmbedding(for key: String) -> [Double]? {
        let rows = loadEmbeddingCache()
        return rows.first(where: { $0.key == key })?.vector
    }

    private func saveCachedEmbedding(_ vector: [Double], key: String, backend: String, model: String) {
        guard !vector.isEmpty else { return }
        var rows = loadEmbeddingCache().filter { $0.key != key }
        rows.append(.init(key: key, backend: backend, model: model, dims: vector.count, vector: vector, updatedAt: Date().timeIntervalSince1970))
        if rows.count > 1200 {
            rows = Array(rows.suffix(1200))
        }
        saveEmbeddingCache(rows)
    }

    private func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0
        for i in 0..<a.count {
            dot += a[i] * b[i]
        }
        // Normalize to 0...1 range to combine with other signals.
        return max(0, min(1, (dot + 1.0) / 2.0))
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
        let clean = text.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        if clean.count <= 900 { return clean }
        let start = String(clean.prefix(550))
        let end = String(clean.suffix(300))
        return "Quick summary (extractive):\n\n\(start)\n\n[...]\n\n\(end)"
    }

    private func evaluateMath(_ expression: String) -> String {
        let allowed = CharacterSet(charactersIn: "0123456789+-*/(). ")
        if expression.rangeOfCharacter(from: allowed.inverted) != nil || expression.count > 120 {
            return "Invalid expression"
        }
        let exp = NSExpression(format: expression)
        if let value = exp.expressionValue(with: nil, context: nil) as? NSNumber {
            return value.stringValue
        }
        return "No pude calcular"
    }

    private func jsonPrettyInfo(_ text: String) -> String {
        guard let data = text.data(using: .utf8) else { return "Invalid text" }
        do {
            let obj = try JSONSerialization.jsonObject(with: data)
            let pretty = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted])
            let out = String(data: pretty, encoding: .utf8) ?? ""
            return String(out.prefix(4000))
        } catch {
            return "Invalid JSON: \(error.localizedDescription)"
        }
    }

    private func csvPreview(text: String, maxRows: Int) -> String {
        let rows = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !rows.isEmpty else { return "Empty CSV" }
        let shown = rows.prefix(maxRows)
        let cols = rows.first?.split(separator: ",").count ?? 0
        let header = "Filas: \(rows.count), columnas (estimadas): \(cols)"
        return header + "\n\n" + shown.joined(separator: "\n")
    }

    private func markdownTOC(_ text: String) -> String {
        let lines = text.split(separator: "\n").map(String.init)
        let items = lines.compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#") else { return nil }
            let level = trimmed.prefix { $0 == "#" }.count
            let title = trimmed.drop { $0 == "#" || $0 == " " }
            guard !title.isEmpty else { return nil }
            let indent = String(repeating: "  ", count: max(0, level - 1))
            return "\(indent)- \(title)"
        }
        return items.isEmpty ? "Sin encabezados markdown" : items.joined(separator: "\n")
    }

    private func simpleDiff(old: String, new: String) -> String {
        let oldLines = old.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let newLines = new.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let oldSet = Set(oldLines)
        let newSet = Set(newLines)
        let removed = oldSet.subtracting(newSet).prefix(50).map { "- \($0)" }
        let added = newSet.subtracting(oldSet).prefix(50).map { "+ \($0)" }
        if removed.isEmpty && added.isEmpty { return "No line-level differences detected" }
        return (["Cambios detectados:"] + removed + added).joined(separator: "\n")
    }

    private func extractCodeBlocks(_ text: String) -> String {
        let pattern = #"```([a-zA-Z0-9_-]*)\n([\s\S]*?)```"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return "Invalid regex" }
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, options: [], range: range)
        if matches.isEmpty { return "No code blocks found" }

        let rows: [String] = matches.prefix(20).enumerated().compactMap { idx, m in
            guard let langR = Range(m.range(at: 1), in: text),
                  let codeR = Range(m.range(at: 2), in: text) else { return nil }
            let lang = String(text[langR]).isEmpty ? "plain" : String(text[langR])
            let code = String(text[codeR]).trimmingCharacters(in: .whitespacesAndNewlines)
            return "[Block \(idx + 1) - \(lang)]\n\(String(code.prefix(1200)))"
        }
        return rows.joined(separator: "\n\n")
    }

    private func lintMarkdown(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var issues: [String] = []

        var headingLevels: [Int] = []
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                let lvl = trimmed.prefix { $0 == "#" }.count
                headingLevels.append(lvl)
                if lvl > 1, let prev = headingLevels.dropLast().last, lvl - prev > 1 {
                    issues.append("Line \(i + 1): abrupt heading jump H\(prev) -> H\(lvl)")
                }
            }
            if trimmed.contains("\\t") {
                issues.append("Line \(i + 1): contains tabs")
            }
        }

        if text.contains("  ") {
            issues.append("Espacios dobles detectados (revisar formato)")
        }

        return issues.isEmpty ? "Markdown OK" : issues.prefix(40).joined(separator: "\n")
    }

    private func tableToBullets(_ text: String) -> String {
        let rows = text.split(separator: "\n").map(String.init).filter { $0.contains("|") }
        guard rows.count >= 2 else { return "No markdown table detected" }

        let parsed = rows.map { row in
            row.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        guard let header = parsed.first, header.count >= 2 else { return "Invalid table" }

        let body = parsed.dropFirst().filter { !$0.allSatisfy { Set($0).isSubset(of: Set("-:")) } }
        if body.isEmpty { return "Sin filas de datos" }

        let out = body.prefix(80).map { cols -> String in
            let pairs = zip(header, cols).map { "\($0): \($1)" }
            return "- " + pairs.joined(separator: " · ")
        }
        return out.joined(separator: "\n")
    }

    private func normalizeWhitespace(_ text: String) -> String {
        var out = text.replacingOccurrences(of: "\r\n", with: "\n")
        out = out.replacingOccurrences(of: "\t", with: " ")
        while out.contains("  ") {
            out = out.replacingOccurrences(of: "  ", with: " ")
        }
        out = out.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func textStats(_ text: String) -> String {
        let chars = text.count
        let words = text.split { !$0.isLetter && !$0.isNumber }.count
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
        let paragraphs = text.split(separator: "\n\n").count
        return "chars: \(chars)\nwords: \(words)\nlines: \(lines)\nparagraphs: \(paragraphs)"
    }

    private func extractEmails(from text: String) -> String {
        let pattern = #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return "Invalid regex" }
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, options: [], range: range)
        let rows = matches.compactMap { m -> String? in
            guard let r = Range(m.range, in: text) else { return nil }
            return String(text[r])
        }
        if rows.isEmpty { return "No emails found" }
        return Array(Set(rows)).sorted().joined(separator: "\n")
    }

    private func extractURLs(from text: String) -> String {
        let pattern = #"https?://[^\s\)\]\>\"]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return "Invalid regex" }
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, options: [], range: range)
        let rows = matches.compactMap { m -> String? in
            guard let r = Range(m.range, in: text) else { return nil }
            return String(text[r])
        }
        if rows.isEmpty { return "No URLs found" }
        return Array(Set(rows)).sorted().joined(separator: "\n")
    }

    private func jsonPath(text: String, path: String) -> String {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else {
            return "Invalid JSON"
        }
        let cleanPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanPath.hasPrefix("$.") else { return "Invalid path (use format $.field.subfield)" }
        let parts = cleanPath.dropFirst(2).split(separator: ".").map(String.init)
        var current: Any = obj
        for part in parts {
            if let dict = current as? [String: Any], let next = dict[part] {
                current = next
            } else {
                return "Path no encontrado"
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: current, options: [.prettyPrinted]),
           let out = String(data: data, encoding: .utf8) {
            return String(out.prefix(4000))
        }
        return String(describing: current)
    }

    private func csvFilter(text: String, contains: String) -> String {
        let rows = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !rows.isEmpty else { return "Empty CSV" }
        guard !contains.isEmpty else { return rows.prefix(50).joined(separator: "\n") }
        let filtered = rows.filter { $0.localizedCaseInsensitiveContains(contains) }
        if filtered.isEmpty { return "Sin filas coincidentes" }
        return filtered.prefix(80).joined(separator: "\n")
    }

    private func htmlToText(_ html: String) -> String {
        guard let data = html.data(using: .utf8) else { return html }
        if let attr = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html], documentAttributes: nil) {
            return String(attr.string.prefix(6000))
        }
        return html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
    }

    private func keywordExtract(text: String, top: Int) -> String {
        let stop: Set<String> = ["de","la","el","y","en","a","que","los","las","un","una","por","para","con","the","and","for","to","of","in","on","is","are","it"]
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        var freq: [String:Int] = [:]
        for w in words where w.count > 2 && !stop.contains(w) {
            freq[w, default: 0] += 1
        }
        let ranked = freq.sorted { $0.value > $1.value }.prefix(top)
        if ranked.isEmpty { return "Sin keywords" }
        return ranked.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
    }

    private func chunkText(text: String, size: Int) -> String {
        if text.isEmpty { return "Empty text" }
        var out: [String] = []
        var idx = text.startIndex
        var i = 1
        while idx < text.endIndex {
            let end = text.index(idx, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            out.append("[Chunk \(i)]\n" + text[idx..<end])
            idx = end
            i += 1
            if out.count >= 12 { break }
        }
        return out.joined(separator: "\n\n")
    }

    private func regexExtract(pattern: String, text: String) -> String {
        guard !pattern.isEmpty else { return "Empty pattern" }
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return "Invalid regex" }
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, options: [], range: range)
        if matches.isEmpty { return "Sin coincidencias" }

        let rows: [String] = matches.prefix(30).enumerated().map { idx, m in
            var groups: [String] = []
            for i in 0..<m.numberOfRanges {
                if let r = Range(m.range(at: i), in: text) {
                    groups.append(String(text[r]))
                }
            }
            return "#\(idx + 1): " + groups.joined(separator: " | ")
        }
        return rows.joined(separator: "\n")
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
        await self.withNetworkRetries(attempts: self.networkAttempts(), initialDelayMs: 500) {
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
            return .init(ok: false, output: "Invalid URL para Brave")
        }

        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(key, forHTTPHeaderField: "X-Subscription-Token")

        return await self.withNetworkRetries(attempts: self.networkAttempts(), initialDelayMs: 500) {
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

    private func networkAttempts() -> Int {
        if config.isLowPowerModeEnabled() { return 2 }
        switch LocalRuntimeConfig.shared.loadRunProfile() {
        case .stable: return 2
        case .balanced: return 3
        case .turbo: return 4
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
                chunks.append("[Page \(i + 1)]\n\(pageText)")
            }
        }
        if chunks.isEmpty { return "PDF downloaded, no extractable text." }
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
            let title = row.title ?? "Untitled"
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
