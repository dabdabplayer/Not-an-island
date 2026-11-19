import AppKit
import SwiftUI
import Testing
@testable import NotAnIsland

struct IslandGeometryTests {
    private let externalFrame = CGRect(x: 1470, y: 0, width: 2560, height: 1440)

    @Test func islandIsCentredInTheMenuBar() {
        let geometry = NotchGeometry(islandAtTopOf: externalFrame, menuBarHeight: 24)

        #expect(geometry.kind == .island)
        #expect(geometry.notchRect.midX == externalFrame.midX)
        #expect(geometry.notchRect.width == NotchGeometry.islandWidth)
        // Inset from the top edge and shorter than the menu bar, so it reads as a floating pill.
        #expect(geometry.notchRect.maxY == externalFrame.maxY - NotchGeometry.islandInset)
        #expect(geometry.notchRect.height == 24 - 2 * NotchGeometry.islandInset)
    }

    @Test func islandFollowsTheScreenOrigin() {
        let left = CGRect(x: -1920, y: 200, width: 1920, height: 1080)
        let geometry = NotchGeometry(islandAtTopOf: left, menuBarHeight: 24)

        #expect(geometry.notchRect.midX == left.midX)
        #expect(geometry.notchRect.maxY == left.maxY - NotchGeometry.islandInset)
    }

    @Test func islandIsNeverShorterThanTheMinimum() {
        let geometry = NotchGeometry(islandAtTopOf: externalFrame, menuBarHeight: 0)
        #expect(geometry.notchRect.height == NotchGeometry.minimumIslandHeight)
    }

    @Test func notchedScreensKeepTheNotchKind() throws {
        let geometry = try #require(NotchGeometry(
            screenFrame: CGRect(x: 0, y: 0, width: 1470, height: 956),
            topInset: 32,
            leftAuxiliaryWidth: 645.5,
            rightAuxiliaryWidth: 645.5
        ))
        #expect(geometry.kind == .notch)
    }

    @Test func expandedIslandHangsFromTheIslandTop() {
        let geometry = NotchGeometry(islandAtTopOf: externalFrame, menuBarHeight: 24)
        let expanded = geometry.expandedRect(contentSize: CGSize(width: 380, height: 184))

        #expect(expanded.maxY == geometry.notchRect.maxY)
        #expect(expanded.midX == geometry.notchRect.midX)
        #expect(expanded.height == geometry.notchRect.height + 184)
    }
}

@MainActor
final class FakeNotchScreens {
    var screens: [NotchScreen] = []
}

@MainActor
struct NotchScreensTests {
    private let builtIn = NotchScreen(
        id: 1,
        geometry: NotchGeometry(
            screenFrame: CGRect(x: 0, y: 0, width: 1470, height: 956),
            topInset: 32,
            leftAuxiliaryWidth: 645.5,
            rightAuxiliaryWidth: 645.5
        )!
    )
    private let external = NotchScreen(id: 2, geometry: NotchGeometry(islandAtTopOf: CGRect(x: 1470, y: 0, width: 2560, height: 1440), menuBarHeight: 24))
    private let source = FakeNotchScreens()

    private func makeController() -> NotchWindowController {
        let source = source
        return NotchWindowController(activities: [], moments: NotchMoments(), screens: { source.screens })
    }

    @Test func everyScreenGetsItsOwnPanel() {
        source.screens = [builtIn, external]
        let controller = makeController()
        controller.start()
        defer { controller.stop() }

        #expect(controller.screenIDs == [1, 2])
        #expect(controller.panelFrame(for: 1) == builtIn.geometry.notchRect.integral)
        #expect(controller.panelFrame(for: 2) == external.geometry.notchRect.integral)
    }

    @Test func unpluggingAScreenRemovesOnlyItsPanel() {
        source.screens = [builtIn, external]
        let controller = makeController()
        controller.start()
        defer { controller.stop() }

        source.screens = [builtIn]
        controller.screensDidChange()

        #expect(controller.screenIDs == [1])
        #expect(controller.panelFrame(for: 2) == nil)
    }

    @Test func pluggingInAScreenAddsAPanel() {
        source.screens = [builtIn]
        let controller = makeController()
        controller.start()
        defer { controller.stop() }

        source.screens = [builtIn, external]
        controller.screensDidChange()

        #expect(controller.screenIDs == [1, 2])
    }

    @Test func movedScreenMovesItsPanel() {
        source.screens = [external]
        let controller = makeController()
        controller.start()
        defer { controller.stop() }

        let moved = NotchScreen(id: 2, geometry: NotchGeometry(islandAtTopOf: CGRect(x: -2560, y: 0, width: 2560, height: 1440), menuBarHeight: 24))
        source.screens = [moved]
        controller.screensDidChange()

        #expect(controller.panelFrame(for: 2) == moved.geometry.notchRect.integral)
    }

    @Test func noScreensMeansNoPanels() {
        let controller = makeController()
        controller.start()
        defer { controller.stop() }

        #expect(controller.screenIDs.isEmpty)
    }
}

@MainActor
struct IslandRenderingTests {
    private func render(kind: NotchGeometry.Kind) throws -> NSBitmapImageRep {
        let presentation = NotchPresentation(activities: [])
        presentation.kind = kind
        presentation.notchSize = CGSize(width: 126, height: 22)
        presentation.shapeSize = CGSize(width: 126, height: 22)
        let view = NotchHostingView(rootView: NotchView(presentation: presentation, onHide: {}, onQuit: {}))
        view.frame = CGRect(x: 0, y: 0, width: 126, height: 22)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    @Test func islandIsPureBlack() throws {
        let pixel = try #require(try render(kind: .island).colorAt(x: 63, y: 11)?.usingColorSpace(.sRGB))
        #expect(pixel.redComponent == 0)
        #expect(pixel.greenComponent == 0)
        #expect(pixel.blueComponent == 0)
        #expect(pixel.alphaComponent == 1)
    }

    // A notch is flush with the top of the screen; an island is rounded all the way round.
    @Test func islandTopCornersAreRoundedButTheNotchsAreNot() throws {
        let islandCorner = try #require(try render(kind: .island).colorAt(x: 0, y: 0))
        let notchCorner = try #require(try render(kind: .notch).colorAt(x: 0, y: 0))
        #expect(islandCorner.alphaComponent == 0)
        #expect(notchCorner.alphaComponent == 1)
    }
}
