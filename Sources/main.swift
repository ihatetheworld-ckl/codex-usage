import AppKit

if CommandLine.arguments.contains("--probe") {
    // Probe the exact same transport used by the app without starting a GUI or model turn.
    let client = CodexClient()
    var finished = false
    var exitCode: Int32 = 1
    client.onUsage = { payload in
        let result: [String: Any] = [
            "fiveHourRemainingPercent": payload.window(minutes: 300)?.remainingPercent as Any? ?? NSNull(),
            "weeklyRemainingPercent": payload.window(minutes: 10080)?.remainingPercent as Any? ?? NSNull(),
            "fiveHourUsedPercent": payload.window(minutes: 300)?.validPercent as Any? ?? NSNull(),
            "weeklyUsedPercent": payload.window(minutes: 10080)?.validPercent as Any? ?? NSNull(),
            "fiveHourResetsAt": payload.window(minutes: 300)?.resetsAt as Any? ?? NSNull(),
            "weeklyResetsAt": payload.window(minutes: 10080)?.resetsAt as Any? ?? NSNull()
        ]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) { print(text) }
        exitCode = payload.window(minutes: 300)?.validPercent != nil && payload.window(minutes: 10080)?.validPercent != nil ? 0 : 2
        finished = true
    }
    client.onError = { message in fputs("\(message)\n", stderr); finished = true }
    client.refresh()
    let deadline = Date().addingTimeInterval(25)
    while !finished && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    client.stop()
    exit(exitCode)
}

if CommandLine.arguments.contains("--quit") {
    for running in NSRunningApplication.runningApplications(withBundleIdentifier: "local.codex-usage-sidebar")
        where running.processIdentifier != ProcessInfo.processInfo.processIdentifier { running.terminate() }
    exit(0)
}

if NSRunningApplication.runningApplications(withBundleIdentifier: "local.codex-usage-sidebar").contains(where: {
    $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
}) { exit(0) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
