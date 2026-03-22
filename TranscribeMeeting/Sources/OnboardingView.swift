import AppKit
import AVFoundation
import SwiftUI

// MARK: - Container

struct OnboardingView: View {
    let onComplete: () -> Void

    @EnvironmentObject private var appState: AppState
    @State private var step = 0

    // Permissions state
    @State private var micStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var axTrusted: Bool = AXIsProcessTrusted()
    @State private var axPollTimer: Timer?

    // Model state
    @State private var hasModel = false

    var body: some View {
        VStack(spacing: 0) {
            stepContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            bottomBar
        }
        .onAppear { startAxPolling() }
        .onDisappear { axPollTimer?.invalidate() }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case 0: WelcomeStep()
        case 1: PermissionsStep(micStatus: $micStatus, axTrusted: $axTrusted)
        case 2: ModelStep(hasModel: $hasModel)
        case 3: TryItStep(onDone: finish)
        default: EmptyView()
        }
    }

    private var bottomBar: some View {
        HStack {
            // Step dots
            HStack(spacing: 7) {
                ForEach(0..<4, id: \.self) { i in
                    Circle()
                        .fill(i == step ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: 6, height: 6)
                }
            }

            Spacer()

            if step < 3 {
                Button(step == 0 ? "Get Started" : "Continue") {
                    withAnimation(.easeInOut(duration: 0.2)) { step += 1 }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canAdvance)
                .keyboardShortcut(.return)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
        .background(.regularMaterial)
    }

    private var canAdvance: Bool {
        switch step {
        case 1: return micStatus == .authorized && axTrusted
        case 2: return hasModel
        default: return true
        }
    }

    private func finish() {
        SettingsStore.shared.hasCompletedOnboarding = true
        onComplete()
    }

    private func startAxPolling() {
        axPollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            DispatchQueue.main.async { axTrusted = AXIsProcessTrusted() }
        }
    }
}

// MARK: - Step 0: Welcome

private struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.blue)
                .symbolRenderingMode(.hierarchical)

            VStack(spacing: 8) {
                Text("TranscribeMeeting")
                    .font(.largeTitle.bold())

                Text("Hold a key, speak, release.\nYour words are transcribed and pasted instantly.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .font(.body)
            }
        }
        .padding(40)
    }
}

// MARK: - Step 1: Permissions

private struct PermissionsStep: View {
    @Binding var micStatus: AVAuthorizationStatus
    @Binding var axTrusted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Grant two permissions")
                    .font(.title2.bold())
                Text("Both are required for the app to work.")
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 0) {
                PermissionRow(
                    icon: "mic.fill", color: .red,
                    title: "Microphone",
                    description: "To record your voice during meetings.",
                    isGranted: micStatus == .authorized,
                    onGrant: requestMic
                )
                Divider().padding(.leading, 46)
                PermissionRow(
                    icon: "accessibility", color: .blue,
                    title: "Accessibility",
                    description: "To detect the push-to-talk key from any app.",
                    isGranted: axTrusted,
                    onGrant: requestAccessibility
                )
            }
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(28)
    }

    private func requestMic() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            DispatchQueue.main.async {
                micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            }
        }
    }

    private func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}

private struct PermissionRow: View {
    let icon: String
    let color: Color
    let title: String
    let description: String
    let isGranted: Bool
    let onGrant: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(description).font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            if isGranted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
                    .fontWeight(.medium)
            } else {
                Button("Grant", action: onGrant)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

// MARK: - Step 2: Model

private struct ModelStep: View {
    @Binding var hasModel: Bool
    @ObservedObject private var store = SettingsStore.shared

    @State private var models: [ModelInfo] = []
    @State private var downloading: Set<String> = []
    @State private var downloadProgress: [String: Double] = [:]
    @State private var serverReady = false
    @State private var downloadError: String?
    @State private var pollTimer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Download a model")
                    .font(.title2.bold())
                Text("Stored on your Mac. One-time download, no internet needed after.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            .padding(.horizontal, 28)
            .padding(.top, 28)

            if let downloadError {
                Text(downloadError)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .padding(.horizontal, 28)
            }

            if !serverReady {
                // Server still starting — show a friendly wait state
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Starting transcription server…")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(models) { model in
                    ModelRow(
                        model:            model,
                        isActive:         store.activeModelId == model.id && model.downloaded,
                        isDownloading:    downloading.contains(model.id),
                        downloadProgress: downloadProgress[model.id],
                        onSelect:         { store.activeModelId = model.id },
                        onDownload:       { Task { await download(model) } }
                    )
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await fetchModels() }
        .onAppear  { startPolling() }
        .onDisappear { pollTimer?.invalidate() }
    }

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { await fetchModels() }
        }
    }

    private func fetchModels() async {
        do {
            let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:8765/models")!)
            let resp = try JSONDecoder().decode(ModelsResponse.self, from: data)
            serverReady = true
            models = resp.models
            // Only unlock Continue when no download is in progress
            // (the cache dir is created immediately so downloaded=true too early)
            if downloading.isEmpty {
                hasModel = models.contains { $0.downloaded }
            }
        } catch {
            serverReady = false
        }
    }

    private func download(_ model: ModelInfo) async {
        downloading.insert(model.id)
        defer {
            downloading.remove(model.id)
            downloadProgress.removeValue(forKey: model.id)
        }

        // Poll progress while download is in-flight
        let pollTask = Task {
            while !Task.isCancelled {
                await fetchDownloadProgress(for: model.id)
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
        }
        defer { pollTask.cancel() }

        var req = URLRequest(url: URL(string: "http://127.0.0.1:8765/models/download")!)
        req.httpMethod = "POST"
        let boundary = UUID().uuidString
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        body.appendField("model_id", value: model.id, boundary: boundary)
        req.httpBody = body
        req.timeoutInterval = 1200

        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                downloadError = "\(model.label) failed to download — try restarting the app (error \(http.statusCode))"
                return
            }
            await fetchModels()
            hasModel = true  // unlock Continue only after full download completes
            if store.activeModelId.isEmpty || !models.contains(where: { $0.downloaded && $0.id == store.activeModelId }) {
                store.activeModelId = model.id
            }
        } catch {
            downloadError = "Download failed: \(error.localizedDescription)"
        }
    }

    private func fetchDownloadProgress(for modelId: String) async {
        let encoded = modelId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? modelId
        guard let url = URL(string: "http://127.0.0.1:8765/models/download-progress?model_id=\(encoded)") else { return }
        struct Resp: Decodable { let percent: Double }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let resp = try? JSONDecoder().decode(Resp.self, from: data) else { return }
        if resp.percent > 0.01 { downloadProgress[modelId] = resp.percent }
    }
}

private struct ModelsResponse: Decodable { let models: [ModelInfo] }

// MARK: - Step 3: Configure & Try

private struct TryItStep: View {
    let onDone: () -> Void
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var store = SettingsStore.shared
    @State private var pttPreset: PTTPreset = .globe
    @State private var pttRecorderAutoStart = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Configure & Try")
                    .font(.title2.bold())

                // ── Push-to-Talk ──────────────────────────────────────────
                OnboardingCard {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Push-to-Talk")
                                .fontWeight(.semibold)
                            Text("Hold a key to record, release to transcribe.")
                                .font(.caption).foregroundStyle(.secondary)
                        }

                        HStack {
                            Text("Key").foregroundStyle(.secondary).font(.callout)
                            Spacer()
                            Picker("", selection: $pttPreset) {
                                ForEach(PTTPreset.allCases) { p in
                                    Text(p.rawValue).tag(p)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .fixedSize()
                            .onChange(of: pttPreset) { preset in
                                if let kc = preset.keyCode {
                                    store.pttKeyCode = kc; store.pttModifiers = 0
                                } else { pttRecorderAutoStart = true }
                            }
                        }

                        if pttPreset == .custom {
                            HStack {
                                Text("Custom key").foregroundStyle(.secondary).font(.callout)
                                Spacer()
                                PTTRecorderView(
                                    keyCode: $store.pttKeyCode,
                                    modifiers: $store.pttModifiers,
                                    startImmediately: pttRecorderAutoStart
                                )
                                .onAppear { pttRecorderAutoStart = false }
                            }
                        }

                        Divider()

                        // ── Try it ────────────────────────────────────────
                        Label {
                            Text("Switch to any other app, hold **\(store.pttKeyLabel)**, speak, then release. Your words will be transcribed and pasted automatically.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "hand.point.right")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // ── Toggle Record ─────────────────────────────────────────
                OnboardingCard {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Toggle Recording")
                                .fontWeight(.semibold)
                            Text("Press once to start, press again to stop and save as markdown.")
                                .font(.caption).foregroundStyle(.secondary)
                        }

                        HStack {
                            Text("Key").foregroundStyle(.secondary).font(.callout)
                            Spacer()
                            KeyRecorderView(
                                keyCode: $store.toggleKeyCode,
                                modifiers: $store.toggleModifiers
                            )
                        }

                        // Transcript folder
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Save transcripts to").foregroundStyle(.secondary).font(.callout)
                            Button(action: pickFolder) {
                                HStack {
                                    Text(store.transcriptFolder.abbreviatedPath)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                    Image(systemName: "folder").foregroundStyle(.secondary)
                                }
                                .padding(8)
                                .frame(maxWidth: .infinity)
                                .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(NSColor.separatorColor), lineWidth: 0.5))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Start Using App") { onDone() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(.regularMaterial)
        }
        .onAppear { pttPreset = derivedPreset() }
    }


    private func derivedPreset() -> PTTPreset {
        guard store.pttModifiers == 0 else { return .custom }
        return PTTPreset.allCases.first { $0.keyCode == store.pttKeyCode } ?? .custom
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            store.transcriptFolderPath = url.path
        }
    }
}

// MARK: - Card container

private struct OnboardingCard<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(NSColor.separatorColor), lineWidth: 0.5))
    }
}
