import SwiftUI

/// The HUD's one pill. Whatever it shows — the recording bars, the processing wave, the paste
/// hint, an error — it's the same black capsule, which grows or shrinks to the new content
/// while the old content blurs out, so states follow each other without the pill leaving.
struct RecordingPillView: View {
    let model: HUDPillModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HUDShadowContainer {
            content
                .background(.black, in: .capsule)
                .clipShape(.capsule)
        }
        .scaleEffect(model.isPresented || reduceMotion ? 1 : 0.9)
        .opacity(model.isPresented ? 1 : model.isLeaving ? 0 : 0.9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: model.alignment)
    }

    /// `if`, not `switch`, so recording and processing share one bars view and its motion
    /// carries across the change instead of starting over.
    @ViewBuilder
    private var content: some View {
        if model.content.showsWaveform {
            RecordingBarsView(meter: model.content.meter, isProcessing: model.content == .processing)
                .frame(width: 36, height: 20)
                .padding(.horizontal, 6)
                .padding(.vertical, 8)
                .transition(.blurReplace)
        } else if case .pasteHint(let reason) = model.content {
            PasteHintView(reason: reason)
                .transition(.blurReplace)
        } else if case .message(let message, let isError) = model.content {
            StatusMessageView(message: message, isError: isError)
                .transition(.blurReplace)
        }
    }
}

/// Shown briefly when auto-paste is not possible (no focused text input).
/// Lets the user know the transcript is ready on the clipboard.
private struct PasteHintView: View {
    let reason: RecordingIndicatorWindow.PasteHintReason

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if reason == .accessibilityMissing {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .font(.system(size: 11, weight: .semibold))
            }

            VStack(alignment: .leading, spacing: 2) {
                switch reason {
                case .manualPasteOnly:
                    HStack(spacing: 4) {
                        Text("Copied")
                            .foregroundStyle(.white.opacity(0.55))
                        Text("·")
                            .foregroundStyle(.white.opacity(0.3))
                        Text("⌘V to paste")
                            .foregroundStyle(.white)
                    }

                case .accessibilityMissing:
                    Text("No Accessibility permission")
                        .foregroundStyle(.white)
                    Text("Open Settings to grant access · ⌘V to paste")
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .font(.system(size: 12, weight: .medium))
        .fixedSize()
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

private struct StatusMessageView: View {
    let message: String
    let isError: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "xmark.circle.fill")
                .foregroundStyle(isError ? .red : .secondary)
            Text(message)
                .foregroundStyle(.white)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        // No frame: the window offers the widest pill, and text reports only the width it
        // uses, so a short message stays a short pill and a long one wraps at the window.
    }
}
