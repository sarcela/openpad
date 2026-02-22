import Foundation

enum LocalModelConfigError: LocalizedError {
    case documentsDirectoryUnavailable

    var errorDescription: String? {
        switch self {
        case .documentsDirectoryUnavailable:
            return "No se encontró el directorio Documents de la app"
        }
    }
}

struct LocalModelConfig {
    static let shared = LocalModelConfig()

    let appModelsDirectoryName = "Models"
    private let selectedModelBookmarkKey = "local.selectedModelPath"

    func documentsDirectory() throws -> URL {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw LocalModelConfigError.documentsDirectoryUnavailable
        }
        return docs
    }

    func modelsDirectory(in documentsDir: URL) -> URL {
        documentsDir.appendingPathComponent(appModelsDirectoryName, isDirectory: true)
    }

    func ensureModelsDirectoryExists(in documentsDir: URL) throws {
        let dir = modelsDirectory(in: documentsDir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func availableModels(in documentsDir: URL) -> [URL] {
        let fm = FileManager.default
        let dir = modelsDirectory(in: documentsDir)
        let contents = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []

        return contents
            .filter { $0.pathExtension.lowercased() == "gguf" }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    func importModel(from sourceURL: URL, into documentsDir: URL) throws -> URL {
        try ensureModelsDirectoryExists(in: documentsDir)

        let destination = modelsDirectory(in: documentsDir)
            .appendingPathComponent(sourceURL.lastPathComponent, isDirectory: false)

        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(at: sourceURL, to: destination)
        return destination
    }

    func deleteModel(at modelURL: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: modelURL.path) else { return }
        try fm.removeItem(at: modelURL)

        if loadSelectedModelPath() == modelURL.path {
            saveSelectedModelPath(nil)
        }
    }

    func displayName(for modelURL: URL) -> String {
        modelURL.deletingPathExtension().lastPathComponent
    }

    func saveSelectedModelPath(_ path: String?) {
        let defaults = UserDefaults.standard
        if let path, !path.isEmpty {
            defaults.set(path, forKey: selectedModelBookmarkKey)
        } else {
            defaults.removeObject(forKey: selectedModelBookmarkKey)
        }
    }

    func loadSelectedModelPath() -> String? {
        UserDefaults.standard.string(forKey: selectedModelBookmarkKey)
    }

    func firstExistingModelPath(in documentsDir: URL) -> URL? {
        let models = availableModels(in: documentsDir)

        if let selected = loadSelectedModelPath(),
           FileManager.default.fileExists(atPath: selected) {
            return URL(fileURLWithPath: selected)
        }

        return models.first
    }
}
