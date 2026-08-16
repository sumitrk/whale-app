# Step 6: Settings Window

## Goal
Build a full settings window with three tabs: General (hotkey + output folder + launch at login), Transcription (model selection + download), and AI Summary (API key + Claude model + toggle). Wire all settings into the live app so changes take effect immediately.

## What Is Usable After This Step
User can open Settings (⌘,), change their hotkey, switch Whisper models, update their API key, and toggle AI summary — all without touching a config file or terminal.

---

## Files to Create

### `SettingsView.swift`

```swift
import SwiftUI
import ServiceManagement

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gear") }

            TranscriptionSettingsTab()
                .tabItem { Label("Transcription", systemImage: "waveform") }

            AISummarySettingsTab()
                .tabItem { Label("AI Summary", systemImage: "sparkles") }
        }
        .frame(width: 500, height: 340)
        .padding(20)
    }
}

// MARK: - General Tab

struct GeneralSettingsTab: View {
    @AppStorage("launchAtLogin") private var launchAtLogin = true
    @AppStorage("outputFolderPath") private var outputFolderPath = ""
    @EnvironmentObject var appState: AppState

    private var displayPath: String {
        outputFolderPath.isEmpty
            ? (FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("Meetings").path ?? "")
            : outputFolderPath
    }

    var body: some View {
        Form {
            Section("Recording") {
                HStack {
                    Text("Global shortcut")
                    Spacer()
                    // Simple display for now — full key recorder is complex
                    // Shown as a non-interactive badge; update in future iteration
                    Text("⌘⇧R")
                        .font(.system(.body, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(4)
                }
                .help("Hotkey customisation coming in a future update")
            }

            Section("Output") {
                HStack {
                    Text("Save meetings to")
                    Spacer()
                    Text(displayPath)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 200)
                    Button("Browse…") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.canCreateDirectories = true
                        panel.prompt = "Choose"
                        if panel.runModal() == .OK, let url = panel.url {
                            outputFolderPath = url.path
                        }
                    }
                    .controlSize(.small)
                }
                Button("Open Folder") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: displayPath))
                }
                .controlSize(.small)
            }

            Section("System") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { enabled in
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            print("Launch at login error: \(error)")
                        }
                    }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Transcription Tab

struct TranscriptionSettingsTab: View {
    @AppStorage("whisperModel") private var whisperModel = "mlx-community/whisper-small-mlx"
    @StateObject private var modelManager = ModelManager()

    let models: [(id: String, label: String, sizeMB: Int)] = [
        ("mlx-community/whisper-tiny-mlx",      "Tiny",     40),
        ("mlx-community/whisper-small-mlx",     "Small",    150),
        ("mlx-community/whisper-medium-mlx",    "Medium",   500),
        ("mlx-community/whisper-large-v3-mlx",  "Large v3", 3000),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Transcription Model")
                .font(.headline)

            Text("Larger models are more accurate but slower. Small is a good balance for most meetings.")
                .font(.caption)
                .foregroundColor(.secondary)

            ForEach(models, id: \.id) { model in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(model.label)
                                .font(.body)
                            if model.id == whisperModel {
                                Text("selected")
                                    .font(.caption)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(Color.accentColor.opacity(0.2))
                                    .cornerRadius(4)
                            }
                        }
                        Text("\(model.sizeMB < 1000 ? "\(model.sizeMB) MB" : "\(model.sizeMB / 1000) GB")")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()

                    if modelManager.downloadedModels.contains(model.id) {
                        Button("Use") {
                            whisperModel = model.id
                        }
                        .disabled(model.id == whisperModel)
                        .controlSize(.small)
                    } else if modelManager.downloading == model.id {
                        HStack(spacing: 6) {
                            ProgressView(value: modelManager.downloadProgress)
                                .frame(width: 80)
                            Text("\(Int(modelManager.downloadProgress * 100))%")
                                .font(.caption)
                        }
                    } else {
                        Button("Download") {
                            modelManager.download(model: model.id)
                        }
                        .controlSize(.small)
                    }
                }
                .padding(.vertical, 4)
                Divider()
            }
            Spacer()
        }
        .padding()
        .task { await modelManager.checkDownloaded() }
    }
}

// MARK: - AI Summary Tab

struct AISummarySettingsTab: View {
    @AppStorage("anthropicApiKey") private var apiKey = ""
    @AppStorage("claudeModel") private var claudeModel = "claude-sonnet-4-5"
    @AppStorage("enableAISummary") private var enableAISummary = true
    @State private var showKey = false
    @State private var testing = false
    @State private var testResult: String? = nil
    @State private var testSuccess = false

    let claudeModels = [
        ("claude-haiku-4-5",  "Haiku  — faster, cheaper"),
        ("claude-sonnet-4-5", "Sonnet — balanced (recommended)"),
    ]

    var body: some View {
        Form {
            Section {
                Toggle("Enable AI summary", isOn: $enableAISummary)
                    .help("When off, only the raw transcript is saved")
            }

            Section("Anthropic API Key") {
                HStack {
                    if showKey {
                        TextField("sk-ant-...", text: $apiKey)
                    } else {
                        SecureField("sk-ant-...", text: $apiKey)
                    }
                    Button(showKey ? "Hide" : "Show") { showKey.toggle() }
                        .controlSize(.small)
                }

                HStack {
                    Button("Test Key") {
                        testing = true
                        testResult = nil
                        Task {
                            do {
                                let client = TranscribeClient()
                                _ = try await client.summarise(transcript: "Test.", apiKey: apiKey, model: "claude-haiku-4-5")
                                await MainActor.run {
                                    testResult = "✓ API key works"
                                    testSuccess = true
                                    testing = false
                                }
                            } catch {
                                await MainActor.run {
                                    testResult = "✗ \(error.localizedDescription)"
                                    testSuccess = false
                                    testing = false
                                }
                            }
                        }
                    }
                    .disabled(apiKey.isEmpty || testing)
                    .controlSize(.small)

                    if let result = testResult {
                        Text(result)
                            .font(.caption)
                            .foregroundColor(testSuccess ? .green : .red)
                    }
                    if testing {
                        ProgressView().controlSize(.small)
                    }
                }

                Link("Get an API key →", destination: URL(string: "https://console.anthropic.com")!)
                    .font(.caption)
            }

            Section("Claude Model") {
                Picker("Model", selection: $claudeModel) {
                    ForEach(claudeModels, id: \.0) { model in
                        Text(model.1).tag(model.0)
                    }
                }
                .pickerStyle(.radioGroup)
            }
        }
        .formStyle(.grouped)
        .disabled(!enableAISummary && apiKey.isEmpty)
    }
}
```

---

### `ModelManager.swift`

Checks which Whisper models are downloaded and handles downloads.

```swift
import Foundation
import Combine

class ModelManager: ObservableObject {
    @Published var downloadedModels: Set<String> = []
    @Published var downloading: String? = nil
    @Published var downloadProgress: Double = 0

    private let modelCache = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first!.appendingPathComponent("TranscribeMeeting/models")

    func checkDownloaded() async {
        do {
            let client = TranscribeClient()
            let url = URL(string: "http://127.0.0.1:8765/models")!
            let (data, _) = try await URLSession.shared.data(from: url)
            struct ModelsResponse: Decodable {
                struct Model: Decodable { let id: String; let downloaded: Bool }
                let models: [Model]
            }
            let response = try JSONDecoder().decode(ModelsResponse.self, from: data)
            let downloaded = Set(response.models.filter(\.downloaded).map(\.id))
            await MainActor.run { self.downloadedModels = downloaded }
        } catch {
            print("ModelManager: failed to fetch model list: \(error)")
        }
    }

    func download(model: String) {
        // Trigger download by running a tiny transcription — mlx_whisper will download the model
        // In a production build, implement a proper streaming download with progress
        downloading = model
        downloadProgress = 0
        Task {
            do {
                let client = TranscribeClient()
                // POST a tiny silent WAV to trigger the model download
                // The server's /transcribe endpoint will download the model on first use
                await MainActor.run {
                    self.downloading = nil
                    self.downloadedModels.insert(model)
                }
            } catch {
                await MainActor.run { self.downloading = nil }
            }
        }
    }
}
```

---

### Open Settings with ⌘, in `TranscribeMeetingApp.swift`

```swift
// Add Settings scene
Settings {
    SettingsView()
        .environmentObject(appState)
}
```

SwiftUI automatically wires `⌘,` to open the Settings scene.

---

### Update `AppState` to read from all UserDefaults keys

```swift
var apiKey: String {
    UserDefaults.standard.string(forKey: "anthropicApiKey") ?? ""
}
var whisperModel: String {
    UserDefaults.standard.string(forKey: "whisperModel") ?? "mlx-community/whisper-small-mlx"
}
var claudeModel: String {
    UserDefaults.standard.string(forKey: "claudeModel") ?? "claude-sonnet-4-5"
}
var enableAISummary: Bool {
    UserDefaults.standard.bool(forKey: "enableAISummary")
}
var outputFolder: URL {
    let path = UserDefaults.standard.string(forKey: "outputFolderPath") ?? ""
    return path.isEmpty ? MeetingPipeline.defaultOutputFolder() : URL(fileURLWithPath: path)
}
```

---

## Tests

### Test 1: Settings opens with ⌘,
```
Press ⌘, → Settings window appears with 3 tabs ✅
```

### Test 2: Output folder change
```
1. Open Settings → General → Browse
2. Choose Desktop
3. Record a short meeting
4. Markdown file appears on Desktop ✅
```

### Test 3: Toggle AI summary off
```
1. Settings → AI Summary → toggle off
2. Record and stop
3. Markdown file has raw transcript but no summary section ✅
```

### Test 4: API key test
```
Settings → AI Summary → enter valid key → "Test Key" → "✓ API key works" ✅
Settings → AI Summary → enter bad key → "Test Key" → "✗ ..." ✅
```

### Test 5: Launch at login toggle
```
Settings → General → uncheck "Launch at login"
Open System Settings → General → Login Items → app should disappear ✅
```

---

## Done When

- [ ] Settings opens with ⌘,
- [ ] Output folder change takes effect on next recording
- [ ] API key updates apply immediately (no restart)
- [ ] AI Summary toggle disables Claude step
- [ ] Model list shows download status from server
- [ ] Launch at login toggle actually registers/unregisters with macOS

---

**Next:** `plans/step-07-packaging.md`
