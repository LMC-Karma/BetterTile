import Foundation

public enum NativeAuditClock {
    public static var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime } // real-time: audit timestamps correlate with system logs and do not drive test timing
    public static var utc: String { Date().ISO8601Format(.iso8601(timeZone: .gmt, includingFractionalSeconds: true)) } // real-time: audit timestamps correlate with system logs and do not drive test timing
}
