import Foundation

/// Cross-platform token formatting utilities. No AppKit/SwiftUI dependencies.
/// Mirrors the Mac's `TokenFormatter`, including its rounding rules (upstream #365, #418): a unit is
/// chosen from the value the user will see, not the raw one, so no readout ever says "1000.0K",
/// "$100.0" or "80.0%".
public enum TokenFormatter {
    /// 987 → "987", 12_345 → "12.3K", 190_612_940 → "190.6M", 1_240_000_000 → "1.24B"
    public static func compact(_ value: Int) -> String {
        let v = Double(abs(value))
        let sign = value < 0 ? "-" : ""
        switch v {
        case ..<1_000:
            return "\(value)"
        // K and M use one decimal: promote when rounding would display 1000.0.
        case ..<999_950:
            return sign + trim(v / 1_000, decimals: 1) + "K"
        case ..<999_950_000:
            return sign + trim(v / 1_000_000, decimals: 1) + "M"
        default:
            return sign + trim(v / 1_000_000_000, decimals: 2) + "B"
        }
    }

    public static func cost(_ usd: Double) -> String {
        String(format: "$%.2f", usd)
    }

    /// Short cost readout: $9.5 / $311 / $1.2K
    /// The band is picked from the *rounded string*, not the raw value — 99.96 is "$100", not "$100.0".
    public static func costCompact(_ usd: Double) -> String {
        let tenths = String(format: "%.1f", usd)
        if let v = Double(tenths), v < 100 { return "$" + tenths }
        let whole = String(format: "%.0f", usd)
        if let v = Double(whole), v < 10_000 { return "$" + whole }
        return String(format: "$%.1fK", usd / 1_000)
    }

    /// 79.96 → "80%" (not "80.0%"), 88.35 → "88.3%"
    public static func percent(_ value: Double) -> String {
        let tenths = String(format: "%.1f", value)
        return (tenths.hasSuffix(".0") ? String(tenths.dropLast(2)) : tenths) + "%"
    }

    private static func trim(_ value: Double, decimals: Int) -> String {
        var s = String(format: "%.\(decimals)f", value)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}
