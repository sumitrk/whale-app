import XCTest
@testable import Whale

/// The HUD's script, through a recording surface: what shows for each event, and for how long.
@MainActor
final class HUDTests: XCTestCase {
    private var surface: RecordingSurface!
    private var hud: HUD!
    private let meter = MicLevelMeter()

    override func setUp() async throws {
        surface = RecordingSurface()
        hud = HUD(surface: surface)
    }

    func testDictationShowsBarsThenTheWaveThenLeavesOnceInserted() {
        hud.update(.recording(.dictation, meter))
        hud.update(.processing(.dictation))
        hud.update(.delivered(.inserted))

        XCTAssertEqual(surface.calls, [
            .show(.recording(meter), dismissAfter: nil),
            .show(.processing, dismissAfter: nil),
            .hide,
        ])
    }

    func testAMeetingRecordsWithoutAPill() {
        hud.update(.recording(.transcriptMode, meter))
        hud.update(.processing(.transcriptMode))
        hud.update(.finished)

        XCTAssertEqual(surface.calls, [.hide, .hide, .hide])
    }

    func testCopiedTextBecomesThePasteHintForTwoSeconds() {
        hud.update(.delivered(.copied(.accessibilityMissing)))

        XCTAssertEqual(surface.calls, [.show(.pasteHint(.accessibilityMissing), dismissAfter: 2)])
    }

    func testAReplacedAIActionLeavesWithoutAMessage() {
        hud.update(.cancelled(replaced: true))

        XCTAssertEqual(surface.calls, [.hide])
    }

}

@MainActor
private final class RecordingSurface: HUDSurface {
    var calls: [HUDPresentation] = []

    func present(_ content: HUDPillContent, dismissAfter: TimeInterval?) {
        calls.append(.show(content, dismissAfter: dismissAfter))
    }

    func hide() {
        calls.append(.hide)
    }
}
