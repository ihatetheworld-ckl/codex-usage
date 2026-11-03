import AppKit

final class UsagePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Window numbers remain stable when a sheet or an open/save panel becomes frontmost.
/// Keep the host's identity instead of adopting whichever large window is in front.
final class CodexWindowTracker {
    struct Window {
        let id: CGWindowID
        let pid: Int32
        let frame: NSRect
        let onScreen: Bool
    }
    struct Selection {
        let window: Window
        let blocked: Bool
    }
    private let snapshot: () -> [Window]?
    private let clock: () -> TimeInterval
    private var boundWindow: Window?
    private var mainWindows = Set<CGWindowID>()
    private var dialogs = Set<CGWindowID>()
    private var pendingDialogs: [CGWindowID: (Window, TimeInterval)] = [:]
    var hasPendingDialogs: Bool { !pendingDialogs.isEmpty }

    init(snapshot: @escaping () -> [Window]? = CodexWindowTracker.codexWindows,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.snapshot = snapshot
        self.clock = clock
    }

    func selection() -> Selection? {
        guard let windows = snapshot() else { return nil }
        let alive = Set(windows.map(\.id))
        mainWindows.formIntersection(alive)
        dialogs.formIntersection(alive)
        pendingDialogs = pendingDialogs.filter { alive.contains($0.key) }
        if let bound = boundWindow,
           !windows.contains(where: { $0.id == bound.id && $0.pid == bound.pid }) {
            boundWindow = nil
        }
        // WindowServer does not expose main-vs-sheet roles without Accessibility access.
        // Recognize inset dialogs against their larger parent, then retain that identity
        // while the dialog moves/resizes. Already known main windows keep their role.
        var tentativeDialogs = Set<CGWindowID>()
        for (index, window) in windows.enumerated() where !mainWindows.contains(window.id) && !dialogs.contains(window.id) {
            let inset = window.onScreen && Self.isMainSized(window) && windows.dropFirst(index + 1).contains(where: { parent in
                guard parent.pid == window.pid, parent.onScreen, Self.isMainSized(parent),
                      parent.frame.width >= window.frame.width,
                      parent.frame.height >= window.frame.height else { return false }
                let area = window.frame.width * window.frame.height
                let overlap = parent.frame.intersection(window.frame)
                return area > 0 && area < parent.frame.width * parent.frame.height * 0.8 &&
                    overlap.width * overlap.height >= area * 0.9 &&
                    abs(parent.frame.midX - window.frame.midX) <= max(32, parent.frame.width * 0.04)
            })
            guard inset else { pendingDialogs.removeValue(forKey: window.id); continue }
            tentativeDialogs.insert(window.id)
            if let pending = pendingDialogs[window.id], pending.0.pid == window.pid, pending.0.frame == window.frame {
                if clock() - pending.1 >= 0.12 { dialogs.insert(window.id); pendingDialogs.removeValue(forKey: window.id) }
            } else { pendingDialogs[window.id] = (window, clock()) }
        }
        let candidates = windows.filter { $0.onScreen && Self.isMainSized($0) && !dialogs.contains($0.id) && !tentativeDialogs.contains($0.id) }
        // Follow the visible main window, even when the previous host is minimized,
        // on another Space, or behind another main window. It must not remain latched
        // to an invisible host and classify every other window as a blocking dialog.
        mainWindows.formUnion(candidates.map(\.id))
        if let foregroundMain = candidates.first { boundWindow = foregroundMain }
        guard let bound = boundWindow,
              let index = windows.firstIndex(where: { $0.id == bound.id && $0.pid == bound.pid }),
              windows[index].onScreen, Self.isMainSized(windows[index]) else { return nil }
        boundWindow = windows[index]
        return Selection(window: windows[index], blocked: windows[..<index].contains {
            // Tiny helper/tooltip windows are not modal dialogs. A helper can remain
            // ordered above the main window long after a menu has been dismissed.
            $0.onScreen && $0.pid == bound.pid && !mainWindows.contains($0.id) &&
                $0.frame.width >= 160 && $0.frame.height >= 80 && $0.frame.intersects(windows[index].frame)
        })
    }

    func reset() {
        boundWindow = nil; mainWindows.removeAll(); dialogs.removeAll(); pendingDialogs.removeAll()
    }

    private static func isMainSized(_ window: Window) -> Bool {
        window.frame.width >= 500 && window.frame.height >= 300
    }

    static func codexWindows() -> [Window]? {
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").map(\.processIdentifier))
        return windows(processIDs: pids)
    }

    static func windows(processIDs: Set<Int32>) -> [Window]? {
        if processIDs.isEmpty { return [] }
        // Only optionOnScreenOnly guarantees front-to-back ordering. optionAll is
        // solely an existence inventory for retaining minimized/off-Space identities.
        guard let visible = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let all = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let primaryTop = NSScreen.screens.first?.frame.maxY else { return nil }
        let visibleIDs = Set(visible.compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
        let entries = visible.map { ($0, true) } + all.filter {
            !visibleIDs.contains($0[kCGWindowNumber as String] as? CGWindowID ?? kCGNullWindowID)
        }.map { ($0, false) }
        return entries.compactMap { entry, onScreen in
            guard let pid = entry[kCGWindowOwnerPID as String] as? Int32, processIDs.contains(pid),
                  entry[kCGWindowLayer as String] as? Int == 0,
                  let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"], let width = bounds["Width"], let height = bounds["Height"],
                  width > 1, height > 1 else { return nil }
            return Window(id: id, pid: pid,
                          frame: NSRect(x: x, y: primaryTop - y - height, width: width, height: height),
                          onScreen: onScreen && (entry[kCGWindowAlpha as String] as? CGFloat ?? 1) > 0.01)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let client = CodexClient()
    private let windowTracker: CodexWindowTracker
    private let hostIsFrontmost: () -> Bool
    private var payload: UsagePayload?
    private var updatedAt: Date?
    private var errorMessage: String?
    private var statusItem: NSStatusItem!
    private var panel: UsagePanel!
    private var glassRoot: GlassRoot!
    private var gauge: CompactGauge!
    private let details = DetailCard()
    private var ticker: Timer?
    private var poller: Timer?
    private var placementRetry: Timer?
    private var pendingDockWindow: CodexWindowTracker.Window?
    private var pendingDockStableSince: TimeInterval?
    private var menu: NSMenu!
    private var menuOpen = false
    private var isInteracting = false
    private var mode = UserDefaults.standard.string(forKey: "displayMode") ?? "follow"
    private var lastWindow: NSRect?
    private var lastWindowID: CGWindowID?
    private var hostBlocked = false
    private var placementReason = "starting"
    private var freeOrigin: NSPoint? = {
        let settings = UserDefaults.standard
        guard settings.object(forKey: "freeX") != nil, settings.object(forKey: "freeY") != nil else { return nil }
        return NSPoint(x: settings.double(forKey: "freeX"), y: settings.double(forKey: "freeY"))
    }()
    private var lastTick: Date = .distantPast
    private let diagnosticsPath = ProcessInfo.processInfo.environment["CODEX_USAGE_DIAGNOSTICS"]
    private var renderedPreview = false
    private var previewTask: DispatchWorkItem?

    init(windowTracker: CodexWindowTracker = CodexWindowTracker(),
         hostIsFrontmost: @escaping () -> Bool = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.openai.codex" }) {
        self.windowTracker = windowTracker
        self.hostIsFrontmost = hostIsFrontmost
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // The user requested a new position and remaining values. Migrate the old large-card layout once.
        if UserDefaults.standard.integer(forKey: "layoutVersion") < 2 {
            mode = "follow"
            UserDefaults.standard.removeObject(forKey: "offsetX"); UserDefaults.standard.removeObject(forKey: "offsetY")
            UserDefaults.standard.removeObject(forKey: "showRemaining")
            UserDefaults.standard.set(mode, forKey: "displayMode")
            UserDefaults.standard.set(2, forKey: "layoutVersion")
        }
        buildPanel()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        statusItem.button?.image = Brand.markImage(size: 17, template: true)
        statusItem.button?.imagePosition = .imageLeading
        buildMenu()
        client.onUsage = { [weak self] payload in
            guard let self else { return }
            self.payload = payload; self.updatedAt = Date(); self.errorMessage = nil; self.render()
        }
        client.onError = { [weak self] message in self?.errorMessage = message; self?.render() }
        client.onAccountChanged = { [weak self] in
            self?.payload = nil; self?.updatedAt = nil; self?.errorMessage = "账户已变化，正在刷新…"; self?.render()
        }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.positionPanel()
            if let self, Date().timeIntervalSince(self.lastTick) > 5 { self.lastTick = Date(); self.render() }
        }
        poller = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.client.refresh() }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(hostActivationChanged), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(hostActivationChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(hostActivationChanged), name: NSWorkspace.didUnhideApplicationNotification, object: nil)
        render(); positionPanel(); client.refresh()
        if let raw = ProcessInfo.processInfo.environment["CODEX_USAGE_QUIT_AFTER"], let seconds = Double(raw), seconds > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { NSApp.terminate(nil) }
        }
    }

    private func buildPanel() {
        panel = UsagePanel(contentRect: NSRect(origin: NSPoint(x: 80, y: 120), size: WidgetLayout.size),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Codex 剩余用量"
        panel.isOpaque = false; panel.backgroundColor = .clear
        panel.level = mode == "free" ? .floating : .normal; panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.isMovable = false // The gauge handles the complete mouse gesture, including click vs drag.
        glassRoot = GlassRoot(size: WidgetLayout.size)
        panel.contentView = glassRoot
        gauge = CompactGauge(frame: glassRoot.body.bounds)
        // GlassRoot centers this fixed-size gauge during its appearance animation.
        gauge.onDragged = { [weak self] in self?.didDrag() }
        gauge.onClick = { [weak self] in self?.showDetails() }
        gauge.onMenu = { [weak self] in self?.showDetails() }
        gauge.onInteractionChanged = { [weak self] active in
            self?.isInteracting = active
            if active { self?.glassRoot.finishReveal() }
        }
        glassRoot.body.addSubview(gauge)
    }

    private func buildMenu() {
        menu = NSMenu(); menu.delegate = self; menu.autoenablesItems = false
        let detailItem = NSMenuItem(); detailItem.view = details; detailItem.isEnabled = true; menu.addItem(detailItem)
        menu.addItem(.separator())
        addMenu("立即刷新", action: #selector(refreshNow))
        addMenu("每 30 秒自动更新 · 百分比和进度均为剩余", action: nil)
        menu.addItem(.separator())
        addMenu("贴在左下角窄栏", action: #selector(followMode), checked: mode == "follow")
        addMenu("自由悬浮", action: #selector(freeMode), checked: mode == "free")
        addMenu("仅菜单栏", action: #selector(menuMode), checked: mode == "menu")
        addMenu("恢复左下角位置", action: #selector(resetPosition))
        addMenu("复制显示诊断信息", action: #selector(copyPlacementDiagnostics))
        menu.addItem(.separator())
        addMenu("退出 Codex Usage", action: #selector(quit), key: "q")
        statusItem.menu = menu
    }

    private func addMenu(_ title: String, action: Selector?, checked: Bool = false, key: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self; item.isEnabled = action != nil; item.state = checked ? .on : .off; menu.addItem(item)
    }

    func menuWillOpen(_ menu: NSMenu) { menuOpen = true; render(); details.needsDisplay = true }
    func menuDidClose(_ menu: NSMenu) { menuOpen = false; positionPanel() }

    private func render() {
        let short = payload?.window(minutes: 300), week = payload?.window(minutes: 10080)
        let stale = errorMessage != nil || (updatedAt.map { Date().timeIntervalSince($0) > 90 } ?? true)
        let shortText = UsageText.percent(short, remaining: true), weekText = UsageText.percent(week, remaining: true)
        statusItem.button?.title = " 5h \(shortText) · 周 \(weekText)\(stale ? " ⏳" : "")"
        var freshness = "正在连接 Codex…"
        if let errorMessage { freshness = errorMessage }
        else if let updatedAt { freshness = "\(stale ? "数据已旧" : "更新于") \(UsageText.timestamp(updatedAt)) · 30 秒刷新" }
        let dragHint = mode == "free" ? "拖动调整位置" : "拖动松手后回到左下角"
        let tooltip = "剩余用量\n5 小时：\(shortText) · \(UsageText.reset(short))\n本周：\(weekText) · \(UsageText.reset(week))\n\(freshness)\n点击查看详情 · \(dragHint)"
        gauge.update(short: shortText, week: weekText, stale: stale, tooltip: tooltip)
        statusItem.button?.toolTip = tooltip
        details.update(payload: payload, message: freshness, stale: stale)
        writeDiagnostics()
        previewTask?.cancel()
        if payload != nil && errorMessage == nil && !renderedPreview, let path = ProcessInfo.processInfo.environment["CODEX_USAGE_RENDER"] {
            let task = DispatchWorkItem { [weak self] in
                guard let self, self.payload != nil, self.errorMessage == nil else { return }
                self.renderedPreview = true
                self.renderView(self.glassRoot, path: path)
                if let detailPath = ProcessInfo.processInfo.environment["CODEX_USAGE_RENDER_DETAILS"] {
                    self.renderView(self.details, path: detailPath, withPreviewBackground: true)
                }
            }
            previewTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: task)
        }
    }

    private func renderView(_ view: NSView, path: String, withPreviewBackground: Bool = false) {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        var rendered = bitmap
        // Menu glass comes from the window compositor. Use a neutral surface for the optional
        // standalone details preview only; the live menu itself retains native transparency.
        if withPreviewBackground, let preview = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: bitmap.pixelsWide,
            pixelsHigh: bitmap.pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: preview)
            let rect = NSRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
            NSColor.windowBackgroundColor.setFill(); NSBezierPath(roundedRect: rect, xRadius: 20, yRadius: 20).fill()
            if let image = bitmap.cgImage {
                NSGraphicsContext.current?.cgContext.setBlendMode(.normal)
                NSGraphicsContext.current?.cgContext.draw(image, in: rect)
            }
            NSGraphicsContext.restoreGraphicsState()
            rendered = preview
        }
        if let png = rendered.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    func positionPanel() {
        // A lost mouse-up or a menu-tracking interruption must never prevent hiding
        // and recovery on the next app switch.
        if mode == "follow" && !hostIsFrontmost() {
            gauge.cancelInteraction()
            if menuOpen { menu.cancelTrackingWithoutAnimation(); menuOpen = false }
            isInteracting = false
            stopPlacementRetry(); resetPendingDock()
            hidePanel(); lastWindow = nil; lastWindowID = nil; hostBlocked = false
            placementReason = "host-background"; writeDiagnostics(); return
        }
        if isInteracting { return }
        guard mode != "menu" else {
            stopPlacementRetry(); resetPendingDock(); hidePanel(); placementReason = "menu-only"; return
        }
        if mode == "free" {
            stopPlacementRetry(); resetPendingDock()
            placementReason = "free"
            glassRoot.finishReveal()
            if !panel.isVisible {
                if let freeOrigin { panel.setFrameOrigin(freeOrigin) }
                if let screen = NSScreen.main, panel.frame.intersection(screen.visibleFrame).isEmpty {
                    panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX + 10, y: screen.visibleFrame.minY + 110))
                }
                panel.orderFrontRegardless()
            }
            return
        }
        if menuOpen { stopPlacementRetry(); return }
        guard hostIsFrontmost() else {
            stopPlacementRetry(); resetPendingDock()
            hidePanel(); lastWindow = nil; lastWindowID = nil; hostBlocked = false
            placementReason = "host-background"; writeDiagnostics(); return
        }
        guard let selection = windowTracker.selection() else {
            // An activating Stage Manager host initially exists only as a thumbnail.
            // Keep an activation retry alive while waiting for an eligible main frame.
            resetPendingDock()
            hidePanel(); lastWindow = nil; lastWindowID = nil; hostBlocked = false
            placementReason = "no-visible-main-window"; writeDiagnostics(); return
        }
        let window = selection.window.frame
        if let previous = lastWindowID, previous != selection.window.id {
            // Switching between main windows needs the same stable-frame gate as activation.
            hidePanel(); resetPendingDock()
        }
        lastWindow = window
        lastWindowID = selection.window.id
        hostBlocked = selection.blocked
        // Hide during host-owned dialogs. Do not move to or float above the file picker.
        guard !selection.blocked else {
            if windowTracker.hasPendingDialogs { schedulePlacementRetry() } else { stopPlacementRetry() }
            resetPendingDock(); hidePanel(); placementReason = "host-dialog"; writeDiagnostics(); return
        }
        // WindowServer reports the intermediate, transformed host bounds during app
        // switching. They can already exceed our minimum window size. Never reveal
        // the panel at that temporary anchor and wait half a second to correct it.
        if !panel.isVisible && !dockedFrameIsSettled(selection.window) {
            schedulePlacementRetry(); placementReason = "waiting-for-stable-frame"; writeDiagnostics(); return
        }
        let anchor = WidgetLayout.anchor(in: window)
        var point = anchor
        point.x = min(max(point.x, window.minX + 2), window.maxX - panel.frame.width - 2)
        point.y = min(max(point.y, window.minY + 2), window.maxY - panel.frame.height - 40)
        if abs(panel.frame.minX - point.x) > 0.5 || abs(panel.frame.minY - point.y) > 0.5 { panel.setFrameOrigin(point) }
        if !panel.isVisible { glassRoot.reveal() }
        // Stay just above the host, at its normal window level. A newly opened system
        // dialog can cover the widget immediately, even before the next positioning tick.
        panel.order(.above, relativeTo: Int(selection.window.id))
        stopPlacementRetry(); resetPendingDock()
        placementReason = "visible"
        writeDiagnostics()
    }

    private func hidePanel() {
        panel.orderOut(nil)
        glassRoot.finishReveal()
    }

    private func dockedFrameIsSettled(_ window: CodexWindowTracker.Window) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if pendingDockWindow?.id != window.id || pendingDockWindow?.pid != window.pid ||
           pendingDockWindow?.frame != window.frame {
            pendingDockWindow = window
            pendingDockStableSince = now
            return false
        }
        return now - (pendingDockStableSince ?? now) >= 0.12
    }

    private func resetPendingDock() {
        pendingDockWindow = nil
        pendingDockStableSince = nil
    }

    private func schedulePlacementRetry() {
        guard placementRetry == nil else { return }
        // Only sample densely during activation/restoration. Missing hosts or a
        // continuously moving window cannot leave a permanent high-frequency timer.
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                self.stopPlacementRetry(); return
            }
            self.positionPanel()
        }
        placementRetry = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopPlacementRetry() {
        placementRetry?.invalidate()
        placementRetry = nil
    }

    private func didDrag() {
        if mode == "free" {
            freeOrigin = panel.frame.origin
            UserDefaults.standard.set(freeOrigin!.x, forKey: "freeX"); UserDefaults.standard.set(freeOrigin!.y, forKey: "freeY")
            writeDiagnostics()
            return
        }
        // Docked mode never adopts a dropped position. Restore the current Codex anchor
        // immediately on mouse-up, without waiting for the positioning timer.
        if mode == "follow" { positionPanel() }
    }

    private func changeMode(_ next: String) {
        if next == "free", mode != "free" {
            if let freeOrigin { panel.setFrameOrigin(freeOrigin) }
            else {
                freeOrigin = panel.frame.origin
                UserDefaults.standard.set(freeOrigin!.x, forKey: "freeX"); UserDefaults.standard.set(freeOrigin!.y, forKey: "freeY")
            }
        }
        mode = next; UserDefaults.standard.set(next, forKey: "displayMode")
        panel.level = next == "free" ? .floating : .normal
        buildMenu(); positionPanel(); render()
    }

    private func writeDiagnostics() {
        guard let diagnosticsPath else { return }
        let object: [String: Any] = [
            "mode": mode, "panelVisible": panel.isVisible, "displayMetric": "remaining",
            "isDragging": isInteracting, "detailDrawCount": details.drawCount,
            "panelFrame": NSStringFromRect(panel.frame), "codexWindowFound": lastWindow != nil,
            "codexWindowID": lastWindowID as Any? ?? NSNull(), "hostDialogVisible": hostBlocked,
            "placementReason": placementReason,
            "codexWindowFrame": lastWindow.map(NSStringFromRect) as Any? ?? NSNull(),
            "nativeLiquidGlass": glassRoot.nativeGlass,
            "revealDurationMilliseconds": Int(GlassRoot.revealDuration * 1000),
            "isRevealing": glassRoot.isRevealing,
            "updatedAt": updatedAt.map { ISO8601DateFormatter().string(from: $0) } as Any? ?? NSNull(),
            "fiveHourRemainingPercent": payload?.window(minutes: 300)?.remainingPercent as Any? ?? NSNull(),
            "weeklyRemainingPercent": payload?.window(minutes: 10080)?.remainingPercent as Any? ?? NSNull(),
            "error": errorMessage as Any? ?? NSNull()
        ]
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: diagnosticsPath), options: .atomic)
        }
    }

    private func showDetails() {
        glassRoot.finishReveal()
        render()
        menu.popUp(positioning: menu.items.first, at: NSPoint(x: gauge.bounds.maxX + 8, y: -8), in: gauge)
    }
    @objc private func refreshNow() { client.refresh() }
    @objc private func didWake() { client.refresh(); hostActivationChanged() }
    @objc private func hostActivationChanged() {
        positionPanel()
        if mode == "follow", hostIsFrontmost(), !panel.isVisible, !hostBlocked {
            schedulePlacementRetry()
        }
    }
    @objc private func followMode() { changeMode("follow") }
    @objc private func freeMode() { changeMode("free") }
    @objc private func menuMode() { changeMode("menu") }
    @objc private func resetPosition() {
        UserDefaults.standard.removeObject(forKey: "offsetX"); UserDefaults.standard.removeObject(forKey: "offsetY")
        windowTracker.reset(); resetPendingDock()
        changeMode("follow")
    }
    @objc private func copyPlacementDiagnostics() {
        let serverWindows = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(panel.windowNumber)) as? [[String: Any]]
        let fields: [String: Any] = [
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development",
            "mode": mode, "panelVisible": panel.isVisible, "reason": placementReason,
            "hostWindowID": lastWindowID as Any? ?? NSNull(),
            "hostFrame": lastWindow.map(NSStringFromRect) as Any? ?? NSNull(),
            "panelFrame": NSStringFromRect(panel.frame), "isInteracting": isInteracting, "menuOpen": menuOpen,
            "hostFrontmost": hostIsFrontmost(), "windowLevel": panel.level.rawValue,
            "windowServerVisible": serverWindows?.first(where: {
                $0[kCGWindowNumber as String] as? CGWindowID == CGWindowID(panel.windowNumber)
            })?[kCGWindowIsOnscreen as String] as Any? ?? NSNull()
        ]
        if let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .prettyPrinted]),
           let text = String(data: data, encoding: .utf8) {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        }
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        ticker?.invalidate(); poller?.invalidate(); stopPlacementRetry(); glassRoot?.finishReveal(); client.stop()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}
