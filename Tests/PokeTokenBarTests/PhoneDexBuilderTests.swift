import XCTest
import PokeTokenBarShared
@testable import PokeTokenBar

private struct MockDexDetailProvider: PokeProviding, PokemonDetailProviding {
    func line(baseSpeciesID: Int) async throws -> EvoLine {
        EvoLine(baseID: baseSpeciesID, tree: EvoNode(speciesID: baseSpeciesID, children: []),
                rarity: .common, names: [baseSpeciesID: ["en": "TestMon"]])
    }
    func baseSpeciesIndex() async throws -> [BaseSpecies] { [] }
    func baseSpecies(id: Int) async throws -> BaseSpecies? { nil }
    func pokemonDetails(speciesID: Int) async throws -> PokemonDetails {
        PokemonDetails(
            speciesID: speciesID,
            name: "pikachu",
            height: 4,
            weight: 60,
            baseExperience: 112,
            genderRate: 4,
            types: ["electric"],
            baseStats: [
                "hp": 35, "attack": 55, "defense": 40,
                "special-attack": 50, "special-defense": 50, "speed": 90,
            ],
            abilities: [
                PokemonAbilityOption(name: "static", slot: 1, isHidden: false),
                PokemonAbilityOption(name: "lightning-rod", slot: 3, isHidden: true),
            ],
            moves: [
                PokemonMoveOption(name: "thunder-shock", learnMethods: [
                    PokemonMoveLearnMethod(method: "level-up", level: 1),
                    PokemonMoveLearnMethod(method: "level-up", level: 1),
                ]),
                PokemonMoveOption(name: "thunderbolt", learnMethods: [
                    PokemonMoveLearnMethod(method: "machine", level: 0),
                ]),
            ]
        )
    }
}

@MainActor
final class PhoneDexBuilderTests: XCTestCase {
    nonisolated(unsafe) private var tempFiles: [URL] = []

    override func tearDown() {
        for url in tempFiles { try? FileManager.default.removeItem(at: url) }
        super.tearDown()
    }

    private func makeCompanion() -> (CompanionStore, URL) {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("phone-dex-tests-\(UUID())")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let file = tempDir.appendingPathComponent("state.json")
        tempFiles.append(tempDir)
        let provider = MockDexDetailProvider()
        let store = CompanionStore(provider: provider, detailProvider: provider, fileURL: file)
        return (store, file)
    }

    func testPhoneDexEntryTransformsEntryWithProfileAndCalculatesStats() async throws {
        let (companion, _) = makeCompanion()
        await companion.loadPokemonDetails(speciesID: 25)

        var profile = PokemonProfile.generate(seed: 123, instanceID: "inst-1")
        profile.level = 50
        profile.gender = .male
        profile.abilityName = "static"
        profile.abilityIsHidden = false
        profile.moves = [PokemonKnownMove(name: "thunder-shock", learnedAtLevel: 1)]

        let entry = DexEntry(
            id: "catch-1",
            baseID: 25,
            finalID: 25,
            chainOrder: [25],
            rarity: .common,
            caughtAt: Date(timeIntervalSince1970: 1_700_000_000),
            isShiny: true,
            nature: .adamant,
            profile: profile,
            names: [25: ["en": "Pikachu"]],
            unownForm: nil
        )

        let phoneEntry = AppDelegate.phoneDexEntry(entry, companion: companion)
        XCTAssertEqual(phoneEntry.id, "catch-1")
        XCTAssertEqual(phoneEntry.baseID, 25)
        XCTAssertEqual(phoneEntry.finalID, 25)
        XCTAssertEqual(phoneEntry.rarity, "common")
        XCTAssertTrue(phoneEntry.isShiny)
        XCTAssertFalse(phoneEntry.isRaising)
        XCTAssertFalse(phoneEntry.isReleased)
        XCTAssertEqual(phoneEntry.natureName, PokemonNature.adamant.name(companion.language))
        XCTAssertEqual(phoneEntry.chainNames[25], "Pikachu")
        XCTAssertNil(phoneEntry.unownForm)

        let phoneProf: PhoneIndividualProfile = try XCTUnwrap(phoneEntry.profile)
        XCTAssertEqual(phoneProf.level, 50)
        XCTAssertEqual(phoneProf.gender, "male")
        XCTAssertEqual(phoneProf.genderLabel, companion.l.genderLabel(.male))
        XCTAssertFalse(phoneProf.abilityIsHidden)
        XCTAssertEqual(phoneProf.moves.count, 1)
        XCTAssertEqual(phoneProf.moves.first?.learnedAtLevel, 1)
        XCTAssertEqual(phoneProf.stats.count, 6)
        XCTAssertEqual(phoneProf.stats.map(\.name), ["hp", "attack", "defense", "special-attack", "special-defense", "speed"])
    }

    func testPhoneSpeciesDetailsTransformsCachedPokemonDetails() async throws {
        let (companion, _) = makeCompanion()
        XCTAssertNil(AppDelegate.phoneSpeciesDetails(speciesID: 25, companion: companion))

        await companion.loadPokemonDetails(speciesID: 25)
        let details = try XCTUnwrap(AppDelegate.phoneSpeciesDetails(speciesID: 25, companion: companion))

        XCTAssertEqual(details.types, ["electric"])
        XCTAssertEqual(details.height, 4)
        XCTAssertEqual(details.weight, 60)
        XCTAssertEqual(details.baseStats.count, 6)
        XCTAssertEqual(details.possibleAbilities.count, 2)
        XCTAssertEqual(details.possibleAbilities[0].isHidden, false)
        XCTAssertEqual(details.possibleAbilities[1].isHidden, true)
        XCTAssertEqual(details.moveList.count, 2)
        // Deduplication of learnMethods
        XCTAssertEqual(details.moveList[0].methods.count, 1)
    }

    func testPhoneDexEntryCarriesUnownForm() {
        let (companion, _) = makeCompanion()
        let entry = DexEntry(
            id: "unown-1",
            baseID: 201,
            finalID: 201,
            chainOrder: [201],
            rarity: .rare,
            caughtAt: Date(),
            isShiny: false,
            nature: .timid,
            profile: nil,
            names: [:],
            unownForm: .f
        )
        let phoneEntry = AppDelegate.phoneDexEntry(entry, companion: companion)
        XCTAssertEqual(phoneEntry.unownForm, "f")
    }
}
