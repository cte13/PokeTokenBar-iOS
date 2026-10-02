import Foundation
import PokeTokenBarShared

// The cadence lives in PokeTokenBarShared (`ClaudeLimits.swift`): the iPhone polls claude.ai too,
// and both devices must stay under the same request budget.
typealias LimitsPollCadence = PokeTokenBarShared.LimitsPollCadence
