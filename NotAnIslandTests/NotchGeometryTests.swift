import CoreGraphics
import Testing
@testable import NotAnIsland

struct NotchGeometryTests {
    // Values measured from a 14" MacBook Pro built-in display.
    private let builtInFrame = CGRect(x: 0, y: 0, width: 1470, height: 956)

    @Test func notchRectSitsBetweenAuxiliaryAreasAtTopOfScreen() throws {
        let geometry = try #require(NotchGeometry(
            screenFrame: builtInFrame,
            topInset: 32,
            leftAuxiliaryWidth: 645.5,
            rightAuxiliaryWidth: 645.5
        ))

        #expect(geometry.notchRect == CGRect(x: 645.5, y: 924, width: 179, height: 32))
    }

    @Test func notchRectIsOffsetByScreenOriginInGlobalCoordinates() throws {
        let frame = CGRect(x: -1470, y: 200, width: 1470, height: 956)
        let geometry = try #require(NotchGeometry(
            screenFrame: frame,
            topInset: 32,
            leftAuxiliaryWidth: 645.5,
            rightAuxiliaryWidth: 645.5
        ))

        #expect(geometry.notchRect == CGRect(x: -824.5, y: 1124, width: 179, height: 32))
    }

    @Test func expandedRectGrowsAroundNotchCentreWhileStayingAtTopOfScreen() throws {
        let geometry = try #require(NotchGeometry(
            screenFrame: builtInFrame,
            topInset: 32,
            leftAuxiliaryWidth: 645.5,
            rightAuxiliaryWidth: 645.5
        ))

        // 179×32 scaled by 1.45 is 259.55×46.4, centred on x = 735 and hanging from the top edge (y = 956).
        #expect(geometry.expandedRect(scale: 1.45).integral == CGRect(x: 605, y: 909, width: 260, height: 47))
        #expect(geometry.expandedRect(scale: 1) == geometry.notchRect)
    }

    @Test func compactRectWidensBothSidesOfTheNotch() throws {
        let geometry = try #require(NotchGeometry(
            screenFrame: builtInFrame, topInset: 32, leftAuxiliaryWidth: 645.5, rightAuxiliaryWidth: 645.5
        ))

        #expect(geometry.compactRect(sideWidth: 36) == CGRect(x: 609.5, y: 924, width: 251, height: 32))
    }

    @Test func expandedContentHangsBelowTheCameraBand() throws {
        let geometry = try #require(NotchGeometry(
            screenFrame: builtInFrame, topInset: 32, leftAuxiliaryWidth: 645.5, rightAuxiliaryWidth: 645.5
        ))

        #expect(geometry.expandedRect(contentSize: CGSize(width: 380, height: 136))
            == CGRect(x: 545, y: 788, width: 380, height: 168))
        // Content narrower than the notch still covers the camera.
        #expect(geometry.expandedRect(contentSize: CGSize(width: 100, height: 20)).width == 179)
    }

    @Test func screenWithoutTopInsetHasNoNotch() {
        #expect(NotchGeometry(screenFrame: builtInFrame, topInset: 0, leftAuxiliaryWidth: 645.5, rightAuxiliaryWidth: 645.5) == nil)
    }

    @Test func screenWithoutAuxiliaryAreasHasNoNotch() {
        #expect(NotchGeometry(screenFrame: builtInFrame, topInset: 32, leftAuxiliaryWidth: nil, rightAuxiliaryWidth: 645.5) == nil)
        #expect(NotchGeometry(screenFrame: builtInFrame, topInset: 32, leftAuxiliaryWidth: 645.5, rightAuxiliaryWidth: nil) == nil)
    }

    @Test func auxiliaryAreasCoveringWholeWidthMeanNoNotch() {
        #expect(NotchGeometry(screenFrame: builtInFrame, topInset: 32, leftAuxiliaryWidth: 735, rightAuxiliaryWidth: 735) == nil)
    }
}
