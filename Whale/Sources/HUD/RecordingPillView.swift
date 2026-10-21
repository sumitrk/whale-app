import SwiftUI

/// The live recording HUD: the bars on the dark capsule.
struct RecordingPillView: View {
    let meter: MicLevelMeter

    var body: some View {
        RecordingBarsView(meter: meter)
            .frame(width: 36, height: 20)
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
            .background(.black.opacity(0.72), in: .capsule)
    }
}
