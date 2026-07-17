import SwiftUI

/// "Create a Postcard": `PostcardStage` (the drop-zone/preview hero) beside or above a
/// `Form` of metadata fields, compiling straight into a collection. Thin over
/// `CreatePostcardModel`, which owns every piece of state and the create-gating/JSON-building
/// logic — this view is layout (the adaptive stage/fields split), `Section`/`LabeledContent`
/// scaffolding for the fields (following `CardInfoPanel`'s `Form` idiom), and the create flow's
/// two Go core calls (`GoCore.compilePostcard` → `GoCore.addCard`).
///
/// Hosted from two places (see `PostcardsApp`/`LibraryView`): a macOS `Window` scene, and an
/// iPad `fullScreenCover` — both pass the same `library`/`cloudLibrary` so either presentation
/// reads/writes the identical destination list and bumps the identical `contentGeneration`.
struct CreatePostcardForm: View {
    let library: LibraryModel
    let cloudLibrary: CloudLibrary

    @State private var model = CreatePostcardModel()
    @State private var isCreating = false
    @State private var dimensionsError: String?
    @State private var flipError: String?
    @State private var alertMessage: String?
    /// Autocomplete corpus for the From/To/Catalogued-by rows — loaded once on appear,
    /// quietly empty when the call fails or the library knows no one: just no suggestions.
    @State private var people: [PersonRef] = []
    /// Whether the Location section shows its manual fields — search-first, so they're
    /// revealed by the "Enter manually" button or automatically (already filled) once a
    /// search result is chosen.
    @State private var showsManualLocation = false
    @Environment(\.dismiss) private var dismiss

    /// Below this width the stage sits above a scrolling fields column instead of beside it —
    /// roughly separates iPad portrait (≤834pt) from iPad landscape/a macOS window, without
    /// hardcoding device breakpoints (see the type doc for the `GeometryReader` this drives).
    private static let wideLayoutMinWidth: CGFloat = 780
    private static let stageWidthFraction: CGFloat = 0.45

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                if proxy.size.width >= Self.wideLayoutMinWidth {
                    HStack(spacing: 0) {
                        ScrollView {
                            stage.padding()
                        }
                        .frame(width: min(max(proxy.size.width * Self.stageWidthFraction, 320), 480))
                        Divider()
                        Form { fieldsSections }
                            .formStyle(.grouped)
                            .safeAreaInset(edge: .top) { blockingIssueToast }
                            .animation(.default, value: model.canCreate)
                    }
                } else {
                    Form {
                        // Strips the Form's default row chrome (inset background, separator)
                        // so the stage's own cards/shadows render edge-to-edge above the
                        // fields, rather than looking like just another grouped row.
                        Section {
                            stage
                                .padding(.vertical, 8)
                                .padding(.horizontal, 4)
                                .listRowInsets(EdgeInsets())
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }
                        fieldsSections
                    }
                    .formStyle(.grouped)
                    .safeAreaInset(edge: .top) { blockingIssueToast }
                    .animation(.default, value: model.canCreate)
                }
            }
            .navigationTitle("Create a Postcard")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create Postcard") { Task { await create() } }
                        .disabled(!model.canCreate || isCreating)
                }
            }
            .disabled(isCreating)
            .overlay {
                if isCreating {
                    ProgressView("Creating…")
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .alert(
                "Couldn't create postcard",
                isPresented: Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(alertMessage ?? "")
            }
            .task { people = (try? await GoCore.shared.libraryPeople()) ?? [] }
        }
        #if os(macOS)
        .frame(minWidth: 860, minHeight: 640)
        #endif
    }

    private var stage: some View {
        PostcardStage(model: model, dimensionsError: dimensionsError)
    }

    /// Every remaining `Form` section, in order — factored out so both the wide (beside the
    /// stage) and narrow (below it, in the same `Form`) layouts share exactly one definition.
    /// The pane reads: Card · Flip axis (once a back exists) · From/To · Location ·
    /// Describe & transcribe · Destination · Advanced, with Create in the toolbar and
    /// blocking issues surfaced as a floating toast pinned above everything (see
    /// `blockingIssueToast`) rather than a trailing section.
    @ViewBuilder
    private var fieldsSections: some View {
        cardSection
        if model.back != nil {
            flipAxisSection
        }
        peopleSection
        locationSection
        describeSection
        destinationSection
        advancedSection
    }

    // MARK: - Card

    private var cardSection: some View {
        Section("Card") {
            TextField("Name", text: $model.name)
            Toggle("Sent on a known date", isOn: sentOnKnownBinding)
            if model.sentOn != nil {
                DatePicker("Date", selection: sentOnDateBinding, displayedComponents: .date)
            }
        }
    }

    // MARK: - Flip axis

    /// Only mounted once a back image exists (see `fieldsSections`) — matches the flip
    /// picker's old visibility rule from when it lived on the stage.
    private var flipAxisSection: some View {
        Section("Flip axis") {
            FlipAxisPicker(model: model, flipError: flipError)
        }
    }

    // MARK: - People (From / To / Catalogued by)

    private var peopleSection: some View {
        Section {
            PersonFieldRow(label: "From", name: $model.senderName, uri: $model.senderURI, people: people, preferredRole: "from")
            PersonFieldRow(label: "To", name: $model.recipientName, uri: $model.recipientURI, people: people, preferredRole: "to")
            PersonFieldRow(label: "Catalogued by", name: $model.contextAuthorName, uri: $model.contextAuthorURI, people: people, preferredRole: "collector")
        }
    }

    private var sentOnKnownBinding: Binding<Bool> {
        Binding(
            get: { model.sentOn != nil },
            set: { isKnown in model.sentOn = isKnown ? (model.sentOn ?? Date()) : nil }
        )
    }

    private var sentOnDateBinding: Binding<Date> {
        Binding(get: { model.sentOn ?? Date() }, set: { model.sentOn = $0 })
    }

    // MARK: - Location

    private var locationSection: some View {
        Section("Location") {
            LocationSearchField(
                name: $model.locationName,
                latitude: $model.locationLatitude,
                longitude: $model.locationLongitude,
                countryCode: $model.locationCountryCode
            )
            // A chosen search result always writes a coordinate, so this is the "a result
            // was picked" signal that reveals the (now filled) manual fields.
            .onChange(of: model.locationLatitude) { _, newValue in
                guard newValue != nil else { return }
                withAnimation(.easeInOut) { showsManualLocation = true }
            }

            if showsManualLocation {
                TextField("Place name", text: $model.locationName)
                TextField("Latitude", text: latitudeTextBinding)
                TextField("Longitude", text: longitudeTextBinding)
                HStack {
                    TextField("Country code (alpha-3)", text: countryCodeBinding)
                        #if os(iOS)
                        .textInputAutocapitalization(.characters)
                        #endif
                        .autocorrectionDisabled()
                    if let flag = CountryFlags.flag(forAlpha3: model.locationCountryCode) {
                        Text(flag)
                    }
                }
            } else {
                Button("Enter manually") {
                    withAnimation(.easeInOut) { showsManualLocation = true }
                }
                .font(.footnote)
                .buttonStyle(.borderless)
            }
        }
    }

    /// Stored uppercase — `Location.countryCode` is always the uppercase alpha-3 form
    /// (`CountryFlags`' table keys, e.g. "ITA"), so this normalizes on entry rather than
    /// leaving a lowercase mistype to silently fail the flag lookup and round-trip oddly.
    private var countryCodeBinding: Binding<String> {
        Binding(get: { model.locationCountryCode }, set: { model.locationCountryCode = $0.uppercased() })
    }

    private var latitudeTextBinding: Binding<String> {
        Binding(
            get: { model.locationLatitude.map { String($0) } ?? "" },
            set: { model.locationLatitude = Double($0) }
        )
    }

    private var longitudeTextBinding: Binding<String> {
        Binding(
            get: { model.locationLongitude.map { String($0) } ?? "" },
            set: { model.locationLongitude = Double($0) }
        )
    }

    // MARK: - Describe & transcribe

    private var describeSection: some View {
        Section {
            DescribeWizard(model: model)
        } header: {
            Text("Describe & transcribe")
        } footer: {
            Text("Describing the card helps blind collectors and powers search.")
                .font(.footnote)
        }
    }

    // MARK: - Advanced

    private var advancedSection: some View {
        Section {
            DisclosureGroup("Advanced") {
                TextField("Locale", text: $model.locale)
                LabeledContent("Thickness (mm)") {
                    TextField("mm", value: $model.thicknessMM, format: .number)
                        .multilineTextAlignment(.trailing)
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                }
                ColorPicker("Card colour", selection: cardColorBinding, supportsOpacity: false)
                Toggle("Remove scan border", isOn: $model.removeBorder)
                Toggle(isOn: $model.archival) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Archival (lossless)")
                        Text("Stores a larger file, sized for preservation rather than everyday viewing.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                labeledTextEditor("Notes", text: $model.contextDescription)
            }
        }
    }

    private var cardColorBinding: Binding<Color> {
        Binding(
            get: { Color(hex: model.cardColorHex) ?? Color(hex: "#E6E6D9") ?? .white },
            set: { model.cardColorHex = $0.hexString }
        )
    }

    // MARK: - Destination

    /// "Individual postcards" (a bare file, `destinationCollectionPath == nil`) leads and is
    /// the default — creating with zero collections is fine — with any writable collections
    /// listed after it.
    private var destinationSection: some View {
        Section("Destination") {
            Picker("Add to", selection: $model.destinationCollectionPath) {
                Text("Individual postcards").tag(nil as String?)
                ForEach(writableCollections) { collection in
                    Text(collection.displayName).tag(collection.path as String?)
                }
            }
        }
    }

    /// The same "known writable collections" rule `LibraryView.writableCollections` uses (see
    /// `WritableCollection.known(sources:downloaded:)`), so both build the identical list.
    private var writableCollections: [WritableCollection] {
        let downloaded = cloudLibrary.items
            .filter { $0.isCollection && $0.downloadState == .current }
            .map { WritableCollection(path: $0.path, displayName: $0.displayName) }
        return WritableCollection.known(sources: library.sources, downloaded: downloaded)
    }

    // MARK: - Blocking issues

    /// A compact, floating "next thing to do" banner pinned above the fields pane's scroll
    /// content via `.safeAreaInset(edge: .top)` — content scrolls beneath it, never behind
    /// it, and its reserved inset (plus the banner itself) disappears with a standard
    /// transition the instant `model.canCreate` goes true. Shows only the first blocking
    /// issue: one thing to fix at a time, not a growing list.
    @ViewBuilder
    private var blockingIssueToast: some View {
        if let issue = model.blockingIssues.first {
            Label(issue.message, systemImage: "exclamationmark.circle.fill")
                .font(.footnote)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: - Shared field helper

    private func labeledTextEditor(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: text)
                .frame(minHeight: 60)
        }
    }

    // MARK: - Create

    private func create() async {
        guard let front = model.front?.data else { return }
        dimensionsError = nil
        flipError = nil
        isCreating = true
        defer { isCreating = false }
        do {
            let metadataJSON = try model.metadataJSON()
            let compiled = try await GoCore.shared.compilePostcard(
                name: model.name.trimmingCharacters(in: .whitespacesAndNewlines),
                metadataJSON: metadataJSON,
                front: front,
                back: model.back?.data,
                removeBorder: model.removeBorder,
                archival: model.archival
            )
            // `nil` is "Individual postcards" — a bare file — not an unset destination; see
            // `CreatePostcardModel.destinationCollectionPath`.
            if let destination = model.destinationCollectionPath {
                if isCloudBacked(destination) {
                    try await CloudLibrary.primeForGoCoreWrite(path: destination)
                }
                try await GoCore.shared.addCard(filename: compiled.filename, data: compiled.data, toCollectionAt: destination)
            } else {
                _ = try library.addBareCard(filename: compiled.filename, data: compiled.data)
            }
            library.contentGeneration += 1
            dismiss()
        } catch {
            mapCreateError(error)
        }
    }

    private func isCloudBacked(_ path: String) -> Bool {
        cloudLibrary.items.contains { $0.path == path }
    }

    /// Maps a create failure to the section it's about when that's obvious — a physical-size
    /// mismatch (Go's `SimilarPhysical` check, or this model's own `MetadataError`) to the
    /// dimensions section, an illegal flip (Go's `CheckFlip`) to the flip row — falling back
    /// to a general alert for anything else (e.g. a secret-region bounds error, which has
    /// nowhere to land until `SecretRegionEditor` exists).
    private func mapCreateError(_ error: Error) {
        if error is CreatePostcardModel.MetadataError {
            dimensionsError = error.localizedDescription
            return
        }
        let message = error.localizedDescription
        if message.localizedCaseInsensitiveContains("physical size") {
            dimensionsError = message
        } else if message.localizedCaseInsensitiveContains("flip") {
            flipError = message
        } else {
            alertMessage = message
        }
    }
}

/// A minimal hex ↔ `Color` bridge for `cardColorHex`'s `ColorPicker` — view-only, so it lives
/// here rather than in `CreatePostcardModel`, which stores and validates the hex string but
/// never needs to construct a `Color` from it.
private extension Color {
    init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let rgb = UInt32(value, radix: 16) else { return nil }
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }

    var hexString: String {
        let resolved = resolve(in: EnvironmentValues())
        return String(
            format: "#%02X%02X%02X",
            Int((resolved.red * 255).rounded()),
            Int((resolved.green * 255).rounded()),
            Int((resolved.blue * 255).rounded())
        )
    }
}
