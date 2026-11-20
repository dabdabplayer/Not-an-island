import AppKit

/// Where the notch sits, in global screen coordinates: the physical camera housing, or on a screen
/// without one, an island drawn in the middle of the menu bar.
struct NotchGeometry: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case notch, island
    }

    nonisolated static let islandWidth: CGFloat = 126
    /// The gap above and below the island inside the menu bar.
    nonisolated static let islandInset: CGFloat = 1
    nonisolated static let minimumIslandHeight: CGFloat = 20
    /// Space between the right wing and the bubble.
    nonisolated static let bubbleGap: CGFloat = 6
    /// A bubble is at most this many times wider than it is tall.
    nonisolated static let maximumBubbleAspect: CGFloat = 3

    let notchRect: CGRect
    let kind: Kind

    /// Returns nil for screens without a notch. Only the auxiliary areas' widths are used,
    /// so the result doesn't depend on which coordinate space AppKit reports them in.
    init?(screenFrame: CGRect, topInset: CGFloat, leftAuxiliaryWidth: CGFloat?, rightAuxiliaryWidth: CGFloat?) {
        guard topInset > 0, let leftAuxiliaryWidth, let rightAuxiliaryWidth else { return nil }

        let notchWidth = screenFrame.width - leftAuxiliaryWidth - rightAuxiliaryWidth
        guard notchWidth > 0 else { return nil }

        notchRect = CGRect(
            x: screenFrame.minX + leftAuxiliaryWidth,
            y: screenFrame.maxY - topInset,
            width: notchWidth,
            height: topInset
        )
        kind = .notch
    }

    init(islandAtTopOf screenFrame: CGRect, menuBarHeight: CGFloat) {
        let height = max(menuBarHeight - 2 * Self.islandInset, Self.minimumIslandHeight)
        notchRect = CGRect(
            x: screenFrame.midX - Self.islandWidth / 2,
            y: screenFrame.maxY - Self.islandInset - height,
            width: Self.islandWidth,
            height: height
        )
        kind = .island
    }

    /// The notch scaled around its horizontal centre, still hanging from the top edge of the screen.
    func expandedRect(scale: CGFloat) -> CGRect {
        hangingRect(width: notchRect.width * scale, height: notchRect.height * scale)
    }

    /// The notch widened on both sides; compact content sits beside the camera, never over it.
    func compactRect(sideWidth: CGFloat) -> CGRect {
        notchRect.insetBy(dx: -sideWidth, dy: 0)
    }

    /// A bubble beside the compact wings, centred on the camera band and never taller than it.
    func bubbleRect(besides compact: CGRect, size: CGSize) -> CGRect {
        let height = min(size.height, notchRect.height)
        let width = min(size.width, height * Self.maximumBubbleAspect)
        return CGRect(x: compact.maxX + Self.bubbleGap, y: notchRect.midY - height / 2, width: width, height: height)
    }

    /// A panel whose content area hangs below the camera band, never narrower than the notch itself.
    func expandedRect(contentSize: CGSize) -> CGRect {
        hangingRect(width: max(contentSize.width, notchRect.width), height: notchRect.height + contentSize.height)
    }

    private func hangingRect(width: CGFloat, height: CGFloat) -> CGRect {
        CGRect(x: notchRect.midX - width / 2, y: notchRect.maxY - height, width: width, height: height)
    }
}

extension NotchGeometry {
    /// The notch on a notched screen, otherwise an island in its menu bar.
    @MainActor
    init(screen: NSScreen) {
        if let notch = NotchGeometry(
            screenFrame: screen.frame,
            topInset: screen.safeAreaInsets.top,
            leftAuxiliaryWidth: screen.auxiliaryTopLeftArea?.width,
            rightAuxiliaryWidth: screen.auxiliaryTopRightArea?.width
        ) {
            self = notch
            return
        }
        // The visible frame stops below the menu bar; with the menu bar hidden, use its standard height.
        let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        self.init(
            islandAtTopOf: screen.frame,
            menuBarHeight: menuBarHeight > 0 ? menuBarHeight : NSStatusBar.system.thickness
        )
    }
}

/// A display and where its notch or island sits.
struct NotchScreen: Equatable, Sendable {
    let id: CGDirectDisplayID
    let geometry: NotchGeometry

    /// Every connected display. Mirrored displays appear once.
    @MainActor
    static func all() -> [NotchScreen] {
        NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                return nil
            }
            return NotchScreen(id: id, geometry: NotchGeometry(screen: screen))
        }
    }
}
