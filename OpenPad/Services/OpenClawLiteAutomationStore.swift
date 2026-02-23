import Foundation

struct LocalSkill: Codable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var content: String
}

struct LocalCron: Codable, Identifiable {
    var id: UUID = UUID()
    var title: String
    var schedule: String
    var command: String
    var enabled: Bool = true
}

struct LocalCronLog: Codable, Identifiable {
    var id: UUID = UUID()
    var cronId: UUID
    var title: String
    var command: String
    var executedAt: Date = Date()
    var source: String = "timer"
    var success: Bool = true
    var note: String = ""
}

@MainActor
final class OpenClawLiteAutomationStore {
    static let shared = OpenClawLiteAutomationStore()

    private let rootFolder = "OpenClawLite"
    private let skillsFile = "skills.json"
    private let cronsFile = "crons.json"
    private let heartbeatFile = "HEARTBEAT.md"
    private let cronLogsFile = "cron_logs.json"
    private let filesFolder = "OpenClawFiles"

    private func docs() throws -> URL {
        guard let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw NSError(domain: "OpenClawLiteAutomationStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Documents no disponible"])
        }
        return url
    }

    private func rootURL() throws -> URL {
        let url = try docs().appendingPathComponent(rootFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fileURL(_ name: String) throws -> URL {
        try rootURL().appendingPathComponent(name)
    }

    func loadSkills() -> [LocalSkill] {
        do {
            let url = try fileURL(skillsFile)
            guard FileManager.default.fileExists(atPath: url.path) else { return [] }
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([LocalSkill].self, from: data)
        } catch {
            return []
        }
    }

    func saveSkills(_ rows: [LocalSkill]) throws {
        let data = try JSONEncoder().encode(rows)
        try data.write(to: fileURL(skillsFile), options: .atomic)
    }

    func loadCrons() -> [LocalCron] {
        do {
            let url = try fileURL(cronsFile)
            guard FileManager.default.fileExists(atPath: url.path) else { return [] }
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([LocalCron].self, from: data)
        } catch {
            return []
        }
    }

    func saveCrons(_ rows: [LocalCron]) throws {
        let data = try JSONEncoder().encode(rows)
        try data.write(to: fileURL(cronsFile), options: .atomic)
    }

    func loadCronLogs() -> [LocalCronLog] {
        do {
            let url = try fileURL(cronLogsFile)
            guard FileManager.default.fileExists(atPath: url.path) else { return [] }
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([LocalCronLog].self, from: data)
        } catch {
            return []
        }
    }

    func appendCronLog(_ log: LocalCronLog, keepLast max: Int = 200) {
        var logs = loadCronLogs()
        logs.append(log)
        if logs.count > max {
            logs = Array(logs.suffix(max))
        }
        if let data = try? JSONEncoder().encode(logs), let url = try? fileURL(cronLogsFile) {
            try? data.write(to: url, options: .atomic)
        }
    }

    func clearCronLogs() {
        if let url = try? fileURL(cronLogsFile), FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func loadHeartbeat() -> String {
        do {
            let url = try fileURL(heartbeatFile)
            guard FileManager.default.fileExists(atPath: url.path) else { return "" }
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            return ""
        }
    }

    func saveHeartbeat(_ content: String) throws {
        try content.write(to: fileURL(heartbeatFile), atomically: true, encoding: .utf8)
    }

    func listWorkspaceFiles() -> [String] {
        do {
            let dir = try docs().appendingPathComponent(filesFolder, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        } catch {
            return []
        }
    }

    func readWorkspaceFile(_ name: String) -> String {
        do {
            let url = try docs().appendingPathComponent(filesFolder, isDirectory: true).appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { return "" }
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            return ""
        }
    }

    func saveWorkspaceFile(name: String, content: String) throws {
        let dir = try docs().appendingPathComponent(filesFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safeName = name.replacingOccurrences(of: "/", with: "_")
        try content.write(to: dir.appendingPathComponent(safeName), atomically: true, encoding: .utf8)
    }
}
