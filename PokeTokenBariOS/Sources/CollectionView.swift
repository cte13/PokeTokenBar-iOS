import SwiftUI
import PokeTokenBarShared

/// Collection — read-only mirror of the Mac's collection tab.
/// Two views over the same data:
///  - **Dex**: One cell per collected species with rarity filter, representative status, and tap to detail.
///  - **Catch Log**: Chronological list of caught individuals with evolution line, nature, and timestamps.
struct CollectionView: View {
    @Environment(PhonePayloadStore.self) private var store
    @State private var showingCatchLog = false
    @State private var selectedDexRarity: String?
    @State private var selectedLogRarity: String?

    private var dexSpecies: [PhoneDexSpecies] {
        guard let payload = store.payload else { return [] }
        guard let r = selectedDexRarity else { return payload.dex }
        return payload.dex.filter { $0.rarity == r }
    }

    private var catchLogEntries: [PhoneDexEntry] {
        guard let payload = store.payload else { return [] }
        guard let r = selectedLogRarity else { return payload.catchLog }
        return payload.catchLog.filter { $0.rarity == r }
    }

    private var totalSpeciesCount: Int {
        store.payload?.dex.count ?? 0
    }

    private var totalCatchesCount: Int {
        store.payload?.catchLog.count ?? 0
    }

    var body: some View {
        NavigationStack {
            Group {
                if let payload = store.payload {
                    if payload.dex.isEmpty && payload.catchLog.isEmpty {
                        emptyState
                    } else {
                        content
                    }
                } else {
                    waitingView
                }
            }
            .navigationTitle(showingCatchLog ? String(localized: "Catch Log") : String(localized: "Collection"))
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: PhoneDexSpecies.self) { species in
                PokemonDetailView(species: species)
            }
            .navigationDestination(for: PhoneDexEntry.self) { entry in
                PokemonDetailView(entry: entry)
            }
            .refreshable { await store.fetch() }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            Picker("", selection: $showingCatchLog) {
                Text("Pokédex").tag(false)
                Text("Catch Log").tag(true)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 6)

            if showingCatchLog {
                catchLogView
            } else {
                dexGridView
            }
        }
    }

    // MARK: - Pokédex Grid View

    private var dexGridView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                dexRarityFilter
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 8)], spacing: 10) {
                    ForEach(dexSpecies) { sp in
                        NavigationLink(value: sp) {
                            DexSpeciesCell(species: sp, isRepresentative: isRepresentative(sp))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text("Pokémon graduate from your Mac to appear here.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
            }
            .padding(.horizontal)
            .padding(.bottom, 16)
        }
    }

    private var dexRarityFilter: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Pokédex")
                    .font(.callout.weight(.semibold))
                Text("\(totalSpeciesCount) species", comment: "Species count in the collection header")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                ForEach(RarityStyle.displayOrder, id: \.self) { rarity in
                    let count = store.payload?.dex.filter { $0.rarity == rarity }.count ?? 0
                    RarityChip(label: RarityStyle.label(rarity), count: count,
                               color: RarityStyle.color(rarity),
                               isSelected: selectedDexRarity == rarity) {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedDexRarity = selectedDexRarity == rarity ? nil : rarity
                        }
                    }
                    .disabled(count == 0)
                }
            }
        }
    }

    // MARK: - Catch Log View

    private var catchLogView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                catchLogSummaryHeader
                if catchLogEntries.isEmpty {
                    VStack(spacing: 8) {
                        Text("No log entries match the selected filter.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(catchLogEntries) { entry in
                            NavigationLink(value: entry) {
                                CatchLogRow(entry: entry)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 16)
        }
    }

    private var catchLogSummaryHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Catch Log")
                    .font(.callout.weight(.semibold))
                Text(String(localized: "\(totalCatchesCount) catches"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                ForEach(RarityStyle.displayOrder, id: \.self) { rarity in
                    let count = store.payload?.catchLog.filter { $0.rarity == rarity }.count ?? 0
                    RarityChip(label: RarityStyle.label(rarity), count: count,
                               color: RarityStyle.color(rarity),
                               isSelected: selectedLogRarity == rarity) {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedLogRarity = selectedLogRarity == rarity ? nil : rarity
                        }
                    }
                    .disabled(count == 0)
                }
            }
        }
    }

    private func isRepresentative(_ species: PhoneDexSpecies) -> Bool {
        if species.isRepresentative == true { return true }
        return store.payload?.companion?.representativeSpeciesID == species.id
    }

    // MARK: - Placeholders

    private var emptyState: some View {
        VStack(spacing: 12) {
            SpeciesSprite(speciesID: 25, shiny: false, size: 96)
            Text("No Pokémon collected yet")
                .font(.callout.weight(.semibold))
            Text("Raise your Pokémon on the Mac —\ngraduated species appear here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var waitingView: some View {
        VStack(spacing: 12) {
            Image(systemName: "desktopcomputer.and.iphone")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Waiting for data from your Mac…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

// MARK: - Dex Species Cell

private struct DexSpeciesCell: View {
    let species: PhoneDexSpecies
    let isRepresentative: Bool

    private static let thumb: CGFloat = 54

    /// Same as the Mac's Pokédex: species with forms show "collected/total".
    private var displayName: String {
        let forms = species.displayForms
        guard !forms.isEmpty else { return species.name }
        return "\(species.name) \(forms.filter(\.isOwned).count)/\(forms.count)"
    }

    var body: some View {
        VStack(spacing: 2) {
            // Like the Mac, a species with forms keeps its default, non-shiny icon; the detail
            // picker shows each form's colors.
            SpeciesSprite(speciesID: species.id,
                          shiny: species.displayForms.isEmpty && species.isShiny, size: Self.thumb)
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 2) {
                        Text("#\(species.id)")
                        if isRepresentative {
                            Image(systemName: "star.fill")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(.regularMaterial, in: Capsule())
                }
                .overlay(alignment: .topTrailing) {
                    if species.isShiny {
                        Text("✨")
                            .font(.system(size: 8))
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(.regularMaterial, in: Capsule())
                    }
                }
                .overlay(alignment: .bottom) {
                    if species.isRaising {
                        Text("RAISING")
                            .font(.system(size: 7, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .foregroundStyle(.white)
                            .background(Color.accentColor, in: Capsule())
                    }
                }

            Text(displayName)
                .font(.caption2)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text(RarityStyle.label(species.rarity))
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
        }
        .padding(6)
        .frame(maxWidth: .infinity)
        .background(isRepresentative ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            if isRepresentative {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor.opacity(0.4), lineWidth: 1)
            }
        }
    }
}

// MARK: - Catch Log Row

private struct CatchLogRow: View {
    let entry: PhoneDexEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(RarityStyle.label(entry.rarity).uppercased())
                    .font(.system(size: 8, weight: .bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(RarityStyle.color(entry.rarity))
                    .foregroundStyle(.white)
                    .clipShape(Capsule())

                if entry.isRaising {
                    Text("RAISING")
                        .font(.system(size: 8, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.16))
                        .foregroundStyle(Color.accentColor)
                        .clipShape(Capsule())
                } else if entry.isReleased {
                    Text("RELEASED")
                        .font(.system(size: 8, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.16))
                        .foregroundStyle(.secondary)
                        .clipShape(Capsule())
                }

                if entry.isShiny {
                    Text("✨")
                        .font(.system(size: 10))
                }

                Spacer()

                if let nature = entry.natureName {
                    Text(nature)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }

            CatchLogEvolutionLine(
                chainOrder: entry.chainOrder,
                chainNames: entry.chainNames,
                isShiny: entry.isShiny,
                forms: Dictionary(uniqueKeysWithValues: entry.chainOrder.compactMap { id in
                    entry.form(at: id).map { (id, $0) }
                })
            )

            HStack {
                if let caughtAt = entry.caughtAt {
                    Text(caughtAt, style: .relative)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Catch Log Evolution Line

private struct CatchLogEvolutionLine: View {
    let chainOrder: [Int]
    let chainNames: [Int: String]
    let isShiny: Bool
    /// The individual's form at each species that has forms.
    let forms: [Int: PhoneSpriteForm]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row
            ScrollView(.horizontal, showsIndicators: false) {
                row
            }
        }
    }

    private var row: some View {
        HStack(spacing: 6) {
            ForEach(Array(chainOrder.enumerated()), id: \.offset) { index, id in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                VStack(spacing: 2) {
                    SpeciesSprite(speciesID: id, shiny: isShiny, size: 42, form: forms[id])
                    Text(chainNames[id] ?? "#\(id)")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(minWidth: 46)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Pokémon Detail View

struct PokemonDetailView: View {
    @Environment(PhonePayloadStore.self) private var store
    private let initialSpecies: PhoneDexSpecies?
    private let entry: PhoneDexEntry?

    /// Selected form identifier, for species with forms.
    @State private var selectedForm: String?
    @State private var selectedIndividualID: String = ""

    init(species: PhoneDexSpecies) {
        self.initialSpecies = species
        self.entry = nil
    }

    init(entry: PhoneDexEntry) {
        self.entry = entry
        self.initialSpecies = nil
    }

    private var speciesID: Int {
        if let initialSpecies { return initialSpecies.id }
        if let entry { return entry.finalID }
        return 0
    }

    private var currentSpecies: PhoneDexSpecies? {
        if let initialSpecies {
            return store.payload?.dex.first { $0.id == initialSpecies.id } ?? initialSpecies
        }
        return store.payload?.dex.first { $0.id == speciesID }
    }

    private var forms: [PhoneDexForm] { currentSpecies?.displayForms ?? [] }

    /// The form shown in the header: the picker's selection, else the opened catch's form.
    private var displayedForm: PhoneSpriteForm? {
        if let selectedForm, let match = forms.first(where: { $0.id == selectedForm }) { return match.sprite }
        return entry?.form(at: speciesID) ?? forms.first?.sprite
    }

    /// The form to select first: the opened catch's, else the representative, else the first owned.
    private var initialForm: String? {
        if let form = entry?.form(at: speciesID) { return form.form }
        let owned = forms.filter(\.isOwned)
        return (owned.first(where: \.isRepresentative) ?? owned.first ?? forms.first)?.id
    }

    private var baseSpeciesName: String {
        currentSpecies?.name ?? entry?.chainNames[speciesID] ?? "#\(speciesID)"
    }

    private var speciesName: String {
        displayedForm?.displayName(baseSpeciesName, speciesID: speciesID) ?? baseSpeciesName
    }

    private var rarity: String {
        currentSpecies?.rarity ?? entry?.rarity ?? "common"
    }

    private var isRaising: Bool {
        currentSpecies?.isRaising ?? entry?.isRaising ?? false
    }

    private var isRepresentative: Bool {
        if let displayedForm {
            return forms.first { $0.id == displayedForm.form }?.isRepresentative ?? false
        }
        if currentSpecies?.isRepresentative == true { return true }
        return store.payload?.companion?.representativeSpeciesID == speciesID
    }

    /// For species with forms, only individuals of the displayed form (as on the Mac).
    private var matchingIndividuals: [PhoneDexEntry] {
        guard let payload = store.payload else { return entry.map { [$0] } ?? [] }
        let defaultForm = forms.first?.id
        return payload.catchLog.filter { log in
            guard log.finalID == speciesID, log.profile != nil else { return false }
            guard let shown = displayedForm?.form else { return true }
            return (log.form(at: speciesID)?.form ?? defaultForm) == shown
        }
    }

    private var currentIndividual: PhoneDexEntry? {
        if !selectedIndividualID.isEmpty,
           let found = matchingIndividuals.first(where: { $0.id == selectedIndividualID }) {
            return found
        }
        // The opened catch, while its form is the one displayed.
        if let entry {
            let entryForm = entry.form(at: speciesID)?.form ?? forms.first?.id
            if displayedForm == nil || entryForm == displayedForm?.form { return entry }
        }
        return matchingIndividuals.first
    }

    private var isShiny: Bool {
        if let currentIndividual { return currentIndividual.isShiny }
        if let displayedForm, let match = forms.first(where: { $0.id == displayedForm.form }) {
            return match.isShiny
        }
        return currentSpecies?.isShiny ?? false
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !forms.isEmpty {
                    formGrid
                }

                identityHeader

                if matchingIndividuals.count > 1 {
                    individualPicker
                }

                if let individual = currentIndividual, let profile = individual.profile {
                    individualSection(entry: individual, profile: profile)
                }

                if let details = currentSpecies?.details {
                    if currentIndividual?.profile == nil {
                        baseStatsSection(details)
                    }
                    speciesSection(details)
                    movesSection(details)
                } else if currentIndividual?.profile == nil {
                    VStack(spacing: 8) {
                        Image(systemName: "info.circle")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("Pokémon details sync from your Mac.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }
            }
            .padding()
        }
        .navigationTitle("#\(speciesID)")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if selectedForm == nil {
                selectedForm = initialForm
            }
            if selectedIndividualID.isEmpty {
                selectedIndividualID = currentIndividual?.id ?? ""
            }
        }
    }

    // MARK: - Identity Header

    private var identityHeader: some View {
        HStack(spacing: 14) {
            AnimatedSpeciesSprite(
                speciesID: speciesID,
                shiny: isShiny,
                size: 80,
                form: displayedForm
            )
            .frame(width: 80, height: 80)

            VStack(alignment: .leading, spacing: 4) {
                Text(speciesName)
                    .font(.title3.weight(.bold))

                Text(RarityStyle.label(rarity))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                // Stats and moves come from the species' default form (same note as the Mac).
                if let displayedForm, !displayedForm.isDefault, currentSpecies?.details != nil {
                    Text("Data uses the default form")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 4) {
                    if isShiny {
                        Text("✨ \(String(localized: "Shiny"))")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.yellow.opacity(0.18), in: Capsule())
                    }
                    if isRaising {
                        Text("RAISING")
                            .font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .foregroundStyle(.white)
                            .background(Color.accentColor, in: Capsule())
                    }
                    if isRepresentative {
                        HStack(spacing: 2) {
                            Image(systemName: "star.fill")
                            Text("Representative")
                        }
                        .font(.system(size: 8, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .foregroundStyle(Color.accentColor)
                        .background(Color.accentColor.opacity(0.14), in: Capsule())
                    }
                }
            }
            Spacer()
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Form Grid

    /// Same column rule as the Mac: Unown's 28 letters fill seven columns, named forms get wider cells.
    static func formGridColumns(formCount: Int) -> Int {
        formCount > 8 ? (formCount > 20 ? 7 : 6) : min(formCount, 4)
    }

    private var formGrid: some View {
        let ownedCount = forms.filter(\.isOwned).count
        let columns = Self.formGridColumns(formCount: forms.count)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Forms \(ownedCount)/\(forms.count)")
                .font(.caption.weight(.semibold))

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: columns), spacing: 4) {
                ForEach(forms) { form in
                    let label = form.sprite.label ?? form.sprite.form
                    let isSelected = displayedForm?.form == form.id

                    Button {
                        selectedForm = form.id
                        selectedIndividualID = ""
                    } label: {
                        VStack(spacing: 1) {
                            SpeciesSprite(speciesID: speciesID, shiny: form.isShiny, size: 28, form: form.sprite)
                                .frame(width: 28, height: 28)
                                .overlay(alignment: .topTrailing) {
                                    if form.isShiny {
                                        Text("✨").font(.system(size: 6))
                                    }
                                }
                            // Wide grids hold short labels (letters, types); longer names wrap on two lines.
                            Text(label)
                                .font(.system(size: 9, weight: .semibold))
                                .multilineTextAlignment(.center)
                                .lineLimit(columns > 4 ? 1 : 2, reservesSpace: columns <= 4)
                                .minimumScaleFactor(0.6)
                                .padding(.horizontal, 2)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 3)
                        .opacity(form.isOwned ? 1 : 0.25)
                        .background(form.isRepresentative
                                    ? Color.accentColor.opacity(0.16)
                                    : Color.secondary.opacity(0.06),
                                    in: RoundedRectangle(cornerRadius: 6))
                        .overlay {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!form.isOwned)
                    .accessibilityLabel(form.sprite.displayName(baseSpeciesName, speciesID: speciesID))
                    .accessibilityValue(form.isOwned ? "" : String(localized: "Not collected"))
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Individual Picker

    private var individualPicker: some View {
        HStack {
            Text("Individual")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Picker("Individual", selection: $selectedIndividualID) {
                ForEach(Array(matchingIndividuals.enumerated()), id: \.element.id) { index, entry in
                    Text("#\(index + 1) · Lv. \(entry.profile?.level ?? 5)").tag(entry.id)
                }
            }
            .pickerStyle(.menu)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Individual Section

    private func individualSection(entry: PhoneDexEntry, profile: PhoneIndividualProfile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Individual")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                valuePair("Level", "Lv. \(profile.level)")
                valuePair("Gender", profile.genderLabel ?? "—")
                valuePair("Nature", entry.natureName ?? "—")
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("Ability").font(.system(size: 9)).foregroundStyle(.secondary)
                if let name = profile.abilityName {
                    Text(name + (profile.abilityIsHidden ? " · Hidden Ability" : ""))
                        .font(.caption.weight(.semibold))
                } else {
                    Text("—").font(.caption.weight(.semibold))
                }
            }

            if !profile.stats.isEmpty {
                statsSection(profile.stats)
            }

            Text("Known Moves")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            if profile.moves.isEmpty {
                Text("No level-up moves learned at this level.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(profile.moves) { move in
                    HStack {
                        Text(move.name)
                            .font(.caption)
                        Spacer()
                        Text("Lv. \(move.learnedAtLevel)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .detailCard()
    }

    // MARK: - Stats Section

    private func statsSection(_ stats: [PhoneComputedStat]) -> some View {
        let maxVal = max(100, stats.map(\.value).max() ?? 100)
        return VStack(alignment: .leading, spacing: 5) {
            Text("Actual Stats")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(stats) { stat in
                HStack(spacing: 6) {
                    Text(stat.label)
                        .frame(width: 70, alignment: .leading)
                    ProgressView(value: Double(stat.value), total: Double(maxVal))
                        .tint(Color.accentColor)
                    Text("\(stat.value)")
                        .monospacedDigit()
                        .frame(width: 32, alignment: .trailing)
                    if let iv = stat.iv {
                        Text("IV \(iv)")
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)
                    }
                }
                .font(.system(size: 10))
            }
        }
    }

    // MARK: - Base Stats Section

    private func baseStatsSection(_ details: PhoneSpeciesDetails) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Base Stats")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(details.baseStats) { stat in
                HStack(spacing: 6) {
                    Text(stat.label)
                        .frame(width: 70, alignment: .leading)
                    ProgressView(value: Double(stat.value), total: 255)
                        .tint(Color.accentColor)
                    Text("\(stat.value)")
                        .monospacedDigit()
                        .frame(width: 32, alignment: .trailing)
                }
                .font(.system(size: 10))
            }
        }
        .detailCard()
    }

    // MARK: - Species Section

    private func speciesSection(_ details: PhoneSpeciesDetails) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Species Data")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 5) {
                ForEach(details.types, id: \.self) { TypeBadge(type: $0) }
            }

            HStack(spacing: 16) {
                valuePair("Height", String(format: "%.1f m", Double(details.height) / 10))
                valuePair("Weight", String(format: "%.1f kg", Double(details.weight) / 10))
                valuePair("Base Total", "\(details.baseStatTotal)")
            }

            Text("Possible Abilities")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            Text(details.possibleAbilities.map { opt in
                opt.name + (opt.isHidden ? " (Hidden)" : "")
            }.joined(separator: " · "))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .detailCard()
    }

    // MARK: - Moves Section

    private func movesSection(_ details: PhoneSpeciesDetails) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Complete Move List (\(details.moveList.count))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(details.moveList) { move in
                HStack(alignment: .firstTextBaseline) {
                    Text(move.name)
                        .font(.caption)
                    Spacer()
                    Text(move.methods.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                Divider()
            }
        }
        .detailCard()
    }

    private func valuePair(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.semibold))
        }
    }
}

// MARK: - View Extensions

private extension View {
    func detailCard() -> some View {
        self.padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Rarity Chip

private struct RarityChip: View {
    let label: String
    let count: Int
    let color: Color
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(label)
                    .font(.caption2)
                Text("\(count)")
                    .font(.caption2.weight(.bold))
                    .monospacedDigit()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(isSelected ? color : .secondary)
            .background(isSelected ? color.opacity(0.18) : Color.secondary.opacity(0.08))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
