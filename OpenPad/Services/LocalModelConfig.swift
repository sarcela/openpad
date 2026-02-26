import Foundation

enum LocalModelConfigError: LocalizedError {
    case documentsDirectoryUnavailable

    var errorDescription: String? {
        switch self {
        case .documentsDirectoryUnavailable:
            return "App Documents directory not found"
        }
    }
}

struct LocalModelConfig {
    static let shared = LocalModelConfig()

    let appModelsDirectoryName = "Models"
    let appEmbeddingModelsDirectoryName = "EmbeddingModels"

    private let selectedModelBookmarkKey = "local.selectedModelPath"
    private let selectedEmbeddingModelBookmarkKey = "local.selectedEmbeddingModelPath"

    func documentsDirectory() throws -> URL {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw LocalModelConfigError.documentsDirectoryUnavailable
        }
        return docs
    }

    func modelsDirectory(in documentsDir: URL) -> URL {
        documentsDir.appendingPathComponent(appModelsDirectoryName, isDirectory: true)
    }

    func embeddingModelsDirectory(in documentsDir: URL) -> URL {
        documentsDir.appendingPathComponent(appEmbeddingModelsDirectoryName, isDirectory: true)
    }

    func ensureModelsDirectoryExists(in documentsDir: URL) throws {
        try FileManager.default.createDirectory(at: modelsDirectory(in: documentsDir), withIntermediateDirectories: true)
    }

    func ensureEmbeddingModelsDirectoryExists(in documentsDir: URL) throws {
        try FileManager.default.createDirectory(at: embeddingModelsDirectory(in: documentsDir), withIntermediateDirectories: true)
    }

    func availableModels(in documentsDir: URL) -> [URL] {
        availableGGUF(in: modelsDirectory(in: documentsDir))
    }

    func availableEmbeddingModels(in documentsDir: URL) -> [URL] {
        availableGGUF(in: embeddingModelsDirectory(in: documentsDir))
    }

    func importModel(from sourceURL: URL, into documentsDir: URL) throws -> URL {
        try ensureModelsDirectoryExists(in: documentsDir)
        return try copyModel(from: sourceURL, to: modelsDirectory(in: documentsDir))
    }

    func importEmbeddingModel(from sourceURL: URL, into documentsDir: URL) throws -> URL {
        try ensureEmbeddingModelsDirectoryExists(in: documentsDir)
        return try copyModel(from: sourceURL, to: embeddingModelsDirectory(in: documentsDir))
    }

    func deleteModel(at modelURL: URL) throws {
        try deleteFile(at: modelURL)
        if loadSelectedModelPath() == modelURL.path {
            saveSelectedModelPath(nil)
        }
    }

    func deleteEmbeddingModel(at modelURL: URL) throws {
        try deleteFile(at: modelURL)
        if loadSelectedEmbeddingModelPath() == modelURL.path {
            saveSelectedEmbeddingModelPath(nil)
        }
    }

    func displayName(for modelURL: URL) -> String {
        modelURL.deletingPathExtension().lastPathComponent
    }

    func saveSelectedModelPath(_ path: String?) {
        savePath(path, key: selectedModelBookmarkKey)
    }

    func loadSelectedModelPath() -> String? {
        UserDefaults.standard.string(forKey: selectedModelBookmarkKey)
    }

    func saveSelectedEmbeddingModelPath(_ path: String?) {
        savePath(path, key: selectedEmbeddingModelBookmarkKey)
    }

    func loadSelectedEmbeddingModelPath() -> String? {
        UserDefaults.standard.string(forKey: selectedEmbeddingModelBookmarkKey)
    }

    func firstExistingModelPath(in documentsDir: URL) -> URL? {
        let models = availableModels(in: documentsDir)

        if let selected = loadSelectedModelPath(), FileManager.default.fileExists(atPath: selected) {
            return URL(fileURLWithPath: selected)
        }

        return models.first
    }

    private func availableGGUF(in directory: URL) -> [URL] {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isReadableKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return contents
            .filter { $0.pathExtension.lowercased() == "gguf" }
            .filter {
                guard let values = try? $0.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey, .fileSizeKey]) else {
                    return false
                }
                guard values.isRegularFile == true, values.isReadable == true else { return false }
                // Hide tiny placeholder files caused by interrupted imports/downloads.
                return (values.fileSize ?? 0) >= 4_096
            }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func copyModel(from sourceURL: URL, to targetDirectory: URL) throws -> URL {
        let destination = targetDirectory.appendingPathComponent(sourceURL.lastPathComponent, isDirectory: false)
        let fm = FileManager.default

        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(at: sourceURL, to: destination)
        return destination
    }

    private func deleteFile(at url: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        try fm.removeItem(at: url)
    }

    private func savePath(_ path: String?, key: String) {
        let defaults = UserDefaults.standard
        if let path, !path.isEmpty {
            defaults.set(path, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
