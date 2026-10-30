import AppKit

final class WidgetInteractionTests: NSObject, NSApplicationDelegate {
    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 48, height: 84),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let root = GlassRoot(size: WidgetLayout.size)
    private var gauge: CompactGauge!
    private let menu = NSMenu()
    private let detail = DetailCard()
    private var checks = 0

    private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.isMovable = false
        panel.contentView = root; panel.level = .floating
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        panel.setFrameOrigin(NSPoint(x: screen.midX - 100, y: screen.minY + 180))
        gauge = CompactGauge(frame: root.body.bounds)
        root.body.addSubview(gauge)
        panel.orderFrontRegardless()
        root.layoutSubtreeIfNeeded()
        var clicks = 0, drags = 0
        var states = [Bool]()
        gauge.onClick = { clicks += 1 }
        gauge.onDragged = { drags += 1 }
        gauge.onInteractionChanged = { states.append($0) }
        check(gauge.acceptsFirstMouse(for: nil), "drag works without activating the widget")
        let hit = root.hitTest(NSPoint(x: 24, y: 42))
        check(hit === gauge, "glass passes pointer events to the gauge")

        let origin = panel.frame.origin
        let start = NSPoint(x: origin.x + 24, y: origin.y + 42)
        send(.leftMouseDown, at: start)
        check(clicks == 0 && drags == 0, "mouse down must not open a menu")
        send(.leftMouseDragged, at: NSPoint(x: start.x + 90, y: start.y + 60))
        check(panel.frame.origin == NSPoint(x: origin.x + 90, y: origin.y + 60), "drag moves the real window")
        send(.leftMouseDragged, at: NSPoint(x: start.x + 120, y: start.y - 20))
        check(panel.frame.origin == NSPoint(x: origin.x + 120, y: origin.y - 20), "repeated drag uses screen coordinates")
        send(.leftMouseUp, at: NSPoint(x: start.x + 120, y: start.y - 20))
        check(drags == 1 && clicks == 0, "drag never opens the click menu")
        check(states == [true, false], "placement is paused until mouse up")
        let releasedOrigin = panel.frame.origin
        let click = NSPoint(x: releasedOrigin.x + 24, y: releasedOrigin.y + 42)
        send(.leftMouseDown, at: click)
        send(.leftMouseDragged, at: NSPoint(x: click.x + 1, y: click.y + 1))
        check(panel.frame.origin == releasedOrigin && clicks == 0, "tiny motion remains a click, without premature action")
        send(.leftMouseUp, at: click)
        check(clicks == 1 && drags == 1, "click opens details only on mouse up")

        let payload = try! JSONDecoder().decode(UsagePayload.self, from: Data(#"{"rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":300},"secondary":{"usedPercent":11,"windowDurationMins":10080}}}"#.utf8))
        detail.update(payload: payload, message: "更新于 16:30:00 · 30 秒刷新", stale: false)
        menu.autoenablesItems = false
        let item = NSMenuItem(); item.view = detail; item.isEnabled = true; menu.addItem(item)
        menu.addItem(.separator())
        let refresh = NSMenuItem(title: "立即刷新", action: nil, keyEquivalent: ""); refresh.isEnabled = false; menu.addItem(refresh)
        let baseline = detail.drawCount
        let timer = Timer(timeInterval: 0.7, repeats: false) { [self] _ in
            check(item.isEnabled, "custom detail item stays enabled during native menu tracking")
            check(detail.window?.isVisible == true, "details are attached to an on-screen menu window")
            check(detail.visibleRect.height >= 180 && detail.visibleRect.width >= 236, "detail section is not clipped")
            check(detail.drawCount > baseline, "native menu invokes actual detail painting, without a preview")
            print("Native menu detail paint calls:", detail.drawCount - baseline)
            menu.cancelTracking()
        }
        RunLoop.main.add(timer, forMode: .eventTracking)
        menu.popUp(positioning: nil, at: NSPoint(x: panel.frame.maxX + 10, y: panel.frame.maxY), in: nil)
        panel.orderOut(nil)
        verifyFreeModePersistence()
        print("PASS: \(checks) native menu and window gesture checks")
        NSApp.terminate(nil)
    }

    private func send(_ type: NSEvent.EventType, at point: NSPoint, to target: NSWindow? = nil) {
        let window = target ?? panel
        let event = NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: point), modifierFlags: [],
                                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                      context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        NSApp.sendEvent(event)
    }

    private func verifyFreeModePersistence() {
        // This executable has its own preferences domain; preserve even its prior test preferences.
        let settings = UserDefaults.standard
        let keys = ["layoutVersion", "displayMode", "freeX", "freeY", "offsetX", "offsetY"]
        let saved = Dictionary(uniqueKeysWithValues: keys.compactMap { key in settings.object(forKey: key).map { (key, $0) } })
        defer { for key in keys { if let value = saved[key] { settings.set(value, forKey: key) } else { settings.removeObject(forKey: key) } } }
        settings.set(2, forKey: "layoutVersion"); settings.set("follow", forKey: "displayMode")
        settings.set(200, forKey: "offsetX"); settings.set(90, forKey: "offsetY")
        settings.removeObject(forKey: "freeX"); settings.removeObject(forKey: "freeY")
        let subject = AppDelegate()
        subject.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        subject.perform(NSSelectorFromString("freeMode"))
        check(settings.string(forKey: "displayMode") == "free", "the actual free-mode menu action changes mode")
        guard let floating = NSApp.windows.first(where: { $0.title == "Codex 剩余用量" && $0.isVisible }) else {
            check(false, "free mode shows the actual app window"); return
        }
        let old = floating.frame.origin
        let start = NSPoint(x: old.x + 24, y: old.y + 42)
        let end = NSPoint(x: start.x + 75, y: start.y + 35)
        send(.leftMouseDown, at: start, to: floating)
        send(.leftMouseDragged, at: end, to: floating)
        send(.leftMouseUp, at: end, to: floating)
        let expected = NSPoint(x: old.x + 75, y: old.y + 35)
        check(floating.frame.origin == expected, "drag moves the actual app in free mode")
        check(settings.double(forKey: "freeX") == expected.x && settings.double(forKey: "freeY") == expected.y,
              "actual drag callback saves the free position")
        subject.perform(NSSelectorFromString("followMode"))
        if ProcessInfo.processInfo.environment["CODEX_USAGE_UI_WITH_CODEX"] == "1" {
            guard let host = visibleCodexWindow() else { check(false, "Codex window must be visible for docking checks"); return }
            let docked = WidgetLayout.anchor(in: host)
            check(floating.isVisible && floating.frame.origin == docked, "docked mode ignores old saved offsets")
            let start = NSPoint(x: docked.x + 24, y: docked.y + 42)
            let elsewhere = NSPoint(x: start.x + 200, y: start.y + 80)
            send(.leftMouseDown, at: start, to: floating)
            send(.leftMouseDragged, at: elsewhere, to: floating)
            check(floating.frame.origin == NSPoint(x: docked.x + 200, y: docked.y + 80), "docked widget can move temporarily while held")
            send(.leftMouseUp, at: elsewhere, to: floating)
            check(floating.frame.origin == docked, "docked widget snaps back immediately on release")
            let second = NSPoint(x: start.x + 90, y: start.y - 60)
            send(.leftMouseDown, at: start, to: floating)
            send(.leftMouseDragged, at: second, to: floating)
            send(.leftMouseUp, at: second, to: floating)
            check(floating.frame.origin == docked, "repeated docking drags do not accumulate displacement")
            check(settings.double(forKey: "offsetX") == 200 && settings.double(forKey: "offsetY") == 90,
                  "docking drops do not persist a new offset")
        }
        subject.perform(NSSelectorFromString("freeMode"))
        check(floating.frame.origin == expected, "returning to free mode restores its own position")
        subject.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        floating.orderOut(nil)

        let relaunched = AppDelegate()
        relaunched.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        let restored = NSApp.windows.first(where: { $0.title == "Codex 剩余用量" && $0.isVisible })
        check(restored?.frame.origin == expected, "a fresh app instance restores the saved free position")
        relaunched.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        restored?.orderOut(nil)
    }

    private func visibleCodexWindow() -> NSRect? {
        let pids = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").map(\.processIdentifier)
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let screenTop = NSScreen.screens.first?.frame.maxY else { return nil }
        for entry in windows {
            guard let pid = entry[kCGWindowOwnerPID as String] as? Int32, pids.contains(pid),
                  entry[kCGWindowLayer as String] as? Int == 0,
                  let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"], let w = bounds["Width"], let h = bounds["Height"],
                  w >= 500, h >= 300 else { continue }
            return NSRect(x: x, y: screenTop - y - h, width: w, height: h)
        }
        return nil
    }
}

@main
struct WidgetUITestMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = WidgetInteractionTests()
        app.delegate = delegate
        app.run()
    }
}
