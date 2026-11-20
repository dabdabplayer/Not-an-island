import Foundation
import Testing
@testable import NotAnIslandKit

struct NotchMessageTests {
    private let sizes = NotchActivitySizes(
        compactSideWidth: 40,
        expanded: CGSize(width: 300, height: 80),
        minimal: CGSize(width: 24, height: 24),
        banner: CGSize(width: 240, height: 44)
    )

    @Test func extensionMessagesSurviveTheWire() throws {
        let messages: [ExtensionMessage] = [
            .activityChanged(activityID: "default", isActive: true, sizes: sizes),
            .postBanner(activityID: "default", duration: 3),
            .holdOpen(activityID: "default", held: true),
        ]
        for message in messages {
            #expect(try NotchWire.decode(ExtensionMessage.self, from: NotchWire.encode(message)) == message)
        }
    }

    @Test func hostMessagesSurviveTheWire() throws {
        let messages: [HostMessage] = [
            .hello(protocolVersion: NotchWire.majorVersion),
            .presentationsChanged(visible: [.compactLeading, .compactTrailing]),
        ]
        for message in messages {
            #expect(try NotchWire.decode(HostMessage.self, from: NotchWire.encode(message)) == message)
        }
    }

    // A newer extension must not be half-understood: the host refuses its messages outright.
    @Test func newerMajorVersionIsRejected() throws {
        let future = try JSONSerialization.data(withJSONObject: ["major": NotchWire.majorVersion + 1, "message": [:]])
        #expect(throws: NotchWire.Error.newerVersion(NotchWire.majorVersion + 1)) {
            try NotchWire.decode(ExtensionMessage.self, from: future)
        }
    }

    @Test func sceneIDsAreStable() {
        // Published extensions name their scenes with these strings; changing one breaks them all.
        #expect(NotchScene.allCases.map(\.rawValue) == ["compact-leading", "compact-trailing", "minimal", "expanded", "banner"])
        #expect(NotchWire.extensionPointID == "app.arysha.NotAnIsland.activity")
    }
}
