import Foundation

/// Time series of official rate-limit utilization, recorded locally.
///
/// Every limit endpoint we consume (`api/oauth/usage`, the Codex app-server snapshot, …) reports a
/// **current snapshot only** — a percentage plus a reset instant. Once a window resets, how much of
/// it was consumed is gone: Anthropic exposes no per-account limit history (the Admin usage/cost and
/// Claude Code Analytics APIs are org-scoped, need an admin credential, and report tokens/dollars,
/// never window utilization), and Claude Code writes no limit state to disk either. So the only way
/// to answer "am I on the right plan" is to keep the samples ourselves as they go by.
///
/// Storage is a **sample log**, not pre-aggregated windows. Keying records by `resets_at` looks
/// tempting and is wrong: the weekly window is rolling and its `resets_at` moves on every fetch
/// (see the `notifiedTier` comment in `UsageStore` — that same field already caused a re-notify
/// regression). Windows are instead *derived* at read time by finding resets in the utilization
/// series, which holds regardless of how a provider chooses to express its reset instant.
@MainActor
final class LimitHistoryStore {
    static let shared = LimitHistoryStore()

    struct Sample: Codable, Sendable, Equatable {
        let at: Date
        let utilization: Double
    }

    /// One derived limit window: the span between two resets.
    struct Window: Sendable, Equatable {
        let start: Date
        let end: Date
        let peak: Double
        let sampleCount: Int
        /// The window ended while the app was not running, so usage between the last sample and
        /// the reset went unobserved: `peak` is a lower bound, and whole windows may have come and
        /// gone inside the gap. Surfaced so the UI can say "partial" instead of quietly presenting
        /// a hole as a fact.
        let truncated: Bool
    }

    struct Summary: Sendable, Equatable {
        let windows: [Window]
        let peak: Double
        let median: Double
        /// Windows whose peak reached `threshold` — a lower bound when `hasTruncated`.
        let atOrAbove: Int
        let hasTruncated: Bool

        var isEmpty: Bool { windows.isEmpty }
    }

    // MARK: - Tuning

    /// Below this the series is noise, not signal: a flat window still gets one sample per
    /// heartbeat so "we were watching and nothing happened" is distinguishable from a gap.
    static let heartbeat: TimeInterval = 15 * 60
    /// Utilization moves smaller than this are not worth a row (the endpoint reports fractions).
    static let minimumDelta: Double = 0.5
    /// Fallback window length for a series whose key has no registered duration — the shortest
    /// window any provider reports, so an unknown series errs toward splitting at a gap.
    static let defaultWindowDuration: TimeInterval = 5 * 60 * 60
    static let retention: TimeInterval = 90 * 24 * 60 * 60
    /// Backstop against unbounded growth if a provider ever reports jittery utilization: at the
    /// 15-minute heartbeat, 90 days of one window is ~8.6k samples, so this is headroom, not a cap
    /// that bites in normal use. Oldest are dropped first.
    static let maxSamplesPerSeries = 20_000

    // MARK: - State

    private var series: [String: [Sample]] = [:]
    private var loaded = false
    private var dirty = false
    private var lastSave: Date?

    private let fileURL: URL
    private let now: () -> Date
    /// Whether this instance may touch disk — `AppEnv.persistsToUserLocation`.
    /// Internal rather than private so tests can assert the gate without doing IO.
    let persists: Bool

    init(fileURL: URL? = nil, now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL ?? Self.defaultFileURL
        self.now = now
        // Without this gate, every `swift test` run that constructs a `UsageStore` would read and
        // rewrite the user's actual `limit-history.json`, since `UsageStore` defaults to `.shared`.
        self.persists = AppEnv.persistsToUserLocation(injectedFileURL: fileURL)
    }

    private static let defaultFileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PokeTokenBar")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("limit-history.json")
    }()

    /// Series key. Provider-scoped so adding Codex/OpenCode/Antigravity history is a call site
    /// rather than a new subsystem — no provider literal lives inside this store
    /// (`docs/reference/provider-extension.md`).
    static func key(providerID: String, window: String) -> String { "\(providerID)/\(window)" }

    // MARK: - Recording

    /// Append one observation per window, subject to the downsampling policy.
    /// `windows` is `(window key, utilization 0…100)`; nil utilizations are dropped by the caller.
    func record(providerID: String, windows: [(window: String, utilization: Double)]) {
        guard !windows.isEmpty else { return }
        ensureLoaded()
        let at = now()
        for (window, utilization) in windows {
            let key = Self.key(providerID: providerID, window: window)
            let candidate = Sample(at: at, utilization: utilization)
            guard Self.shouldRecord(previous: series[key]?.last, candidate: candidate,
                                    heartbeat: Self.heartbeat, minimumDelta: Self.minimumDelta)
            else { continue }
            series[key, default: []].append(candidate)
            dirty = true
        }
        saveIfNeeded()
    }

    /// Downsampling policy. Deliberately does **not** trigger on a changed reset instant: the
    /// rolling weekly window reports a new `resets_at` on every single fetch, so keying off it
    /// would store every poll and defeat the whole policy.
    static func shouldRecord(previous: Sample?, candidate: Sample,
                             heartbeat: TimeInterval, minimumDelta: Double) -> Bool
    {
        guard let previous else { return true }
        // Clock moved backwards (sleep/wake, NTP step): keep the series monotonic in time rather
        // than appending a sample that would read as a gap-then-jump to the window splitter.
        if candidate.at <= previous.at { return false }
        if abs(candidate.utilization - previous.utilization) >= minimumDelta { return true }
        return candidate.at.timeIntervalSince(previous.at) >= heartbeat
    }

    // MARK: - Reading

    func samples(providerID: String, window: String) -> [Sample] {
        ensureLoaded()
        return series[Self.key(providerID: providerID, window: window)] ?? []
    }

    /// Derived windows for one series, newest last.
    func windows(providerID: String, window: String) -> [Window] {
        Self.windows(from: samples(providerID: providerID, window: window),
                     windowDuration: Self.windowDurations[window] ?? Self.defaultWindowDuration)
    }

    /// Length of each recorded window, keyed by window id. Each provider adapter below contributes
    /// its own entries, so the splitter never branches on a provider.
    static let windowDurations: [String: TimeInterval] =
        ClaudeWindow.durations.merging(AntigravityWindow.durations) { first, _ in first }

    func summary(providerID: String, window: String, threshold: Double, limit: Int) -> Summary {
        Self.summarize(windows(providerID: providerID, window: window),
                       threshold: threshold, limit: limit)
    }

    // MARK: - Derivation (pure)

    /// Split a sample series into windows at resets, including resets hidden inside an
    /// observation gap.
    ///
    /// Utilization is cumulative within a window: it only climbs until the reset (bar a rolling
    /// window's slow decay). So when the app resumes after a gap *inside* the same window, the
    /// first sample already includes everything used while it was not running — nothing was lost,
    /// and the gap is neither a boundary nor a reason to dim. A gap only hides something when a
    /// reset fell inside it; then the tail of the window before it went unobserved. That is
    /// certain when the gap outlasts the window, and evident when utilization came back lower.
    ///
    /// Splitting at every gap longer than a 5-hour session used to shatter one weekly window into
    /// a bar per night the Mac slept, all dimmed, inflating "N of 14" (see defect-log).
    ///
    /// Blind spot: a gap shorter than the window that straddles a reset *and* is followed by
    /// usage climbing past the old level reads as one window. Recording `resets_at` would close
    /// it, but the rolling weekly window's instant moves on every fetch, so it is not a key.
    static func windows(from samples: [Sample], windowDuration: TimeInterval) -> [Window] {
        guard !samples.isEmpty else { return [] }
        var result: [Window] = []
        var current: [Sample] = [samples[0]]

        func flush(truncated: Bool) {
            guard let first = current.first, let last = current.last else { return }
            result.append(Window(
                start: first.at, end: last.at,
                peak: current.map(\.utilization).max() ?? 0,
                sampleCount: current.count,
                truncated: truncated))
        }

        for sample in samples.dropFirst() {
            let previous = current[current.count - 1]
            let gap = sample.at.timeIntervalSince(previous.at)
            let resetInGap = gap >= windowDuration
                || (gap > heartbeat && previous.utilization - sample.utilization >= 5.0)
            if resetInGap {
                // The window before the gap ended unobserved. The one we resume into is exact:
                // its first sample already counts all usage since its own reset.
                flush(truncated: true)
                current = [sample]
                continue
            }
            if isReset(previous: previous.utilization, current: sample.utilization) {
                flush(truncated: false)
                current = [sample]
                continue
            }
            current.append(sample)
        }
        flush(truncated: false)
        return result
    }

    /// Did the window reset between these two utilizations?
    ///
    /// Not simply "it went down". The weekly window is rolling, so its utilization *drifts*
    /// downward as old usage ages out; treating any decrease as a boundary shatters the weekly
    /// history into dozens of fake windows. A reset drops utilization to near zero, so require the
    /// value to at least halve **and** the absolute fall to be material.
    static func isReset(previous: Double, current: Double) -> Bool {
        current <= previous / 2 && (previous - current) >= 5.0
    }

    static func summarize(_ windows: [Window], threshold: Double, limit: Int) -> Summary {
        let recent = Array(windows.suffix(limit))
        guard !recent.isEmpty else {
            return Summary(windows: [], peak: 0, median: 0, atOrAbove: 0, hasTruncated: false)
        }
        let peaks = recent.map(\.peak).sorted()
        let median = peaks.count % 2 == 1
            ? peaks[peaks.count / 2]
            : (peaks[peaks.count / 2 - 1] + peaks[peaks.count / 2]) / 2
        return Summary(
            windows: recent,
            peak: peaks.last ?? 0,
            median: median,
            atOrAbove: recent.filter { $0.peak >= threshold }.count,
            hasTruncated: recent.contains(where: \.truncated))
    }

    static func pruned(_ samples: [Sample], now: Date,
                       retention: TimeInterval, maxCount: Int) -> [Sample]
    {
        let cutoff = now.addingTimeInterval(-retention)
        var kept = samples.filter { $0.at >= cutoff }
        if kept.count > maxCount { kept.removeFirst(kept.count - maxCount) }
        return kept
    }

    // MARK: - Persistence

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        guard persists,
              let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode([String: [Sample]].self, from: data)
        else { return }
        series = stored
    }

    private func saveIfNeeded() {
        guard dirty else { return }
        if let lastSave, now().timeIntervalSince(lastSave) < 60 { return }
        flush()
    }

    /// Write now, ignoring the throttle. Called on app termination so the tail of the series
    /// survives a quit — without it, up to a minute of samples is lost on every launch/quit cycle.
    func flush() {
        guard dirty else { return }
        let at = now()
        for (key, samples) in series {
            series[key] = Self.pruned(samples, now: at, retention: Self.retention,
                                      maxCount: Self.maxSamplesPerSeries)
        }
        series = series.filter { !$0.value.isEmpty }
        // Pruning above still runs so an unbundled run stays memory-bounded; only the write stops.
        guard persists else { dirty = false; lastSave = at; return }
        guard let data = try? JSONEncoder().encode(series) else { return }
        try? data.write(to: fileURL, options: .atomic)
        dirty = false
        lastSave = at
    }
}

// MARK: - Claude adapter

extension LimitHistoryStore {
    /// Window keys for the Claude limit response. Stable identifiers — they are persisted, so
    /// renaming one orphans that history.
    enum ClaudeWindow {
        static let fiveHour = "five_hour"
        static let sevenDay = "seven_day"

        /// Display order for the history section, matching the live limit rows above it.
        static let displayed = [fiveHour, sevenDay]

        static let durations: [String: TimeInterval] = [
            fiveHour: 5 * 60 * 60,
            sevenDay: 7 * 24 * 60 * 60,
        ]
    }

    /// Flatten a `LimitStatus` into recordable windows. Only the two windows every plan reports are
    /// kept: the model-scoped weekly entries come and go with plan changes and would leave dangling
    /// series, and the session/weekly pair is what actually answers "is my tier right".
    static func claudeWindows(from status: LimitStatus) -> [(window: String, utilization: Double)] {
        var result: [(window: String, utilization: Double)] = []
        if let utilization = status.fiveHour?.utilization {
            result.append((ClaudeWindow.fiveHour, utilization))
        }
        if let utilization = status.sevenDay?.utilization {
            result.append((ClaudeWindow.sevenDay, utilization))
        }
        return result
    }
}

// MARK: - Antigravity adapter

extension LimitHistoryStore {
    /// Window keys for the Antigravity limit response. Stable identifiers — they are persisted, so
    /// renaming one orphans that history.
    enum AntigravityWindow {
        static let geminiFiveHour = "gemini_5h"
        static let geminiWeekly = "gemini_weekly"
        static let thirdPartyFiveHour = "third_party_5h"
        static let thirdPartyWeekly = "third_party_weekly"

        /// Display order for the history section, matching the live limit rows above it.
        static let displayed = [
            geminiFiveHour,
            geminiWeekly,
            thirdPartyFiveHour,
            thirdPartyWeekly,
        ]

        static let durations: [String: TimeInterval] = [
            geminiFiveHour: 5 * 60 * 60,
            geminiWeekly: 7 * 24 * 60 * 60,
            thirdPartyFiveHour: 5 * 60 * 60,
            thirdPartyWeekly: 7 * 24 * 60 * 60,
        ]
    }

    /// Flatten an `AntigravityRateLimitStatus` into recordable windows.
    static func antigravityWindows(from status: AntigravityRateLimitStatus) -> [(window: String, utilization: Double)] {
        var result: [(window: String, utilization: Double)] = []
        if let gemini = status.geminiGroup {
            if let fiveHour = gemini.fiveHourBucket {
                result.append((AntigravityWindow.geminiFiveHour, fiveHour.usedPercent))
            }
            if let weekly = gemini.weeklyBucket {
                result.append((AntigravityWindow.geminiWeekly, weekly.usedPercent))
            }
        }
        if let tp = status.thirdPartyGroup {
            if let fiveHour = tp.fiveHourBucket {
                result.append((AntigravityWindow.thirdPartyFiveHour, fiveHour.usedPercent))
            }
            if let weekly = tp.weeklyBucket {
                result.append((AntigravityWindow.thirdPartyWeekly, weekly.usedPercent))
            }
        }
        return result
    }
}
