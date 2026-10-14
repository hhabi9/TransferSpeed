import Foundation

enum Format {
    static func bytes(_ count: Int64) -> String {
        count.formatted(.byteCount(style: .file))
    }

    /// Decimal megabytes per second, matching how drive makers and most disk tools report speed.
    static func speed(_ bytesPerSecond: Double) -> (value: String, unit: String) {
        let megabytes = max(0, bytesPerSecond) / 1_000_000
        let digits = megabytes >= 100 ? 0 : megabytes >= 10 ? 1 : 2
        return (megabytes.formatted(.number.precision(.fractionLength(digits))), "MB/s")
    }

    static func speedText(_ bytesPerSecond: Double) -> String {
        let parts = speed(bytesPerSecond)
        return "\(parts.value) \(parts.unit)"
    }

    static func duration(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "—" }
        let pattern: Duration.TimeFormatStyle.Pattern = seconds >= 3600 ? .hourMinuteSecond : .minuteSecond
        return Duration.seconds(seconds).formatted(.time(pattern: pattern))
    }
}
