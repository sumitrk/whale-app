import Observation
import SwiftUI

/// The state the HUD window hands its one SwiftUI view. The window changes it inside
/// `withAnimation`, so every change — appearing, morphing, leaving — is animated by SwiftUI.
@MainActor
@Observable
final class HUDPillModel {
    var content: HUDPillContent = .processing
    var isPresented = false
    /// Leaving shrinks to 90% and fades out completely; arriving starts from 50% scale and
    /// 90% opacity.
    var isLeaving = false
    /// Where the pill sits in the window, which is sized for the widest pill: the corner nearest
    /// the field or pointer it belongs to, so the pill grows away from it.
    var alignment: Alignment = .topLeading
}
