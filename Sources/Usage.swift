import Foundation

struct UsageWindow: Decodable, Equatable {
    let usedPercent: Double?
    let windowDurationMins: Int?
    let resetsAt: Double?

    var validPercent: Double? {
        guard let value = usedPercent, value.isFinite, (0...100).contains(value) else { return nil }
        return value
    }
    var resetDate: Date? { resetsAt.map(Date.init(timeIntervalSince1970:)) }
    var remainingPercent: Double? { validPercent.map { 100 - $0 } }
}

struct UsageBucket: Decodable {
    let limitId: String?
    let primary: UsageWindow?
    let secondary: UsageWindow?
    let planType: String?
}

struct UsagePayload: Decodable {
    let rateLimits: UsageBucket?
    let rateLimitsByLimitId: [String: UsageBucket]?
    let accountId: String?

    var codex: UsageBucket? {
        // A present multi-bucket response is authoritative. Never use another model's quota.
        if let buckets = rateLimitsByLimitId { return buckets["codex"] }
        guard rateLimits?.limitId == nil || rateLimits?.limitId == "codex" else { return nil }
        return rateLimits
    }
    func window(minutes: Int) -> UsageWindow? {
        [codex?.primary, codex?.secondary].compactMap { $0 }.first { $0.windowDurationMins == minutes }
    }
}

enum UsageText {
    static func percent(_ window: UsageWindow?, remaining: Bool) -> String {
        guard let used = window?.validPercent else { return "—" }
        return "\(Int((remaining ? 100 - used : used).rounded()))%"
    }

    static func reset(_ window: UsageWindow?, now: Date = Date()) -> String {
        guard let date = window?.resetDate else { return "重置时间未知" }
        let seconds = Int(date.timeIntervalSince(now))
        guard seconds > 0 else { return "重置时间已到 · 待刷新" }
        let minutes = max(1, Int(ceil(Double(seconds) / 60)))
        if minutes < 60 { return "\(minutes) 分钟后重置" }
        if minutes < 1440 { return "\(minutes / 60) 小时 \(minutes % 60) 分后重置" }
        return "\(minutes / 1440) 天 \((minutes % 1440) / 60) 小时后重置"
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
