import AppKit
import SwiftUI
import Testing
@testable import NotAnIsland

@MainActor
struct NotchRenderingTests {
    // The notch must render as true black (0, 0, 0) so it matches the camera housing as closely as the display allows.
    @Test func notchIsDrawnInPureBlack() throws {
        let presentation = NotchPresentation(activities: [])
        presentation.shapeSize = CGSize(width: 180, height: 32)
        let view = NotchHostingView(rootView: NotchView(presentation: presentation, onHide: {}, onQuit: {}))
        view.frame = CGRect(x: 0, y: 0, width: 180, height: 32)
        view.layoutSubtreeIfNeeded()

        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let pixel = try #require(bitmap.colorAt(x: 90, y: 10)?.usingColorSpace(.sRGB))

        #expect(pixel.redComponent == 0)
        #expect(pixel.greenComponent == 0)
        #expect(pixel.blueComponent == 0)
        #expect(pixel.alphaComponent == 1)
    }
}
