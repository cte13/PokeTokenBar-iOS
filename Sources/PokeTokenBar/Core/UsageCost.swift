import Foundation
import PokeTokenBarShared

// CostCoverage and UsageCost live in PokeTokenBarShared; the localized text stays here.
typealias CostCoverage = PokeTokenBarShared.CostCoverage
typealias UsageCost = PokeTokenBarShared.UsageCost

extension UsageCost {
    func text(_ l: L, compact: Bool = false) -> String {
        if coverage.unknown && !coverage.hasKnown { return compact ? "$—" : l.costUnavailable }
        return compact ? TokenFormatter.costCompact(amount) : TokenFormatter.cost(amount)
    }

    func explanation(_ l: L) -> String {
        if coverage.unknown { return coverage.hasKnown ? l.costPartialHint : l.costUnavailableHint }
        return coverage.estimated ? l.costEstimateHint : l.costReportedHint
    }
}
