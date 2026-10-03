import Foundation

/// Claude limit windows for the phone, built in one place for both devices.
///
/// The Mac builds them from its own fetch with its localized labels (`AppDelegate.phoneLimitStatus`).
/// The iPhone builds them from the limits it fetches itself with the shared session key, reusing
/// the labels the Mac last sent, so a recount never changes how a window is named.
public enum PhoneClaudeLimits {
    public struct Labels: Sendable {
        public var fiveHour: String
        public var weekly: String
        public var opusWeekly: String
        public var sonnetWeekly: String
        public var scoped: @Sendable (_ model: String?) -> String

        public init(fiveHour: String, weekly: String, opusWeekly: String, sonnetWeekly: String,
                    scoped: @escaping @Sendable (String?) -> String) {
            self.fiveHour = fiveHour
            self.weekly = weekly
            self.opusWeekly = opusWeekly
            self.sonnetWeekly = sonnetWeekly
            self.scoped = scoped
        }

        /// The Mac's labels where it sent that window; English otherwise (a window the Mac has not
        /// seen yet, or no Mac payload at all). The phone has no copy of the Mac's string table.
        public static func reusing(_ mac: PhoneLimitStatus?) -> Labels {
            let scopedLabels = Dictionary((mac?.claudeScoped ?? []).compactMap { w in w.scopeModel.map { ($0, w.label) } },
                                          uniquingKeysWith: { a, _ in a })
            return Labels(
                fiveHour: mac?.claude5h?.label ?? "Claude 5h",
                weekly: mac?.claudeWeekly?.label ?? "Claude Weekly",
                opusWeekly: mac?.claudeOpusWeekly?.label ?? "Claude Weekly Opus",
                sonnetWeekly: mac?.claudeSonnetWeekly?.label ?? "Claude Weekly Sonnet",
                scoped: { model in
                    model.flatMap { scopedLabels[$0] } ?? model.map { "Claude Weekly \($0)" } ?? "Claude Weekly (scoped)"
                })
        }
    }

    public struct Windows: Sendable, Equatable {
        public var fiveHour: PhoneLimitWindow?
        public var weekly: PhoneLimitWindow?
        public var opusWeekly: PhoneLimitWindow?
        public var sonnetWeekly: PhoneLimitWindow?
        public var scoped: [PhoneLimitWindow]?
    }

    /// A window exists only when the source reported a utilization — the same rule the Mac's
    /// popover follows. Model weekly windows outside the legacy Opus/Sonnet fields come from
    /// `limits[]` (`scopedLimitEntries`).
    public static func windows(_ limits: LimitStatus?, labels: Labels) -> Windows {
        func window(_ w: LimitWindow?, _ label: String, _ span: TimeInterval) -> PhoneLimitWindow? {
            w?.utilization.map { PhoneLimitWindow(label: label, utilization: $0, resetsAt: w?.resetDate, windowDuration: span) }
        }
        let scoped: [PhoneLimitWindow] = (limits?.scopedLimitEntries ?? []).compactMap { entry in
            guard let percent = entry.percent else { return nil }
            let model = entry.scope?.model?.displayName
            return PhoneLimitWindow(label: labels.scoped(model), utilization: percent,
                                    resetsAt: entry.resetsAt.flatMap { ISO8601Parser.date(from: $0) },
                                    windowDuration: LimitWindowSpan.sevenDay, scopeModel: model)
        }
        return Windows(
            fiveHour: window(limits?.fiveHour, labels.fiveHour, LimitWindowSpan.fiveHour),
            weekly: window(limits?.sevenDay, labels.weekly, LimitWindowSpan.sevenDay),
            opusWeekly: window(limits?.sevenDayOpus, labels.opusWeekly, LimitWindowSpan.sevenDay),
            sonnetWeekly: window(limits?.sevenDaySonnet, labels.sonnetWeekly, LimitWindowSpan.sevenDay),
            scoped: scoped.isEmpty ? nil : scoped)
    }

    /// The Mac's limits with its Claude windows replaced by the phone's own fetch. Every other
    /// provider's windows, the thresholds, the plan and the history stay the Mac's.
    public static func overlay(_ mac: PhoneLimitStatus?, fresh: LimitStatus) -> PhoneLimitStatus {
        let w = windows(fresh, labels: .reusing(mac))
        return PhoneLimitStatus(
            claude5h: w.fiveHour, claudeWeekly: w.weekly,
            claudeOpusWeekly: w.opusWeekly, claudeSonnetWeekly: w.sonnetWeekly,
            claudeScoped: w.scoped,
            codexPrimary: mac?.codexPrimary, codexSecondary: mac?.codexSecondary,
            opencodeGo5h: mac?.opencodeGo5h, opencodeGoWeekly: mac?.opencodeGoWeekly,
            opencodeGoMonthly: mac?.opencodeGoMonthly,
            antigravity: mac?.antigravity,
            planDisplay: mac?.planDisplay,
            warnThreshold: mac?.warnThreshold, critThreshold: mac?.critThreshold,
            history: mac?.history)
    }
}
