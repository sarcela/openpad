import SwiftUI
import UniformTypeIdentifiers

private enum ImportTarget {
    case chat
    case embedding
}

struct ChatView: View {
    @StateObject private var vm = ChatViewModel()
    @State private var showSettings = false

    private let localConfig = LocalModelConfig.shared
    private let runtimeConfig = LocalRuntimeConfig.shared

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "cpu")
                        .foregroundColor(.secondary)
                    Text(selectedModelBannerText())
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemBackground))

                if vm.messages.isEmpty {
                    ContentUnavailableView("Sin mensajes aún", systemImage: "bubble.left.and.bubble.right")
                } else {
                    List(vm.messages) { msg in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(msg.role.uppercased()).font(.caption).foregroundColor(.secondary)
                            Text(msg.text)
                        }
                        .padding(.vertical, 4)
                    }
                }

                HStack {
                    TextField("Escribe un prompt...", text: $vm.inputText, axis: .vertical)
                        .textFieldStyle(.roundedBorder)

                    Button(vm.isLoading ? "..." : "Enviar") {
                        vm.send()
                    }
                    .disabled(vm.isLoading || vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding()
            }
            .navigationTitle("OpenPad")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                    }
                    .accessibilityLabel("Configuración")
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(vm: vm)
        }
    }

    private func selectedModelBannerText() -> String {
        let provider = runtimeConfig.loadProvider()
        switch provider {
        case .llamaCpp:
            if let selectedPath = localConfig.loadSelectedModelPath(), !selectedPath.isEmpty {
                return "Privado/offline • llama.cpp • \(URL(fileURLWithPath: selectedPath).deletingPathExtension().lastPathComponent)"
            }
            return "Privado/offline • llama.cpp • sin seleccionar"
        case .ollama:
            let cfg = runtimeConfig.loadOllama()
            return "Local (Ollama) • \(cfg.model)"
        case .mlx:
            return "Privado/offline • MLX • \(runtimeConfig.loadMLXModelName())"
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var vm: ChatViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var baseURL = ""
    @State private var token = ""
    @State private var model = ""

    @State private var models: [URL] = []
    @State private var selectedModelPath: String = ""

    @State private var embeddingModels: [URL] = []
    @State private var selectedEmbeddingModelPath: String = ""

    @State private var showFileImporter = false
    @State private var importTarget: ImportTarget = .chat

    @State private var runtimeProvider: LocalRuntimeProvider = .mlx
    @State private var ollamaBaseURL = ""
    @State private var ollamaModel = ""
    @State private var mlxModelName = ""

    @State private var importMessage = ""
    @State private var modelToDelete: URL?
    @State private var embeddingModelToDelete: URL?

    private let remoteConfig = RemoteModelConfig.shared
    private let localConfig = LocalModelConfig.shared
    private let runtimeConfig = LocalRuntimeConfig.shared

    var body: some View {
        NavigationStack {
            Form {
                Section("Cómo quieres correr") {
                    Picker("Modo", selection: $vm.routePreference) {
                        ForEach(RoutePreference.allCases) { option in
                            Label(option.title, systemImage: icon(for: option)).tag(option)
                        }
                    }
                }

                if vm.routePreference == .local {
                    Section("Motor local") {
                        Picker("Proveedor", selection: $runtimeProvider) {
                            ForEach(LocalRuntimeProvider.allCases) { provider in
                                Text(provider.title).tag(provider)
                            }
                        }

                        if runtimeProvider == .ollama {
                            TextField("Ollama URL", text: $ollamaBaseURL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            TextField("Modelo Ollama", text: $ollamaModel)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }

                        if runtimeProvider == .mlx {
                            TextField("Modelo MLX", text: $mlxModelName)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            Text("Requiere integrar mlx-swift en Xcode para inferencia real en iPad.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if runtimeProvider == .llamaCpp {
                    Section {
                        if models.isEmpty {
                            Text("No hay modelos locales para chat")
                                .foregroundColor(.secondary)
                        } else {
                            Picker("Modelo de chat", selection: $selectedModelPath) {
                                ForEach(models, id: \.path) { url in
                                    Text(localConfig.displayName(for: url)).tag(url.path)
                                }
                            }
                            .pickerStyle(.navigationLink)
                        }

                        HStack {
                            Button {
                                importTarget = .chat
                                showFileImporter = true
                            } label: {
                                Label("Añadir .gguf", systemImage: "plus.circle.fill")
                            }

                            Spacer()

                            if !selectedModelPath.isEmpty,
                               let selectedURL = models.first(where: { $0.path == selectedModelPath }) {
                                Button(role: .destructive) {
                                    modelToDelete = selectedURL
                                } label: {
                                    Label("Borrar", systemImage: "trash")
                                }
                            }
                        }
                    } header: {
                        Text("Modelo local de chat")
                    }

                    Section {
                        if embeddingModels.isEmpty {
                            Text("No hay modelos para embeddings/memoria")
                                .foregroundColor(.secondary)
                        } else {
                            Picker("Modelo embeddings", selection: $selectedEmbeddingModelPath) {
                                ForEach(embeddingModels, id: \.path) { url in
                                    Text(localConfig.displayName(for: url)).tag(url.path)
                                }
                            }
                            .pickerStyle(.navigationLink)
                        }

                        HStack {
                            Button {
                                importTarget = .embedding
                                showFileImporter = true
                            } label: {
                                Label("Añadir .gguf embeddings", systemImage: "plus.circle")
                            }

                            Spacer()

                            if !selectedEmbeddingModelPath.isEmpty,
                               let selectedURL = embeddingModels.first(where: { $0.path == selectedEmbeddingModelPath }) {
                                Button(role: .destructive) {
                                    embeddingModelToDelete = selectedURL
                                } label: {
                                    Label("Borrar", systemImage: "trash")
                                }
                            }
                        }
                    } header: {
                        Text("Embeddings y memoria")
                    }
                    }
                }

                if vm.routePreference != .local {
                    Section("API remota") {
                        TextField("URL del API", text: $baseURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Token (opcional)", text: $token)
                        TextField("Modelo", text: $model)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }

                if !importMessage.isEmpty {
                    Section("Estado") {
                        Text(importMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Configuración")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") {
                        remoteConfig.save(baseURL: baseURL, token: token, model: model)
                        runtimeConfig.saveProvider(runtimeProvider)
                        runtimeConfig.saveOllama(baseURL: ollamaBaseURL, model: ollamaModel)
                        runtimeConfig.saveMLXModelName(mlxModelName)
                        localConfig.saveSelectedModelPath(selectedModelPath.isEmpty ? nil : selectedModelPath)
                        localConfig.saveSelectedEmbeddingModelPath(selectedEmbeddingModelPath.isEmpty ? nil : selectedEmbeddingModelPath)
                        dismiss()
                    }
                }
            }
            .onAppear {
                let savedRemote = remoteConfig.load()
                baseURL = savedRemote.baseURL
                token = savedRemote.token
                model = savedRemote.model

                runtimeProvider = runtimeConfig.loadProvider()
                let ollama = runtimeConfig.loadOllama()
                ollamaBaseURL = ollama.baseURL
                ollamaModel = ollama.model
                mlxModelName = runtimeConfig.loadMLXModelName()

                refreshModels()

                if selectedModelPath.isEmpty,
                   let selected = localConfig.loadSelectedModelPath() {
                    selectedModelPath = selected
                }
                if selectedModelPath.isEmpty {
                    selectedModelPath = models.first?.path ?? ""
                }

                if selectedEmbeddingModelPath.isEmpty,
                   let selectedEmbedding = localConfig.loadSelectedEmbeddingModelPath() {
                    selectedEmbeddingModelPath = selectedEmbedding
                }
                if selectedEmbeddingModelPath.isEmpty {
                    selectedEmbeddingModelPath = embeddingModels.first?.path ?? ""
                }
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [UTType(filenameExtension: "gguf") ?? .data],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let sourceURL = urls.first else { return }
                    let access = sourceURL.startAccessingSecurityScopedResource()
                    defer {
                        if access { sourceURL.stopAccessingSecurityScopedResource() }
                    }

                    do {
                        let docs = try localConfig.documentsDirectory()
                        switch importTarget {
                        case .chat:
                            let copied = try localConfig.importModel(from: sourceURL, into: docs)
                            selectedModelPath = copied.path
                            importMessage = "Modelo chat añadido: \(localConfig.displayName(for: copied))"
                        case .embedding:
                            let copied = try localConfig.importEmbeddingModel(from: sourceURL, into: docs)
                            selectedEmbeddingModelPath = copied.path
                            importMessage = "Modelo embeddings añadido: \(localConfig.displayName(for: copied))"
                        }
                        refreshModels()
                    } catch {
                        importMessage = "Error al importar: \(error.localizedDescription)"
                    }
                case .failure(let error):
                    importMessage = "Importación cancelada/error: \(error.localizedDescription)"
                }
            }
            .confirmationDialog(
                "Borrar modelo local",
                isPresented: Binding(
                    get: { modelToDelete != nil },
                    set: { isPresented in if !isPresented { modelToDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Borrar", role: .destructive) {
                    guard let url = modelToDelete else { return }
                    do {
                        try localConfig.deleteModel(at: url)
                        importMessage = "Modelo eliminado: \(localConfig.displayName(for: url))"
                        refreshModels()
                        selectedModelPath = models.first?.path ?? ""
                    } catch {
                        importMessage = "Error al borrar: \(error.localizedDescription)"
                    }
                    modelToDelete = nil
                }

                Button("Cancelar", role: .cancel) {
                    modelToDelete = nil
                }
            } message: {
                if let modelToDelete {
                    Text("¿Seguro que quieres borrar \(localConfig.displayName(for: modelToDelete))?")
                }
            }
            .confirmationDialog(
                "Borrar modelo de embeddings",
                isPresented: Binding(
                    get: { embeddingModelToDelete != nil },
                    set: { isPresented in if !isPresented { embeddingModelToDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Borrar", role: .destructive) {
                    guard let url = embeddingModelToDelete else { return }
                    do {
                        try localConfig.deleteEmbeddingModel(at: url)
                        importMessage = "Modelo embeddings eliminado: \(localConfig.displayName(for: url))"
                        refreshModels()
                        selectedEmbeddingModelPath = embeddingModels.first?.path ?? ""
                    } catch {
                        importMessage = "Error al borrar embeddings: \(error.localizedDescription)"
                    }
                    embeddingModelToDelete = nil
                }

                Button("Cancelar", role: .cancel) {
                    embeddingModelToDelete = nil
                }
            } message: {
                if let embeddingModelToDelete {
                    Text("¿Seguro que quieres borrar \(localConfig.displayName(for: embeddingModelToDelete))?")
                }
            }
        }
    }

    private func refreshModels() {
        do {
            let docs = try localConfig.documentsDirectory()
            try localConfig.ensureModelsDirectoryExists(in: docs)
            try localConfig.ensureEmbeddingModelsDirectoryExists(in: docs)
            models = localConfig.availableModels(in: docs)
            embeddingModels = localConfig.availableEmbeddingModels(in: docs)
        } catch {
            models = []
            embeddingModels = []
            importMessage = "No pude leer modelos: \(error.localizedDescription)"
        }
    }

    private func icon(for mode: RoutePreference) -> String {
        switch mode {
        case .auto: return "sparkles"
        case .local: return "iphone"
        case .remote: return "network"
        }
    }
}
