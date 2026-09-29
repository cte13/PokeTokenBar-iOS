import Foundation

/// The iPhone's own count. It takes the Mac's last payload and replaces the usage of every
/// provider the ledger carries (`PhoneUsageLedgerManifest.providers`) with numbers computed here
/// from ledger + cloud-session entries. Those numbers stay current with the Mac off.
///
/// Providers the ledger does not carry keep the Mac's per-provider numbers, but only while those
/// numbers still describe the current period. The Mac's today counts only on the Mac's last local
/// day, its week only in the same week, and so on. A Mac that went to sleep yesterday must read as
/// zero today, not as yesterday's total.
public enum PhoneLedgerOverlay {
    /// A Mac-reported burn rate older than this no longer describes "now".
    public static let macBurnFreshness: TimeInterval = 10 * 60

    /// - Parameters:
    ///   - entries: per provider id, every entry the phone holds (Mac ledger + cloud sessions);
    ///     duplicates across the two sources are expected and collapsed here.
    ///   - countedAt: when the ledger was last read — the usage freshness the dashboard shows.
    public static func apply(macPayload: PhonePayload?, manifest: PhoneUsageLedgerManifest,
                             entries: [String: [UsageEntry]], countedAt: Date,
                             now: Date = Date()) -> PhonePayload {
        let fmt = UsageAggregation.localDayFormatter()
        let todayKey = fmt.string(from: now)
        let macDate = macPayload?.lastUpdated ?? .distantPast
        let sameDay = fmt.string(from: macDate) == todayKey
        let sameWeek = UsageAggregation.startOfWeek(macDate) == UsageAggregation.startOfWeek(now)
        let sameMonth = UsageAggregation.monthKey(macDate) == UsageAggregation.monthKey(now)
        let burnFresh = now.timeIntervalSince(macDate) < macBurnFreshness

        var counted: [String: PhoneProviderSnapshot] = [:]
        var countedVisible: Set<String> = []
        for provider in manifest.providers {
            let all = UsageAggregation.dedupKeepMax(entries[provider.id] ?? [])
            let enrichment = ProviderEnrichment.local(entries: all, now: now)
            let today = UsageAggregation.daily(entries: all, localDay: todayKey)
            counted[provider.id] = PhoneProviderSnapshot(
                id: provider.id, displayName: provider.displayName,
                todayTokens: today?.totalTokens ?? 0, todayCost: today?.totalCost ?? 0,
                inputTokens: today?.inputTokens ?? 0, outputTokens: today?.outputTokens ?? 0,
                cacheWriteTokens: today?.cacheCreationTokens ?? 0, cacheReadTokens: today?.cacheReadTokens ?? 0,
                reportsCost: provider.reportsCost,
                weekTokens: enrichment.weekTotal?.totalTokens, weekCost: enrichment.weekTotal?.totalCost,
                monthTokens: enrichment.monthTotal?.totalTokens, monthCost: enrichment.monthTotal?.totalCost,
                tokensPerMinute: enrichment.activeBlock?.tokensPerMinute,
                monthDaily: enrichment.monthDaily?.map {
                    PhoneDailyTrend(date: $0.date, totalTokens: $0.totalTokens, totalCost: $0.totalCost,
                                    isToday: $0.date == todayKey)
                })
            // Same rule as the Mac's snapshot list: a tab for usage today, or a carrier tab while a
            // 5-hour block from late last night is still active.
            if today != nil || (enrichment.activeBlock?.totalTokens ?? 0) > 0 {
                countedVisible.insert(provider.id)
            }
        }

        // Every provider contributes to the totals; only ones with something current get a tab.
        var all: [(snapshot: PhoneProviderSnapshot, visible: Bool)] = []
        for mac in macPayload?.providers ?? [] {
            if let replacement = counted.removeValue(forKey: mac.id) {
                all.append((replacement, countedVisible.contains(mac.id)))
                continue
            }
            let kept = PhoneProviderSnapshot(
                id: mac.id, displayName: mac.displayName,
                todayTokens: sameDay ? mac.todayTokens : 0, todayCost: sameDay ? mac.todayCost : 0,
                inputTokens: sameDay ? mac.inputTokens : 0, outputTokens: sameDay ? mac.outputTokens : 0,
                cacheWriteTokens: sameDay ? mac.cacheWriteTokens : 0,
                cacheReadTokens: sameDay ? mac.cacheReadTokens : 0,
                reportsCost: mac.reportsCost,
                weekTokens: sameWeek ? mac.weekTokens : 0, weekCost: sameWeek ? mac.weekCost : 0,
                monthTokens: sameMonth ? mac.monthTokens : 0, monthCost: sameMonth ? mac.monthCost : 0,
                tokensPerMinute: burnFresh ? mac.tokensPerMinute : nil,
                monthDaily: sameMonth ? mac.monthDaily : nil)
            all.append((kept, kept.todayTokens > 0 || (kept.tokensPerMinute ?? 0) > 0))
        }
        for provider in manifest.providers {
            guard let snapshot = counted[provider.id] else { continue }
            all.append((snapshot, countedVisible.contains(provider.id)))
        }

        let snapshots = all.map(\.snapshot)
        let costing = snapshots.filter(\.reportsCost)
        let burn = snapshots.compactMap(\.tokensPerMinute).reduce(0, +)
        let forecast = macPayload?.burn.flatMap { b in b.depletionDate.map { $0 > now } == true ? b : nil }

        var trendByDay: [String: (tokens: Int, cost: Double)] = [:]
        for snapshot in snapshots {
            for day in snapshot.monthDaily ?? [] {
                var sum = trendByDay[day.date] ?? (0, 0)
                sum.tokens += day.totalTokens
                if snapshot.reportsCost { sum.cost += day.totalCost }
                trendByDay[day.date] = sum
            }
        }
        let trend = trendByDay.keys.sorted().map {
            PhoneDailyTrend(date: $0, totalTokens: trendByDay[$0]!.tokens, totalCost: trendByDay[$0]!.cost,
                            isToday: $0 == todayKey)
        }

        return PhonePayload(
            todayTokens: snapshots.reduce(0) { $0 + $1.todayTokens },
            todayCost: costing.reduce(0) { $0 + $1.todayCost },
            weekTokens: snapshots.reduce(0) { $0 + ($1.weekTokens ?? 0) },
            monthTokens: snapshots.reduce(0) { $0 + ($1.monthTokens ?? 0) },
            lastUpdated: max(macDate, countedAt),
            serverVersion: macPayload?.serverVersion ?? "",
            limits: macPayload?.limits,
            companion: macPayload?.companion,
            providers: all.filter(\.visible).map(\.snapshot),
            bag: macPayload?.bag ?? [],
            dex: macPayload?.dex ?? [],
            spendableTokens: macPayload?.spendableTokens ?? 0,
            shop: macPayload?.shop ?? [],
            weekCost: costing.reduce(0) { $0 + ($1.weekCost ?? 0) },
            monthCost: costing.reduce(0) { $0 + ($1.monthCost ?? 0) },
            burn: forecast != nil || burn > 0
                ? PhoneBurnForecast(depletionDate: forecast?.depletionDate, beforeReset: forecast?.beforeReset ?? false,
                                    tokensPerMinute: burn > 0 ? burn : nil)
                : nil,
            catchLog: macPayload?.catchLog ?? [],
            dailyTrend: trend.isEmpty ? nil : trend,
            incidents: macPayload?.incidents)
    }
}
