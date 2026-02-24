import SwiftUI
import UniformTypeIdentifiers
import PhotosUI
import AVFoundation
#if canImport(UIKit)
import UIKit
#endif

private enum ImportTarget {
    case chat
    case embedding
}

private enum SidebarPanel: String, CaseIterable, Identifiable {
    case chat = "Chat"
    case overview = "Overview"
    case channels = "Channels"
    case instances = "Instances"
    case sessions = "Sessions"
    case usage = "Usage"
    case cronJobs = "Cron Jobs"
    case agents = "Agents"
    case skills = "Skills"
    case nodes = "Nodes"

    var id: String { rawValue }
}

struct ChatView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var vm = ChatViewModel()
    @State private var showSettings = false
    @State private var showSidebar = false
    @State private var activePanel: SidebarPanel = .chat
    @State private var showToolTrace = false
    @StateObject private var cronRunner = OpenClawLiteCronRunner.shared
    @State private var showAttachmentOptions = false
    @State private var showAttachmentFileImporter = false
    @State private var showPhotoPicker = false
    @State private var showCameraPicker = false
    @State private var showAudioRecorder = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var attachmentStatus = ""

    private let localConfig = LocalModelConfig.shared
    private let runtimeConfig = LocalRuntimeConfig.shared
    private let openClawLiteConfig = OpenClawLiteConfig.shared

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                if showSidebar {
                    SidebarMenuView(vm: vm, selection: $activePanel)
                        .frame(width: 260)
                        .transition(.move(edge: .leading))
                }

                Group {
                    if activePanel == .chat {
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

                            if !attachmentStatus.isEmpty {
                                Text(attachmentStatus)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal)
                                    .padding(.top, 2)
                            }

                            if !vm.lastModelUsedBadge.isEmpty {
                                Text("Model used: \(vm.lastModelUsedBadge)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal)
                                    .padding(.top, 2)
                            }

                            if !vm.activeDocumentBadge.isEmpty {
                                Text("Active document: \(vm.activeDocumentBadge)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal)
                                    .padding(.top, 2)
                            }

                            if vm.backgroundPaused || !vm.backgroundStatus.isEmpty {
                                Text(vm.backgroundStatus.isEmpty ? "Background mode active." : vm.backgroundStatus)
                                    .font(.caption2)
                                    .foregroundColor(.orange)
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
                                ContentUnavailableView("No messages yet", systemImage: "bubble.left.and.bubble.right")
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
                                    .onChange(of: vm.messages.count) { _, _ in
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
                                Button {
                                    showAttachmentOptions = true
                                } label: {
                                    Image(systemName: "paperclip")
                                        .font(.headline)
                                        .frame(width: 36, height: 36)
                                }
                                .buttonStyle(.bordered)

                                ComposerTextView(text: $vm.inputText, isEnabled: !vm.isLoading) {
                                    vm.send()
                                }
                                .frame(minHeight: 38, maxHeight: 120)

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
                    } else {
                        SidebarContentView(panel: activePanel, vm: vm)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color(.systemBackground))
                    }
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
                    .accessibilityLabel(showSidebar ? "Hide menu" : "Show menu")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                    }
                    .accessibilityLabel("Settings")
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(vm: vm)
        }
        .confirmationDialog("Attach", isPresented: $showAttachmentOptions, titleVisibility: .visible) {
            Button("File") { showAttachmentFileImporter = true }
            Button("Photo from library") { showPhotoPicker = true }
            Button("Take photo") { showCameraPicker = true }
            Button("Record audio") { showAudioRecorder = true }
            Button("Cancel", role: .cancel) {}
        }
        .fileImporter(isPresented: $showAttachmentFileImporter, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            handleFileImport(result)
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotoItem, matching: .images)
        .onChange(of: selectedPhotoItem) { _, item in
            guard let item else { return }
            Task { await handlePhotoSelection(item) }
        }
        .sheet(isPresented: $showCameraPicker) {
            CameraPicker { image in
                handleCapturedImage(image)
            }
        }
        .sheet(isPresented: $showAudioRecorder) {
            AudioRecorderSheet { url in
                handleRecordedAudio(url)
            }
        }
        .onAppear {
            if openClawLiteConfig.isAutomationLoopEnabled() {
                cronRunner.start()
            } else {
                cronRunner.stop()
            }
        }
        .onDisappear {
            cronRunner.stop()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                vm.appDidEnterBackground()
            case .active:
                vm.appWillEnterForeground()
            default:
                break
            }
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let sourceURL = urls.first else { return }
            let access = sourceURL.startAccessingSecurityScopedResource()
            defer { if access { sourceURL.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: sourceURL)
                let saved = try saveAttachment(data: data, preferredName: sourceURL.lastPathComponent)
                attachmentStatus = "Adjunto: \(saved.lastPathComponent)"
                vm.inputText += " [adjunto: \(saved.lastPathComponent)]"
            } catch {
                attachmentStatus = "Error attaching file: \(error.localizedDescription)"
            }
        case .failure(let error):
            attachmentStatus = "Attach cancelled/error: \(error.localizedDescription)"
        }
    }

    private func handlePhotoSelection(_ item: PhotosPickerItem) async {
        do {
            if let data = try await item.loadTransferable(type: Data.self) {
                let saved = try saveAttachment(data: data, preferredName: "foto_\(Int(Date().timeIntervalSince1970)).jpg")
                attachmentStatus = "Foto adjunta: \(saved.lastPathComponent)"
                vm.inputText += " [foto: \(saved.lastPathComponent)]"
            }
        } catch {
            attachmentStatus = "Error attaching photo: \(error.localizedDescription)"
        }
    }

    private func handleCapturedImage(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.9) else { return }
        do {
            let saved = try saveAttachment(data: data, preferredName: "camera_\(Int(Date().timeIntervalSince1970)).jpg")
            attachmentStatus = "Photo captured: \(saved.lastPathComponent)"
            vm.inputText += " [foto-camara: \(saved.lastPathComponent)]"
        } catch {
            attachmentStatus = "Error saving photo: \(error.localizedDescription)"
        }
    }

    private func handleRecordedAudio(_ sourceURL: URL) {
        do {
            let data = try Data(contentsOf: sourceURL)
            let saved = try saveAttachment(data: data, preferredName: "audio_\(Int(Date().timeIntervalSince1970)).m4a")
            attachmentStatus = "Audio attached: \(saved.lastPathComponent)"
            vm.inputText += " [audio: \(saved.lastPathComponent)]"
        } catch {
            attachmentStatus = "Error attaching audio: \(error.localizedDescription)"
        }
    }

    private func saveAttachment(data: Data, preferredName: String) throws -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("OpenClawFiles/Attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safeName = preferredName.replacingOccurrences(of: "/", with: "_")
        let url = dir.appendingPathComponent(safeName)
        try data.write(to: url, options: .atomic)
        return url
    }

    private func selectedModelBannerText() -> String {
        let provider = runtimeConfig.loadProvider()
        switch provider {
        case .llamaCpp:
            if let selectedPath = localConfig.loadSelectedModelPath(), !selectedPath.isEmpty {
                return "Private/offline • llama.cpp • \(URL(fileURLWithPath: selectedPath).deletingPathExtension().lastPathComponent)"
            }
            return "Private/offline • llama.cpp • no model selected"
        case .ollama:
            let cfg = runtimeConfig.loadOllama()
            return "Local (Ollama) • \(cfg.model)"
        case .mlx:
            let model = runtimeConfig.loadMLXModelName()
            let compat = model.lowercased().contains("thinking") || model.lowercased().contains("lfm2.5")
            return "Private/offline • MLX • \(model)\(compat ? " • compat" : "")"
        }
    }
}

#if canImport(UIKit)
private struct ComposerTextView: UIViewRepresentable {
    @Binding var text: String
    var isEnabled: Bool = true
    var onSend: () -> Void

    func makeUIView(context: Context) -> ReturnAwareTextView {
        let tv = ReturnAwareTextView()
        tv.delegate = context.coordinator
        tv.font = UIFont.preferredFont(forTextStyle: .body)
        tv.backgroundColor = .clear
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)
        tv.layer.cornerRadius = 10
        tv.layer.borderWidth = 1
        tv.layer.borderColor = UIColor.separator.cgColor
        tv.isScrollEnabled = true
        tv.returnHandler = { shiftPressed in
            if shiftPressed {
                tv.insertText("\n")
            } else {
                onSend()
            }
        }
        return tv
    }

    func updateUIView(_ uiView: ReturnAwareTextView, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }
        uiView.isEditable = isEnabled
        uiView.alpha = isEnabled ? 1 : 0.6
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func textViewDidChange(_ textView: UITextView) {
            text = textView.text
        }
    }
}

private final class ReturnAwareTextView: UITextView {
    var returnHandler: ((Bool) -> Void)?

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false

        for press in presses {
            guard let key = press.key else { continue }
            if key.keyCode == .keyboardReturnOrEnter {
                let shiftPressed = key.modifierFlags.contains(.shift)
                returnHandler?(shiftPressed)
                handled = true
            }
        }

        if handled { return }
        super.pressesBegan(presses, with: event)
    }
}
#endif

private struct MessageRowView: View {
    let msg: ChatMessage

    private var isUser: Bool { msg.role.lowercased() == "user" }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if !isUser { avatar("sparkles", color: .purple) }
            if isUser { Spacer(minLength: 24) }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(msg.role.uppercased())
                        .font(.caption2)
                        .foregroundColor(isUser ? .white.opacity(0.85) : .secondary)

                    if let badge = msg.modelBadge, !badge.isEmpty {
                        Text(badge)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(isUser ? Color.white.opacity(0.2) : Color.blue.opacity(0.12))
                            .foregroundColor(isUser ? .white : .blue)
                            .clipShape(Capsule())
                    }
                }

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

private struct AudioRecorderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var recorder: AVAudioRecorder?
    @State private var isRecording = false
    @State private var status = "Ready"

    let onSaved: (URL) -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text(status)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button(isRecording ? "Stop recording" : "Start recording") {
                    if isRecording {
                        stopRecording(save: true)
                    } else {
                        Task { await startRecording() }
                    }
                }
                .buttonStyle(.borderedProminent)

                Button("Cancel", role: .cancel) {
                    stopRecording(save: false)
                    dismiss()
                }
            }
            .padding()
            .navigationTitle("Record audio")
        }
    }

    private func startRecording() async {
        let granted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            AVAudioSession.sharedInstance().requestRecordPermission { ok in
                cont.resume(returning: ok)
            }
        }
        guard granted else {
            status = "Microphone permission denied"
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default)
            try session.setActive(true)

            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("rec_\(UUID().uuidString).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
            ]
            let rec = try AVAudioRecorder(url: tmp, settings: settings)
            rec.prepareToRecord()
            rec.record()
            recorder = rec
            isRecording = true
            status = "Recording..."
        } catch {
            status = "Recorder error: \(error.localizedDescription)"
        }
    }

    private func stopRecording(save: Bool) {
        guard let rec = recorder else { return }
        rec.stop()
        isRecording = false
        let url = rec.url
        recorder = nil

        if save {
            onSaved(url)
            dismiss()
        }
    }
}

private struct CameraPicker: UIViewControllerRepresentable {
    var onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: CameraPicker
        init(parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.onCapture(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

private struct SidebarMenuView: View {
    @ObservedObject var vm: ChatViewModel
    @Binding var selection: SidebarPanel

    private struct Item: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let panel: SidebarPanel
    }

    private let sections: [(String, [Item])] = [
        ("Control", [
            Item(icon: "chart.bar", title: "Overview", panel: .overview),
            Item(icon: "link", title: "Channels", panel: .channels),
            Item(icon: "dot.radiowaves.left.and.right", title: "Instances", panel: .instances),
            Item(icon: "doc.text", title: "Sessions", panel: .sessions),
            Item(icon: "chart.xyaxis.line", title: "Usage", panel: .usage),
            Item(icon: "clock.arrow.circlepath", title: "Cron Jobs", panel: .cronJobs)
        ]),
        ("Agent", [
            Item(icon: "folder", title: "Agents", panel: .agents),
            Item(icon: "bolt", title: "Skills", panel: .skills),
            Item(icon: "desktopcomputer", title: "Nodes", panel: .nodes)
        ])
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

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Chats")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.6))
                            Spacer()
                            Button {
                                selection = .chat
                                vm.createNewChat()
                            } label: {
                                Image(systemName: "plus")
                                    .foregroundColor(.white.opacity(0.8))
                            }
                        }

                        ForEach(vm.chatSessions.prefix(12)) { chat in
                            Button {
                                selection = .chat
                                vm.selectChat(sessionId: chat.id)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "bubble.left")
                                        .frame(width: 16)
                                        .foregroundColor(.white.opacity(0.75))
                                    Text((chat.pinned ? "📌 " : "") + (chat.title.isEmpty ? "Nuevo chat" : chat.title))
                                        .lineLimit(1)
                                        .foregroundColor(.white.opacity(0.92))
                                    Spacer()
                                }
                                .font(.subheadline)
                                .padding(.vertical, 8)
                                .padding(.horizontal, 10)
                                .background(vm.activeSessionId == chat.id ? Color.red.opacity(0.22) : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }

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
                                Button {
                                    selection = item.panel
                                } label: {
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
                                    .background(selection == item.panel ? Color.white.opacity(0.14) : Color.clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                            }
                        }
                    }
                }
                .padding(14)
            }
        }
    }
}

private struct SidebarContentView: View {
    let panel: SidebarPanel
    @ObservedObject var vm: ChatViewModel
    @State private var renameTarget: ChatSessionSummary?
    @State private var renameText: String = ""
    @State private var sessionSearch = ""
    @State private var includeArchived = false
    @State private var exportPreview = ""
    @State private var showExport = false

    var body: some View {
        NavigationStack {
            List {
                switch panel {
                case .overview:
                    Section("Status") {
                        Label("Sesiones: \(vm.chatSessions.count)", systemImage: "bubble.left.and.bubble.right")
                        Label("Messages in active session: \(vm.messages.count)", systemImage: "text.bubble")
                        Label("Last route: \(vm.lastRoute)", systemImage: "arrow.triangle.branch")
                        Label("Reason: \(vm.lastReason)", systemImage: "info.circle")
                    }

                    Section("Salud") {
                        if let health = vm.healthChecks.first {
                            Text(health.message)
                                .foregroundColor(health.level == "ok" ? .green : .orange)
                        } else {
                            Text("No data yet")
                                .foregroundColor(.secondary)
                        }
                    }

                case .channels:
                    Section("Channels") {
                        Text("Channel integrations (WhatsApp/Telegram/etc) coming soon.")
                            .foregroundColor(.secondary)
                    }

                case .instances:
                    Section("Instances") {
                        Text("Active local runtime: \(LocalRuntimeConfig.shared.loadProvider().title)")
                        Text("Perfil: \(LocalRuntimeConfig.shared.loadRunProfile().title)")
                    }

                case .sessions:
                    Section("Sesiones savedas") {
                        if vm.chatSessions.isEmpty {
                            Text("No hay sesiones")
                                .foregroundColor(.secondary)
                        } else {
                            ForEach(vm.chatSessions) { c in
                                Button {
                                    vm.selectChat(sessionId: c.id)
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(c.title)
                                                .font(.subheadline)
                                            Text(dateText(c.updatedAt))
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                        Spacer()
                                        if vm.activeSessionId == c.id {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundColor(.green)
                                        }
                                    }
                                }
                            }
                        }

                        Button {
                            vm.createNewChat()
                        } label: {
                            Label("Nuevo chat", systemImage: "plus.circle")
                        }
                    }

                case .usage:
                    Section("Metrics") {
                        Label("Last latency: \(vm.lastLatencyMs) ms", systemImage: "speedometer")
                        Label("Successes: \(vm.successCount)", systemImage: "checkmark.circle")
                        Label("Errores: \(vm.errorCount)", systemImage: "xmark.circle")
                    }

                    Section("Last error") {
                        Text(vm.lastErrorText.isEmpty ? "Sin errores recientes" : vm.lastErrorText)
                            .foregroundColor(vm.lastErrorText.isEmpty ? .secondary : .orange)
                    }

                case .cronJobs:
                    Section("Cron Jobs") {
                        Text("Configura jobs desde Settings > Crons")
                        Text(OpenClawLiteCronRunner.shared.lastRunSummary.isEmpty ? "Sin ejecuciones recientes" : OpenClawLiteCronRunner.shared.lastRunSummary)
                            .foregroundColor(.secondary)
                    }

                case .agents:
                    Section("Agents") {
                        Text("Subagentes locales (roadmap)")
                            .foregroundColor(.secondary)
                    }

                case .skills:
                    Section("Skills") {
                        Text("Gestiona skills desde Settings > Skills")
                            .foregroundColor(.secondary)
                    }

                case .nodes:
                    Section("Nodes") {
                        Text("Node/device integration (roadmap)")
                            .foregroundColor(.secondary)
                    }

                case .chat:
                    Section {
                        Text("Selecciona Chat en sidebar")
                    }
                }
            }
             .navigationTitle(panel.rawValue)
            .onChange(of: includeArchived) { v in vm.refreshSessions(includeArchived: v) }
            .onAppear { vm.refreshSessions(includeArchived: includeArchived) }
            .sheet(item: $renameTarget) { chat in
                NavigationStack {
                    Form {
                        TextField("Title", text: $renameText)
                    }
                    .navigationTitle("Renombrar chat")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancelar") { renameTarget = nil }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") {
                                vm.renameChat(sessionId: chat.id, title: renameText)
                                renameTarget = nil
                            }
                        }
                    }
                }
            }
            .sheet(isPresented: $showExport) {
                NavigationStack {
                    VStack {
                        TextEditor(text: $exportPreview)
                            .padding(8)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
                            .padding()
                    }
                    .navigationTitle("Exportar Markdown")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { showExport = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Copiar") {
                                #if canImport(UIKit)
                                UIPasteboard.general.string = exportPreview
                                #endif
                            }
                        }
                    }
                }
            }
        }
    }

    private func dateText(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: d)
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
                    Text("No stored memory yet")
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
                    Button("Close") { dismiss() }
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
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
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
                            TextField("Title", text: $cron.title)
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

                                Button("Save") {
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
                        Text("No runs yet")
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
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
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
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
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
                    TextField("new-file.txt", text: $newName)
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

                Button("Save file") {
                    guard !selected.isEmpty else { return }
                    try? OpenClawLiteAutomationStore.shared.saveWorkspaceFile(name: selected, content: content)
                    files = OpenClawLiteAutomationStore.shared.listWorkspaceFiles()
                }
                .buttonStyle(.borderedProminent)
            }
            .navigationTitle("Archivos")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }
}

private struct EmbeddingInspectorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var stats = ""

    private let memoryDirName = "OpenClawMemory"

    var body: some View {
        NavigationStack {
            Form {
                Section("Embedding backend") {
                    Text("Primary: Ollama embeddings when available")
                    Text("Fallback: Local hash embedding")
                        .foregroundColor(.secondary)
                }

                Section("Cache") {
                    Text(stats.isEmpty ? "Loading..." : stats)
                        .font(.caption)
                    Button("Refresh") { loadStats() }
                    Button("Clear embedding cache", role: .destructive) {
                        clearCache()
                    }
                }
            }
            .navigationTitle("Embeddings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { loadStats() }
        }
    }

    private func loadStats() {
        do {
            let docs = try LocalModelConfig.shared.documentsDirectory()
            let url = docs.appendingPathComponent(memoryDirName, isDirectory: true).appendingPathComponent("embedding_cache.json")
            if !FileManager.default.fileExists(atPath: url.path) {
                stats = "Cache file not created yet."
                return
            }
            let data = try Data(contentsOf: url)
            let arr = (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
            let sizeKB = Double(data.count) / 1024.0
            stats = "Entries: \(arr.count)\nSize: \(String(format: "%.1f", sizeKB)) KB\nPath: \(url.lastPathComponent)"
        } catch {
            stats = "Error: \(error.localizedDescription)"
        }
    }

    private func clearCache() {
        do {
            let docs = try LocalModelConfig.shared.documentsDirectory()
            let url = docs.appendingPathComponent(memoryDirName, isDirectory: true).appendingPathComponent("embedding_cache.json")
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            stats = "Cache cleared."
        } catch {
            stats = "Error clearing cache: \(error.localizedDescription)"
        }
    }
}

private struct DownloadsManagerView: View {
    @Environment(\.dismiss) private var dismiss

    @Binding var mlxDownloadedModels: [String]
    @Binding var mlxModelName: String
    @Binding var mlxToolsModelName: String
    @Binding var mlxReasoningModelName: String
    @Binding var mlxVisionModelName: String
    @Binding var mlxAudioModelName: String

    @Binding var models: [URL]
    @Binding var embeddingModels: [URL]
    @Binding var selectedModelPath: String
    @Binding var selectedEmbeddingModelPath: String
    @Binding var importMessage: String

    var onRefresh: () -> Void

    private let openClawLiteConfig = OpenClawLiteConfig.shared
    private let localConfig = LocalModelConfig.shared

    var body: some View {
        NavigationStack {
            List {
                Section("Downloaded MLX models") {
                    if mlxDownloadedModels.isEmpty {
                        Text("No downloaded MLX models")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(mlxDownloadedModels, id: \.self) { model in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(model).font(.subheadline)
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        Button("Chat") { mlxModelName = model }
                                            .buttonStyle(.bordered)
                                        Button("Tools") { mlxToolsModelName = model }
                                            .buttonStyle(.bordered)
                                        Button("Reasoning") { mlxReasoningModelName = model }
                                            .buttonStyle(.bordered)
                                        Button("Vision") { mlxVisionModelName = model }
                                            .buttonStyle(.bordered)
                                        Button("Audio") { mlxAudioModelName = model }
                                            .buttonStyle(.bordered)
                                        Button("Remove", role: .destructive) {
                                            openClawLiteConfig.unmarkMLXModelDownloaded(model)
                                            mlxDownloadedModels = openClawLiteConfig.loadDownloadedMLXModels()
                                            importMessage = "Removed downloaded mark: \(model)"
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                Section("Local chat models (.gguf)") {
                    if models.isEmpty {
                        Text("No local chat models")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(models, id: \.path) { url in
                            HStack {
                                Text(localConfig.displayName(for: url))
                                Spacer()
                                if selectedModelPath == url.path {
                                    Text("Active").font(.caption).foregroundColor(.green)
                                }
                                Button("Use") { selectedModelPath = url.path }
                                Button("Delete", role: .destructive) {
                                    do {
                                        try localConfig.deleteModel(at: url)
                                        importMessage = "Deleted model: \(localConfig.displayName(for: url))"
                                        onRefresh()
                                    } catch {
                                        importMessage = "Delete error: \(error.localizedDescription)"
                                    }
                                }
                            }
                        }
                    }
                }

                Section("Local embedding models") {
                    if embeddingModels.isEmpty {
                        Text("No local embedding models")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(embeddingModels, id: \.path) { url in
                            HStack {
                                Text(localConfig.displayName(for: url))
                                Spacer()
                                if selectedEmbeddingModelPath == url.path {
                                    Text("Active").font(.caption).foregroundColor(.green)
                                }
                                Button("Use") { selectedEmbeddingModelPath = url.path }
                                Button("Delete", role: .destructive) {
                                    do {
                                        try localConfig.deleteEmbeddingModel(at: url)
                                        importMessage = "Deleted embedding model: \(localConfig.displayName(for: url))"
                                        onRefresh()
                                    } catch {
                                        importMessage = "Delete error: \(error.localizedDescription)"
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Downloads")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct IntentRouterInspectorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var routerEnabled = true
    @State private var timeEnabled = true
    @State private var attachmentEnabled = true
    @State private var urlEnabled = true
    @State private var listEnabled = true

    private let runtime = LocalRuntimeConfig.shared

    var body: some View {
        NavigationStack {
            Form {
                Section("Routing toggles") {
                    Toggle("Enable intent router", isOn: $routerEnabled)
                    Toggle("Time route", isOn: $timeEnabled)
                    Toggle("Attachment route", isOn: $attachmentEnabled)
                    Toggle("URL route", isOn: $urlEnabled)
                    Toggle("List attachments route", isOn: $listEnabled)
                }

                Section("Usage metrics") {
                    metricRow("time_query", runtime.loadIntentRouteMetric("time_query"))
                    metricRow("attachment_query", runtime.loadIntentRouteMetric("attachment_query"))
                    metricRow("url_query", runtime.loadIntentRouteMetric("url_query"))
                    metricRow("attachment_list", runtime.loadIntentRouteMetric("attachment_list"))
                }
            }
            .navigationTitle("Intent Router")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        runtime.setIntentRouterEnabled(routerEnabled)
                        runtime.setIntentRouteTimeEnabled(timeEnabled)
                        runtime.setIntentRouteAttachmentEnabled(attachmentEnabled)
                        runtime.setIntentRouteURLEnabled(urlEnabled)
                        runtime.setIntentRouteListAttachmentsEnabled(listEnabled)
                        dismiss()
                    }
                }
            }
            .onAppear {
                routerEnabled = runtime.isIntentRouterEnabled()
                timeEnabled = runtime.isIntentRouteTimeEnabled()
                attachmentEnabled = runtime.isIntentRouteAttachmentEnabled()
                urlEnabled = runtime.isIntentRouteURLEnabled()
                listEnabled = runtime.isIntentRouteListAttachmentsEnabled()
            }
        }
    }

    @ViewBuilder
    private func metricRow(_ name: String, _ value: Int) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text("\(value)")
                .foregroundColor(.secondary)
        }
    }
}

private struct PolicyEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selected = "POLICY.md"
    @State private var content = ""
    @State private var status = ""

    private let files = ["POLICY.md", "ROUTING.md", "TOOL_RULES.md"]

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                Picker("Policy file", selection: $selected) {
                    ForEach(files, id: \.self) { file in
                        Text(file).tag(file)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .onChange(of: selected) { _, _ in
                    loadSelected()
                }

                TextEditor(text: $content)
                    .padding(8)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2)))
                    .padding(.horizontal)

                if !status.isEmpty {
                    Text(status)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                }

                HStack {
                    Button("Reload") { loadSelected() }
                    Spacer()
                    Button("Save") { saveSelected() }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal)
            }
            .navigationTitle("Policy Editor")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear { loadSelected() }
        }
    }

    private func appMemoryDir() throws -> URL {
        let docs = try LocalModelConfig.shared.documentsDirectory()
        return docs.appendingPathComponent("OpenClawMemory/AppMemory", isDirectory: true)
    }

    private func loadSelected() {
        do {
            let dir = try appMemoryDir()
            let url = dir.appendingPathComponent(selected)
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                content = text
                status = "Loaded \(selected)"
            } else {
                content = ""
                status = "File not found yet: \(selected)"
            }
        } catch {
            status = "Load error: \(error.localizedDescription)"
        }
    }

    private func saveSelected() {
        do {
            let dir = try appMemoryDir()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(selected)
            try content.write(to: url, atomically: true, encoding: .utf8)
            status = "Saved \(selected)"
        } catch {
            status = "Save error: \(error.localizedDescription)"
        }
    }
}

private struct ToolsManagerView: View {
    @Binding var toolPermissions: [String: Bool]
    @Environment(\.dismiss) private var dismiss
    private let config = OpenClawLiteConfig.shared

    var body: some View {
        NavigationStack {
            List {
                Section("Tool permissions") {
                    ForEach(config.availableToolNames(), id: \.self) { tool in
                        Toggle(tool, isOn: Binding(
                            get: { toolPermissions[tool, default: true] },
                            set: { toolPermissions[tool] = $0 }
                        ))
                    }
                }
            }
            .navigationTitle("Tools")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct SettingsView: View {
    enum SettingsCategory: String, CaseIterable, Identifiable {
        case all = "All"
        case models = "Models"
        case network = "Network"
        case automation = "Automation"
        case tools = "Tools"

        var id: String { rawValue }
    }

    enum QuickPanel: String, Identifiable {
        case skills, crons, heartbeat, files
        var id: String { rawValue }
    }

    @ObservedObject var vm: ChatViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var remoteProvider: RemoteProvider = .customOpenAICompatible
    @State private var baseURL = ""
    @State private var token = ""
    @State private var model = ""
    @State private var remoteOrganization = ""
    @State private var remoteProject = ""

    @State private var models: [URL] = []
    @State private var selectedModelPath: String = ""

    @State private var embeddingModels: [URL] = []
    @State private var selectedEmbeddingModelPath: String = ""

    @State private var showFileImporter = false
    @State private var importTarget: ImportTarget = .chat

    @State private var runtimeProvider: LocalRuntimeProvider = .mlx
    @State private var ollamaBaseURL = ""
    @State private var ollamaModel = ""
    @State private var llamaBaseURL = ""
    @State private var llamaModel = ""
    @State private var mlxModelName = ""
    @State private var mlxToolsModelName = ""
    @State private var mlxReasoningModelName = ""
    @State private var mlxVisionModelName = ""
    @State private var mlxAudioModelName = ""
    @State private var separateToolsModelEnabled = false
    @State private var dualPassReasoningEnabled = true
    @State private var multimodalRoutingEnabled = true
    @State private var mlxPresetModel = "mlx-community/Qwen2.5-1.5B-Instruct-4bit"
    @State private var isDownloadingMLXModel = false
    @State private var mlxDownloadProgress: Double = 0
    @State private var mlxDownloadPhase: String = "idle"
    @State private var mlxDownloadedModels: [String] = []

    @State private var importMessage = ""
    @State private var modelToDelete: URL?
    @State private var embeddingModelToDelete: URL?
    @State private var allowlistHostsText = ""
    @State private var braveApiKey = ""
    @State private var showMemoryManager = false
    @State private var internetOpenAccess = true
    @State private var quickPanel: QuickPanel?
    @State private var showToolsManager = false
    @State private var showDownloadsManager = false
    @State private var showPolicyEditor = false
    @State private var showIntentRouterInspector = false
    @State private var showEmbeddingInspector = false
    @State private var showAdvancedModelIDs = false
    @State private var showAdvancedNetwork = false
    @State private var recentContextWindow: Double = 10
    @State private var automationLoopEnabled = false
    @State private var lowPowerModeEnabled = false
    @State private var emergencyMemoryModeEnabled = false
    @State private var autodevEnabled = false
    @State private var qualityGateStrictness = "balanced"
    @State private var selfImprovingAgentEnabled = true
    @State private var offlineStrictModeEnabled = false
    @State private var forceAttachmentFirstEnabled = true
    @State private var toolPermissions: [String: Bool] = [:]
    @State private var settingsSearch = ""
    @State private var settingsCategory: SettingsCategory = .all

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

    private var isNativeLlamaModuleAvailable: Bool {
        #if canImport(LlamaCpp) || canImport(llama) || canImport(LlamaSwift)
        return true
        #else
        return false
        #endif
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Settings navigator") {
                    Picker("Category", selection: $settingsCategory) {
                        ForEach(SettingsCategory.allCases) { cat in
                            Text(cat.rawValue).tag(cat)
                        }
                    }
                    .pickerStyle(.segmented)

                    TextField("Search settings…", text: $settingsSearch)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                if shouldShowSection(.models, keywords: ["run", "route", "mode", "provider", "engine"]) {
                    Section("How do you want to run?") {
                        Picker("Mode", selection: $vm.routePreference) {
                            ForEach(RoutePreference.allCases) { option in
                                Label(option.title, systemImage: icon(for: option)).tag(option)
                            }
                        }
                    }
                }

                if vm.routePreference == .local && shouldShowSection(.models, keywords: ["local", "mlx", "ollama", "llama", "model", "reasoning", "vision", "audio", "tools"]) {
                    Section("Local engine") {
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
                            Button {
                                showDownloadsManager = true
                            } label: {
                                Label("Open Downloads Manager", systemImage: "arrow.down.circle")
                            }

                            Picker("Suggested models", selection: $mlxPresetModel) {
                                ForEach(mlxPresetModels, id: \.self) { modelId in
                                    Text(modelId).tag(modelId)
                                }
                            }

                            if !mlxDownloadedModels.isEmpty {
                                Picker("Downloaded models", selection: $mlxModelName) {
                                    ForEach(mlxDownloadedModels, id: \.self) { modelId in
                                        Text(modelId).tag(modelId)
                                    }
                                }
                            }

                            Button("Use suggested model") {
                                mlxModelName = mlxPresetModel
                                importMessage = "Selected MLX model: \(mlxPresetModel)"
                            }

                            Toggle("Show advanced model IDs", isOn: $showAdvancedModelIDs)

                            if showAdvancedModelIDs {
                                TextField("MLX model (manual)", text: $mlxModelName)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            }

                            Toggle("Use a separate model for tools", isOn: $separateToolsModelEnabled)
                            if hasLFMFamilyAvailable {
                                Toggle("Enable dual-pass reasoning (Thinking → Instruct)", isOn: $dualPassReasoningEnabled)
                                Toggle("Enable multimodal routing (Vision/Audio)", isOn: $multimodalRoutingEnabled)

                                if dualPassReasoningEnabled && !mlxDownloadedModels.isEmpty {
                                    Picker("Reasoning model", selection: $mlxReasoningModelName) {
                                        Text("(none)").tag("")
                                        ForEach(mlxDownloadedModels, id: \.self) { modelId in
                                            Text(modelId).tag(modelId)
                                        }
                                    }
                                }

                                if multimodalRoutingEnabled && !mlxDownloadedModels.isEmpty {
                                    Picker("Vision model", selection: $mlxVisionModelName) {
                                        Text("(none)").tag("")
                                        ForEach(mlxDownloadedModels, id: \.self) { modelId in
                                            Text(modelId).tag(modelId)
                                        }
                                    }

                                    Picker("Audio model", selection: $mlxAudioModelName) {
                                        Text("(none)").tag("")
                                        ForEach(mlxDownloadedModels, id: \.self) { modelId in
                                            Text(modelId).tag(modelId)
                                        }
                                    }
                                }
                            }

                            if showAdvancedModelIDs && hasLFMFamilyAvailable {
                                if dualPassReasoningEnabled {
                                    TextField("MLX reasoning model (optional)", text: $mlxReasoningModelName)
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled()
                                }
                                if multimodalRoutingEnabled {
                                    TextField("MLX vision model (optional)", text: $mlxVisionModelName)
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled()

                                    TextField("MLX audio model (optional)", text: $mlxAudioModelName)
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled()
                                }
                            }

                            if separateToolsModelEnabled {
                                if !mlxDownloadedModels.isEmpty {
                                    Picker("Tools model", selection: $mlxToolsModelName) {
                                        ForEach(mlxDownloadedModels, id: \.self) { modelId in
                                            Text(modelId).tag(modelId)
                                        }
                                    }
                                }
                                if showAdvancedModelIDs {
                                    TextField("MLX tools model", text: $mlxToolsModelName)
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled()
                                }
                                Text("More RAM usage: may cause OOM/crashes on iPad if both models are heavy.")
                                    .font(.caption2)
                                    .foregroundColor(.orange)
                                Text("Active tools model: \(mlxToolsModelName.isEmpty ? "(not set)" : mlxToolsModelName)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            } else {
                                Text("Active tools model: same as chat model")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }

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
                                    Label(isDownloadingMLXModel ? "Downloading..." : "Download selected MLX model", systemImage: "arrow.down.circle")
                                }
                                .disabled(isDownloadingMLXModel || mlxModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }

                            Text("Approx size: \(mlxEstimatedSizeText(for: mlxModelName))")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            if isDownloadingMLXModel {
                                ProgressView(value: mlxDownloadProgress, total: 1.0)
                                    .progressViewStyle(.linear)

                                HStack {
                                    Text("Progreso estimado: \(Int(mlxDownloadProgress * 100))%")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text(mlxDownloadPhaseLabel())
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }

                                if mlxDownloadPhase == "verifying" {
                                    Text("Finishing download and verifying model…")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }

                            Text("You can pick a suggested model or enter a manual ID if you know what to use.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if runtimeProvider == .llamaCpp {
                    if isNativeLlamaModuleAvailable {
                        Section("Backend llama.cpp") {
                            Text("Native llama.cpp module detected. Loopback server fields are hidden by default.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Section("Backend llama.cpp") {
                            TextField("llama-server URL", text: $llamaBaseURL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            TextField("Modelo (opcional)", text: $llamaModel)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            Text("If model is empty, the selected .gguf filename is used.")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }

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
                                Label("Add .gguf", systemImage: "plus.circle.fill")
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
                        Text("Local chat model")
                    }

                    Section {
                        if embeddingModels.isEmpty {
                            Text("No hay modelos para embeddings/memory")
                                .foregroundColor(.secondary)
                        } else {
                            Picker("Embedding model", selection: $selectedEmbeddingModelPath) {
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
                                Label("Add .gguf embeddings", systemImage: "plus.circle")
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
                        Text("Embeddings and memory")
                    }
                    }
                }

                if vm.routePreference != .local && shouldShowSection(.network, keywords: ["remote", "api", "token", "url", "model", "provider", "openai", "anthropic", "google", "nvidia"]) {
                    Section("Remote API") {
                        Picker("Provider", selection: $remoteProvider) {
                            ForEach(RemoteProvider.allCases) { provider in
                                Text(provider.title).tag(provider)
                            }
                        }

                        TextField("URL del API", text: $baseURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Token/API key", text: $token)
                        TextField("Modelo", text: $model)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                        TextField("Organization (optional)", text: $remoteOrganization)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Project/App (optional)", text: $remoteProject)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }

                if shouldShowSection(.automation, keywords: ["internet", "network", "context", "automation", "low-power", "memory", "heartbeat", "skills", "crons", "files", "brave", "autodev"]) {
                Section {
                    Toggle(isOn: $internetOpenAccess) {
                        Label("Open internet access", systemImage: "globe")
                    }

                    Toggle("Show advanced network controls", isOn: $showAdvancedNetwork)

                    if showAdvancedNetwork {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Allowed hosts for http_get (one per line)")
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
                            Text("Open mode: can visit any domain.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Contexto reciente")
                            Spacer()
                            Text("\(Int(recentContextWindow)) msgs")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $recentContextWindow, in: 2...30, step: 1)
                    }

                    Toggle(isOn: $automationLoopEnabled) {
                        Label("Background automation (cron loop)", systemImage: "clock.arrow.circlepath")
                    }

                    Toggle(isOn: $lowPowerModeEnabled) {
                        Label("Low-power mode (less heat/battery use)", systemImage: "bolt.horizontal.circle")
                    }

                    Toggle(isOn: $emergencyMemoryModeEnabled) {
                        Label("Emergency memory mode (aggressive RAM limits)", systemImage: "exclamationmark.triangle")
                    }

                    Picker("Quality gate strictness", selection: $qualityGateStrictness) {
                        Text("Relaxed").tag("relaxed")
                        Text("Balanced").tag("balanced")
                        Text("Strict").tag("strict")
                    }

                    Toggle("Self-improving agent", isOn: $selfImprovingAgentEnabled)
                    Toggle("Offline strict mode (never fallback to remote)", isOn: $offlineStrictModeEnabled)
                    Toggle("Force attachment-first answers", isOn: $forceAttachmentFirstEnabled)

                    if lowPowerModeEnabled || emergencyMemoryModeEnabled || offlineStrictModeEnabled {
                        Text("Reduces context, OCR, and retries. Emergency mode also enforces stricter prompt condensation and smaller context windows.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    Toggle(isOn: $vm.autoResumeQueuedPrompt) {
                        Label("Auto-resume queued prompt on foreground", systemImage: "play.circle")
                    }

                    SecureField("Brave API Key", text: $braveApiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button {
                        showMemoryManager = true
                    } label: {
                        Label("Open memory manager", systemImage: "brain.head.profile")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        showPolicyEditor = true
                    } label: {
                        Label("Open policy editor", systemImage: "doc.text.magnifyingglass")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        showIntentRouterInspector = true
                    } label: {
                        Label("Open intent router inspector", systemImage: "point.3.connected.trianglepath.dotted")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        showEmbeddingInspector = true
                    } label: {
                        Label("Open embeddings inspector", systemImage: "square.stack.3d.up")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)

                    VStack(alignment: .leading, spacing: 10) {
                        Button { quickPanel = .skills } label: {
                            Label("Skills", systemImage: "wand.and.stars")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Button { quickPanel = .crons } label: {
                            Label("Crons", systemImage: "clock.arrow.circlepath")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Button { quickPanel = .heartbeat } label: {
                            Label("Heartbeat", systemImage: "heart.text.square")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Button { quickPanel = .files } label: {
                            Label("Files", systemImage: "folder")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .buttonStyle(.bordered)
                } header: {
                    Text("OpenClaw Lite")
                } footer: {
                    Text("You can switch between open internet mode and allowlist-restricted mode.")
                }
                }

                if shouldShowSection(.tools, keywords: ["tools", "permissions", "autodev"]) {
                Section("Tools") {
                    Button {
                        showToolsManager = true
                    } label: {
                        Label("Open Tools submenu", systemImage: "wrench.and.screwdriver")
                    }

                    Toggle("AutoDev (proactive micro-improvements)", isOn: $autodevEnabled)
                }
                }

                if !importMessage.isEmpty {
                    Section("Status") {
                        Text(importMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        remoteConfig.save(provider: remoteProvider, baseURL: baseURL, token: token, model: model, organization: remoteOrganization, project: remoteProject)
                        runtimeConfig.saveProvider(runtimeProvider)
                        runtimeConfig.saveOllama(baseURL: ollamaBaseURL, model: ollamaModel)
                        runtimeConfig.saveLlama(baseURL: llamaBaseURL, model: llamaModel)
                        runtimeConfig.saveMLXModelName(mlxModelName)
                        runtimeConfig.saveMLXToolsModelName(mlxToolsModelName)
                        runtimeConfig.saveMLXReasoningModelName(mlxReasoningModelName)
                        runtimeConfig.saveMLXVisionModelName(mlxVisionModelName)
                        runtimeConfig.saveMLXAudioModelName(mlxAudioModelName)
                        runtimeConfig.setSeparateMLXToolsModelEnabled(separateToolsModelEnabled)
                        runtimeConfig.setDualPassReasoningEnabled(dualPassReasoningEnabled)
                        runtimeConfig.setMultimodalRoutingEnabled(multimodalRoutingEnabled)
                        openClawLiteConfig.saveAllowlistHosts(allowlistHostsText)
                        openClawLiteConfig.saveBraveApiKey(braveApiKey)
                        openClawLiteConfig.setInternetOpenAccessEnabled(internetOpenAccess)
                        runtimeConfig.saveRecentContextWindow(Int(recentContextWindow))
                        openClawLiteConfig.setAutomationLoopEnabled(automationLoopEnabled)
                        openClawLiteConfig.setLowPowerModeEnabled(lowPowerModeEnabled)
                        runtimeConfig.setEmergencyMemoryModeEnabled(emergencyMemoryModeEnabled)
                        runtimeConfig.saveQualityGateStrictness(qualityGateStrictness)
                        runtimeConfig.setSelfImprovingAgentEnabled(selfImprovingAgentEnabled)
                        runtimeConfig.setOfflineStrictModeEnabled(offlineStrictModeEnabled)
                        runtimeConfig.setForceAttachmentFirstEnabled(forceAttachmentFirstEnabled)
                        openClawLiteConfig.setAutodevEnabled(autodevEnabled)
                        for (tool, enabled) in toolPermissions {
                            openClawLiteConfig.setToolEnabled(tool, enabled: enabled)
                        }
                        localConfig.saveSelectedModelPath(selectedModelPath.isEmpty ? nil : selectedModelPath)
                        localConfig.saveSelectedEmbeddingModelPath(selectedEmbeddingModelPath.isEmpty ? nil : selectedEmbeddingModelPath)
                        dismiss()
                    }
                }
            }
            .onAppear {
                let savedRemote = remoteConfig.load()
                remoteProvider = savedRemote.provider
                baseURL = savedRemote.baseURL
                token = savedRemote.token
                model = savedRemote.model
                remoteOrganization = savedRemote.organization
                remoteProject = savedRemote.project

                runtimeProvider = runtimeConfig.loadProvider()
                let ollama = runtimeConfig.loadOllama()
                ollamaBaseURL = ollama.baseURL
                ollamaModel = ollama.model
                let llama = runtimeConfig.loadLlama()
                llamaBaseURL = llama.baseURL
                llamaModel = llama.model
                mlxModelName = runtimeConfig.loadMLXModelName()
                mlxToolsModelName = runtimeConfig.loadMLXToolsModelName()
                mlxReasoningModelName = runtimeConfig.loadMLXReasoningModelName()
                mlxVisionModelName = runtimeConfig.loadMLXVisionModelName()
                mlxAudioModelName = runtimeConfig.loadMLXAudioModelName()
                separateToolsModelEnabled = runtimeConfig.isSeparateMLXToolsModelEnabled()
                dualPassReasoningEnabled = runtimeConfig.isDualPassReasoningEnabled()
                multimodalRoutingEnabled = runtimeConfig.isMultimodalRoutingEnabled()
                mlxPresetModel = mlxPresetModels.contains(mlxModelName) ? mlxModelName : mlxPresetModels[0]
                allowlistHostsText = openClawLiteConfig.allowlistHostsText()
                braveApiKey = openClawLiteConfig.loadBraveApiKey()
                internetOpenAccess = openClawLiteConfig.isInternetOpenAccessEnabled()
                recentContextWindow = Double(runtimeConfig.loadRecentContextWindow())
                automationLoopEnabled = openClawLiteConfig.isAutomationLoopEnabled()
                lowPowerModeEnabled = openClawLiteConfig.isLowPowerModeEnabled()
                emergencyMemoryModeEnabled = runtimeConfig.isEmergencyMemoryModeEnabled()
                qualityGateStrictness = runtimeConfig.loadQualityGateStrictness()
                selfImprovingAgentEnabled = runtimeConfig.isSelfImprovingAgentEnabled()
                offlineStrictModeEnabled = runtimeConfig.isOfflineStrictModeEnabled()
                forceAttachmentFirstEnabled = runtimeConfig.isForceAttachmentFirstEnabled()
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
            .sheet(item: $quickPanel) { panel in
                switch panel {
                case .skills:
                    SkillsManagerView()
                case .crons:
                    CronsManagerView()
                case .heartbeat:
                    HeartbeatManagerView()
                case .files:
                    FilesManagerView()
                }
            }
            .sheet(isPresented: $showToolsManager) {
                ToolsManagerView(toolPermissions: $toolPermissions)
            }
            .sheet(isPresented: $showDownloadsManager) {
                DownloadsManagerView(
                    mlxDownloadedModels: $mlxDownloadedModels,
                    mlxModelName: $mlxModelName,
                    mlxToolsModelName: $mlxToolsModelName,
                    mlxReasoningModelName: $mlxReasoningModelName,
                    mlxVisionModelName: $mlxVisionModelName,
                    mlxAudioModelName: $mlxAudioModelName,
                    models: $models,
                    embeddingModels: $embeddingModels,
                    selectedModelPath: $selectedModelPath,
                    selectedEmbeddingModelPath: $selectedEmbeddingModelPath,
                    importMessage: $importMessage,
                    onRefresh: { refreshModels() }
                )
            }
            .sheet(isPresented: $showPolicyEditor) {
                PolicyEditorView()
            }
            .sheet(isPresented: $showIntentRouterInspector) {
                IntentRouterInspectorView()
            }
            .sheet(isPresented: $showEmbeddingInspector) {
                EmbeddingInspectorView()
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
                            importMessage = "Chat model added: \(localConfig.displayName(for: copied))"
                        case .embedding:
                            let copied = try localConfig.importEmbeddingModel(from: sourceURL, into: docs)
                            selectedEmbeddingModelPath = copied.path
                            importMessage = "Embedding model added: \(localConfig.displayName(for: copied))"
                        }
                        refreshModels()
                    } catch {
                        importMessage = "Error al importar: \(error.localizedDescription)"
                    }
                case .failure(let error):
                    importMessage = "Import cancelled/error: \(error.localizedDescription)"
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
                        importMessage = "Embedding model eliminado: \(localConfig.displayName(for: url))"
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

    private var hasLFMFamilyAvailable: Bool {
        if mlxModelName.lowercased().contains("lfm") { return true }
        if mlxToolsModelName.lowercased().contains("lfm") { return true }
        return mlxDownloadedModels.contains { $0.lowercased().contains("lfm") }
    }

    private func shouldShowSection(_ category: SettingsCategory, keywords: [String]) -> Bool {
        let categoryOk = settingsCategory == .all || settingsCategory == category
        guard categoryOk else { return false }

        let q = settingsSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return true }

        return keywords.contains(where: { $0.lowercased().contains(q) || q.contains($0.lowercased()) })
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
            importMessage = "Enter a valid MLX model ID."
            return
        }

        isDownloadingMLXModel = true
        mlxDownloadProgress = 0.03
        mlxDownloadPhase = "downloading"

        let progressTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 450_000_000)
                await MainActor.run {
                    if isDownloadingMLXModel {
                        if mlxDownloadProgress < 0.92 {
                            mlxDownloadProgress = min(0.92, mlxDownloadProgress + 0.04)
                            mlxDownloadPhase = "downloading"
                        } else {
                            mlxDownloadPhase = "verifying"
                            mlxDownloadProgress = (mlxDownloadProgress >= 0.98) ? 0.93 : (mlxDownloadProgress + 0.01)
                        }
                    }
                }
            }
        }

        defer {
            progressTask.cancel()
            isDownloadingMLXModel = false
            if mlxDownloadPhase != "ready" { mlxDownloadPhase = "idle" }
        }

        do {
            runtimeConfig.saveMLXModelName(cleanId)
            try await mlxService.prewarmModel(modelId: cleanId)
            mlxDownloadProgress = 1.0
            mlxDownloadPhase = "ready"
            importMessage = "Modelo MLX descargado/listo: \(cleanId)"
            openClawLiteConfig.markMLXModelDownloaded(cleanId)
            mlxDownloadedModels = openClawLiteConfig.loadDownloadedMLXModels()
        } catch {
            importMessage = "No pude descargar el modelo MLX: \(error.localizedDescription)"
            mlxDownloadProgress = 0
            mlxDownloadPhase = "idle"
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

    private func mlxDownloadPhaseLabel() -> String {
        switch mlxDownloadPhase {
        case "downloading": return "Descargando"
        case "verifying": return "Verificando"
        case "ready": return "Listo"
        default: return ""
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
