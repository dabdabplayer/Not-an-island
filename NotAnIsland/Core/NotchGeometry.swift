import AppKit

/// The physical camera housing's position, in global screen coordinates.
struct NotchGeometry: Equatable, Sendable {
    let notchRect: CGRect

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
    }

    /// The notch scaled around its horizontal centre, still hanging from the top edge of the screen.
    func expandedRect(scale: CGFloat) -> CGRect {
        hangingRect(width: notchRect.width * scale, height: notchRect.height * scale)
    }

    /// The notch widened on both sides; compact content sits beside the camera, never over it.
    func compactRect(sideWidth: CGFloat) -> CGRect {
        notchRect.insetBy(dx: -sideWidth, dy: 0)
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
    @MainActor
    init?(screen: NSScreen) {
        self.init(
            screenFrame: screen.frame,
            topInset: screen.safeAreaInsets.top,
            leftAuxiliaryWidth: screen.auxiliaryTopLeftArea?.width,
            rightAuxiliaryWidth: screen.auxiliaryTopRightArea?.width
        )
    }
}
