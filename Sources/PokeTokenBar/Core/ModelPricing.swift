import Foundation
import PokeTokenBarShared

// The price table lives in PokeTokenBarShared so the iPhone prices ledger entries with the same
// rows (`ModelPricing.unpricedLogger` is pointed at `AppLog` at launch).
typealias ModelRate = PokeTokenBarShared.ModelRate
typealias ModelPricing = PokeTokenBarShared.ModelPricing
