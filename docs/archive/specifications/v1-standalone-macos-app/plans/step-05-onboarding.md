# Step 5: Onboarding + Permissions Flow

## Goal
Build the guided 4-step onboarding window that runs on first launch. It walks the user through: granting microphone access, granting screen recording access, entering their Anthropic API key, and choosing an output folder. After completing onboarding, the app works fully with no manual configuration.

## What Is Usable After This Step
A clean Mac install of the app (no .env, no manual setup) runs onboarding, collects everything needed, and is immediately usable. Settings are persisted to `UserDefaults`.

---

## State Persistence

All settings stored via `UserDefaults` / `@AppStorage`:

| Key | Type | Default |
|-----|------|---------|
| `onboardingComplete` | Bool | false |
| `anthropicApiKey` | String | "" |
| `outputFolderPath` | String | ~/Documents/Meetings |
| `whisperModel` | String | mlx-community/whisper-small-mlx |
| `hotkeyKeyCode` | Int | 15 (R) |
| `hotkeyModifiers` | Int | cmd+shift flags |
| `launchAtLogin` | Bool | true |

---

## Files to Create

### `OnboardingView.swift`

```swift
import SwiftUI
import AVFoundation
import ScreenCaptureKit

struct OnboardingView: View {
    @AppStorage("onboardingComplete") private var onboardingComplete = false
    @State private var currentStep = 0

    var body: some View {
        VStack(spacing: 0) {
            // Progress dots
            HStack(spacing: 8) {
                ForEach(0..<4) { i in
                    Circle()
                        .fill(i == currentStep ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.top, 24)

            // Step content
            Group {
                switch currentStep {
                case 0: MicPermissionStep(onNext: { currentStep = 1 })
                case 1: ScreenRecordingStep(onNext: { currentStep = 2 })
                case 2: APIKeyStep(onNext: { currentStep = 3 })
                case 3: OutputFolderStep(onDone: {
                    onboardingComplete = true
                    // Register login item
                    try? SMAppService.mainApp.register()
                    NSApp.windows.first?.close()
                })
                default: EmptyView()
                }
            }
            .padding(32)
        }
        .frame(width: 480, height: 380)
    }
}

// MARK: - Step 1: Microphone

struct MicPermissionStep: View {
    let onNext: () -> Void
    @State private var granted = false
    @State private var denied = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "mic.circle.fill")
                .font(.system(size: 56))
                .foregroundColor(.accentColor)

            Text("Microphone Access")
                .font(.title2.bold())

            Text("TranscribeMeeting needs microphone access to record your voice during meetings.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            if denied {
                Button("Open System Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                }
                .buttonStyle(.borderedProminent)
            } else if granted {
                Label("Access granted", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Button("Continue →", action: onNext)
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Grant Access →") {
                    AVCaptureDevice.requestAccess(for: .audio) { success in
                        DispatchQueue.main.async {
                            granted = success
                            denied = !success
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

// MARK: - Step 2: Screen Recording

struct ScreenRecordingStep: View {
    let onNext: () -> Void
    @State private var checking = false
    @State private var granted = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "record.circle")
                .font(.system(size: 56))
                .foregroundColor(.accentColor)

            Text("Screen Recording Access")
                .font(.title2.bold())

            Text("To capture audio from Google Meet, Zoom, and other apps, we need Screen Recording permission. We only record audio — never video.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            if granted {
                Label("Access granted", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Button("Continue →", action: onNext)
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Grant Access →") {
                    // Trigger the ScreenCaptureKit permission prompt
                    Task {
                        do {
                            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                            await MainActor.run { granted = true }
                        } catch {
                            // Open System Settings if denied
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)

                Button("Skip (mic only)") { onNext() }
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Step 3: API Key

struct APIKeyStep: View {
    let onNext: () -> Void
    @AppStorage("anthropicApiKey") private var apiKey = ""
    @State private var testing = false
    @State private var testResult: TestResult? = nil
    @State private var inputKey = ""

    enum TestResult { case success, failure(String) }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "key.fill")
                .font(.system(size: 56))
                .foregroundColor(.accentColor)

            Text("Anthropic API Key")
                .font(.title2.bold())

            Text("Used to generate meeting summaries with Claude. Get your key at console.anthropic.com")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            SecureField("sk-ant-...", text: $inputKey)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)

            HStack(spacing: 12) {
                Button("Test Key") {
                    testing = true
                    testResult = nil
                    Task {
                        do {
                            let client = TranscribeClient()
                            _ = try await client.summarise(
                                transcript: "Test",
                                apiKey: inputKey,
                                model: "claude-haiku-4-5"
                            )
                            await MainActor.run {
                                testResult = .success
                                apiKey = inputKey
                                testing = false
                            }
                        } catch {
                            await MainActor.run {
                                testResult = .failure(error.localizedDescription)
                                testing = false
                            }
                        }
                    }
                }
                .disabled(inputKey.isEmpty || testing)

                Button("Continue →") {
                    apiKey = inputKey
                    onNext()
                }
                .buttonStyle(.borderedProminent)
                .disabled(inputKey.isEmpty)
            }

            if let result = testResult {
                switch result {
                case .success:
                    Label("API key works!", systemImage: "checkmark.circle.fill").foregroundColor(.green)
                case .failure(let msg):
                    Label(msg, systemImage: "xmark.circle.fill").foregroundColor(.red)
                }
            }

            Button("Skip for now") { onNext() }
                .foregroundColor(.secondary)
                .font(.caption)
        }
    }
}

// MARK: - Step 4: Output Folder

struct OutputFolderStep: View {
    let onDone: () -> Void
    @AppStorage("outputFolderPath") private var outputFolderPath = ""
    @State private var selectedFolder: URL? = nil

    private var displayPath: String {
        if let url = selectedFolder { return url.path }
        if !outputFolderPath.isEmpty { return outputFolderPath }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Meetings").path
    }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "folder.fill")
                .font(.system(size: 56))
                .foregroundColor(.accentColor)

            Text("Where to Save Meetings")
                .font(.title2.bold())

            Text("Meeting notes will be saved here as markdown files.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            HStack {
                Text(displayPath)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Browse…") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.canCreateDirectories = true
                    panel.prompt = "Choose Folder"
                    if panel.runModal() == .OK {
                        selectedFolder = panel.url
                    }
                }
            }
            .padding(8)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(6)

            Button("Done — Start Using App →") {
                let path = selectedFolder?.path ?? displayPath
                outputFolderPath = path
                // Create the folder if needed
                try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
                onDone()
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
```

---

### Show onboarding on first launch in `TranscribeMeetingApp.swift`

```swift
@main
struct TranscribeMeetingApp: App {
    @StateObject private var appState = AppState()
    @AppStorage("onboardingComplete") private var onboardingComplete = false

    var body: some Scene {
        // Menu bar
        MenuBarExtra {
            MenuBarView().environmentObject(appState)
        } label: {
            Image(systemName: appState.isRecording ? "record.circle.fill" : "mic")
        }
        .menuBarExtraStyle(.menu)

        // Onboarding window (shows only if not complete)
        Window("Setup", id: "onboarding") {
            OnboardingView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 480, height: 380)
        .windowResizability(.contentSize)
    }
}
```

Add to `AppState.init()`:
```swift
// Show onboarding on first launch
if !UserDefaults.standard.bool(forKey: "onboardingComplete") {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "onboarding" }) {
            window.makeKeyAndOrderFront(nil)
        }
    }
}
```

---

### Update `AppState` to read from `UserDefaults`

```swift
var apiKey: String {
    UserDefaults.standard.string(forKey: "anthropicApiKey") ?? ""
}

var outputFolder: URL {
    let path = UserDefaults.standard.string(forKey: "outputFolderPath") ?? ""
    if path.isEmpty {
        return MeetingPipeline.defaultOutputFolder()
    }
    return URL(fileURLWithPath: path)
}
```

---

## Tests

### Test 1: Fresh install simulation
```
1. Delete UserDefaults: defaults delete com.sumitrk.transcribe-meeting
2. Build and run → onboarding window appears automatically ✅
```

### Test 2: Step-by-step completion
```
Step 1: Click "Grant Access →" → macOS mic prompt appears → Allow → checkmark appears ✅
Step 2: Click "Grant Access →" → macOS screen recording prompt → Allow → checkmark ✅
Step 3: Enter API key → click "Test Key" → "API key works!" label appears ✅
Step 4: Click "Browse…" → choose a folder → click "Done" → window closes ✅
```

### Test 3: Onboarding doesn't repeat
```
1. Complete onboarding
2. Quit and relaunch app
3. Onboarding window should NOT appear ✅
```

### Test 4: Settings persist
```
After onboarding, confirm in Xcode console:
- apiKey is non-empty
- outputFolderPath is the chosen path
```

---

## Done When

- [ ] Onboarding appears automatically on first launch
- [ ] Each step's permission prompt fires correctly
- [ ] API key is tested and stored in UserDefaults
- [ ] Output folder is stored and used by MeetingPipeline
- [ ] Onboarding doesn't show again after completion
- [ ] Full pipeline still works after onboarding (end-to-end test)

---

**Next:** `plans/step-06-settings-window.md`
