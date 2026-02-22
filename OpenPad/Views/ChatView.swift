import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

private enum ImportTarget {
    case chat
    case embedding
}

struct ChatView: View {
    @StateObject private var vm = ChatViewModel()
    @State private var showSettings = false
    @State private var showSidebar = true

    private let localConfig = LocalModelConfig.shared
    private let runtimeConfig = LocalRuntimeConfig.shared

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                if showSidebar {
                    SidebarMenuView()
                        .frame(width: 260)
                        .transition(.move(edge: .leading))
                }

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

                    if !vm.toolTrace.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Tool Trace")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            ForEach(vm.toolTrace, id: \.self) { line in
                                Text("• \(line)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.top, 6)
                    }

                    if vm.messages.isEmpty {
                        ContentUnavailableView("Sin mensajes aún", systemImage: "bubble.left.and.bubble.right")
                    } else {
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 0) {
                                    ForEach(vm.messages) { msg in
                                        MessageRowView(msg: msg)
                                            .padding(.vertical, 4)
                                            .id(msg.id)
                                    }
                                }
                                .padding(.horizontal)
                            }
                            .overlay(alignment: .bottomTrailing) {
                                if vm.messages.count > 6 {
                                    Button {
                                        if let last = vm.messages.last {
                                            withAnimation(.easeOut(duration: 0.2)) {
                                                proxy.scrollTo(last.id, anchor: .bottom)
                                            }
                                        }
                                    } label: {
                                        Image(systemName: "arrow.down.circle.fill")
                                            .font(.system(size: 28))
                                            .foregroundColor(.accentColor)
                                            .padding(10)
                                            .background(.ultraThinMaterial)
                                            .clipShape(Circle())
                                    }
                                    .padding(14)
                                }
                            }
                            .defaultScrollAnchor(.bottom)
                            .onAppear {
                                if let last = vm.messages.last {
                                    proxy.scrollTo(last.id, anchor: .bottom)
                                }
                            }
                            .onChange(of: vm.messages.count) { _, _ in
                                if let last = vm.messages.last {
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        proxy.scrollTo(last.id, anchor: .bottom)
                                    }
                                }
                            }
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
            }
            .animation(.easeInOut(duration: 0.2), value: showSidebar)
            .navigationTitle("OpenPad")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showSidebar.toggle()
                    } label: {
                        Image(systemName: "line.3.horizontal")
                    }
                    .accessibilityLabel(showSidebar ? "Ocultar menú" : "Mostrar menú")
                }

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

private struct MessageRowView: View {
    let msg: ChatMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(msg.role.uppercased()).font(.caption).foregroundColor(.secondary)
            Text(msg.text)

            if msg.role == "assistant" {
                let urls = detectURLs(in: msg.text)
                if !urls.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(urls, id: \.absoluteString) { url in
                            HStack {
                                Link(destination: url) {
                                    Label("Abrir enlace", systemImage: "link")
                                        .font(.caption)
                                }
                                Spacer()
                                Button {
                                    copyToClipboard(url.absoluteString)
                                } label: {
                                    Label("Copiar", systemImage: "doc.on.doc")
                                        .font(.caption)
                                }
                            }
                            .padding(8)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
        }
    }

    private func detectURLs(in text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, options: [], range: range).compactMap { $0.url }
    }

    private func copyToClipboard(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
    }
}

private struct SidebarMenuView: View {
    private struct Item: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
    }

    private let sections: [(String, [Item])] = [
        ("Chat", [Item(icon: "message", title: "Chat")]),
        ("Control", [
            Item(icon: "chart.bar", title: "Overview"),
            Item(icon: "link", title: "Channels"),
            Item(icon: "dot.radiowaves.left.and.right", title: "Instances"),
            Item(icon: "doc.text", title: "Sessions"),
            Item(icon: "chart.xyaxis.line", title: "Usage"),
            Item(icon: "clock.arrow.circlepath", title: "Cron Jobs")
        ]),
        ("Agent", [
            Item(icon: "folder", title: "Agents"),
            Item(icon: "bolt", title: "Skills"),
            Item(icon: "desktopcomputer", title: "Nodes")
        ]),
        ("Settings", [])
    ]

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.05, green: 0.07, blue: 0.14), Color(red: 0.02, green: 0.04, blue: 0.09)], startPoint: .top, endPoint: .bottom)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 10) {
                        Text("🐞")
                            .font(.title2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("OPENCLAW")
                                .font(.headline)
                                .foregroundColor(.white)
                            Text("GATEWAY DASHBOARD")
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.7))
                        }
                    }
                    .padding(.bottom, 8)

                    ForEach(sections, id: \.0) { section in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(section.0)
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.6))
                                Spacer()
                                Text("-")
                                    .foregroundColor(.white.opacity(0.3))
                            }

                            ForEach(section.1) { item in
                                HStack(spacing: 12) {
                                    Image(systemName: item.icon)
                                        .frame(width: 18)
                                        .foregroundColor(.white.opacity(0.75))
                                    Text(item.title)
                                        .foregroundColor(.white.opacity(0.9))
                                    Spacer()
                                }
                                .font(.subheadline)
                                .padding(.vertical, 10)
                                .padding(.horizontal, 10)
                                .background(item.title == "Chat" ? Color.red.opacity(0.22) : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }
                }
                .padding(14)
            }
        }
    }
}

private struct MemoryManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [String] = []
    @State private var status = ""

    private let tools = OpenClawLiteTools()

    var body: some View {
        NavigationStack {
            List {
                if rows.isEmpty {
                    Text("Sin memoria guardada")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(rows, id: \.self) { row in
                        Text(row)
                            .font(.caption)
                    }
                }

                if !status.isEmpty {
                    Text(status)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Memoria")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu("Acciones") {
                        Button("Recargar") {
                            rows = tools.listAllMemories()
                            status = "Memoria recargada"
                        }
                        Button("Borrar todo", role: .destructive) {
                            do {
                                try tools.clearAllMemoriesForUI()
                                rows = []
                                status = "Memoria borrada"
                            } catch {
                                status = "Error: \(error.localizedDescription)"
                            }
                        }
                    }
                }
            }
            .onAppear {
                rows = tools.listAllMemories()
            }
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
    @State private var mlxPresetModel = "mlx-community/Qwen2.5-1.5B-Instruct-4bit"
    @State private var isDownloadingMLXModel = false
    @State private var mlxDownloadProgress: Double = 0

    @State private var importMessage = ""
    @State private var modelToDelete: URL?
    @State private var embeddingModelToDelete: URL?
    @State private var allowlistHostsText = ""
    @State private var braveApiKey = ""
    @State private var showMemoryManager = false

    private let remoteConfig = RemoteModelConfig.shared
    private let localConfig = LocalModelConfig.shared
    private let runtimeConfig = LocalRuntimeConfig.shared
    private let mlxService = MLXLocalModelService()
    private let openClawLiteConfig = OpenClawLiteConfig.shared

    private let mlxPresetModels = [
        "mlx-community/Qwen2.5-1.5B-Instruct-4bit",
        "mlx-community/Qwen2.5-3B-Instruct-4bit",
        "mlx-community/Llama-3.2-3B-Instruct-4bit",
        "mlx-community/Phi-3.5-mini-instruct-4bit"
    ]

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
                            Picker("Modelos sugeridos", selection: $mlxPresetModel) {
                                ForEach(mlxPresetModels, id: \.self) { modelId in
                                    Text(modelId).tag(modelId)
                                }
                            }

                            Button("Usar modelo sugerido") {
                                mlxModelName = mlxPresetModel
                                importMessage = "Modelo MLX seleccionado: \(mlxPresetModel)"
                            }

                            TextField("Modelo MLX (manual)", text: $mlxModelName)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()

                            Button {
                                Task {
                                    await downloadSelectedMLXModel()
                                }
                            } label: {
                                Label(isDownloadingMLXModel ? "Descargando..." : "Descargar modelo MLX seleccionado", systemImage: "arrow.down.circle")
                            }
                            .disabled(isDownloadingMLXModel || mlxModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                            Text("Tamaño aprox: \(mlxEstimatedSizeText(for: mlxModelName))")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            if isDownloadingMLXModel {
                                ProgressView(value: mlxDownloadProgress, total: 1.0)
                                    .progressViewStyle(.linear)
                                Text("Progreso estimado: \(Int(mlxDownloadProgress * 100))%")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }

                            Text("Puedes elegir uno sugerido o escribir un ID manual si ya sabes cuál usar.")
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

                Section("OpenClaw Lite") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Hosts permitidos para http_get (uno por línea)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextEditor(text: $allowlistHostsText)
                            .frame(minHeight: 90)
                            .font(.caption)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
                    }

                    SecureField("Brave API Key", text: $braveApiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button("Abrir gestor de memoria") {
                        showMemoryManager = true
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
                        openClawLiteConfig.saveAllowlistHosts(allowlistHostsText)
                        openClawLiteConfig.saveBraveApiKey(braveApiKey)
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
                mlxPresetModel = mlxPresetModels.contains(mlxModelName) ? mlxModelName : mlxPresetModels[0]
                allowlistHostsText = openClawLiteConfig.allowlistHostsText()
                braveApiKey = openClawLiteConfig.loadBraveApiKey()

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
            .sheet(isPresented: $showMemoryManager) {
                MemoryManagerView()
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

    private func downloadSelectedMLXModel() async {
        let cleanId = mlxModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanId.isEmpty else {
            importMessage = "Escribe un ID de modelo MLX válido."
            return
        }

        isDownloadingMLXModel = true
        mlxDownloadProgress = 0.03

        let progressTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 450_000_000)
                await MainActor.run {
                    if isDownloadingMLXModel {
                        mlxDownloadProgress = min(0.92, mlxDownloadProgress + 0.04)
                    }
                }
            }
        }

        defer {
            progressTask.cancel()
            isDownloadingMLXModel = false
        }

        do {
            runtimeConfig.saveMLXModelName(cleanId)
            try await mlxService.prewarmModel(modelId: cleanId)
            mlxDownloadProgress = 1.0
            importMessage = "Modelo MLX descargado/listo: \(cleanId)"
        } catch {
            importMessage = "No pude descargar el modelo MLX: \(error.localizedDescription)"
            mlxDownloadProgress = 0
        }
    }

    private func mlxEstimatedSizeText(for modelId: String) -> String {
        let knownSizesMB: [String: Int] = [
            "mlx-community/Qwen2.5-1.5B-Instruct-4bit": 950,
            "mlx-community/Qwen2.5-3B-Instruct-4bit": 1800,
            "mlx-community/Llama-3.2-3B-Instruct-4bit": 1900,
            "mlx-community/Phi-3.5-mini-instruct-4bit": 2200
        ]
        let clean = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        if let mb = knownSizesMB[clean] {
            return "~\(mb) MB"
        }
        return "desconocido"
    }

    private func icon(for mode: RoutePreference) -> String {
        switch mode {
        case .auto: return "sparkles"
        case .local: return "iphone"
        case .remote: return "network"
        }
    }
}
