import Foundation
import PokeTokenBarShared

/// Pokémon forms in the iPhone payload. The Mac owns the form catalog (`PokemonForm`), so it
/// resolves sprite file names and localized labels here and the phone only renders them.
/// Fork-only: kept out of upstream files so upstream syncs don't conflict with it.
extension PokemonForm {
    /// Nil for species without forms.
    @MainActor
    static func phoneSprite(speciesID: Int, form: PokemonForm?, language: AppLanguage) -> PhoneSpriteForm? {
        guard let resolved = resolved(speciesID: speciesID, form: form) else { return nil }
        return PhoneSpriteForm(
            form: resolved.rawValue,
            staticAsset: staticAssetName(speciesID: speciesID, form: resolved),
            animatedAsset: assetName(speciesID: speciesID, form: resolved),
            label: label(speciesID: speciesID, form: resolved, language: language),
            isDefault: isDefault(resolved, speciesID: speciesID))
    }
}

extension CompanionStore {
    /// Every form of the species, default first, with what the user owns. Nil without forms.
    func phoneDexForms(speciesID: Int) -> [PhoneDexForm]? {
        guard PokemonForm.hasForms(speciesID: speciesID) else { return nil }
        let owned = formSpecies(speciesID: speciesID)
        return PokemonForm.forms(speciesID: speciesID).compactMap { form in
            guard let sprite = PokemonForm.phoneSprite(speciesID: speciesID, form: form, language: language)
            else { return nil }
            let match = owned.first { $0.form == form }
            return PhoneDexForm(sprite: sprite, isOwned: match != nil, isShiny: match?.isShiny ?? false,
                                isRepresentative: match.map(isRepresentative) ?? false)
        }
    }

    /// The individual's form at each chain species that has forms (Sandy Burmy → Sandy Wormadam).
    func phoneChainForms(_ entry: DexEntry) -> [Int: PhoneSpriteForm] {
        entry.chainOrder.reduce(into: [:]) { forms, speciesID in
            forms[speciesID] = PokemonForm.phoneSprite(speciesID: speciesID, form: entry.form, language: language)
        }
    }

    /// Warms the localized names of every owned species with forms, so the payload sends
    /// "Sky Forme" rather than the identifier. Runs on every payload build, so names already
    /// loaded are skipped and a refresh only fetches newly collected species.
    func loadPhoneFormNames(displayStore: PokemonNameDisplayStore = .shared) async {
        let speciesIDs = Set(dexSpecies.map(\.id)).filter(PokemonForm.hasForms(speciesID:))
        let missing = speciesIDs.flatMap(PokemonForm.nameResources(speciesID:))
            .filter { displayStore.names[$0] == nil }
        guard !missing.isEmpty else { return }
        await loadFormNames(missing)
    }
}
