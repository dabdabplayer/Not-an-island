import AppKit
import Testing
@testable import NotAnIsland

@MainActor
struct NotchPanelTests {
    private let notchRect = CGRect(x: 645.5, y: 924, width: 179, height: 32)

    // AppKit snaps window frames to whole points, so the panel uses the enclosing integral rect
    // (same centre as the notch) rather than letting creation and resizing round differently.
    private let enclosingFrame = CGRect(x: 645, y: 924, width: 180, height: 32)

    @Test func panelCoversNotchWithEnclosingWholePointFrame() {
        #expect(NotchPanel(notchRect: notchRect).frame == enclosingFrame)
    }

    @Test func movingPanelKeepsTheSameEnclosingFrame() {
        let panel = NotchPanel(notchRect: CGRect(x: 0, y: 0, width: 100, height: 20))
        panel.cover(notchRect: notchRect)

        #expect(panel.frame == enclosingFrame)
    }

    @Test func panelSitsAboveMenuBarWithoutChrome() {
        let panel = NotchPanel(notchRect: notchRect)

        #expect(panel.level.rawValue > NSWindow.Level.mainMenu.rawValue)
        #expect(panel.styleMask.contains(.borderless))
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(!panel.isOpaque)
        #expect(panel.backgroundColor == .clear)
        #expect(!panel.hasShadow)
    }

    @Test func panelNeverTakesFocusFromTheActiveApp() {
        let panel = NotchPanel(notchRect: notchRect)

        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
    }

    @Test func panelStaysOnEverySpaceAndOverFullScreenApps() {
        let behavior = NotchPanel(notchRect: notchRect).collectionBehavior

        #expect(behavior.contains(.canJoinAllSpaces))
        #expect(behavior.contains(.fullScreenAuxiliary))
        #expect(behavior.contains(.stationary))
        #expect(behavior.contains(.ignoresCycle))
    }
}

struct NotchContentLayoutTests {
    private let expandedSize = CGSize(width: 260, height: 47)

    // SwiftUI content keeps one fixed size; only its position changes as the panel grows or shrinks,
    // so a window resize is never folded into the shape's expand/collapse animation.
    @Test func contentIsCentredAndTopAlignedInCompactPanel() {
        let frame = NotchWindowController.contentFrame(
            in: CGRect(x: 0, y: 0, width: 180, height: 32),
            contentSize: expandedSize
        )

        #expect(frame == CGRect(x: -40, y: -15, width: 260, height: 47))
    }

    @Test func contentFillsExpandedPanel() {
        let frame = NotchWindowController.contentFrame(
            in: CGRect(x: 0, y: 0, width: 260, height: 47),
            contentSize: expandedSize
        )

        #expect(frame == CGRect(x: 0, y: 0, width: 260, height: 47))
    }
}
