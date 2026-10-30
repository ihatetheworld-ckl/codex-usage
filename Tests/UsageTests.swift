import Foundation

@main
struct UsageTests {
    static var assertions = 0
    static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        assertions += 1
        if !condition() { fputs("FAIL: \(label)\n", stderr); exit(1) }
    }
    static func decode(_ json: String) throws -> UsagePayload {
        try JSONDecoder().decode(UsagePayload.self, from: Data(json.utf8))
    }
    static func main() throws {
        let liveShape = try decode(#"{"rateLimits":{"primary":{"usedPercent":90,"windowDurationMins":300}},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":14,"windowDurationMins":300,"resetsAt":2000000000},"secondary":{"usedPercent":10,"windowDurationMins":10080}}}}"#)
        check(liveShape.window(minutes: 300)?.validPercent == 14, "multi-bucket wins")
        check(liveShape.window(minutes: 10080)?.validPercent == 10, "weekly bucket")
        check(UsageText.percent(liveShape.window(minutes: 300), remaining: false) == "14%", "used percent")
        check(UsageText.percent(liveShape.window(minutes: 300), remaining: true) == "86%", "remaining percent")
        check(liveShape.window(minutes: 300)?.remainingPercent == 86, "remaining meter equals remaining label")
        let missing = try decode(#"{"rateLimits":{"primary":{"usedPercent":80,"windowDurationMins":300}},"rateLimitsByLimitId":{"other":{"primary":{"usedPercent":1,"windowDurationMins":300}}}}"#)
        check(missing.window(minutes: 300) == nil, "never show another bucket or stale legacy fallback")
        let noValues = try decode(#"{"rateLimits":{"primary":{"usedPercent":null,"windowDurationMins":300},"secondary":null}}"#)
        check(UsageText.percent(noValues.window(minutes: 300), remaining: false) == "—", "null is unknown")
        check(noValues.window(minutes: 300)?.remainingPercent == nil, "unknown remaining meter")
        check(UsageText.percent(nil, remaining: true) == "—", "missing remaining is unknown")
        let swapped = try decode(#"{"rateLimits":{"primary":{"usedPercent":21,"windowDurationMins":10080},"secondary":{"usedPercent":3,"windowDurationMins":300}}}"#)
        check(swapped.window(minutes: 300)?.validPercent == 3, "identify windows by duration")
        check(swapped.window(minutes: 10080)?.validPercent == 21, "swapped weekly duration")
        let unknownDuration = try decode(#"{"rateLimits":{"primary":{"usedPercent":7,"windowDurationMins":15}}}"#)
        check(unknownDuration.window(minutes: 300) == nil, "15 minute window is not 5 hours")
        for invalid in [-1.0, 101.0, Double.infinity, Double.nan] {
            check(UsageWindow(usedPercent: invalid, windowDurationMins: 300, resetsAt: nil).validPercent == nil, "invalid percent rejected")
        }
        for edge in [0.0, 100.0] {
            check(UsageWindow(usedPercent: edge, windowDurationMins: 300, resetsAt: nil).validPercent == edge, "quota boundary accepted")
            check(UsageWindow(usedPercent: edge, windowDurationMins: 300, resetsAt: nil).remainingPercent == 100 - edge, "remaining quota boundary")
        }
        let due = UsageWindow(usedPercent: 100, windowDurationMins: 300, resetsAt: 1000)
        check(UsageText.reset(due, now: Date(timeIntervalSince1970: 1001)) == "重置时间已到 · 待刷新", "no invented reset")
        check(UsageText.percent(due, remaining: false) == "100%", "keep server percentage until refresh")
        check(UsageText.reset(nil) == "重置时间未知", "unknown reset")
        check(UsageText.reset(due, now: Date(timeIntervalSince1970: 999)) == "1 分钟后重置", "round future minute up")
        print("PASS: \(assertions) usage assertions")
    }
}
