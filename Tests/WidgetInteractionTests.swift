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

    private func waitFor(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        repeat {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        } while Date() < deadline
        return condition()
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
        verifyHostWindowIdentity()
        verifyNativeFilePanel()
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
        CodexWindowTracker().selection()?.window.frame
    }

    private func verifyHostWindowIdentity() {
        let main = CodexWindowTracker.Window(id: 101, pid: 7, frame: NSRect(x: 80, y: 80, width: 1200, height: 800), onScreen: true)
        let picker = CodexWindowTracker.Window(id: 102, pid: 7, frame: NSRect(x: 240, y: 240, width: 879, height: 448), onScreen: true)
        var windows: [CodexWindowTracker.Window]? = [main]
        let tracker = CodexWindowTracker(snapshot: { windows })
        check(tracker.selection()?.window.id == main.id, "bind to the main window before a picker opens")
        windows = [picker, main]
        check(tracker.selection()?.window.id == main.id, "a frontmost file picker cannot replace the host")
        check(tracker.selection()?.blocked == true, "a host-owned file picker suppresses the docked widget")
        let coldStart = CodexWindowTracker(snapshot: { windows })
        check(coldStart.selection()?.window.id == main.id && coldStart.selection()?.blocked == true,
              "starting with an open picker still binds to the underlying main window")
        windows = nil
        check(tracker.selection() == nil, "failed window snapshots hide the widget safely")
        windows = [picker, main]
        check(tracker.selection()?.window.id == main.id, "a failed snapshot does not forget the main window")
        windows = [main]
        check(tracker.selection()?.blocked == false, "closing the picker restores the same host")
        let moved = CodexWindowTracker.Window(id: 101, pid: 7, frame: NSRect(x: 140, y: 100, width: 1200, height: 800), onScreen: true)
        windows = [moved]
        check(tracker.selection()?.window.frame == moved.frame, "the bound main window still follows moves and resize")
        windows = [CodexWindowTracker.Window(id: 101, pid: 7, frame: main.frame, onScreen: false)]
        check(tracker.selection() == nil, "minimized or off-space hosts hide the widget")
        windows = [CodexWindowTracker.Window(id: 101, pid: 7, frame: NSRect(x: 16, y: 376, width: 140, height: 150), onScreen: true)]
        check(tracker.selection() == nil, "a temporary miniature frame during minimization never becomes a dock anchor")
        windows = [picker, main]
        check(tracker.selection()?.window.id == main.id && tracker.selection()?.blocked == true,
              "restoring the host behind a picker never adopts the picker")
        windows = []
        check(tracker.selection() == nil, "closing all host windows hides the widget")
        windows = [CodexWindowTracker.Window(id: 103, pid: 8, frame: main.frame, onScreen: true)]
        check(tracker.selection()?.window.id == 103, "a replacement host is accepted after the original closes")
    }

    private func verifyNativeFilePanel() {
        let settings = UserDefaults.standard
        let savedMode = settings.object(forKey: "displayMode")
        defer {
            if let savedMode { settings.set(savedMode, forKey: "displayMode") }
            else { settings.removeObject(forKey: "displayMode") }
        }
        settings.set("follow", forKey: "displayMode")
        let screen = NSScreen.main!.visibleFrame
        let host = NSWindow(contentRect: NSRect(x: screen.minX + 40, y: screen.minY + 40, width: 1000, height: 680),
                            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        host.title = "Codex Usage regression test host"
        host.isReleasedWhenClosed = false
        NSApp.activate(ignoringOtherApps: true)
        host.makeKeyAndOrderFront(nil)
        check(waitFor {
            CodexWindowTracker.windows(processIDs: [ProcessInfo.processInfo.processIdentifier])?.contains {
                $0.id == CGWindowID(host.windowNumber) && $0.onScreen
            } == true
        }, "WindowServer registers the native test host")
        let picker = NSOpenPanel()
        picker.directoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
        var allowedIDs: Set<CGWindowID> = [CGWindowID(host.windowNumber)]
        let tracker = CodexWindowTracker(snapshot: {
            CodexWindowTracker.windows(processIDs: [ProcessInfo.processInfo.processIdentifier])?.filter { allowedIDs.contains($0.id) }
        })
        let subject = AppDelegate(windowTracker: tracker, hostIsFrontmost: { true })
        subject.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        subject.positionPanel()
        guard let floating = NSApp.windows.first(where: { $0.title == "Codex 剩余用量" && $0.isVisible }) else {
            check(false, "docked widget is visible above a real native host"); return
        }
        let anchor = WidgetLayout.anchor(in: host.frame)
        check(floating.frame.origin == anchor && floating.level == .normal, "docked window uses the main host's anchor and normal level")
        picker.beginSheetModal(for: host) { _ in }
        allowedIDs.insert(CGWindowID(picker.windowNumber))
        let pickerReady = waitFor { picker.isVisible && tracker.selection()?.blocked == true }
        if !pickerReady {
            print("Picker state:", picker.isVisible, "IDs:", allowedIDs,
                  "WindowServer:", CodexWindowTracker.windows(processIDs: [ProcessInfo.processInfo.processIdentifier]) as Any)
        }
        check(pickerReady, "a real native file picker is open")
        check(tracker.selection()?.window.id == CGWindowID(host.windowNumber), "native picker leaves main-window identity unchanged")
        subject.positionPanel()
        check(!floating.isVisible, "docked widget hides while the real file picker is open")
        check(floating.frame.origin == anchor, "file picker never becomes the widget's anchor")
        let restarted = CodexWindowTracker(snapshot: {
            CodexWindowTracker.windows(processIDs: [ProcessInfo.processInfo.processIdentifier])?.filter { allowedIDs.contains($0.id) }
        })
        check(restarted.selection()?.window.id == CGWindowID(host.windowNumber) && restarted.selection()?.blocked == true,
              "a cold tracker recognizes the main host behind a real picker")
        picker.cancel(nil)
        check(waitFor { tracker.selection()?.blocked == false }, "WindowServer removes the canceled picker")
        subject.positionPanel()
        check(floating.isVisible && floating.frame.origin == anchor, "canceling the picker restores the widget to the same main anchor")
        host.setFrameOrigin(NSPoint(x: host.frame.minX + 24, y: host.frame.minY + 16))
        check(waitFor { tracker.selection()?.window.frame == host.frame }, "WindowServer reports the moved main host")
        subject.positionPanel()
        check(floating.frame.origin == WidgetLayout.anchor(in: host.frame), "normal following still works after canceling the picker")
        subject.perform(NSSelectorFromString("freeMode"))
        check(floating.level == .floating && floating.isVisible, "free-floating mode retains its independent floating level")
        subject.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        floating.orderOut(nil)
        host.close()
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
