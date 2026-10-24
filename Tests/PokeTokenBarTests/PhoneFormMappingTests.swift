import XCTest
import PokeTokenBarShared
@testable import PokeTokenBar

/// Serves the real Burmy line (Burmy → Wormadam / Mothim) without the network.
private struct BurmyLineProvider: PokeProviding {
    func line(baseSpeciesID: Int) async throws -> EvoLine {
        EvoLine(baseID: 412, tree: EvoNode(speciesID: 412, children: [
            EvoNode(speciesID: 413, children: []), EvoNode(speciesID: 414, children: []),
        ]), rarity: .common, names: [412: ["en": "Burmy"], 413: ["en": "Wormadam"], 414: ["en": "Mothim"]])
    }
    func baseSpeciesIndex() async throws -> [BaseSpecies] { [] }
    func baseSpecies(id: Int) async throws -> BaseSpecies? { nil }
}

/// Pokémon forms in the iPhone payload: the Mac resolves sprite names from its catalog, the phone
/// renders them, and both sides stay compatible with the other's older builds.
@MainActor
final class PhoneFormMappingTests: XCTestCase {
    nonisolated(unsafe) private var tempDirs: [URL] = []

    override func tearDown() {
        for url in tempDirs { try? FileManager.default.removeItem(at: url) }
        super.tearDown()
    }

    private let sandy = PokemonForm("sandy")

    private func burmy(_ chain: [Int], form: PokemonForm?, shiny: Bool = false, id: String = UUID().uuidString) -> DexEntry {
        DexEntry(id: id, baseID: 412, finalID: chain.last!, chainOrder: chain, rarity: .common,
                 caughtAt: Date(timeIntervalSince1970: 1_700_000_000), isShiny: shiny, form: form)
    }

    private func makeCompanion(_ state: CompanionState, provider: any PokeProviding = BurmyLineProvider()) throws -> CompanionStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("phone-forms-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        let file = dir.appendingPathComponent("state.json")
        try JSONEncoder().encode(state).write(to: file)
        return CompanionStore(provider: provider, fileURL: file)
    }

    // MARK: Mac mapping

    /// Sky Shaymin is a separate PokéAPI variety: its PNG is `10006`, its GIF `492-sky`.
    func testSeparateVarietyFormUsesTheVarietyIDForTheStaticSprite() throws {
        let sprite = try XCTUnwrap(PokemonForm.phoneSprite(speciesID: 492, form: PokemonForm("sky"), language: .en))
        XCTAssertEqual(sprite.form, "sky")
        XCTAssertEqual(sprite.staticAsset, "10006")
        XCTAssertEqual(sprite.animatedAsset, "492-sky")
        XCTAssertFalse(sprite.isDefault)
        XCTAssertNotNil(sprite.label)
    }

    /// The default form keeps the plain sprite names, so existing caches stay valid.
    func testDefaultFormKeepsPlainSpriteNames() throws {
        let sprite = try XCTUnwrap(PokemonForm.phoneSprite(speciesID: 492, form: nil, language: .en))
        XCTAssertEqual(sprite.form, "land")
        XCTAssertEqual(sprite.staticAsset, "492")
        XCTAssertEqual(sprite.animatedAsset, "492")
        XCTAssertTrue(sprite.isDefault)
    }

    /// An Unown letter matches the names the phone built itself before generic forms.
    func testUnownLetterMatchesTheLegacyPhoneSprite() throws {
        let sprite = try XCTUnwrap(PokemonForm.phoneSprite(speciesID: 201, form: PokemonForm("b"), language: .en))
        XCTAssertEqual(sprite, PhoneSpriteForm.legacyUnown("b"))
        XCTAssertEqual(PokemonForm.phoneSprite(speciesID: 201, form: nil, language: .en), PhoneSpriteForm.legacyUnown("a"))
    }

    func testSpeciesWithoutFormsSendsNone() {
        XCTAssertNil(PokemonForm.phoneSprite(speciesID: 25, form: nil, language: .en))
        XCTAssertNil(PokemonForm.phoneSprite(speciesID: 25, form: PokemonForm("sky"), language: .en))
    }

    /// Sandy Burmy carries its cloak to Wormadam; Mothim has a single appearance.
    func testChainFormsFollowTheIndividualAcrossItsLine() throws {
        let companion = try makeCompanion(CompanionState())
        let wormadam = companion.phoneChainForms(burmy([412, 413], form: sandy))
        XCTAssertEqual(wormadam[412]?.staticAsset, "412-sandy")
        XCTAssertEqual(wormadam[413]?.staticAsset, "10004", "Sandy Wormadam is a separate variety")
        XCTAssertEqual(wormadam[413]?.animatedAsset, "413-sandy")

        let mothim = companion.phoneChainForms(burmy([412, 414], form: sandy))
        XCTAssertEqual(mothim[412]?.form, "sandy")
        XCTAssertNil(mothim[414])
    }

    func testCatchLogEntryCarriesItsChainForms() throws {
        let entry = burmy([412, 413], form: sandy)
        var state = CompanionState()
        state.dex = [entry]
        let companion = try makeCompanion(state)
        let phone = AppDelegate.phoneDexEntry(entry, companion: companion)
        XCTAssertEqual(phone.form(at: 413)?.form, "sandy")
        XCTAssertNil(phone.unownForm, "Only Unown letters go in the legacy field")
    }

    /// Every form is listed, default first, with ownership and shininess per form.
    func testDexFormsListEveryFormWithOwnership() throws {
        var state = CompanionState()
        state.dex = [burmy([412], form: sandy, shiny: true)]
        let companion = try makeCompanion(state)
        let forms = try XCTUnwrap(companion.phoneDexForms(speciesID: 412))
        XCTAssertEqual(forms.map(\.id), ["plant", "sandy", "trash"])
        XCTAssertEqual(forms.map(\.isOwned), [false, true, false])
        XCTAssertEqual(forms.map(\.isShiny), [false, true, false])
        XCTAssertNil(companion.phoneDexForms(speciesID: 25))
    }

    func testDexFormsMarkTheRepresentativeForm() throws {
        var state = CompanionState()
        state.dex = [burmy([412], form: sandy), burmy([412], form: PokemonForm("trash"))]
        let companion = try makeCompanion(state)
        XCTAssertTrue(companion.setRepresentativeSpeciesID(412, form: sandy))
        let forms = try XCTUnwrap(companion.phoneDexForms(speciesID: 412))
        XCTAssertEqual(forms.filter(\.isRepresentative).map(\.id), ["sandy"])
    }

    /// The evolution strip shows the raised individual's form at each species of its line.
    func testLineNodesCarryTheActiveForm() async throws {
        var state = CompanionState()
        state.active = MonState(baseID: 412, pathIDs: [412, 413], stageIndex: 0, usedAtStage: 0,
                                rarity: .common, totalForms: 2, form: sandy)
        let companion = try makeCompanion(state)
        // The first usage update loads the line, as after a relaunch.
        companion.update(todayTokensByProvider: ["test": 0], todayDate: "d", monthTotal: 0, burnTier: .idle,
                         limitWarning: false, hasUsageData: false)
        for _ in 0..<200 where companion.currentLine == nil { try await Task.sleep(for: .milliseconds(10)) }
        let nodes = companion.phoneLineNodes
        XCTAssertEqual(nodes.compactMap(\.speciesID).first, 412)
        XCTAssertEqual(nodes.first?.form?.form, "sandy")
        for node in nodes {
            guard let id = node.speciesID else { continue }
            XCTAssertEqual(node.form?.form, PokemonForm.hasForms(speciesID: id) ? "sandy" : nil, "species \(id)")
        }
    }

    // MARK: Shared payload

    /// Default forms keep the keys sprites were cached under before forms existed.
    func testSpriteKeysStayCompatibleForDefaultsAndUnown() {
        XCTAssertEqual(PokeSpriteURL.speciesKey(id: 492, shiny: false, form: PhoneSpriteForm.legacyUnown("a")), "492_false.png")
        XCTAssertEqual(PokeSpriteURL.speciesKey(id: 201, shiny: true, form: .legacyUnown("b")), "201_b_true.png")
        XCTAssertEqual(PokeSpriteURL.animatedSpeciesKey(id: 201, shiny: false, form: .legacyUnown("b")), "201_b_false_anim.gif")
        XCTAssertEqual(PokeSpriteURL.speciesKey(id: 25, shiny: false), "25_false.png")
    }

    func testSpriteURLsUseTheResolvedAssetNames() throws {
        let sky = PhoneSpriteForm(form: "sky", staticAsset: "10006", animatedAsset: "492-sky", label: "Sky Forme", isDefault: false)
        XCTAssertEqual(PokeSpriteURL.species(id: 492, shiny: true, form: sky)?.lastPathComponent, "10006.png")
        XCTAssertTrue(try XCTUnwrap(PokeSpriteURL.species(id: 492, shiny: true, form: sky)).path.contains("/shiny/"))
        XCTAssertEqual(PokeSpriteURL.animatedSpecies(id: 492, shiny: false, form: sky)?.lastPathComponent, "492-sky.gif")
        XCTAssertEqual(PokeSpriteURL.speciesKey(id: 492, shiny: false, form: sky), "492_sky_false.png")
    }

    func testDisplayNameNamesUnownAlwaysAndOtherFormsOnlyWhenNotDefault() {
        let land = PhoneSpriteForm(form: "land", staticAsset: "492", animatedAsset: "492", label: "Land Forme", isDefault: true)
        let sky = PhoneSpriteForm(form: "sky", staticAsset: "10006", animatedAsset: "492-sky", label: "Sky Forme", isDefault: false)
        XCTAssertEqual(land.displayName("Shaymin", speciesID: 492), "Shaymin")
        XCTAssertEqual(sky.displayName("Shaymin", speciesID: 492), "Shaymin [Sky Forme]")
        XCTAssertEqual(PhoneSpriteForm.legacyUnown("a")?.displayName("Unown", speciesID: 201), "Unown [A]")
        XCTAssertEqual(PhoneSpriteForm.legacyUnown("question")?.label, "?")
        XCTAssertNil(PhoneSpriteForm.legacyUnown(""))
    }

    /// An older Mac sends only Unown fields; the phone rebuilds all 28 letters from them.
    func testDisplayFormsFallBackToTheLegacyUnownList() {
        let legacy = PhoneDexSpecies(id: 201, name: "Unown", rarity: "rare", isShiny: false, isRaising: false,
                                     unownFormCount: 1,
                                     unownForms: [PhoneUnownForm(form: "c", symbol: "C", isShiny: true)])
        let forms = legacy.displayForms
        XCTAssertEqual(forms.count, 28)
        XCTAssertEqual(forms.filter(\.isOwned).map(\.id), ["c"])
        XCTAssertEqual(forms.first { $0.id == "c" }?.isShiny, true)

        let pikachu = PhoneDexSpecies(id: 25, name: "Pikachu", rarity: "common", isShiny: false, isRaising: false)
        XCTAssertTrue(pikachu.displayForms.isEmpty)
    }

    func testCatchLogFormFallsBackToTheLegacyUnownLetter() {
        let legacy = PhoneDexEntry(id: "x", baseID: 201, finalID: 201, rarity: "rare", isShiny: false,
                                   isRaising: false, isReleased: false, natureName: nil, caughtAt: nil,
                                   chainOrder: [201], chainNames: [:], unownForm: "f")
        XCTAssertEqual(legacy.form(at: 201)?.staticAsset, "201-f")
    }

    /// The widget mirrors the pinned representative, form included, else the current mon.
    func testWidgetSpriteFollowsTheRepresentative() throws {
        let sky = PhoneSpriteForm(form: "sky", staticAsset: "10006", animatedAsset: "492-sky", label: nil, isDefault: false)
        let pinned = PhoneCompanionState(name: "Pikachu", speciesID: 25, isShiny: false, isEgg: false, progress: 0,
                                         stageText: "", rarity: nil, dexCount: 1, eggProgress: 0, displayState: "idle",
                                         representativeSpeciesID: 492, representativeIsShiny: true,
                                         representativeForm: sky)
        let sprite = try XCTUnwrap(pinned.widgetSprite)
        XCTAssertEqual(sprite.id, 492)
        XCTAssertTrue(sprite.shiny)
        XCTAssertEqual(sprite.form, sky)

        let unpinned = PhoneCompanionState(name: "Pikachu", speciesID: 25, isShiny: true, isEgg: false, progress: 0,
                                           stageText: "", rarity: nil, dexCount: 1, eggProgress: 0, displayState: "idle")
        XCTAssertEqual(unpinned.widgetSprite?.id, 25)
        XCTAssertEqual(unpinned.widgetSprite?.shiny, true)
    }

    /// New fields round-trip, and a payload from an older Mac (no form fields) still decodes.
    func testFormFieldsRoundTripAndAreOptional() throws {
        let sky = PhoneSpriteForm(form: "sky", staticAsset: "10006", animatedAsset: "492-sky", label: "Sky Forme", isDefault: false)
        let species = PhoneDexSpecies(id: 492, name: "Shaymin", rarity: "legendary", isShiny: false, isRaising: false,
                                      forms: [PhoneDexForm(sprite: sky, isOwned: true, isShiny: false, isRepresentative: true)])
        let decoded = try JSONDecoder().decode(PhoneDexSpecies.self, from: JSONEncoder().encode(species))
        XCTAssertEqual(decoded, species)

        let entry = PhoneDexEntry(id: "e", baseID: 492, finalID: 492, rarity: "legendary", isShiny: false,
                                  isRaising: false, isReleased: false, natureName: nil, caughtAt: nil,
                                  chainOrder: [492], chainNames: [492: "Shaymin"], unownForm: nil,
                                  chainForms: [492: sky])
        XCTAssertEqual(try JSONDecoder().decode(PhoneDexEntry.self, from: JSONEncoder().encode(entry)), entry)

        let oldNode = #"{"speciesID":412,"name":"Burmy","state":"current"}"#
        XCTAssertNil(try JSONDecoder().decode(PhoneEvoNode.self, from: Data(oldNode.utf8)).form)
        let oldEntry = #"{"id":"e","baseID":25,"finalID":25,"rarity":"common","isShiny":false,"isRaising":false,"isReleased":false,"chainOrder":[25],"chainNames":{}}"#
        XCTAssertNil(try JSONDecoder().decode(PhoneDexEntry.self, from: Data(oldEntry.utf8)).chainForms)
    }
}
