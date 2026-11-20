import AppKit
import os
import SwiftUI

/// Borderless panel that sits over the notch without ever taking focus from the active app.
final class NotchPanel: NSPanel {
    init(notchRect: CGRect) {
        super.init(
            contentRect: notchRect.integral,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
    }

    /// AppKit snaps window frames to whole points; the enclosing integral rect keeps the notch's centre.
    func cover(notchRect: CGRect) {
        setFrame(notchRect.integral, display: true)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The panel can never become key, so every click is a "first mouse" click. Without this,
/// the first click on a control would only be swallowed.
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Gives every display its own notch panel: the real notch on a notched screen, an island elsewhere.
/// All panels show the same activities and moments; each one expands on its own under the pointer.
@MainActor
final class NotchWindowController: NSObject {
    nonisolated static let expansionScale: CGFloat = 1.45

    private let activities: NotchActivities
    private let moments: NotchMoments
    private let screens: @MainActor () -> [NotchScreen]
    private var controllers: [CGDirectDisplayID: NotchScreenController] = [:]
    private var isExpanded = false

    /// - Parameter activities: In priority order; the first active one with compact content owns the wings.
    init(
        activities: NotchActivities,
        moments: NotchMoments,
        screens: @escaping @MainActor () -> [NotchScreen] = NotchScreen.all
    ) {
        self.activities = activities
        self.moments = moments
        self.screens = screens
        super.init()
    }

    var screenIDs: [CGDirectDisplayID] { controllers.keys.sorted() }

    func panelFrame(for id: CGDirectDisplayID) -> CGRect? {
        controllers[id]?.panelFrame
    }

    func start() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        moments.isSuppressed = { [weak self] in self?.isExpanded ?? false }
        moments.onChange = { [weak self] moment in
            self?.controllers.values.forEach { $0.momentDidChange(moment) }
        }
        screensDidChange()
    }

    func stop() {
        NotificationCenter.default.removeObserver(self, name: NSApplication.didChangeScreenParametersNotification, object: nil)
        controllers.values.forEach { $0.stop() }
        controllers = [:]
        updateExpansion()
    }

    /// Keeps every screen's notch open, or releases it; for content outside the panel's own views.
    func setHeldOpen(_ held: Bool) {
        controllers.values.forEach { $0.setHeldOpen(held) }
    }

    @objc private func screenParametersDidChange(_ notification: Notification) {
        screensDidChange()
    }

    /// Adds, moves and removes panels to match the connected displays.
    func screensDidChange() {
        let current = screens()
        let currentIDs = Set(current.map(\.id))
        for (id, controller) in controllers where !currentIDs.contains(id) {
            controller.stop()
            controllers[id] = nil
        }
        for screen in current {
            if let controller = controllers[screen.id] {
                controller.update(geometry: screen.geometry)
            } else {
                let controller = NotchScreenController(
                    geometry: screen.geometry,
                    activities: activities,
                    moments: moments,
                    onExpansionChange: { [weak self] expanded in self?.screenDidChangeExpansion(expanded) }
                )
                controllers[screen.id] = controller
                controller.start()
            }
        }
        // A removed screen may have been the expanded one.
        updateExpansion()
    }

    private func screenDidChangeExpansion(_ expanded: Bool) {
        if expanded {
            // The expanded panel takes over from any banner.
            moments.dismiss()
        }
        updateExpansion()
    }

    /// Activities see one notch: expanded while any screen's panel is.
    private func updateExpansion() {
        let expanded = controllers.values.contains { $0.isExpanded }
        guard expanded != isExpanded else { return }
        isExpanded = expanded
        for activity in activities.ordered {
            activity.notchDidChangeExpansion(expanded)
        }
    }

    // MARK: Layout

    /// The notch's main shape: the wings, the expanded notch, or a banner. The bubble is separate.
    nonisolated static func frame(for state: NotchState, geometry: NotchGeometry) -> CGRect {
        let compact = state.compactActivity == nil
            ? geometry.notchRect
            : geometry.compactRect(sideWidth: state.compactSideWidth)

        if state.isExpanded {
            guard !state.sections.isEmpty else { return geometry.expandedRect(scale: expansionScale) }
            var width = state.sections.map(\.size.width).max() ?? 0
            let height = state.sections.reduce(0) { $0 + $1.size.height }
            // Expanded from the bubble, the notch must still reach the pointer resting where the bubble was.
            if let bubble = state.bubble, bubble.activity == state.focus {
                let bubbleRect = geometry.bubbleRect(besides: compact, size: bubble.size)
                width = max(width, 2 * (bubbleRect.maxX - geometry.notchRect.midX))
            }
            return geometry.expandedRect(contentSize: CGSize(width: width, height: height))
        }

        guard let moment = state.momentSize else { return compact }
        return geometry.expandedRect(contentSize: CGSize(width: max(moment.width, compact.width), height: moment.height))
    }

    /// The bubble beside the compact wings; none while expanded.
    nonisolated static func bubbleFrame(for state: NotchState, geometry: NotchGeometry) -> CGRect? {
        guard !state.isExpanded, let bubble = state.bubble else { return nil }
        let compact = state.compactActivity == nil
            ? geometry.notchRect
            : geometry.compactRect(sideWidth: state.compactSideWidth)
        return geometry.bubbleRect(besides: compact, size: bubble.size)
    }

    /// Everything the panel must cover in a state: the main shape and the bubble.
    nonisolated static func panelFrame(for state: NotchState, geometry: NotchGeometry) -> CGRect {
        let main = frame(for: state, geometry: geometry)
        return bubbleFrame(for: state, geometry: geometry).map(main.union) ?? main
    }

    /// The SwiftUI canvas is sized once to fit every state, so it never resizes during an animation.
    /// It is centred on the notch, so its width covers the farthest reach on either side.
    nonisolated static func canvasSize(geometry: NotchGeometry, activities: [NotchActivityMetrics]) -> CGSize {
        let everything = activities.enumerated().map { NotchActivityLayout(id: "\($0.offset)", metrics: $0.element) }
        // The widest wings with the largest bubble beside them, whichever activities those come from.
        let widestBubble = NotchState(
            compactActivity: "wings",
            compactSideWidth: activities.compactMap(\.compactSideWidth).max() ?? 0,
            bubble: activities.compactMap(\.minimalSize).max { $0.width < $1.width }.map { NotchBubble(activity: "bubble", size: $0) }
        )
        let states = [
            NotchState.make(isExpanded: true, activities: everything, momentSize: nil),
            NotchState.make(isExpanded: true, activities: [], momentSize: nil),
            NotchState.make(isExpanded: false, activities: everything, momentSize: NotchMoment.maximumSize),
            widestBubble,
        ]
        let midX = geometry.notchRect.midX
        return states.reduce(.zero) { size, state in
            let frame = panelFrame(for: state, geometry: geometry)
            let halfWidth = max(midX - frame.minX, frame.maxX - midX)
            return CGSize(width: max(size.width, 2 * halfWidth), height: max(size.height, frame.height))
        }
    }

    /// SwiftUI content keeps one fixed size, centred on the notch and hanging from the top of the panel;
    /// the panel clips it. A window resize therefore never reaches SwiftUI, where it would be animated
    /// together with the shape and make one side lead the other.
    /// - Parameter centreX: The notch's centre in the container; the container's own centre if nil.
    nonisolated static func contentFrame(in containerBounds: CGRect, centreX: CGFloat? = nil, contentSize: CGSize) -> CGRect {
        CGRect(
            x: (centreX ?? containerBounds.midX) - contentSize.width / 2,
            y: containerBounds.maxY - contentSize.height,
            width: contentSize.width,
            height: contentSize.height
        )
    }
}

/// One display's panel: keeps it aligned with that screen's notch or island, and runs its
/// hover expansion, activity transitions and moments.
@MainActor
final class NotchScreenController {
    /// Debug-level, so it costs nothing unless streamed: `/usr/bin/log stream --level debug --predicate 'subsystem == "app.arysha.NotAnIsland"'`
    private static let logger = Logger(subsystem: "app.arysha.NotAnIsland", category: "Notch")

    private let activities: NotchActivities
    private let moments: NotchMoments
    private let onExpansionChange: (Bool) -> Void
    private let presentation: NotchPresentation
    private var geometry: NotchGeometry
    private var panel: NotchPanel?
    private var hostingView: NSView?
    private var trackingView: NotchTrackingView?
    private var observedActivities: [NotchActivityLayout]?
    private lazy var hover: NotchHoverModel = {
        let model = NotchHoverModel(isPointerInside: { [weak self] in
            guard let panel = self?.panel else { return false }
            return panel.frame.contains(NSEvent.mouseLocation)
        })
        model.onExpansionChange = { [weak self] expanded in
            guard let self else { return }
            Self.logger.debug("Hover \(expanded ? "expands" : "collapses", privacy: .public) the \(String(describing: self.geometry.kind), privacy: .public)")
            onExpansionChange(expanded)
            transition(to: makeState(isExpanded: expanded))
        }
        return model
    }()

    init(geometry: NotchGeometry, activities: NotchActivities, moments: NotchMoments, onExpansionChange: @escaping (Bool) -> Void) {
        self.geometry = geometry
        self.activities = activities
        self.moments = moments
        self.onExpansionChange = onExpansionChange
        presentation = NotchPresentation(activities: activities)
    }

    var isExpanded: Bool { hover.isExpanded }
    var panelFrame: CGRect? { panel?.frame }

    func start() {
        presentation.state = makeState(isExpanded: false)
        presentation.bubble = bubblePlacement(for: presentation.state)
        if let moment = moments.current {
            presentation.moment = moment
        }
        layOut()
        observeActivities()
    }

    func stop() {
        panel?.orderOut(nil)
        panel = nil
        hostingView = nil
        trackingView = nil
    }

    func update(geometry: NotchGeometry) {
        guard geometry != self.geometry else { return }
        self.geometry = geometry
        layOut()
    }

    func setHeldOpen(_ held: Bool) {
        hover.setHeldOpen(held)
    }

    func momentDidChange(_ moment: NotchMoment?) {
        if let moment {
            presentation.moment = moment
        }
        transition(to: makeState(isExpanded: presentation.state.isExpanded))
    }

    private func currentActivities() -> [NotchActivityLayout] {
        activities.activeLayouts
    }

    private func makeState(isExpanded: Bool) -> NotchState {
        NotchState.make(
            isExpanded: isExpanded,
            focus: isExpanded ? hover.focus : nil,
            activities: currentActivities(),
            momentSize: moments.current?.size
        )
    }

    /// Where the bubble sits relative to the top centre of the notch, which is where the canvas hangs from.
    private func bubblePlacement(for state: NotchState) -> NotchBubblePlacement? {
        guard let bubble = state.bubble, let rect = NotchWindowController.bubbleFrame(for: state, geometry: geometry) else {
            return nil
        }
        let notch = geometry.notchRect
        return NotchBubblePlacement(
            activity: bubble.activity,
            size: rect.size,
            offset: CGSize(width: rect.midX - notch.midX, height: notch.maxY - rect.maxY)
        )
    }

    /// Follows activities starting, stopping, or changing the room they need (for example, narrowing while idle).
    private func observeActivities() {
        let snapshot = withObservationTracking {
            currentActivities()
        } onChange: { [weak self] in
            // Fires before the change is applied; read the new values on the next main-actor turn.
            Task { @MainActor in self?.observeActivities() }
        }
        guard panel != nil, snapshot != observedActivities else { return }
        observedActivities = snapshot
        growCanvasIfNeeded()
        transition(to: makeState(isExpanded: presentation.state.isExpanded))
    }

    /// The canvas only ever grows, and only between animations, so SwiftUI never sees it resize mid-animation.
    private func growCanvasIfNeeded() {
        let needed = NotchWindowController.canvasSize(geometry: geometry, activities: activities.ordered.map(\.metrics))
        let current = presentation.canvasSize
        guard needed.width > current.width || needed.height > current.height else { return }
        presentation.canvasSize = CGSize(width: max(needed.width, current.width), height: max(needed.height, current.height))
        if let panel {
            coverPanel(panel.frame)
        }
    }

    private func frame(for state: NotchState) -> CGRect {
        NotchWindowController.panelFrame(for: state, geometry: geometry)
    }

    private func layOut() {
        presentation.kind = geometry.kind
        presentation.notchSize = geometry.notchRect.size
        presentation.canvasSize = NotchWindowController.canvasSize(geometry: geometry, activities: activities.ordered.map(\.metrics))
        let frame = frame(for: presentation.state)
        presentation.shapeSize = NotchWindowController.frame(for: presentation.state, geometry: geometry).size
        presentation.bubble = bubblePlacement(for: presentation.state)

        if panel == nil {
            let newPanel = NotchPanel(notchRect: frame)
            newPanel.contentView = makeContentView()
            newPanel.orderFrontRegardless()
            panel = newPanel
        }
        coverPanel(frame)
    }

    /// Resizes the panel, re-positions the fixed-size SwiftUI canvas over the notch inside it,
    /// and gives the bubble its own hover region.
    private func coverPanel(_ rect: CGRect) {
        guard let panel else { return }
        panel.cover(notchRect: rect)
        let origin = panel.frame.origin
        if let container = panel.contentView, let hostingView {
            hostingView.frame = NotchWindowController.contentFrame(
                in: container.bounds,
                centreX: geometry.notchRect.midX - origin.x,
                contentSize: presentation.canvasSize
            )
        }
        let state = presentation.state
        if let bubble = state.bubble, let rect = NotchWindowController.bubbleFrame(for: state, geometry: geometry) {
            trackingView?.bubble = NotchTrackingView.Bubble(activity: bubble.activity, rect: rect.offsetBy(dx: -origin.x, dy: -origin.y))
        } else {
            trackingView?.bubble = nil
        }
    }

    private func makeContentView() -> NSView {
        let container = NotchTrackingView()
        container.onPointerEntered = { [weak self] bubble in
            Self.logger.debug("Pointer entered \(bubble.map { "the \($0) bubble" } ?? "the notch", privacy: .public)")
            self?.hover.pointerEntered(focus: bubble)
        }
        container.onPointerExited = { [weak self] speed in
            Self.logger.debug("Pointer exited at \(speed ?? -1, privacy: .public) pt/s")
            self?.hover.pointerExited(speed: speed)
        }

        let rootView = NotchView(
            presentation: presentation,
            onHide: { NSApp.hide(nil) },
            onQuit: { NSApp.terminate(nil) }
        )
        .environment(\.notchHoldOpen, NotchHoldOpenAction { [weak self] held in self?.hover.setHeldOpen(held) })
        .environment(\.notchSurface, ObjectIdentifier(presentation))
        let hostingView = NotchHostingView(rootView: rootView)
        // The engine owns the panel's frame; SwiftUI must not resize the window to fit its content.
        hostingView.sizingOptions = []
        container.addSubview(hostingView)
        self.hostingView = hostingView
        trackingView = container
        return container
    }

    // MARK: Transitions

    /// The panel first grows to cover both the current and the target shape, the shape animates,
    /// and only then does the panel shrink to the target. The shape is never clipped mid-animation
    /// and the window never lags behind it.
    private func transition(to state: NotchState) {
        guard let panel else {
            presentation.state = state
            return
        }
        let target = frame(for: state)
        Self.logger.debug("Transition to \(String(describing: state), privacy: .public), target \(String(describing: target), privacy: .public)")
        coverPanel(panel.frame.union(target))

        let shapeSize = NotchWindowController.frame(for: state, geometry: geometry).size
        let bubble = bubblePlacement(for: state)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            presentation.state = state
            presentation.shapeSize = shapeSize
            presentation.bubble = bubble
            coverPanel(target)
            return
        }

        withAnimation(.smooth(duration: 0.3), completionCriteria: .removed) {
            presentation.state = state
            presentation.shapeSize = shapeSize
            presentation.bubble = bubble
        } completion: { [weak self] in
            guard let self else { return }
            guard presentation.state == state else {
                Self.logger.debug("Transition to \(String(describing: state), privacy: .public) superseded")
                return
            }
            coverPanel(frame(for: state))
            Self.logger.debug("Transition finished; panel \(String(describing: self.panel?.frame), privacy: .public)")
        }
    }
}

/// Reports pointer entry and exit over the notch, with the pointer's speed as it leaves.
/// Tracking lives on a plain view because NSHostingView manages its own tracking areas, and the owner
/// must be an NSResponder so the handlers are real overrides of the selectors AppKit sends.
final class NotchTrackingView: NSView {
    /// A bubble's hover region, in this view's coordinates.
    struct Bubble: Equatable {
        var activity: String
        var rect: CGRect
    }

    static let bubbleKey = "bubble"

    /// Called with the activity whose bubble was entered, or nil for the notch itself.
    var onPointerEntered: (String?) -> Void = { _ in }
    /// Speed in points per second, or nil if no movement was seen inside the notch.
    var onPointerExited: (Double?) -> Void = { _ in }

    /// With a bubble, the notch region stops short of the gap before it, so the gap expands nothing.
    var bubble: Bubble? {
        didSet {
            guard bubble != oldValue else { return }
            updateTrackingAreas()
        }
    }

    private var speedTracker = PointerSpeedTracker()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        updateTrackingAreas()
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        // `.activeAlways` is required: this agent app is never the active app.
        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .mouseMoved, .activeAlways]
        guard let bubble else {
            addTrackingArea(NSTrackingArea(rect: .zero, options: options.union(.inVisibleRect), owner: self, userInfo: nil))
            super.updateTrackingAreas()
            return
        }
        var notch = bounds
        notch.size.width = max(bubble.rect.minX - NotchGeometry.bubbleGap - bounds.minX, 0)
        addTrackingArea(NSTrackingArea(rect: notch, options: options, owner: self, userInfo: nil))
        addTrackingArea(NSTrackingArea(rect: bubble.rect, options: options, owner: self, userInfo: [Self.bubbleKey: bubble.activity]))
        super.updateTrackingAreas()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func mouseEntered(with event: NSEvent) {
        speedTracker.reset()
        speedTracker.record(screenLocation(of: event), at: event.timestamp)
        onPointerEntered(event.trackingArea?.userInfo?[Self.bubbleKey] as? String)
    }

    override func mouseMoved(with event: NSEvent) {
        speedTracker.record(screenLocation(of: event), at: event.timestamp)
    }

    override func mouseExited(with event: NSEvent) {
        onPointerExited(speedTracker.speed(exitingAt: screenLocation(of: event), time: event.timestamp))
    }

    /// Screen coordinates stay stable while the panel resizes under the pointer; window coordinates don't.
    private func screenLocation(of event: NSEvent) -> CGPoint {
        window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
    }
}

/// Where the bubble sits, relative to the top centre of the notch.
struct NotchBubblePlacement: Equatable {
    var activity: String
    var size: CGSize
    var offset: CGSize
}

@MainActor
@Observable
final class NotchPresentation {
    let activities: NotchActivities
    var kind: NotchGeometry.Kind = .notch
    var state = NotchState()
    var shapeSize: CGSize = .zero
    var notchSize: CGSize = .zero
    var canvasSize: CGSize = .zero
    var bubble: NotchBubblePlacement?
    /// The latest moment. Kept after it ends so its content can fade out with the shape.
    var moment: NotchMoment?

    init(activities: NotchActivities) {
        self.activities = activities
    }
}

struct NotchView: View {
    @Environment(\.openSettings) private var openSettings
    let presentation: NotchPresentation
    let onHide: () -> Void
    let onQuit: () -> Void

    var body: some View {
        // A notch is flush with the top of the screen; an island is rounded all the way round.
        let topRadius = presentation.kind == .island ? cornerRadius : 0
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: topRadius,
            bottomLeadingRadius: cornerRadius,
            bottomTrailingRadius: cornerRadius,
            topTrailingRadius: topRadius
        )

        ZStack(alignment: .top) {
            ZStack(alignment: .top) {
                shape.fill(.black)
                if presentation.state.isExpanded {
                    expandedContent
                } else {
                    compactContent
                }
            }
            .frame(width: presentation.shapeSize.width, height: presentation.shapeSize.height)
            .clipShape(shape)
            .contextMenu { menu }

            if let bubble = presentation.bubble, let activity = presentation.activities[bubble.activity] {
                ZStack {
                    Capsule().fill(.black)
                    activity.minimalView()
                }
                .frame(width: bubble.size.width, height: bubble.size.height)
                .clipShape(Capsule())
                .contextMenu { menu }
                .offset(bubble.offset)
                .transition(.opacity.combined(with: .scale(scale: 0.5)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var menu: some View {
        Button("Settings…") {
            // An agent app's windows open behind the frontmost app unless it activates first.
            NSApp.activate()
            openSettings()
        }
        Divider()
        Button("Hide Not an Island", action: onHide)
        Button("Quit Not an Island", action: onQuit)
    }

    private var cornerRadius: CGFloat {
        let state = presentation.state
        if state.isExpanded {
            return state.sections.isEmpty ? 14 : 22
        }
        if state.momentSize != nil {
            return 18
        }
        // The compact island is a capsule.
        return presentation.kind == .island ? presentation.notchSize.height / 2 : 8
    }

    @ViewBuilder
    private var expandedContent: some View {
        let sections = presentation.state.sections
        if !sections.isEmpty {
            VStack(spacing: 0) {
                ForEach(sections, id: \.activity) { section in
                    presentation.activities[section.activity]?.expandedView()
                        .frame(width: section.size.width, height: section.size.height)
                }
            }
            .padding(.top, presentation.notchSize.height)
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var compactContent: some View {
        let state = presentation.state
        let notch = presentation.notchSize
        VStack(spacing: 0) {
            if let owner = state.compactActivity, let activity = presentation.activities[owner] {
                // Without a banner, derived from the animated shape width so the content moves with the edges.
                let sideWidth = state.momentSize == nil
                    ? max((presentation.shapeSize.width - notch.width) / 2, 0)
                    : state.compactSideWidth
                HStack(spacing: 0) {
                    activity.compactLeadingView()
                        .frame(width: sideWidth)
                    Color.clear
                        .frame(width: notch.width)
                    activity.compactTrailingView()
                        .frame(width: sideWidth)
                }
                .frame(height: notch.height)
            } else {
                Color.clear.frame(height: notch.height)
            }

            if let momentSize = state.momentSize, let moment = presentation.moment {
                moment.content
                    .frame(width: momentSize.width, height: momentSize.height)
                    .transition(.opacity)
            }
        }
        .transition(.opacity)
    }
}
