import SwiftUI
import PokeTokenBarShared

struct DashboardView: View {
    @Environment(PhonePayloadStore.self) private var store

    var body: some View {
        NavigationStack {
            Group {
                if !store.hasCompletedInitialFetch {
                    LaunchView()
                        .task { await store.fetch() }
                } else if store.host.isEmpty && store.payload == nil {
                    SetupView()
                } else if let payload = store.payload {
                    dashboardContent(payload)
                } else if store.isLoading {
                    ProgressView("Connecting to Mac...")
                } else if let error = store.lastError {
                    errorView(error)
                } else {
                    ProgressView("Connecting to Mac...")
                        .task { await store.fetch() }
                }
            }
            .navigationTitle("PokeTokenBar")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(destination: SettingsView().environment(store)) {
                        Image(systemName: "gear")
                    }
                }
            }
            .refreshable { await store.fetch() }
            .task { await store.fetch() }
        }
    }

    @ViewBuilder
    private func dashboardContent(_ payload: PhonePayload) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                SourceIndicator(source: store.source, connected: store.isConnected, lastUpdated: payload.lastUpdated, lastFetchSucceeded: store.lastFetchSucceeded)

                if let incidents = payload.incidents, !incidents.isEmpty {
                    ForEach(incidents) { incident in
                        IncidentBanner(incident: incident)
                    }
                }

                if let companion = payload.companion {
                    CompanionCard(companion: companion)
                }

                UsageCard(payload: payload)

                if let trend = payload.dailyTrend, trend.contains(where: { $0.totalTokens > 0 }) {
                    DailyTrendCard(days: trend)
                }

                if let limits = payload.limits {
                    LimitsCard(limits: limits, isProviderVisible: { store.isProviderVisible($0) })
                    let history = filteredHistory(limits.history ?? [])
                    if !history.isEmpty {
                        LimitHistoryCard(series: history, limits: limits)
                    }
                }

                let providers = store.visibleProviders
                if !providers.isEmpty {
                    ForEach(providers, id: \.id) { provider in
                        ProviderDetailCard(provider: provider)
                    }
                }

                Text("Mac app v\(payload.serverVersion)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding()
        }
    }

    private func filteredHistory(_ series: [PhoneLimitHistorySeries]) -> [PhoneLimitHistorySeries] {
        let showClaude = store.isProviderVisible("claude_code")
        let showAgy = store.isProviderVisible("antigravity")
        return series.filter { s in
            let isAgy = s.label.localizedCaseInsensitiveContains("gemini")
                || s.label.localizedCaseInsensitiveContains("antigravity")
                || (s.label.localizedCaseInsensitiveContains("claude") && s.label.localizedCaseInsensitiveContains("gpt"))
            if isAgy { return showAgy }
            let isClaude = s.label.localizedCaseInsensitiveContains("claude")
            if isClaude { return showClaude }
            return true
        }
    }

    @ViewBuilder
    private func errorView(_ error: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.slash")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Cannot connect to Mac")
                .font(.headline)
            Text(error)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry") { Task { await store.fetch() } }
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

// MARK: - Source indicator

/// Where the payload came from and how fresh it is. "Connected" was misleading for iCloud
/// (there is no live connection) — show the source and the Mac-side timestamp instead.
struct SourceIndicator: View {
    let source: PhonePayloadStore.Source?
    let connected: Bool
    let lastUpdated: Date
    /// Whether the most recent fetch() call succeeded. nil before first attempt.
    var lastFetchSucceeded: Bool? = nil

    private var isStale: Bool { Date().timeIntervalSince(lastUpdated) > 30 * 60 }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: source == .localNetwork ? "wifi" : "icloud")
                    .font(.caption2)
                    .foregroundStyle(connected && !isStale ? Color.green : (isStale ? Color.orange : Color.red))
                Text(sourceLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("·")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text("updated \(lastUpdated, style: .relative) ago")
                    .font(.caption)
                    .foregroundStyle(isStale ? .orange : .secondary)
            }
            if lastFetchSucceeded == false, isStale {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.caption2)
                    Text("Couldn't refresh — showing cached data")
                        .font(.caption2)
                }
                .foregroundStyle(.orange)
            }
        }
    }

    private var sourceLabel: String {
        switch source {
        case .iCloud: return String(localized: "iCloud")
        case .localNetwork: return String(localized: "Local network")
        case nil: return String(localized: "Cached")
        }
    }
}

// MARK: - Companion Card

struct CompanionCard: View {
    let companion: PhoneCompanionState

    var body: some View {
        VStack(spacing: 12) {
            if companion.isEgg {
                Text("🥚")
                    .font(.system(size: 64))
                    .accessibilityLabel("Token egg, \(Int(companion.eggProgress * 100)) percent hatched")
                Text("Token Egg")
                    .font(.title2.bold())
                ProgressView(value: companion.eggProgress)
                    .tint(.purple)
                Text("\(Int(companion.eggProgress * 100))% hatched")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                if let id = companion.speciesID {
                    AnimatedSpeciesSprite(speciesID: id, shiny: companion.isShiny, size: 96)
                }

                HStack {
                    Text(companion.name)
                        .font(.title2.bold())
                    if companion.isShiny {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.yellow)
                            .accessibilityLabel("Shiny")
                    }
                }

                if let rarity = companion.rarity {
                    Text(RarityStyle.label(rarity).uppercased())
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(rarityColor.opacity(0.2))
                        .foregroundStyle(rarityColor)
                        .clipShape(Capsule())
                }

                // Stage + nature on one line, same as the Mac header ("Stage 1/3 · Jolly").
                Text([companion.stageText, companion.natureText].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                ProgressView(value: companion.progress)
                    .tint(companion.isShiny ? .yellow : .blue)

                if let remaining = companion.tokensRemainingText {
                    Text(remaining)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let nodes = companion.lineNodes, nodes.count > 1 {
                    EvolutionLineStrip(nodes: nodes)
                }
            }

            if let status = companion.statusText, !status.isEmpty {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .italic()
                    .multilineTextAlignment(.center)
            }
        }
        .accessibilityElement(children: .combine)
        .padding()
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var rarityColor: Color {
        RarityStyle.color(companion.rarity ?? "")
    }
}

extension PhoneCompanionState {
    /// Final stage when the Mac says so (evolution counter absent) or, for older Macs that send both
    /// counters, when the evolution line has no future node after the current one.
    var isFinalStage: Bool {
        if evolutionTokens == nil, graduationTokens != nil { return true }
        if let nodes = lineNodes, !nodes.isEmpty { return !nodes.contains { $0.state == .future } }
        return false
    }

    /// "1.2M to graduation" on the final form, else "1.2M to next evolution". nil when nothing to show.
    var tokensRemainingText: String? {
        if isFinalStage, let g = graduationTokens, g > 0 {
            return String(localized: "\(TokenFormatter.compact(g)) to graduation")
        }
        if let e = evolutionTokens, e > 0 {
            return String(localized: "\(TokenFormatter.compact(e)) to next evolution")
        }
        return nil
    }
}

/// Evolution line — done / current / future sprites with a "?" for an unrevealed branch,
/// mirroring the Mac's line strip. Scrolls horizontally for long lines.
struct EvolutionLineStrip: View {
    let nodes: [PhoneEvoNode]

    var body: some View {
        // Centered when the chain fits; a leading-aligned horizontal scroll only when it doesn't.
        ViewThatFits(in: .horizontal) {
            row
            ScrollView(.horizontal, showsIndicators: false) { row }
        }
        .frame(maxWidth: .infinity)
    }

    private var row: some View {
        HStack(spacing: 4) {
            ForEach(Array(nodes.enumerated()), id: \.offset) { index, node in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                VStack(spacing: 2) {
                    Group {
                        if let id = node.speciesID {
                            SpeciesSprite(speciesID: id, shiny: false, size: 40)
                                .saturation(node.state == .future ? 0 : 1)
                                .opacity(node.state == .future ? 0.45 : 1)
                        } else {
                            Text("?")
                                .font(.title3.bold())
                                .foregroundStyle(.tertiary)
                                .frame(width: 40, height: 40)
                        }
                    }
                    .padding(2)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(node.state == .current ? Color.accentColor : .clear, lineWidth: 1.5)
                    )
                    Text(node.name ?? "???")
                        .font(.system(size: 9))
                        .foregroundStyle(node.state == .current ? .primary : .secondary)
                        .lineLimit(1)
                }
                .frame(width: 56)
            }
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - Usage Card

struct UsageCard: View {
    let payload: PhonePayload

    var body: some View {
        VStack(spacing: 0) {
            statRow(icon: "calendar", title: String(localized: "Today"),
                    value: TokenFormatter.compact(payload.todayTokens),
                    cost: TokenFormatter.costCompact(payload.todayCost))
            Divider().padding(.horizontal)
            statRow(icon: "calendar.badge.clock", title: String(localized: "This Week"),
                    value: TokenFormatter.compact(payload.weekTokens),
                    cost: payload.weekCost.map(TokenFormatter.costCompact))
            Divider().padding(.horizontal)
            statRow(icon: "calendar.badge.plus", title: String(localized: "This Month"),
                    value: TokenFormatter.compact(payload.monthTokens),
                    cost: payload.monthCost.map(TokenFormatter.costCompact))
            if let burn = payload.burn, burn.depletionDate != nil || burn.tokensPerMinute != nil {
                Divider().padding(.horizontal)
                burnRow(burn)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private func statRow(icon: String, title: String, value: String, cost: String?) -> some View {
        HStack {
            Label(title, systemImage: icon)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            if let cost {
                Text(cost)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.body.monospacedDigit().bold())
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(cost != nil ? "\(title), \(value) tokens, \(cost!)" : "\(title), \(value) tokens")
        .padding(.vertical, 10)
    }

    /// Mac's "will hit the 5h limit at HH:mm" forecast row, plus the current burn rate.
    @ViewBuilder
    private func burnRow(_ burn: PhoneBurnForecast) -> some View {
        HStack {
            Label(String(localized: "Burn"), systemImage: "flame")
                .font(.subheadline)
                .foregroundStyle(burn.beforeReset ? .orange : .secondary)
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                if let at = burn.depletionDate {
                    Text(burn.beforeReset
                         ? String(localized: "5h limit at \(at.formatted(date: .omitted, time: .shortened))")
                         : String(localized: "Won't reach the 5h limit before reset"))
                        .font(.caption.weight(burn.beforeReset ? .semibold : .regular))
                        .foregroundStyle(burn.beforeReset ? .orange : .secondary)
                }
                if let tpm = burn.tokensPerMinute, tpm > 0 {
                    Text("\(TokenFormatter.compact(Int(tpm)))/min")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 10)
    }
}

// MARK: - Limits Card

/// One card per provider group (Claude / Codex / Go / Antigravity) driven by `limitGroups`, so any
/// window the Mac adds to the payload shows up here without another hand-written `if let`.
struct LimitsCard: View {
    let limits: PhoneLimitStatus
    var isProviderVisible: (String) -> Bool = { _ in true }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Rate Limits")
                    .font(.headline)
                Spacer()
                if let plan = limits.planDisplay {
                    Text(plan)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.blue.opacity(0.15))
                        .foregroundStyle(.blue)
                        .clipShape(Capsule())
                }
            }

            let groups = limits.filteredLimitGroups(isProviderVisible: isProviderVisible)
            if groups.isEmpty {
                Text("No rate limits active")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                if index > 0 { Divider() }
                VStack(alignment: .leading, spacing: 8) {
                    if groups.count > 1 {
                        Text(group.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(group.windows.enumerated()), id: \.offset) { _, w in
                        LimitRow(window: w, label: shortLabel(w.label, group: group.title, groupCount: groups.count), limits: limits)
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    /// With a group header above, drop the repeated brand prefix ("Claude Weekly" → "Weekly").
    private func shortLabel(_ label: String, group: String, groupCount: Int) -> String {
        guard groupCount > 1, label.hasPrefix(group + " ") else { return label }
        let trimmed = String(label.dropFirst(group.count + 1))
        return trimmed.isEmpty ? label : trimmed
    }
}

/// Per-window peak history for the Claude limits.
///
/// Everything here is recorded by the Mac — no API reports past limit usage, so a phone that has
/// never been paired with a running Mac has no history to show and this card simply does not
/// appear. The phone renders; it never derives. Window boundaries (a reset versus a rolling
/// window's natural decay) are decided once on the Mac.
struct LimitHistoryCard: View {
    let series: [PhoneLimitHistorySeries]
    let limits: PhoneLimitStatus

    private var hasAnyTruncated: Bool {
        series.contains(where: \.hasTruncated)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Limit History")
                    .font(.headline)
                Spacer()
                Text("recorded on Mac")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(series.enumerated()), id: \.offset) { index, entry in
                if index > 0 { Divider() }
                seriesRow(entry)
            }
            if hasAnyTruncated {
                Divider()
                Text("Dimmed windows were partly unobserved — the Mac was not running.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private func seriesRow(_ entry: PhoneLimitHistorySeries) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.label)
                    .font(.subheadline)
                Text("last \(entry.windows.count)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("peak \(TokenFormatter.percent(entry.peak))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(LimitColor.color(for: entry.peak, limits: limits))
                Text("· median \(TokenFormatter.percent(entry.median))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            bars(entry)
            // The line that answers "is my plan the right tier".
            Text("\(entry.atOrAbove) of \(entry.windows.count) reached \(TokenFormatter.percent(limits.effectiveWarnThreshold))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    /// Oldest window on the left. A 0% window still gets a sliver so its slot reads as "this window
    /// happened and was quiet" rather than as missing data.
    private func bars(_ entry: PhoneLimitHistorySeries) -> some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(entry.windows.enumerated()), id: \.offset) { _, window in
                RoundedRectangle(cornerRadius: 2)
                    .fill(LimitColor.color(for: window.peak, limits: limits))
                    .opacity(window.truncated ? 0.35 : 1)
                    .frame(maxWidth: .infinity)
                    .frame(height: max(3, Self.barHeight * min(max(window.peak, 0), 100) / 100))
                    .accessibilityLabel(Text("\(window.end, style: .date): \(TokenFormatter.percent(window.peak))"))
            }
        }
        .frame(height: Self.barHeight, alignment: .bottom)
    }

    private static let barHeight: CGFloat = 32
}

struct LimitRow: View {
    let window: PhoneLimitWindow
    var label: String? = nil
    var limits: PhoneLimitStatus? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label ?? window.label)
                    .font(.subheadline)
                Spacer()
                if let resetsAt = window.resetsAt {
                    Text("resets \(resetsAt, style: .relative)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(TokenFormatter.percent(window.utilization))
                    .font(.subheadline.monospacedDigit().bold())
                    .foregroundStyle(utilizationColor)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.quaternary)
                        .frame(height: 8)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(utilizationColor)
                        .frame(width: geo.size.width * min(1, window.utilization / 100), height: 8)
                        .animation(.easeInOut(duration: 0.3), value: window.utilization)
                    if let pace = paceFraction {
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .fill(.primary.opacity(0.65))
                            .frame(width: 2.5, height: 12)
                            .offset(x: (geo.size.width - 2.5) * pace, y: -2)
                            .allowsHitTesting(false)
                    }
                }
            }
            .accessibilityHidden(true)
            .frame(height: 8)
        }
        .accessibilityElement(children: .combine)
    }

    private var paceFraction: Double? {
        guard let resetsAt = window.resetsAt,
              let span = window.windowDuration,
              span > 0 else { return nil }
        let fraction = (span - resetsAt.timeIntervalSince(Date())) / span
        guard fraction.isFinite, (0...1).contains(fraction) else { return nil }
        return fraction
    }

    private var utilizationColor: Color {
        LimitColor.color(for: window.utilization, limits: limits)
    }
}

/// Utilization colour using the Mac's thresholds when the payload carries them.
enum LimitColor {
    static func color(for utilization: Double, limits: PhoneLimitStatus?) -> Color {
        let tier = limits?.tier(for: utilization) ?? fallbackTier(utilization)
        switch tier {
        case .critical: return .red
        case .warning: return .orange
        case .normal: return .blue
        }
    }

    private static func fallbackTier(_ u: Double) -> PhoneLimitTier {
        if u >= PhoneLimitStatus.defaultCritThreshold { return .critical }
        if u >= PhoneLimitStatus.defaultWarnThreshold { return .warning }
        return .normal
    }
}

// MARK: - Provider Detail Card (token breakdown)

struct ProviderDetailCard: View {
    let provider: PhoneProviderSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(provider.displayName)
                    .font(.headline)
                Spacer()
                Text(TokenFormatter.compact(provider.todayTokens))
                    .font(.subheadline.monospacedDigit().bold())
                if provider.reportsCost && provider.todayCost > 0 {
                    Text(TokenFormatter.cost(provider.todayCost))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if provider.inputTokens > 0 || provider.outputTokens > 0 {
                VStack(spacing: 4) {
                    tokenBar(label: "Input", value: provider.inputTokens, color: .blue)
                    tokenBar(label: "Output", value: provider.outputTokens, color: .green)
                    if provider.cacheWriteTokens > 0 {
                        tokenBar(label: "Cache Write", value: provider.cacheWriteTokens, color: .orange)
                    }
                    if provider.cacheReadTokens > 0 {
                        tokenBar(label: "Cache Read", value: provider.cacheReadTokens, color: .purple)
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private func tokenBar(label: String, value: Int, color: Color) -> some View {
        HStack {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color.opacity(0.15))
                        .frame(height: 6)
                    if provider.todayTokens > 0 {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(color)
                            .frame(width: geo.size.width * min(1, Double(value) / Double(max(provider.todayTokens, 1))), height: 6)
                    }
                }
            }
            .accessibilityHidden(true)
            .frame(height: 6)
            Text(TokenFormatter.compact(value))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Launch View

/// Entry screen shown while the first data-source determination (iCloud or local HTTP)
/// is in flight, so the setup view never flashes before a CloudKit payload lands.
struct LaunchView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "desktopcomputer.and.iphone")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("PokeTokenBar")
                .font(.title2.bold())
            ProgressView()
            Text("Looking for data source…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

// MARK: - Setup View

struct SetupView: View {
    @Environment(PhonePayloadStore.self) private var store
    @State private var hostInput = ""
    @State private var pairingInput = ""

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)

            Text("Connect to Mac")
                .font(.title.bold())

            Text("Data syncs automatically via iCloud when both devices share the same Apple ID.\n\nFor local network sync, enter your Mac's IP address below.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            TextField("Mac IP Address (e.g. 192.168.1.42)", text: $hostInput)
                .textFieldStyle(.roundedBorder)
                .autocapitalization(.none)
                .autocorrectionDisabled()
                .keyboardType(.numbersAndPunctuation)
                .padding(.horizontal, 32)

            TextField("Pairing Code (e.g. ABCD2345)", text: $pairingInput)
                .textFieldStyle(.roundedBorder)
                .autocapitalization(.allCharacters)
                .autocorrectionDisabled()
                .padding(.horizontal, 32)

            Button("Connect") {
                hostInput = hostInput.trimmingCharacters(in: .whitespaces)
                store.host = hostInput
                pairingInput = pairingInput.trimmingCharacters(in: .whitespaces).uppercased()
                store.pairingCode = pairingInput
                Task { await store.fetch() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(hostInput.trimmingCharacters(in: .whitespaces).isEmpty
                      || pairingInput.trimmingCharacters(in: .whitespaces).isEmpty)

            Text("Find your Mac's IP in System Settings → Network. The pairing code is in PokeTokenBar Settings on your Mac, under iPhone Connection.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .navigationTitle("Setup")
    }
}

// MARK: - Daily Trend Card

struct DailyTrendCard: View {
    let days: [PhoneDailyTrend]

    private var peak: Int { days.map(\.totalTokens).max() ?? 0 }
    private var todayDate: String {
        days.first(where: \.isToday)?.date ?? days.last?.date ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Daily Trend")
                    .font(.headline)
                Spacer()
                if peak > 0 {
                    Text("Peak \(TokenFormatter.compact(peak))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            // Bars
            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(days) { day in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(barColor(day))
                        .frame(maxWidth: .infinity)
                        .frame(height: barHeight(day.totalTokens))
                        .accessibilityLabel(Text("\(day.date): \(TokenFormatter.compact(day.totalTokens)) tokens"))
                }
            }
            .frame(height: 26, alignment: .bottom)

            // Weekend ticks
            HStack(spacing: 1.5) {
                ForEach(days) { day in
                    RoundedRectangle(cornerRadius: 0.5)
                        .fill(isWeekend(day.date) ? Color.secondary.opacity(0.3) : .clear)
                        .frame(maxWidth: .infinity)
                        .frame(height: 1.5)
                }
            }

            // Axis labels
            HStack(spacing: 1.5) {
                ForEach(days) { day in
                    Group {
                        if let label = axisLabel(for: day.date) {
                            Text(label)
                                .font(.system(size: 9).monospacedDigit())
                                .foregroundStyle(day.date == todayDate ? Color.accentColor : Color.secondary)
                                .fixedSize(horizontal: true, vertical: false)
                        } else {
                            Color.clear.frame(height: 1)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func barColor(_ day: PhoneDailyTrend) -> Color {
        if day.isToday { return .accentColor }
        if day.totalTokens == 0 { return .secondary.opacity(0.18) }
        return .secondary.opacity(0.45)
    }

    private func barHeight(_ tokens: Int) -> CGFloat {
        guard peak > 0, tokens > 0 else { return 1.5 }
        let ratio = min(1, Double(tokens) / Double(peak))
        return max(1.5, CGFloat(ratio) * 26)
    }

    private func isWeekend(_ dateString: String) -> Bool {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        guard let date = f.date(from: dateString) else { return false }
        return Calendar.current.isDateInWeekend(date)
    }

    private func axisLabel(for date: String) -> String? {
        guard let dayOfMonth = Int(date.suffix(2)) else { return nil }
        if date == todayDate { return "\(dayOfMonth)" }
        let isRegular = dayOfMonth == 1 || dayOfMonth % 7 == 0
        guard isRegular else { return nil }
        if let todayOfMonth = Int(todayDate.suffix(2)),
           abs(dayOfMonth - todayOfMonth) < 3 { return nil }
        return "\(dayOfMonth)"
    }
}

// MARK: - Incident Banner

struct IncidentBanner: View {
    let incident: PhoneIncident

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(incident.statusLabel)
                    .font(.caption.weight(.semibold))
                Text(incident.componentName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(dotColor.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var dotColor: Color {
        switch incident.severity {
        case "critical": return .red
        case "major": return .orange
        case "minor", "maintenance": return .yellow
        default: return .secondary
        }
    }
}
