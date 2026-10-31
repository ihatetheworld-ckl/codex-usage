import AppKit

enum WidgetLayout {
    static let size = NSSize(width: 48, height: 84)
    static let glassInset: CGFloat = 3
    static func anchor(in window: NSRect) -> NSPoint {
        // The user's 56 pt global navigation rail, above download and profile controls.
        NSPoint(x: window.minX + 4, y: window.minY + 104)
    }
}

/// Keep the gauge at its final size while its glass container grows around it.
private final class GaugeBody: NSView {
    let gaugeSize: NSSize
    init(size: NSSize) {
        gaugeSize = size
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        let frame = NSRect(x: bounds.midX - gaugeSize.width / 2, y: bounds.midY - gaugeSize.height / 2,
                           width: gaugeSize.width, height: gaugeSize.height)
        for view in subviews where view.frame != frame { view.frame = frame }
    }
}

/// Transparent window root. Glass has its own rounded shape; no rectangular backdrop is painted.
final class GlassRoot: NSView {
    static let revealDuration: TimeInterval = 0.240
    let body: NSView
    let nativeGlass: Bool
    private var glass: NSView!
    private var revealTimer: Timer?
    private(set) var revealProgress: CGFloat = 1
    var isRevealing: Bool { revealTimer != nil }
    var glassFrame: NSRect { glass.frame }
    override var isOpaque: Bool { false }

    init(size: NSSize) {
        body = GaugeBody(size: NSSize(width: size.width - 6, height: size.height - 6))
        if #available(macOS 26, *) { nativeGlass = true } else { nativeGlass = false }
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true; layer?.backgroundColor = NSColor.clear.cgColor
        let glassFrame = bounds.insetBy(dx: WidgetLayout.glassInset, dy: WidgetLayout.glassInset)
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView(frame: glassFrame)
            glass.style = .clear
            glass.cornerRadius = 18
            glass.tintColor = nil
            glass.contentView = body
            addSubview(glass)
            self.glass = glass
        } else {
            let glass = NSVisualEffectView(frame: glassFrame)
            glass.material = .menu; glass.blendingMode = .behindWindow; glass.state = .active
            glass.wantsLayer = true; glass.layer?.cornerRadius = 18; glass.layer?.masksToBounds = true
            glass.addSubview(body); addSubview(glass)
            self.glass = glass
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Called once, before ordering a previously hidden window on screen.
    /// Animate native glass geometry, never the window's frame or text scale.
    func reveal(reduceMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) {
        finishReveal()
        guard !reduceMotion else { return }
        applyReveal(0)
        let started = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let progress = CGFloat((ProcessInfo.processInfo.systemUptime - started) / Self.revealDuration)
            if progress >= 1 { self.finishReveal() }
            else { self.applyReveal(progress) }
        }
        revealTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Hide/click/drag/mode changes cancel the timer synchronously. No delayed
    /// completion can repaint or resurrect an old appearance after switching away.
    func finishReveal() {
        revealTimer?.invalidate(); revealTimer = nil
        applyReveal(1)
    }

    private func applyReveal(_ rawProgress: CGFloat) {
        let p = min(max(rawProgress, 0), 1)
        revealProgress = p
        func easeOut(_ value: CGFloat) -> CGFloat {
            let t = min(max(value, 0), 1)
            return 1 - pow(1 - t, 3)
        }
        func smooth(_ value: CGFloat) -> CGFloat {
            let t = min(max(value, 0), 1)
            return t * t * (3 - 2 * t)
        }
        let full = bounds.insetBy(dx: WidgetLayout.glassInset, dy: WidgetLayout.glassInset)
        let circle = easeOut(p / 0.5)
        let elongation = easeOut((p - 0.2) / 0.8)
        let width = 6 + (full.width - 6) * circle
        let height = 6 + (full.width - 6) * circle + (full.height - full.width) * elongation
        let radius = min(width / 2, 21 - 3 * elongation)
        // Explicit frames at display cadence keep native glass/refraction shaped
        // correctly, including during an interrupted reveal. No implicit tweening.
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        glass.frame = NSRect(x: full.midX - width / 2, y: full.midY - height / 2,
                             width: width, height: height)
        if #available(macOS 26, *), let native = glass as? NSGlassEffectView {
            native.cornerRadius = radius
        } else {
            glass.layer?.cornerRadius = radius
        }
        glass.layoutSubtreeIfNeeded()
        body.frame = glass.bounds
        body.needsLayout = true
        body.layoutSubtreeIfNeeded()
        body.alphaValue = smooth((p - 0.45) / 0.55)
        glass.alphaValue = smooth(p / 0.1)
        NSAnimationContext.endGrouping()
    }

    deinit { revealTimer?.invalidate() }
}

final class CompactGauge: NSView {
    var onClick: (() -> Void)?
    var onDragged: (() -> Void)?
    var onMenu: (() -> Void)?
    var onInteractionChanged: ((Bool) -> Void)?
    private var short = "—", week = "—"
    private var stale = true
    private var pressPoint: NSPoint?
    private var pressOrigin: NSPoint?
    private var dragged = false
    private var dragCursor = false
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true); setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    func update(short: String, week: String, stale: Bool, tooltip: String) {
        self.short = short; self.week = week; self.stale = stale; toolTip = tooltip
        setAccessibilityLabel("Codex 剩余用量，5 小时 \(short)，本周 \(week)。点击查看详情。")
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let labelColor = NSColor.secondaryLabelColor
        let numberColor = stale ? NSColor.systemOrange : NSColor.labelColor
        func centered(_ text: String, y: CGFloat, font: NSFont, color: NSColor) {
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let width = (text as NSString).size(withAttributes: attributes).width
            (text as NSString).draw(at: NSPoint(x: (bounds.width - width) / 2, y: y), withAttributes: attributes)
        }
        centered("5h", y: 5, font: .systemFont(ofSize: 8, weight: .medium), color: labelColor)
        centered(short, y: 16, font: .monospacedDigitSystemFont(ofSize: 12, weight: .semibold), color: numberColor)
        NSColor.separatorColor.withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: NSRect(x: 13, y: 38, width: bounds.width - 26, height: 0.5), xRadius: 0.25, yRadius: 0.25).fill()
        centered("周", y: 43, font: .systemFont(ofSize: 8, weight: .medium), color: labelColor)
        centered(week, y: 54, font: .monospacedDigitSystemFont(ofSize: 12, weight: .semibold), color: numberColor)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        pressPoint = window.convertPoint(toScreen: event.locationInWindow)
        pressOrigin = window.frame.origin
        dragged = false
        onInteractionChanged?(true)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let window, let start = pressPoint, let origin = pressOrigin else { return }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        let delta = NSPoint(x: point.x - start.x, y: point.y - start.y)
        guard dragged || hypot(delta.x, delta.y) > 3 else { return }
        dragged = true
        if !dragCursor { NSCursor.closedHand.push(); dragCursor = true }
        window.setFrameOrigin(NSPoint(x: origin.x + delta.x, y: origin.y + delta.y))
    }
    override func mouseUp(with event: NSEvent) {
        guard pressPoint != nil else { return }
        let wasDragged = dragged
        pressPoint = nil; pressOrigin = nil; dragged = false
        if dragCursor { NSCursor.pop(); dragCursor = false }
        onInteractionChanged?(false)
        if wasDragged { onDragged?() } else { onClick?() }
    }
    override func rightMouseDown(with event: NSEvent) { onMenu?() }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}

/// Paint menu content directly, so all content participates in NSMenu's actual drawing pass.
/// NSMenu tracks a separate run-loop mode; a standalone Auto Layout preview is insufficient.
final class DetailCard: NSView {
    private var payload: UsagePayload?
    private var freshness = "正在连接…"
    private var stale = true
    private(set) var drawCount = 0
    private let icon = Brand.markImage(size: 28)
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var intrinsicContentSize: NSSize { NSSize(width: 236, height: 180) }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 236, height: 180))
        autoresizingMask = [.width]
        setAccessibilityElement(true)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsDisplay = true
    }

    func update(payload: UsagePayload?, message: String, stale: Bool) {
        self.payload = payload; freshness = message; self.stale = stale
        let short = UsageText.percent(payload?.window(minutes: 300), remaining: true)
        let week = UsageText.percent(payload?.window(minutes: 10080), remaining: true)
        setAccessibilityLabel("Codex Usage，5 小时剩余 \(short)，本周剩余 \(week)，\(message)")
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        drawCount += 1
        func text(_ value: String, x: CGFloat, y: CGFloat, font: NSFont, color: NSColor = .labelColor) {
            (value as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: font, .foregroundColor: color])
        }
        icon.draw(in: NSRect(x: 12, y: 10, width: 28, height: 28), from: .zero, operation: .sourceOver,
                  fraction: 1, respectFlipped: true, hints: nil)
        text("Codex Usage", x: 44, y: 11, font: .systemFont(ofSize: 12, weight: .semibold))
        text("剩余用量", x: 44, y: 27, font: .systemFont(ofSize: 9), color: .secondaryLabelColor)
        func row(_ title: String, window: UsageWindow?, y: CGFloat) {
            text(title, x: 16, y: y + 4, font: .systemFont(ofSize: 11, weight: .medium))
            let value = UsageText.percent(window, remaining: true)
            let font = NSFont.monospacedDigitSystemFont(ofSize: 17, weight: .semibold)
            let width = (value as NSString).size(withAttributes: [.font: font]).width
            text(value, x: bounds.width - 16 - width, y: y, font: font)
            let track = NSRect(x: 16, y: y + 27, width: bounds.width - 32, height: 3)
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: track, xRadius: 1.5, yRadius: 1.5).fill()
            if let remaining = window?.remainingPercent {
                (remaining <= 10 ? NSColor.systemRed : remaining <= 30 ? NSColor.systemOrange : Brand.mint).setFill()
                var fill = track; fill.size.width *= remaining / 100
                NSBezierPath(roundedRect: fill, xRadius: 1.5, yRadius: 1.5).fill()
            }
            text(UsageText.reset(window), x: 16, y: y + 35, font: .systemFont(ofSize: 10), color: .secondaryLabelColor)
        }
        row("5 小时剩余", window: payload?.window(minutes: 300), y: 48)
        row("本周剩余", window: payload?.window(minutes: 10080), y: 104)
        text(freshness, x: 16, y: 161, font: .systemFont(ofSize: 9), color: stale ? .systemOrange : .secondaryLabelColor)
    }
}
