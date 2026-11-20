import AppKit
import QuartzCore
import SwiftUI

struct MusicArtworkView: View {
    let artwork: CGImage?
    let cornerRadius: CGFloat

    var body: some View {
        Group {
            if let artwork {
                Image(decorative: artwork, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.12)
                    Image(systemName: "music.note")
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// While paused for a while, compact content steps back: it dims and shrinks with the notch.
private struct IdleDimming: ViewModifier {
    let isIdle: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isIdle ? 0.4 : 1)
            .animation(.smooth(duration: 0.4), value: isIdle)
    }
}

struct MusicCompactArtwork: View {
    let music: MusicActivity

    var body: some View {
        let size: CGFloat = music.isIdle ? 18 : 22
        MusicArtworkView(artwork: music.artwork, cornerRadius: 5)
            .frame(width: size, height: size)
            .modifier(IdleDimming(isIdle: music.isIdle))
    }
}

struct MusicCompactVisualizer: View {
    let music: MusicActivity

    var body: some View {
        // Paused long enough: the bars leave entirely rather than dimming with the artwork.
        MusicVisualizer(isPlaying: music.isPlaying, colors: music.artworkColors)
            .opacity(music.isIdle ? 0 : 1)
            .animation(.smooth(duration: 0.4), value: music.isIdle)
    }
}

/// Music's bubble: the artwork in a circle, ringed by short bars in the artwork's colours that
/// pulse while playing. Like the compact bars, the ring is decorative and doesn't follow the audio.
struct MusicMinimalView: View {
    let music: MusicActivity

    private static let tickCount = 12
    private static let artworkInset: CGFloat = 5

    var body: some View {
        let colors = music.artworkColors.isEmpty ? [NSColor.white] : music.artworkColors
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !music.isPlaying)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            Canvas { graphics, size in
                let centre = CGPoint(x: size.width / 2, y: size.height / 2)
                let outer = min(size.width, size.height) / 2 - 0.5
                let inner = outer - Self.artworkInset + 1.5
                for tick in 0..<Self.tickCount {
                    let angle = Double(tick) / Double(Self.tickCount) * 2 * .pi
                    let pulse = music.isPlaying ? 0.5 + 0.5 * abs(sin(time * 2.4 + Double(tick) * 1.7)) : 0.35
                    let start = inner
                    let end = inner + (outer - inner) * pulse
                    var path = Path()
                    path.move(to: CGPoint(x: centre.x + cos(angle) * start, y: centre.y + sin(angle) * start))
                    path.addLine(to: CGPoint(x: centre.x + cos(angle) * end, y: centre.y + sin(angle) * end))
                    let color = Color(nsColor: colors[tick % colors.count])
                    graphics.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                }
            }
        }
        .overlay {
            MusicArtworkView(artwork: music.artwork, cornerRadius: 0)
                .clipShape(Circle())
                .padding(Self.artworkInset)
        }
        .modifier(IdleDimming(isIdle: music.isIdle))
        .accessibilityElement()
        .accessibilityLabel(Text("Music"))
    }
}

/// Decorative waveform bars filled with a gradient of the artwork's colours, in the style of the
/// Dynamic Island. They do not reflect the actual audio.
struct MusicVisualizer: NSViewRepresentable {
    let isPlaying: Bool
    let colors: [NSColor]

    func makeNSView(context: Context) -> WaveformBarsView {
        WaveformBarsView()
    }

    func updateNSView(_ view: WaveformBarsView, context: Context) {
        let motion: WaveformBarsView.Motion = if !isPlaying {
            .stopped
        } else if context.environment.accessibilityReduceMotion {
            .still
        } else {
            .animating
        }
        view.update(colors: colors, motion: motion)
    }
}

/// Bars driven by Core Animation: their motion runs in the render server, so playing music
/// doesn't wake the app every frame the way a SwiftUI timeline would. The bars are a mask over a
/// single gradient, so neighbouring bars blend from one colour into the next.
final class WaveformBarsView: NSView {
    enum Motion: Equatable {
        case animating
        /// Reduce Motion: bars hold varied heights instead of moving.
        case still
        case stopped
    }

    static let barCount = 4
    static let animationKey = "waveform"
    private static let settleKey = "settle"
    private static let barWidth: CGFloat = 3
    private static let barSpacing: CGFloat = 2
    private static let maximumHeight: CGFloat = 14
    private static let stoppedScale: CGFloat = 0.22
    private static let stillScales: [CGFloat] = [0.55, 0.85, 0.4, 0.7]
    /// Each bar cycles through its own heights at its own pace, so together they never visibly repeat.
    private static let patterns: [[CGFloat]] = [
        [0.35, 1, 0.5, 0.8, 0.3, 0.9, 0.35],
        [0.8, 0.4, 1, 0.3, 0.7, 0.5, 0.8],
        [0.5, 0.9, 0.3, 1, 0.45, 0.75, 0.5],
        [0.3, 0.7, 0.95, 0.4, 0.85, 0.35, 0.3],
    ]
    private static let durations: [CFTimeInterval] = [1.1, 0.9, 1.3, 1.0]
    static let frameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)

    let gradientLayer = CAGradientLayer()
    private(set) var barLayers: [CALayer] = []
    private let barMask = CALayer()
    private var motion: Motion?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Layout and state changes are applied directly; motion comes only from explicit animations.
        // Colour changes keep their implicit crossfade, so a new track's palette blends in.
        let fixedGeometry: [String: any CAAction] = ["position": NSNull(), "bounds": NSNull(), "transform": NSNull()]
        gradientLayer.startPoint = CGPoint(x: 0, y: 0.5)
        gradientLayer.endPoint = CGPoint(x: 1, y: 0.5)
        gradientLayer.actions = fixedGeometry
        barMask.actions = fixedGeometry
        gradientLayer.mask = barMask
        layer?.addSublayer(gradientLayer)

        barLayers = (0..<Self.barCount).map { _ in
            let bar = CALayer()
            bar.cornerRadius = Self.barWidth / 2
            bar.backgroundColor = NSColor.white.cgColor  // Only its shape matters: it reveals the gradient.
            bar.actions = fixedGeometry
            barMask.addSublayer(bar)
            return bar
        }
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: NSSize {
        let count = CGFloat(Self.barCount)
        return NSSize(width: count * Self.barWidth + (count - 1) * Self.barSpacing, height: Self.maximumHeight)
    }

    override func layout() {
        super.layout()
        let size = intrinsicContentSize
        gradientLayer.frame = CGRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
        barMask.frame = gradientLayer.bounds
        var x: CGFloat = 0
        for bar in barLayers {
            bar.bounds = CGRect(x: 0, y: 0, width: Self.barWidth, height: Self.maximumHeight)
            bar.position = CGPoint(x: x + Self.barWidth / 2, y: Self.maximumHeight / 2)
            x += Self.barWidth + Self.barSpacing
        }
    }

    func update(colors: [NSColor], motion: Motion) {
        // A gradient needs at least two stops; a single colour fills every bar evenly.
        let stops = (colors.count == 1 ? colors + colors : colors).map(\.cgColor)
        if gradientLayer.colors as? [CGColor] != stops {
            gradientLayer.colors = stops
        }

        guard motion != self.motion else { return }
        self.motion = motion
        for (index, bar) in barLayers.enumerated() {
            let current = bar.presentation()?.value(forKeyPath: "transform.scale.y") as? CGFloat
            bar.removeAnimation(forKey: Self.animationKey)

            switch motion {
            case .animating:
                let animation = CAKeyframeAnimation(keyPath: "transform.scale.y")
                animation.values = Self.patterns[index]
                animation.duration = Self.durations[index]
                animation.calculationMode = .cubic
                animation.repeatCount = .infinity
                // Small bars look just as smooth at 30 fps, and the screen needn't recomposite at up to 120 Hz.
                animation.preferredFrameRateRange = Self.frameRateRange
                bar.transform = CATransform3DIdentity
                bar.add(animation, forKey: Self.animationKey)
            case .still, .stopped:
                let scale = motion == .still ? Self.stillScales[index] : Self.stoppedScale
                bar.transform = CATransform3DMakeScale(1, scale, 1)
                // Glide from wherever the bar was rather than snapping.
                if let current {
                    let settle = CABasicAnimation(keyPath: "transform.scale.y")
                    settle.fromValue = current
                    settle.toValue = scale
                    settle.duration = 0.25
                    settle.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    bar.add(settle, forKey: Self.settleKey)
                }
            }
        }
    }
}

/// Picks the colours for the waveform bars from the album artwork.
enum ArtworkPalette {
    static let maximumColors = 3
    static let minimumBrightness: CGFloat = 0.75
    private static let sampleSize = 8
    /// Below this, a sample isn't colourful enough to stand out in the gradient.
    private static let minimumVividness: CGFloat = 0.15
    /// Colours closer in hue than this (about 30°) would blend into a near-flat gradient.
    private static let minimumHueSeparation: CGFloat = 0.08

    /// The artwork's most vivid, distinct colours, brightened so they read clearly on the black notch.
    /// Always returns at least two, so there is a gradient to blend.
    static func colors(of image: CGImage) -> [NSColor] {
        let samples = sampledColors(of: image)
        guard !samples.isEmpty else { return [.white, NSColor(white: 0.75, alpha: 1)] }

        var picked: [NSColor] = []
        let vivid = samples
            .filter { vividness($0) >= minimumVividness }
            .sorted { vividness($0) > vividness($1) }
        for color in vivid where picked.count < maximumColors {
            if picked.allSatisfy({ hueDistance($0, color) >= minimumHueSeparation }) {
                picked.append(color)
            }
        }
        if picked.isEmpty {
            picked = [average(of: samples)]
        }

        let legible = picked.map(legibleOnBlack)
        guard legible.count == 1 else { return legible }
        return legible + [companion(of: legible[0])]
    }

    private static func vividness(_ color: NSColor) -> CGFloat {
        color.saturationComponent * color.brightnessComponent
    }

    private static func hueDistance(_ first: NSColor, _ second: NSColor) -> CGFloat {
        let distance = abs(first.hueComponent - second.hueComponent)
        return min(distance, 1 - distance)
    }

    private static func legibleOnBlack(_ color: NSColor) -> NSColor {
        NSColor(
            colorSpace: .sRGB,
            hue: color.hueComponent,
            saturation: color.saturationComponent,
            brightness: max(color.brightnessComponent, minimumBrightness),
            alpha: 1
        )
    }

    /// A neighbouring shade of the same colour, so single-colour artwork still gets a gentle blend.
    private static func companion(of color: NSColor) -> NSColor {
        NSColor(
            colorSpace: .sRGB,
            hue: (color.hueComponent + 0.05).truncatingRemainder(dividingBy: 1),
            saturation: color.saturationComponent,
            brightness: max(color.brightnessComponent - 0.2, minimumBrightness * 0.8),
            alpha: 1
        )
    }

    private static func average(of colors: [NSColor]) -> NSColor {
        let count = CGFloat(colors.count)
        return NSColor(
            srgbRed: colors.reduce(0) { $0 + $1.redComponent } / count,
            green: colors.reduce(0) { $0 + $1.greenComponent } / count,
            blue: colors.reduce(0) { $0 + $1.blueComponent } / count,
            alpha: 1
        )
    }

    /// Downsamples the artwork to a small grid; each cell is the average of its area.
    private static func sampledColors(of image: CGImage) -> [NSColor] {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: sampleSize,
                  height: sampleSize,
                  bitsPerComponent: 8,
                  bytesPerRow: sampleSize * 4,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return [] }

        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize))
        guard let data = context.data else { return [] }

        let bytes = data.bindMemory(to: UInt8.self, capacity: sampleSize * sampleSize * 4)
        return (0..<sampleSize * sampleSize).compactMap { pixel in
            let alpha = CGFloat(bytes[pixel * 4 + 3]) / 255
            guard alpha > 0 else { return nil }
            return NSColor(
                srgbRed: CGFloat(bytes[pixel * 4]) / 255 / alpha,
                green: CGFloat(bytes[pixel * 4 + 1]) / 255 / alpha,
                blue: CGFloat(bytes[pixel * 4 + 2]) / 255 / alpha,
                alpha: 1
            )
        }
    }
}

struct MusicExpandedView: View {
    let music: MusicActivity

    // The list sits below the controls and is clipped to the section, so it is uncovered
    // as the section grows instead of being drawn over the controls.
    var body: some View {
        VStack(spacing: 0) {
            player
                .frame(height: MusicActivity.expandedHeight)
            if music.isOutputPickerOpen {
                AudioOutputList(outputs: music.outputs, onSelect: music.selectOutput)
                    .padding(.horizontal, 12)
                    .padding(.top, MusicActivity.outputPickerSpacing)
                    .frame(height: MusicActivity.outputPickerHeight(rows: music.outputs.devices.count), alignment: .top)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        // A zero minimum makes the frame take the section's height exactly, rather than growing to
        // fit the list and being centred, which would shift everything up over the controls.
        .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
        .clipped()
    }

    private var player: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                MusicArtworkView(artwork: music.artwork, cornerRadius: 10)
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(music.info?.name ?? "Unknown Track")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.65))
                }
                .lineLimit(1)
                Spacer(minLength: 0)
                MusicVisualizer(isPlaying: music.isPlaying, colors: music.artworkColors)
            }

            if music.permission == .granted {
                if let playback = music.playback, let duration = music.info?.duration, duration > 0 {
                    MusicScrubber(playback: playback, duration: duration, onSeek: music.seek)
                }
                controls
            } else {
                Text(permissionMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.65))
                    .multilineTextAlignment(.center)
                    .frame(maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var subtitle: String {
        [music.info?.artist, music.info?.album].compactMap(\.self).joined(separator: " — ")
    }

    private var permissionMessage: String {
        switch music.permission {
        case .denied:
            "To use playback controls, allow Not an Island to control Music in System Settings › Privacy & Security › Automation."
        default:
            "Playback controls need permission to control Music."
        }
    }

    private var controls: some View {
        HStack(spacing: 28) {
            controlButton("backward.fill", label: "Previous", size: 16, action: music.previousTrack)
            controlButton(
                music.isPlaying ? "pause.fill" : "play.fill",
                label: music.isPlaying ? "Pause" : "Play",
                size: 22,
                action: music.playPause
            )
            controlButton("forward.fill", label: "Next", size: 16, action: music.nextTrack)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 28)
        .overlay(alignment: .trailing) {
            outputButton
        }
    }

    private var outputButton: some View {
        Button(action: music.toggleOutputPicker) {
            Image(systemName: music.outputs.current?.symbolName ?? "hifispeaker")
                .font(.system(size: 14))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(music.isOutputPickerOpen ? Color.accentColor : .white)
        .accessibilityLabel("Sound Output")
        .accessibilityValue(music.outputs.current?.name ?? "Unknown")
    }

    private func controlButton(_ symbol: String, label: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .frame(width: 36, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .accessibilityLabel(label)
    }
}

struct MusicScrubber: View {
    let playback: PlaybackPosition
    let duration: TimeInterval
    let onSeek: (TimeInterval) -> Void

    @Environment(\.notchHoldOpen) private var holdOpen
    @State private var dragPosition: TimeInterval?

    private static let accessibilityStep: TimeInterval = 10

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.5, paused: !playback.isPlaying || dragPosition != nil)) { context in
            let position = dragPosition ?? playback.position(at: context.date)
            HStack(spacing: 8) {
                timeLabel(position)
                track(position: position)
                timeLabel(duration - position, prefix: "-")
            }
        }
        .frame(height: 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
        .accessibilityValue(accessibilityValue)
        .accessibilityAdjustableAction { direction in
            let current = playback.position(at: .now)
            switch direction {
            case .increment: onSeek(min(current + Self.accessibilityStep, duration))
            case .decrement: onSeek(max(current - Self.accessibilityStep, 0))
            @unknown default: break
            }
        }
    }

    private var accessibilityValue: String {
        "\(Self.formatted(playback.position(at: .now))) of \(Self.formatted(duration))"
    }

    private func track(position: TimeInterval) -> some View {
        GeometryReader { geometry in
            let progress = min(max(position / duration, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25))
                Capsule().fill(.white).frame(width: geometry.size.width * progress)
            }
            .frame(height: dragPosition == nil ? 4 : 6)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragPosition == nil { holdOpen(true) }
                        dragPosition = duration * min(max(value.location.x / geometry.size.width, 0), 1)
                    }
                    .onEnded { _ in
                        if let dragPosition { onSeek(dragPosition) }
                        dragPosition = nil
                        holdOpen(false)
                    }
            )
        }
    }

    private func timeLabel(_ seconds: TimeInterval, prefix: String = "") -> some View {
        Text(prefix + Self.formatted(seconds))
            .font(.system(size: 10).monospacedDigit())
            .foregroundStyle(.white.opacity(0.65))
            .frame(width: 38)
    }

    private static func formatted(_ seconds: TimeInterval) -> String {
        Duration.seconds(max(0, seconds)).formatted(.time(pattern: .minuteSecond))
    }
}

/// The outputs below the controls, with a checkmark on the one in use.
struct AudioOutputList: View {
    let outputs: AudioOutputs
    let onSelect: (AudioOutputDevice) -> Void

    var body: some View {
        if outputs.devices.count > MusicActivity.maxVisibleOutputRows {
            ScrollView(.vertical) {
                rows
            }
            .scrollIndicators(.never)
        } else {
            rows
        }
    }

    private var rows: some View {
        VStack(spacing: 0) {
            if outputs.devices.isEmpty {
                Text("No sound outputs")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(height: MusicActivity.outputRowHeight)
            }
            ForEach(outputs.devices) { device in
                row(device, isSelected: device.id == outputs.currentID)
            }
        }
    }

    private func row(_ device: AudioOutputDevice, isSelected: Bool) -> some View {
        Button {
            onSelect(device)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: device.symbolName)
                    .font(.system(size: 13))
                    .frame(width: 20)
                Text(device.name)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                }
            }
            .padding(.horizontal, 8)
            .frame(height: MusicActivity.outputRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .accessibilityLabel(device.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
