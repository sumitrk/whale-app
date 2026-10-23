import AppKit
import Combine
import CoreGraphics
import FluidAudio
import Foundation
import SwiftUI

/// Wires the app together: the shortcuts, the one capture module, onboarding and launch.
/// Holds no capture state of its own; `capture` does.
@MainActor
class AppState: ObservableObject {
    let recorder = AudioRecorder()
    let hotkey   = HotkeyManager()
    let accessibility: AccessibilityController
    let openRouterClient = OpenRouterClient()
    let openRouterConnection = OpenRouterConnection()
    let capture: CaptureController

    private let settings = SettingsStore.shared
    private let transcriber = LocalTranscriptionService.shared
    private let history = HistoryController.shared
    private var cancellables = Set<AnyCancellable>()
    private let onboarding = OnboardingWindowController()
    /// Until launch has loaded History and the model, shortcuts do nothing.
    private var isPreparing = true

    init(
        accessibility: AccessibilityController,
        pipelineFactory: (() -> TranscriptionPipeline)? = nil
    ) {
        self.accessibility = accessibility
        var canStart: () -> Bool = { false }
        self.capture = CaptureController(
            recorder: recorder,
            models: LocalCaptureModels(transcriber: .shared),
            history: HistoryController.shared,
            hud: HUD.shared,
            handlers: [
                .dictation: DictationHandler(),
                .transcriptMode: TranscriptModeHandler(settings: .shared),
                .aiAction: AIActionHandler(client: openRouterClient, settings: .shared),
            ],
            pipelineFactory: pipelineFactory ?? {
                // Rebuilt per recording, so a settings change applies to the next one.
                TranscriptionPipeline(stages: [
                    // VoiceActivityDetectionStage(),
                    TranscriptionStage(transcriber: LocalTranscriptionService.shared),
                    SmartFormattingStage(),
                    PersonalDictionaryStage(dictionary: SettingsStore.shared.personalDictionary),
                ])
            },
            deliver: { TextInsertionManager.insertOrCopy($0) },
            selectedModel: { SettingsStore.shared.selectedBuiltInModelID },
            canStart: { canStart() }
        )
        canStart = { [weak self] in self?.isPreparing == false }

        Task { await prepareApp() }
        Task.detached(priority: .utility) { RemovedCleanupModel.deleteIfPresent(.current) }

        Publishers.CombineLatest4(
            settings.$toggleKeyCode,
            settings.$toggleModifiers,
            settings.$pttKeyCode,
            settings.$pttModifiers
        )
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _, _ in self?.rebuildHotkeys() }
            .store(in: &cancellables)

        Publishers.CombineLatest(settings.$aiActionKeyCode, settings.$aiActionModifiers)
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.rebuildHotkeys() }
            .store(in: &cancellables)

        accessibility.$isTrusted
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildHotkeys() }
            .store(in: &cancellables)

        accessibility.startMonitoring(promptOnLaunch: settings.hasCompletedOnboarding)
        rebuildHotkeys()

        if !settings.hasCompletedOnboarding {
            presentOnboardingAfterLaunch()
        }
    }

    /// Onboarding is the app's only foreground UI, so it is presented once and closed
    /// once; `OnboardingWindowController` owns the window and the activation policy that
    /// goes with it.
    private func presentOnboarding() {
        onboarding.present {
            OnboardingView { [weak self] in self?.onboarding.close() }
                .environmentObject(self)
                .environmentObject(accessibility)
        }
    }

    /// `AppState` is built inside `App.init`, before AppKit has finished launching. A
    /// window ordered front that early races the system's own launch activation — and
    /// that activation is the whole reason onboarding comes up focused — so wait for
    /// the launch to finish before showing it.
    private func presentOnboardingAfterLaunch() {
        var observer: NSObjectProtocol?
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            if let observer { NotificationCenter.default.removeObserver(observer) }
            MainActor.assumeIsolated { self?.presentOnboarding() }
        }
    }

    var isRecording: Bool { capture.phase.isRecording }

    // MARK: - Hotkey setup

    private func rebuildHotkeys() {
        let toggleFlags = NSEvent.ModifierFlags(rawValue: UInt(settings.toggleModifiers))
        let pttFlags = NSEvent.ModifierFlags(rawValue: UInt(settings.pttModifiers))
        let actionFlags = NSEvent.ModifierFlags(rawValue: UInt(settings.aiActionModifiers))

        let capture = capture
        hotkey.rebuild(
            toggleKeyCode: settings.toggleKeyCode,
            toggleModifiers: toggleFlags,
            pttKeyCode: settings.pttKeyCode,
            pttModifiers: pttFlags,
            actionKeyCode: settings.aiActionKeyCode,
            actionModifiers: actionFlags,
            mode: .full,
            onToggle: {
                if capture.phase.intent == .transcriptMode {
                    capture.release(.transcriptMode)
                } else {
                    Task { await capture.start(.transcriptMode) }
                }
            },
            onPTTPress: { [weak self] in
                guard let self else { return }
                if self.settings.dictationKeyMode == .toggle, capture.phase.intent == .dictation {
                    capture.release(.dictation)
                    return
                }
                guard !capture.isBusy else { return }
                if !self.accessibility.isTrusted { self.accessibility.refresh() }
                Task { await capture.start(.dictation) }
            },
            onPTTRelease: { [weak self] in
                guard self?.settings.dictationKeyMode == .hold else { return }
                capture.release(.dictation)
            },
            onActionPress: {
                Task { await capture.start(.aiAction) }
            },
            onActionRelease: {
                capture.release(.aiAction)
            },
            onActionCancel: {
                guard capture.phase.intent == .aiAction else { return }
                Task { await capture.cancel() }
            },
            onEscape: {
                Task { await capture.cancelFromEscape() }
            }
        )
    }

    /// The menu's stop button, for whichever capture is recording.
    func stopRecording() {
        guard let intent = capture.phase.intent else { return }
        capture.release(intent)
    }

    func startClipboardOnlyDictation() {
        guard !capture.isBusy else { return }
        accessibility.refresh()
        Task { await capture.start(.dictation) }
    }

    // MARK: - Startup

    private func prepareApp() async {
        HUD.shared.update(.preparing)
        defer {
            HUD.shared.update(.finished)
            isPreparing = false
        }

        AppRuntimeInfo.migrateSandboxDataIfNeeded()
        recorder.prepareMicrophoneCapture()
        FeedbackSound.preload()

        do {
            try await history.prepare()
        } catch {
            DiagnosticLog.log("[Startup] History unavailable: \(error.localizedDescription)")
            return
        }
        // Runs in the background, so verifying the key costs the first AI
        // Action nothing.
        openRouterConnection.verifyNow()

        if AppRuntimeInfo.current.shouldResetParakeetCacheOnLaunch {
            do {
                try await transcriber.resetModel(.parakeetEnglishV2)
                DiagnosticLog.log("[Parakeet] Reset model cache on launch via \(AppRuntimeInfo.resetParakeetCacheEnvironmentKey).")
            } catch {
                DiagnosticLog.log("[Parakeet] Failed to reset model cache on launch: \(error.localizedDescription)")
            }
        }

        let modelStore = TranscriptionModelStore.shared
        await modelStore.refreshNow()

        let modelID = settings.selectedBuiltInModelID
        if modelStore.isReady(for: modelID) {
            do {
                try await modelStore.prepare(modelID)
            } catch {
                DiagnosticLog.log("[Startup] Failed to prepare \(modelID.rawValue): \(error.localizedDescription)")
            }
        }
    }
}
