import Observation
import SwiftUI

/// The state the HUD window hands its one SwiftUI view. The window changes `content` inside
/// `withAnimation`, so SwiftUI morphs the pill between states; arriving and leaving are Core
/// Animation on the window's layer.
@MainActor
@Observable
final class HUDPillModel {
    var content: HUDPillContent = .processing
    /// False while the window is ordered out. The bars' animation clock stops then: it kept
    /// drawing every frame into the hidden window otherwise.
    var isVisible = false
    /// Where the pill sits in the window, which is sized for the widest pill: the corner nearest
    /// the field or pointer it belongs to, so the pill grows away from it.
    var alignment: Alignment = .topLeading
}
