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
    @State private var showToolTrace = false
    @StateObject private var cronRunner = OpenClawLiteCronRunner.shared

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

                    if !cronRunner.lastRunSummary.isEmpty {
                        Text(cronRunner.lastRunSummary)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                            .padding(.top, 2)
                    }

                    if !vm.toolTrace.isEmpty {
                        DisclosureGroup(isExpanded: $showToolTrace) {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(vm.toolTrace, id: \.self) { line in
                                    Text("• \(line)")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(.top, 4)
                        } label: {
                            Label("Tool Trace", systemImage: "wrench.and.screwdriver")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
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
                                    if vm.isLoading {
                                        TypingIndicatorRow()
                                            .id("typing-indicator")
                                    }
                                }
                                .padding(.horizontal)
                            }
                            .overlay(alignment: .bottomTrailing) {
                                if vm.messages.count > 6 {
                                    Button {
                                        if let last = vm.messages.last {
                                            withAnimation(.easeOut(duration: 0.2)) {
                                                if vm.isLoading {
                                                    proxy.scrollTo("typing-indicator", anchor: .bottom)
                                                } else {
                                                    proxy.scrollTo(last.id, anchor: .bottom)
                                                }
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
                                    if vm.isLoading {
                                        proxy.scrollTo("typing-indicator", anchor: .bottom)
                                    } else {
                                        proxy.scrollTo(last.id, anchor: .bottom)
                                    }
                                }
                            }
                             .onChange(of: vm.messages.count) { _ in
                                if let last = vm.messages.last {
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        if vm.isLoading {
                                        proxy.scrollTo("typing-indicator", anchor: .bottom)
                                    } else {
                                        proxy.scrollTo(last.id, anchor: .bottom)
                                    }
                                    }
                                }
                            }
                        }
                        .frame(maxHeight: .infinity)
                    }

                    HStack(spacing: 8) {
                        TextField("Escribe un prompt...", text: $vm.inputText, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(1...4)

                        Button {
                            vm.send()
                        } label: {
                            Image(systemName: vm.isLoading ? "hourglass" : "paperplane.fill")
                                .font(.headline)
                                .frame(width: 36, height: 36)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(vm.isLoading || vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .padding(.bottom, 10)
                    .background(.ultraThinMaterial)
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
        .onAppear {
            cronRunner.start()
        }
        .onDisappear {
            cronRunner.stop()
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

    private var isUser: Bool { msg.role.lowercased() == "user" }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if !isUser { avatar("sparkles", color: .purple) }
            if isUser { Spacer(minLength: 24) }

            VStack(alignment: .leading, spacing: 6) {
                Text(msg.role.uppercased())
                    .font(.caption2)
                    .foregroundColor(isUser ? .white.opacity(0.85) : .secondary)

                Text(msg.text)
                    .foregroundColor(isUser ? .white : .primary)
                    .textSelection(.enabled)

                Text(Self.timeFmt.string(from: msg.date))
                    .font(.caption2)
                    .foregroundColor(isUser ? .white.opacity(0.75) : .secondary.opacity(0.8))

                if !isUser {
                    let urls = detectURLs(in: msg.text)
                    if !urls.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(urls, id: \.absoluteString) { url in
                                HStack {
                                    Link(destination: url) {
                                        Label("Abrir", systemImage: "link")
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
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(isUser ? Color.accentColor : Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14))

            if !isUser { Spacer(minLength: 24) }
            if isUser { avatar("person.fill", color: .blue) }
        }
    }

    private func avatar(_ systemName: String, color: Color) -> some View {
        Image(systemName: systemName)
            .font(.caption)
            .foregroundColor(.white)
            .frame(width: 24, height: 24)
            .background(color)
            .clipShape(Circle())
    }

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

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

private struct TypingIndicatorRow: View {
    @State private var phase = 0

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Image(systemName: "sparkles")
                .font(.caption)
                .foregroundColor(.white)
                .frame(width: 24, height: 24)
                .background(Color.purple)
                .clipShape(Circle())

            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Color.secondary.opacity(phase == i ? 0.9 : 0.35))
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .task {
                while true {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    phase = (phase + 1) % 3
                }
            }

            Spacer(minLength: 24)
        }
        .padding(.vertical, 4)
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

private struct SkillsManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [LocalSkill] = OpenClawLiteAutomationStore.shared.loadSkills()
    @State private var draftName = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Nuevo skill") {
                    TextField("Nombre", text: $draftName)
                    Button("Agregar") {
                        let n = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !n.isEmpty else { return }
                        rows.append(LocalSkill(name: n, content: "# \(n)\n"))
                        draftName = ""
                        try? OpenClawLiteAutomationStore.shared.saveSkills(rows)
                    }
                }
                Section("Skills") {
                    ForEach($rows) { $skill in
                        VStack(alignment: .leading) {
                            TextField("Nombre", text: $skill.name)
                            TextEditor(text: $skill.content).frame(minHeight: 80)
                        }
                        .onChange(of: skill.content) { _ in try? OpenClawLiteAutomationStore.shared.saveSkills(rows) }
                    }
                    .onDelete { idx in
                        rows.remove(atOffsets: idx)
                        try? OpenClawLiteAutomationStore.shared.saveSkills(rows)
                    }
                }
            }
            .navigationTitle("Skills")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { dismiss() } } }
        }
    }
}

private struct CronsManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [LocalCron] = OpenClawLiteAutomationStore.shared.loadCrons()
    @State private var logs: [LocalCronLog] = OpenClawLiteAutomationStore.shared.loadCronLogs().reversed()

    private let cronRunner = OpenClawLiteCronRunner.shared

    var body: some View {
        NavigationStack {
            List {
                Button("Agregar cron") {
                    rows.append(LocalCron(title: "Nuevo cron", schedule: "0 9 * * *", command: "resumen diario"))
                    saveCrons()
                }

                Section("Crons") {
                    ForEach($rows) { $cron in
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Título", text: $cron.title)
                            TextField("Schedule", text: $cron.schedule)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            TextField("Comando", text: $cron.command)
                            Toggle("Activo", isOn: $cron.enabled)

                            let validation = cronRunner.validate(schedule: cron.schedule)
                            Text(validation.ok ? "✅ \(validation.message)" : "⚠️ \(validation.message)")
                                .font(.caption2)
                                .foregroundColor(validation.ok ? .green : .orange)

                            HStack {
                                Button("Run now") {
                                    cronRunner.runNow(cron: cron)
                                    logs = OpenClawLiteAutomationStore.shared.loadCronLogs().reversed()
                                }
                                .buttonStyle(.bordered)

                                Spacer()

                                Button("Guardar") {
                                    saveCrons()
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                    }
                    .onDelete { idx in
                        rows.remove(atOffsets: idx)
                        saveCrons()
                    }
                }

                Section("Historial") {
                    if logs.isEmpty {
                        Text("Sin ejecuciones todavía")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(logs) { log in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(log.title).font(.subheadline)
                                Text("\(dateText(log.executedAt)) • \(log.source) • \(log.note)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text(log.command).font(.caption)
                            }
                        }
                    }

                    Button("Limpiar historial", role: .destructive) {
                        OpenClawLiteAutomationStore.shared.clearCronLogs()
                        logs = []
                    }
                }
            }
            .navigationTitle("Crons")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { dismiss() } } }
        }
    }

    private func saveCrons() {
        try? OpenClawLiteAutomationStore.shared.saveCrons(rows)
    }

    private func dateText(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: d)
    }
}

private struct HeartbeatManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = OpenClawLiteAutomationStore.shared.loadHeartbeat()

    var body: some View {
        NavigationStack {
            VStack {
                TextEditor(text: $text)
                    .padding(8)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2)))
                    .padding()
            }
            .navigationTitle("Heartbeat")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") {
                        try? OpenClawLiteAutomationStore.shared.saveHeartbeat(text)
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct FilesManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var files: [String] = OpenClawLiteAutomationStore.shared.listWorkspaceFiles()
    @State private var selected = ""
    @State private var content = ""
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                HStack {
                    TextField("nuevo-archivo.txt", text: $newName)
                    Button("Crear") {
                        let n = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !n.isEmpty else { return }
                        try? OpenClawLiteAutomationStore.shared.saveWorkspaceFile(name: n, content: "")
                        files = OpenClawLiteAutomationStore.shared.listWorkspaceFiles()
                        selected = n
                        content = ""
                        newName = ""
                    }
                }
                .padding(.horizontal)

                Picker("Archivo", selection: $selected) {
                    Text("-- seleccionar --").tag("")
                    ForEach(files, id: \.self) { f in Text(f).tag(f) }
                }
                .padding(.horizontal)
                .onChange(of: selected) { v in
                    content = v.isEmpty ? "" : OpenClawLiteAutomationStore.shared.readWorkspaceFile(v)
                }

                TextEditor(text: $content)
                    .padding(8)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2)))
                    .padding(.horizontal)

                Button("Guardar archivo") {
                    guard !selected.isEmpty else { return }
                    try? OpenClawLiteAutomationStore.shared.saveWorkspaceFile(name: selected, content: content)
                    files = OpenClawLiteAutomationStore.shared.listWorkspaceFiles()
                }
                .buttonStyle(.borderedProminent)
            }
            .navigationTitle("Archivos")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { dismiss() } } }
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
    @State private var mlxDownloadedModels: [String] = []

    @State private var importMessage = ""
    @State private var modelToDelete: URL?
    @State private var embeddingModelToDelete: URL?
    @State private var allowlistHostsText = ""
    @State private var braveApiKey = ""
    @State private var showMemoryManager = false
    @State private var internetOpenAccess = true
    @State private var showSkillsManager = false
    @State private var showCronsManager = false
    @State private var showHeartbeatManager = false
    @State private var showFilesManager = false

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

                            if isCurrentMLXModelDownloaded() {
                                HStack {
                                    Label("Modelo ya descargado", systemImage: "checkmark.seal.fill")
                                        .font(.caption)
                                        .foregroundColor(.green)
                                    Spacer()
                                    Button(role: .destructive) {
                                        removeCurrentMLXModelDownloadMark()
                                    } label: {
                                        Label("Borrar", systemImage: "trash")
                                    }
                                }
                            } else {
                                Button {
                                    Task {
                                        await downloadSelectedMLXModel()
                                    }
                                } label: {
                                    Label(isDownloadingMLXModel ? "Descargando..." : "Descargar modelo MLX seleccionado", systemImage: "arrow.down.circle")
                                }
                                .disabled(isDownloadingMLXModel || mlxModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }

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

                Section {
                    Toggle(isOn: $internetOpenAccess) {
                        Label("Acceso abierto a internet", systemImage: "globe")
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Hosts permitidos para http_get (uno por línea)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextEditor(text: $allowlistHostsText)
                            .frame(minHeight: 90)
                            .font(.caption)
                            .opacity(internetOpenAccess ? 0.45 : 1)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
                            .disabled(internetOpenAccess)
                    }

                    if internetOpenAccess {
                        Text("Modo abierto: puede visitar cualquier dominio.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    SecureField("Brave API Key", text: $braveApiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button {
                        showMemoryManager = true
                    } label: {
                        Label("Abrir gestor de memoria", systemImage: "brain.head.profile")
                    }

                    HStack {
                        Button("Skills") { showSkillsManager = true }
                        Spacer()
                        Button("Crons") { showCronsManager = true }
                        Spacer()
                        Button("Heartbeat") { showHeartbeatManager = true }
                        Spacer()
                        Button("Archivos") { showFilesManager = true }
                    }
                    .font(.caption)
                } header: {
                    Text("OpenClaw Lite")
                } footer: {
                    Text("Puedes cambiar entre modo abierto y modo restringido por hosts permitidos.")
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
                        openClawLiteConfig.setInternetOpenAccessEnabled(internetOpenAccess)
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
                internetOpenAccess = openClawLiteConfig.isInternetOpenAccessEnabled()
                mlxDownloadedModels = openClawLiteConfig.loadDownloadedMLXModels()

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
            .sheet(isPresented: $showSkillsManager) {
                SkillsManagerView()
            }
            .sheet(isPresented: $showCronsManager) {
                CronsManagerView()
            }
            .sheet(isPresented: $showHeartbeatManager) {
                HeartbeatManagerView()
            }
            .sheet(isPresented: $showFilesManager) {
                FilesManagerView()
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
            openClawLiteConfig.markMLXModelDownloaded(cleanId)
            mlxDownloadedModels = openClawLiteConfig.loadDownloadedMLXModels()
        } catch {
            importMessage = "No pude descargar el modelo MLX: \(error.localizedDescription)"
            mlxDownloadProgress = 0
        }
    }

    private func isCurrentMLXModelDownloaded() -> Bool {
        let clean = mlxModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !clean.isEmpty && mlxDownloadedModels.contains(clean)
    }

    private func removeCurrentMLXModelDownloadMark() {
        let clean = mlxModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        openClawLiteConfig.unmarkMLXModelDownloaded(clean)
        mlxDownloadedModels = openClawLiteConfig.loadDownloadedMLXModels()
        importMessage = "Modelo marcado como no descargado: \(clean)"
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
