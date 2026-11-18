import AppKit
import Testing
@testable import NotAnIsland

struct ArtworkPaletteTests {
    /// Builds an sRGB image of equal-width vertical stripes in the given colours.
    private func image(stripes: [NSColor], size: Int = 48) throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let stripeWidth = CGFloat(size) / CGFloat(stripes.count)
        for (index, color) in stripes.enumerated() {
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: CGFloat(index) * stripeWidth, y: 0, width: stripeWidth, height: CGFloat(size)))
        }
        return try #require(context.makeImage())
    }

    private func srgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }

    private func hues(_ colors: [NSColor]) throws -> [CGFloat] {
        try colors.map { try #require($0.usingColorSpace(.sRGB)).hueComponent }
    }

    private func isRed(_ hue: CGFloat) -> Bool { hue < 0.04 || hue > 0.96 }
    private func isBlue(_ hue: CGFloat) -> Bool { abs(hue - 0.667) < 0.04 }

    @Test func picksDistinctColoursFromTheArtwork() throws {
        let art = try image(stripes: [srgb(0.9, 0.1, 0.1), srgb(0.5, 0.5, 0.5), srgb(0.1, 0.2, 0.9)])
        let hues = try hues(ArtworkPalette.colors(of: art))

        #expect(hues.count == 2)
        #expect(hues.contains(where: isRed))
        #expect(hues.contains(where: isBlue))
    }

    @Test func usesAtMostThreeColours() throws {
        let art = try image(stripes: [
            srgb(0.9, 0.1, 0.1), srgb(0.1, 0.8, 0.2), srgb(0.1, 0.2, 0.9), srgb(0.9, 0.8, 0.1), srgb(0.7, 0.1, 0.8),
        ])

        #expect(ArtworkPalette.colors(of: art).count == ArtworkPalette.maximumColors)
    }

    // A gradient needs two ends, so single-colour artwork still gets a gentle blend of its own hue.
    @Test func singleColourArtworkStillGetsAGradient() throws {
        let navy = srgb(0.05, 0.05, 0.3)
        let colors = ArtworkPalette.colors(of: try image(stripes: [navy]))
        let components = try colors.map { try #require($0.usingColorSpace(.sRGB)) }

        #expect(colors.count == 2)
        #expect(components[0] != components[1])
        #expect(try hues(colors).allSatisfy { abs($0 - 0.667) < 0.1 })
    }

    // Bars sit on a black notch, so dark colours are brightened until they read clearly.
    @Test func everyColourIsBrightEnoughOnBlack() throws {
        let art = try image(stripes: [srgb(0.05, 0.05, 0.3), srgb(0.3, 0.02, 0.02)])

        for color in ArtworkPalette.colors(of: art) {
            #expect(try #require(color.usingColorSpace(.sRGB)).brightnessComponent >= ArtworkPalette.minimumBrightness - 0.01)
        }
    }

    @Test func greyscaleArtworkGivesNeutralColours() throws {
        let art = try image(stripes: [srgb(0.4, 0.4, 0.4), .black])

        for color in ArtworkPalette.colors(of: art) {
            #expect(try #require(color.usingColorSpace(.sRGB)).saturationComponent < 0.05)
        }
    }
}

@MainActor
struct WaveformBarsViewTests {
    private let barKey = WaveformBarsView.animationKey
    private let palette: [NSColor] = [.systemPink, .systemOrange]

    @Test func playingAnimatesEveryBarInCoreAnimation() {
        let view = WaveformBarsView()
        view.update(colors: palette, motion: .animating)

        #expect(view.barLayers.count == WaveformBarsView.barCount)
        #expect(view.barLayers.allSatisfy { $0.animation(forKey: barKey) != nil })
    }

    // A continuous animation otherwise makes the screen recomposite at the display's full rate (up to 120 Hz).
    @Test func barAnimationIsCappedAtThirtyFramesPerSecond() {
        let view = WaveformBarsView()
        view.update(colors: palette, motion: .animating)

        #expect(view.barLayers.allSatisfy {
            $0.animation(forKey: barKey)?.preferredFrameRateRange.maximum == 30
        })
    }

    @Test func pausingStopsTheAnimation() {
        let view = WaveformBarsView()
        view.update(colors: palette, motion: .animating)
        view.update(colors: palette, motion: .stopped)

        #expect(view.barLayers.allSatisfy { $0.animation(forKey: barKey) == nil })
    }

    @Test func reducedMotionShowsStillBars() {
        let view = WaveformBarsView()
        view.update(colors: palette, motion: .still)

        #expect(view.barLayers.allSatisfy { $0.animation(forKey: barKey) == nil })
    }

    // One gradient spans all the bars, so neighbouring bars blend from one colour into the next.
    @Test func barsRevealOneGradientAcrossThePalette() throws {
        let view = WaveformBarsView()
        view.update(colors: palette, motion: .stopped)

        let colors = try #require(view.gradientLayer.colors as? [CGColor])
        #expect(colors == palette.map(\.cgColor))
        #expect(view.gradientLayer.startPoint.x < view.gradientLayer.endPoint.x)
        #expect(view.barLayers.allSatisfy { $0.superlayer === view.gradientLayer.mask })
    }
}
