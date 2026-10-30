import AppKit

final class UsagePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let client = CodexClient()
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
    private var menu: NSMenu!
    private var menuOpen = false
    private var isInteracting = false
    private var mode = UserDefaults.standard.string(forKey: "displayMode") ?? "follow"
    private var lastWindow: NSRect?
    private var freeOrigin: NSPoint? = {
        let settings = UserDefaults.standard
        guard settings.object(forKey: "freeX") != nil, settings.object(forKey: "freeY") != nil else { return nil }
        return NSPoint(x: settings.double(forKey: "freeX"), y: settings.double(forKey: "freeY"))
    }()
    private var lastTick: Date = .distantPast
    private let diagnosticsPath = ProcessInfo.processInfo.environment["CODEX_USAGE_DIAGNOSTICS"]
    private var renderedPreview = false
    private var previewTask: DispatchWorkItem?

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
        panel.level = .floating; panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.isMovable = false // The gauge handles the complete mouse gesture, including click vs drag.
        glassRoot = GlassRoot(size: WidgetLayout.size)
        panel.contentView = glassRoot
        gauge = CompactGauge(frame: glassRoot.body.bounds)
        gauge.autoresizingMask = [.width, .height]
        gauge.onDragged = { [weak self] in self?.didDrag() }
        gauge.onClick = { [weak self] in self?.showDetails() }
        gauge.onMenu = { [weak self] in self?.showDetails() }
        gauge.onInteractionChanged = { [weak self] active in self?.isInteracting = active }
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

    private func codexWindow() -> NSRect? {
        let pids = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").map(\.processIdentifier)
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let primaryTop = NSScreen.screens.first?.frame.maxY else { return nil }
        for window in windows {
            guard let pid = window[kCGWindowOwnerPID as String] as? Int32, pids.contains(pid),
                  window[kCGWindowLayer as String] as? Int == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"], let width = bounds["Width"], let height = bounds["Height"],
                  width >= 500, height >= 300 else { continue }
            return NSRect(x: x, y: primaryTop - y - height, width: width, height: height)
        }
        return nil
    }

    private func positionPanel() {
        if isInteracting { return }
        guard mode != "menu" else { panel.orderOut(nil); return }
        if mode == "free" {
            if !panel.isVisible {
                if let freeOrigin { panel.setFrameOrigin(freeOrigin) }
                if let screen = NSScreen.main, panel.frame.intersection(screen.visibleFrame).isEmpty {
                    panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX + 10, y: screen.visibleFrame.minY + 110))
                }
                panel.orderFrontRegardless()
            }
            return
        }
        if menuOpen { return }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.openai.codex",
              let window = codexWindow() else { panel.orderOut(nil); lastWindow = nil; return }
        lastWindow = window
        let anchor = WidgetLayout.anchor(in: window)
        var point = anchor
        point.x = min(max(point.x, window.minX + 2), window.maxX - panel.frame.width - 2)
        point.y = min(max(point.y, window.minY + 2), window.maxY - panel.frame.height - 40)
        if abs(panel.frame.minX - point.x) > 0.5 || abs(panel.frame.minY - point.y) > 0.5 { panel.setFrameOrigin(point) }
        if !panel.isVisible { panel.orderFrontRegardless() }
        writeDiagnostics()
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
        buildMenu(); positionPanel(); render()
    }

    private func writeDiagnostics() {
        guard let diagnosticsPath else { return }
        let object: [String: Any] = [
            "mode": mode, "panelVisible": panel.isVisible, "displayMetric": "remaining",
            "isDragging": isInteracting, "detailDrawCount": details.drawCount,
            "panelFrame": NSStringFromRect(panel.frame), "codexWindowFound": lastWindow != nil,
            "codexWindowFrame": lastWindow.map(NSStringFromRect) as Any? ?? NSNull(),
            "nativeLiquidGlass": glassRoot.nativeGlass,
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
        render()
        menu.popUp(positioning: menu.items.first, at: NSPoint(x: gauge.bounds.maxX + 8, y: -8), in: gauge)
    }
    @objc private func refreshNow() { client.refresh() }
    @objc private func didWake() { client.refresh(); positionPanel() }
    @objc private func followMode() { changeMode("follow") }
    @objc private func freeMode() { changeMode("free") }
    @objc private func menuMode() { changeMode("menu") }
    @objc private func resetPosition() {
        UserDefaults.standard.removeObject(forKey: "offsetX"); UserDefaults.standard.removeObject(forKey: "offsetY")
        changeMode("follow")
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        ticker?.invalidate(); poller?.invalidate(); client.stop()
    }
}
