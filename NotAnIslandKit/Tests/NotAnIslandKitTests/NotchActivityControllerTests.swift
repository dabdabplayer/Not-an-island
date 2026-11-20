import Foundation
import Testing
@testable import NotAnIslandKit

@MainActor
struct NotchActivityControllerTests {
    private final class Sent {
        var messages: [ExtensionMessage] = []
    }

    private let sent = Sent()
    private let sizes = NotchActivitySizes(compactSideWidth: 40, minimal: CGSize(width: 24, height: 24))

    private func connected(isActive: Bool = false) -> NotchActivityController {
        let controller = NotchActivityController(isActive: isActive, sizes: sizes)
        let sent = sent
        controller.connect { sent.messages.append($0) }
        return controller
    }

    @Test func connectingReportsTheCurrentState() {
        _ = connected(isActive: true)
        #expect(sent.messages == [.activityChanged(activityID: NotchActivityController.activityID, isActive: true, sizes: sizes)])
    }

    @Test func changesAreSentOnlyWhenSomethingChanged() {
        let controller = connected()
        controller.isActive = true
        controller.isActive = true
        controller.sizes.compactSideWidth = 50

        #expect(sent.messages.count == 3)
        #expect(sent.messages.last == .activityChanged(
            activityID: NotchActivityController.activityID,
            isActive: true,
            sizes: NotchActivitySizes(compactSideWidth: 50, minimal: CGSize(width: 24, height: 24))
        ))
    }

    @Test func changesBeforeConnectingArriveWithTheFirstReport() {
        let controller = NotchActivityController(sizes: sizes)
        controller.isActive = true
        let sent = sent
        controller.connect { sent.messages.append($0) }

        #expect(sent.messages == [.activityChanged(activityID: NotchActivityController.activityID, isActive: true, sizes: sizes)])
    }

    @Test func bannersAndHoldOpenAreForwarded() {
        let controller = connected()
        controller.postBanner(for: .seconds(4))
        controller.holdOpen(true)

        #expect(sent.messages.suffix(2) == [
            .postBanner(activityID: NotchActivityController.activityID, duration: 4),
            .holdOpen(activityID: NotchActivityController.activityID, held: true),
        ])
    }

    @Test func tracksWhatTheHostShows() {
        let controller = connected()
        controller.handle(.presentationsChanged(visible: [.expanded]))

        #expect(controller.visiblePresentations == [.expanded])
    }

    @Test func disconnectingForgetsVisibility() {
        let controller = connected()
        controller.handle(.presentationsChanged(visible: [.expanded]))
        controller.disconnect()

        #expect(!controller.isConnected)
        #expect(controller.visiblePresentations.isEmpty)
    }
}
