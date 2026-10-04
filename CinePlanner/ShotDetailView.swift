//
//  ShotDetailView.swift
//  CinePlanner
//
//  The shot detail editor: setup, camera, script coverage and custom info, with its
//  rows and number fields.
//

import SwiftUI
import SwiftData
import PhotosUI
import AVKit
import UniformTypeIdentifiers
import os

/// Width of the focal-length text fields. Wider on iPad, where the larger text
/// field font needs more room to show three-digit focal lengths (100 mm+).
#if os(iOS)
private let focalFieldWidth: CGFloat = 60
#else
private let focalFieldWidth: CGFloat = 35
#endif

/// One editable custom-info field: a custom label plus its text value, with a
/// delete button. Matches the Shot Setup card's label-column / field layout.
private struct CustomInfoRow: View {
    @Bindable var item: ShotCustomInfo
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            DebouncedTextField("Label", text: $item.label)
                .textFieldStyle(.roundedBorder)
                .font(.headline)
                .frame(width: 100, alignment: .leading)
            DebouncedTextField("Value", text: $item.value, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...10)
                .frame(maxWidth: 200)
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove this field")
        }
    }
}

/// Time-of-day field: a preset picker (dawn, dusk, golden hour…) plus a Custom
/// option that reveals a free-text field.
private struct ShotTimeOfDayRow: View {
    @Bindable var item: ShotCustomInfo
    let onDelete: () -> Void

    private static let customTag = "\u{1}custom"   // sentinel that can't be a preset

    private var isCustom: Bool { !ShotCustomInfo.timeOfDayPresets.contains(item.value) }

    private var selection: Binding<String> {
        Binding(
            get: { ShotCustomInfo.timeOfDayPresets.contains(item.value) ? item.value : Self.customTag },
            set: { newValue in
                if newValue == Self.customTag {
                    if ShotCustomInfo.timeOfDayPresets.contains(item.value) { item.value = "" }
                } else {
                    item.value = newValue
                }
            }
        )
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("Time of day")
                .font(.headline).frame(width: 100, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                Picker("", selection: selection) {
                    ForEach(ShotCustomInfo.timeOfDayPresets, id: \.self) { Text($0).tag($0) }
                    Divider()
                    Text("Custom…").tag(Self.customTag)
                }
                .labelsHidden().fixedSize()
                if isCustom {
                    DebouncedTextField("Describe the time of day", text: $item.value)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                }
            }
            Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                .buttonStyle(.borderless).help("Remove this field")
        }
    }
}

/// Film-stock calculator field: pick a gauge, then convert length↔duration.
private struct FilmStockRow: View {
    @Bindable var item: ShotCustomInfo
    let onDelete: () -> Void
    @State private var showTotals = false

    private var sceneShots: [Shot] { item.shot?.scene?.shots ?? [] }
    private var projectShots: [Shot] {
        item.shot?.scene?.project?.scenes.flatMap { $0.shots } ?? sceneShots
    }

    @ViewBuilder
    private func totalsSection(_ title: String,
                              _ totals: [(gauge: String, metres: Double, seconds: Double)]) -> some View {
        HStack {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Spacer()
            if totals.isEmpty {
                Text("—").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        ForEach(totals, id: \.gauge) { t in
            HStack {
                Text(ShotCustomInfo.filmGaugeLabel(t.gauge))
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(width: 84, alignment: .leading)
                Spacer()
                Text("\(ShotCustomInfo.filmMetresString(t.metres)) · \(ShotCustomInfo.filmDurationString(t.seconds))")
                    .font(.subheadline).fontWeight(.medium).monospacedDigit()
            }
        }
    }

    private var minutesField: Binding<Int> {
        Binding(get: { Int(item.filmAmount) / 60 },
                set: { item.filmAmount = Double(max(0, $0) * 60 + Int(item.filmAmount) % 60) })
    }
    private var secondsField: Binding<Int> {
        Binding(get: { Int(item.filmAmount) % 60 },
                set: { item.filmAmount = Double((Int(item.filmAmount) / 60) * 60 + max(0, min(59, $0))) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "film")
                    .foregroundStyle(.tint)
                Text("Film length")
                    .font(.headline)
                Spacer()
                Menu {
                    Button {
                        item.shot?.scene?.enableSceneFilmTool(
                            gauge: item.filmGauge, fps: item.filmFPS, mode: item.filmMode,
                            context: item.modelContext)
                        item.modelContext?.saveReporting()
                    } label: {
                        Label("Apply to all shots in scene", systemImage: "square.stack.3d.up")
                    }
                    if item.shot?.scene?.sceneFilmToolEnabled == true {
                        Text("New shots inherit these settings")
                        Button {
                            item.shot?.scene?.sceneFilmToolEnabled = false
                            item.modelContext?.saveReporting()
                        } label: {
                            Label("Stop applying to new shots", systemImage: "xmark.circle")
                        }
                    }
                } label: {
                    Image(systemName: "gearshape")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .foregroundStyle(.secondary)
                .help("Use these film settings for every shot in the scene")

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help("Remove this field")
            }

            // Gauge + frame rate.
            HStack(spacing: 12) {
                Picker("", selection: $item.filmGauge) {
                    ForEach(ShotCustomInfo.filmGauges, id: \.self) { Text(ShotCustomInfo.filmGaugeLabel($0)).tag($0) }
                }
                .labelsHidden().fixedSize()
                HStack(spacing: 4) {
                    DecimalField(value: $item.filmFPS, width: 52, alignment: .trailing, placeholder: "fps")
                    Text("fps").foregroundStyle(.secondary)
                }
            }

            // Direction toggle.
            Picker("", selection: $item.filmMode) {
                Text("Length → Time").tag("meters")
                Text("Time → Length").tag("time")
            }
            .pickerStyle(.segmented).labelsHidden()

            // Input → result.
            HStack(spacing: 8) {
                if item.filmMode == "meters" {
                    DecimalField(value: $item.filmAmount, width: 64, alignment: .trailing, placeholder: "0")
                    Text("m").foregroundStyle(.secondary)
                } else {
                    NumericField(value: minutesField, width: 44, alignment: .trailing, placeholder: "0")
                    Text("min").foregroundStyle(.secondary)
                    NumericField(value: secondsField, width: 44, alignment: .trailing, placeholder: "0")
                    Text("sec").foregroundStyle(.secondary)
                }
                Image(systemName: "equal")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 2)
                Text(item.filmComputedText.isEmpty ? "—" : item.filmComputedText)
                    .font(.title3).fontWeight(.semibold).foregroundStyle(.tint)
                    .contentTransition(.numericText())
                    .animation(.default, value: item.filmComputedText)
                Spacer(minLength: 0)
            }

            // Roll-ups across the scene and the whole project, per gauge —
            // collapsed by default so the card stays compact. The whole label row
            // toggles it.
            Divider()
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showTotals.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .rotationEffect(.degrees(showTotals ? 90 : 0))
                    Text("Scene & project totals").font(.caption)
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showTotals {
                VStack(alignment: .leading, spacing: 6) {
                    totalsSection("Scene total", ShotCustomInfo.filmTotalsByGauge(for: sceneShots))
                    totalsSection("Project total", ShotCustomInfo.filmTotalsByGauge(for: projectShots))
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.18)))
        )
        .frame(maxWidth: 340, alignment: .leading)
        .onAppear {
            // Migrate the old generic "35" to explicit 4-perf so the picker matches.
            if item.filmGauge == "35" { item.filmGauge = "35-4" }
        }
    }
}

struct ShotDetailView: View {
    @Bindable var shot: Shot
    /// Which photo is open full size, if any.
    @Environment(\.modelContext) private var shotModelContext
    @State private var isMarkingCoverage = false
    /// iOS two-tap marking: false while picking the first word, true for the last.
    @State private var markLastPhase = false
    /// iPad with a pointer marks the Mac way (drag to select, one Done) instead of
    /// the two-tap word picker.
    @State private var pointerMarking = false
    @State private var showSecondType: Bool = false
    @State private var showThirdType: Bool = false
    @State private var showSecondSize: Bool = false
    /// Presents the per-project card settings (Shot Setup field order + the
    /// Camera Information default), opened from either card's gear.
    @State private var showingCardSettings = false

    // Computed properties for autocomplete suggestions
    /// Camera / framelines / lens values carried on imported reference metadata
    /// across the project. Offered in the camera dropdowns so an imported value is
    /// still one tap away even though it's no longer copied onto a shot's own camera
    /// fields when those already hold something.
    private var referenceMetadataOptions: (cameras: Set<String>, framelines: Set<String>, lenses: Set<String>) {
        var cameras = Set<String>(), framelines = Set<String>(), lenses = Set<String>()
        guard let project = shot.scene?.project else { return (cameras, framelines, lenses) }
        for scene in project.scenes {
            for projectShot in scene.shots {
                for ref in projectShot.references {
                    let cam = Shot.combinedCamera(ref.cameraFamily ?? "", ref.cameraFormat ?? "")
                    if !cam.isEmpty { cameras.insert(cam) }
                    if let fl = ref.framelines, !fl.isEmpty { framelines.insert(fl) }
                    if let lp = ref.lensPreset, !lp.isEmpty { lenses.insert(lp) }
                }
            }
        }
        return (cameras, framelines, lenses)
    }

    private var previousCameraValues: [String] {
        guard let project = shot.scene?.project else { return [] }

        var cameras = Set<String>()
        for scene in project.scenes {
            for projectShot in scene.shots {
                // Don't include the current shot
                if projectShot.id != shot.id && !projectShot.camera.isEmpty {
                    cameras.insert(projectShot.camera)
                }
            }
        }
        cameras.formUnion(referenceMetadataOptions.cameras)
        return Array(cameras).sorted()
    }
    
    /// When this shot's (combined) camera matches one already imported from
    /// CineStager — which carries a real sensor width — reuse that sensor for this
    /// shot. So a manually-added shot set to a previously-imported camera gets the
    /// correct scene-map FOV, without a CineStager import of its own. Only ever
    /// copies a value in — never clears one — so it can't wipe an imported shot's
    /// own sensor. Runs when the camera changes.
    private func inheritCineStagerSensorWidth() {
        guard !shot.camera.isEmpty, let project = shot.scene?.project else { return }
        for scene in project.scenes {
            for other in scene.shots where other.id != shot.id {
                if let sensor = other.sensorWidthMM, sensor > 0, other.camera == shot.camera {
                    if shot.sensorWidthMM != sensor { shot.sensorWidthMM = sensor }
                    return
                }
            }
        }
    }

    private var previousLensValues: [String] {
        guard let project = shot.scene?.project else { return [] }

        var lenses = Set<String>()
        for scene in project.scenes {
            for projectShot in scene.shots {
                // Don't include the current shot
                if projectShot.id != shot.id && !projectShot.lensPreset.isEmpty {
                    lenses.insert(projectShot.lensPreset)
                }
            }
        }
        lenses.formUnion(referenceMetadataOptions.lenses)
        return Array(lenses).sorted()
    }

    private var previousFrameLinesValues: [String] {
        guard let project = shot.scene?.project else { return [] }

        var values = Set<String>()
        for scene in project.scenes {
            for projectShot in scene.shots {
                if projectShot.id != shot.id && !projectShot.framelines.isEmpty {
                    values.insert(projectShot.framelines)
                }
            }
        }
        values.formUnion(referenceMetadataOptions.framelines)
        return Array(values).sorted()
    }

    // MARK: Visual helpers

    /// A titled group of rows, used as one section inside the combined card.
    @ViewBuilder
    private func sectionCard<Content: View>(_ title: String, gear: (() -> Void)? = nil,
                                            @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .kerning(0.5)
                if let gear {
                    Spacer(minLength: 8)
                    Button(action: gear) {
                        Image(systemName: "gearshape")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 24)
                            .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .help("Card settings")
                    .accessibilityLabel("Card settings")
                }
            }

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A SHOT SETUP row: the label sits beside its controls when the pane is wide
    /// enough, and stacks above them when it's too narrow — so the controls (a
    /// zoom range, or several sizes/types) never overlap or clip.
    private func setupRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        let controls = content()
        return ViewThatFits(in: .horizontal) {
            HStack {
                Text(label).font(.headline).frame(width: 100, alignment: .leading)
                controls
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(label).font(.headline)
                controls
            }
        }
    }

    /// The shot's setup and camera sections, unified into one card.
    private var combinedDetailCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Setup + camera side by side when wide, stacked when narrow.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    shotSetupCard
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Divider()
                    cameraInformationCard
                        .frame(width: 300)
                }
                VStack(alignment: .leading, spacing: 18) {
                    shotSetupCard
                    Divider()
                    cameraInformationCard
                }
            }
        }
        .modifier(DetailCardChrome())
    }

    /// Script coverage as its own card, matching the reference cards.
    private var scriptCoverageStandaloneCard: some View {
        scriptCoverageCard
            .modifier(DetailCardChrome())
    }

    // Extracted so both can be laid out either side by side or stacked,
    // depending on how much width the details pane has.
    /// Whether the two photos came from the same capture. It describes the
    /// relationship between the cards, so it sits above the pair rather than
    /// buried under the top-down image.
    /// Images cap at this width; the metadata beneath them uses the same value
    /// so a data block is never wider than the picture it describes.
    private static let mediaMaxWidth: CGFloat = 700

    private var addReferenceLabel: some View {
        Label("Add Reference Image/Video", systemImage: "plus.circle.fill")
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
    }

    private func addReference() {
        let next = (shot.references.map(\.sortOrder).max() ?? -1) + 1
        let reference = ShotReference(sortOrder: next)
        shotModelContext.insert(reference)
        reference.shot = shot
        // Persist immediately so the reference's persistentModelID is permanent
        // from the start. Otherwise a later autosave flips it from temporary to
        // permanent, and if that happens while a file picker is open, the card
        // (keyed by that id) is rebuilt and the picker is torn down mid-use.
        shotModelContext.saveReporting()
    }

    private func deleteReference(_ reference: ShotReference) {
        reference.shot = nil
        shotModelContext.delete(reference)
    }

    private var shotSetupCard: some View {
    sectionCard("SHOT SETUP", gear: { showingCardSettings = true }) {
        ForEach(orderedSetupFields) { field in
            shotSetupFieldView(field)
        }
        customInfoSection
    }
    }

    /// The Shot Setup fields in this project's chosen order, minus any hidden here.
    private var orderedSetupFields: [ShotSetupField] {
        guard let project = shot.scene?.resolvedProject else { return ShotSetupField.allCases }
        let hidden = project.hiddenShotSetupFields
        return project.shotSetupFieldOrder.filter { !hidden.contains($0) }
    }

    /// One Shot Setup field — lets the card render them in the project's order.
    @ViewBuilder
    private func shotSetupFieldView(_ field: ShotSetupField) -> some View {
        switch field {
        case .nickname:
    setupRow("Nickname") {
        DebouncedTextField("Add a nickname for this shot", text: $shot.nickname)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 200)
    }

        case .size:
    setupRow("Size") {
        HStack(spacing: 8) {
            OptionPickerView(
                noun: "size",
                placeholder: "Select size",
                sections: [(title: "Sizes", options: ShotSize.pickerOptions),
                           (title: "Other", options: ShotSize.framingOptions)],
                grouped: true,
                value: $shot.sizeName,
                customKey: "customSizes"
            )

            // Plus button (only show when first size is selected and second dropdown is hidden)
            if shot.hasSize && !showSecondSize {
                Button {
                    showSecondSize = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
            }

            // Arrow and second size dropdown (only show when showSecondSize is true)
            if showSecondSize {
                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                OptionPickerView(
                    noun: "size",
                    placeholder: "Select size",
                    sections: [(title: "", options: ShotSize.pickerOptions)],
                    grouped: false,
                    value: $shot.secondSizeName,
                    customKey: "customSizes",
                    onSelect: { if $0.isEmpty { showSecondSize = false } }
                )

                // Remove button for second size
                Button {
                    shot.secondSizeName = ""
                    showSecondSize = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.gray)
                }
                .buttonStyle(.plain)
            }
        }
    }

        case .type:
    setupRow("Type") {
        HStack(spacing: 8) {
            OptionPickerView(
                noun: "type",
                placeholder: "Select type",
                sections: ShotTypeCategory.pickerGroups,
                value: $shot.typeName,
                customKey: "customTypes"
            )

            // Plus button (only show when first type is selected and second dropdown is hidden)
            if shot.hasType && !showSecondType {
                Button {
                    showSecondType = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
            }

            // Second type dropdown (only show when showSecondType is true)
            if showSecondType {
                OptionPickerView(
                    noun: "type",
                    placeholder: "Select type",
                    sections: ShotTypeCategory.pickerGroups,
                    value: $shot.secondTypeName,
                    customKey: "customTypes",
                    onSelect: {
                        if $0.isEmpty {
                            showSecondType = false
                            showThirdType = false
                            shot.thirdTypeName = ""
                        }
                    }
                )

                // Plus button for third type (only show when second type is selected and third is hidden)
                if shot.hasSecondType && !showThirdType {
                    Button {
                        showThirdType = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                } else if !showThirdType {
                    // Remove button for second type (only show if third type is not visible)
                    Button {
                        shot.secondTypeName = ""
                        showSecondType = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.gray)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Third type dropdown (only show when showThirdType is true)
            if showThirdType {
                OptionPickerView(
                    noun: "type",
                    placeholder: "Select type",
                    sections: ShotTypeCategory.pickerGroups,
                    value: $shot.thirdTypeName,
                    customKey: "customTypes",
                    onSelect: { if $0.isEmpty { showThirdType = false } }
                )

                // Remove button for third type
                Button {
                    shot.thirdTypeName = ""
                    showThirdType = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.gray)
                }
                .buttonStyle(.plain)
            }
        }
    }
    
        case .focal:
    setupRow("Focal Length") {
        HStack(spacing: 8) {
            // First focal length field
            HStack(spacing: 4) {
                NumericField(value: $shot.lensfocal, width: focalFieldWidth)

                Text("mm")
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            
            // Arrow and second field (only for zoom)
            if !shot.lensIsPrime {
                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 4) {
                    NumericField(value: $shot.lensfocalEnd, width: focalFieldWidth)

                    Text("mm")
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }

            Divider()
                .frame(height: 16)
                .padding(.horizontal, 4)

            // Zoom toggle (off = prime lens, the default).
            let zoomBinding = Binding(
                get: { !shot.lensIsPrime },
                set: { shot.lensIsPrime = !$0 }
            )
            #if os(macOS)
            Toggle("Zoom", isOn: zoomBinding)
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .fixedSize()
                .help("On: zoom lens with a focal range. Off: prime lens with a single focal length.")
            #else
            // A compact switch so the row fits more often before it has to stack.
            HStack(spacing: 10) {
                Text("Zoom").foregroundStyle(.secondary).fixedSize()
                Toggle("", isOn: zoomBinding)
                    .labelsHidden()
                    .scaleEffect(0.8)
                    .frame(width: 42, height: 26)
            }
            .help("On: zoom lens with a focal range. Off: prime lens with a single focal length.")
            #endif
        }
    }
    
        case .grip:
    setupRow("Grip") {
        OptionPickerView(
            noun: "grip",
            placeholder: "Select grip",
            sections: ShotType.pickerGroups,
            value: $shot.gripName,
            customKey: "customGrips"
        )
    }

        case .description:
    // Shot description — part of the core shot settings, right under Grip.
    // Vertical axis lets the field grow as the text gets longer.
    HStack(alignment: .top) {
        Text("Description")
            .font(.headline)
            .frame(width: 100, alignment: .leading)

        DebouncedTextField("Describe the shot", text: $shot.extraInfo, axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .lineLimit(1...10)
            .frame(maxWidth: 200)
    }

        }
    }

    // User-added custom fields, listed under Extra info with an "Add Custom Info"
    // menu (a labelled text box for now; more field types can join the menu).
    // Film-length tools live in the Camera Information card (see filmToolsSection).
    @ViewBuilder
    private var customInfoSection: some View {
        ForEach(shot.orderedCustomInfo.filter { $0.kind != "filmstock" }) { item in
            if item.kind == "timeofday" {
                ShotTimeOfDayRow(item: item) { deleteCustomInfo(item) }
            } else {
                CustomInfoRow(item: item) { deleteCustomInfo(item) }
            }
        }
        Menu {
            Button {
                addCustomInfo(kind: "text")
            } label: {
                Label("Text field with label", systemImage: "textformat")
            }
            Button {
                addCustomInfo(kind: "timeofday")
            } label: {
                Label("Time of day", systemImage: "sun.horizon")
            }
            Button {
                addCustomInfo(kind: "filmstock")
            } label: {
                Label("Film length calculator", systemImage: "film")
            }
        } label: {
            Label("Add Tool", systemImage: "plus")
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.top, 2)
    }

    private func addCustomInfo(kind: String) {
        let next = (shot.customInfo.map(\.sortOrder).max() ?? -1) + 1
        let item = ShotCustomInfo(sortOrder: next, kind: kind)
        if kind == "timeofday" { item.value = ShotCustomInfo.timeOfDayPresets.first ?? "" }
        item.shot = shot
        shotModelContext.insert(item)
        shotModelContext.saveReporting()
    }

    private func deleteCustomInfo(_ item: ShotCustomInfo) {
        shotModelContext.delete(item)
        shotModelContext.saveReporting()
    }

    private var scriptCoverageCard: some View {
    sectionCard("SCRIPT COVERAGE") {
        // While marking, the instruction and Done/Cancel — previously an overlay
        // on the PDF — appear here in the card. The PDF selection itself is
        // unchanged; Done/Cancel just signal the coordinator.
        if isMarkingCoverage {
            HStack(spacing: 10) {
                Image(systemName: "highlighter")
                    .foregroundStyle(.blue)
                #if os(iOS)
                Text(pointerMarking ? "Select text in the PDF, then:"
                     : (markLastPhase ? "Tap the last word, then Done"
                                      : "Tap the first word, then Next"))
                    .font(.body)
                #else
                Text("Select text in the PDF, then:")
                    .font(.body)
                #endif
                Spacer(minLength: 0)
                Button("Cancel") {
                    NotificationCenter.default.post(name: .cancelScriptSelection, object: nil)
                }
                .buttonStyle(.bordered)
                #if os(iOS)
                Button(pointerMarking || markLastPhase ? "Done" : "Next") {
                    NotificationCenter.default.post(name: .captureScriptSelection, object: nil)
                }
                .buttonStyle(.borderedProminent)
                #else
                Button("Done") {
                    NotificationCenter.default.post(name: .captureScriptSelection, object: nil)
                }
                .buttonStyle(.borderedProminent)
                #endif
            }
        } else {
            HStack {
                Button {
                    // Signal the PDF viewer to enter text selection mode
                    NotificationCenter.default.post(
                        name: .startScriptTextSelection, object: nil,
                        userInfo: ["shot": shot])
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "highlighter")
                        Text("Mark Text")
                    }
                }
                .buttonStyle(.bordered)

                if let selections = shot.scriptCoverageSelections, !selections.isEmpty {
                    Text("(\(selections.count) marking\(selections.count == 1 ? "" : "s"))")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button(role: .destructive) {
                        shot.scriptCoverageSelections = nil
                        shot.coverageSceneUIDs = nil   // no coverage → no aliases
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Clear all coverage markings")
                }
            }
        }
    }
    .onReceive(NotificationCenter.default.publisher(for: .scriptSelectionModeChanged)) { note in
        // Only react to this shot's selection; ignore an id that isn't ours.
        let active = note.userInfo?["active"] as? Bool ?? false
        if active {
            if let id = note.userInfo?["shotID"] as? PersistentIdentifier, id == shot.persistentModelID {
                isMarkingCoverage = true
                markLastPhase = false
                pointerMarking = note.userInfo?["pointer"] as? Bool ?? false
            }
        } else {
            isMarkingCoverage = false
            markLastPhase = false
            pointerMarking = false
        }
    }
    .onReceive(NotificationCenter.default.publisher(for: .scriptSelectionPhaseChanged)) { note in
        markLastPhase = (note.userInfo?["phase"] as? Int ?? 0) == 1
    }
    }

    private var cameraInformationCard: some View {
    sectionCard("CAMERA INFORMATION") {
        // Camera - Always editable
        HStack {
            Text("Camera")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)

            HStack(spacing: 4) {
                DebouncedTextField("Camera · Format", text: $shot.camera)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                    .onChange(of: shot.camera) { inheritCineStagerSensorWidth() }

                // Show suggestions menu if there are previous values
                if !previousCameraValues.isEmpty {
                    ChipMenu(items: previousCameraValues.map { v in
                        ChipMenuItem(title: v) { shot.camera = v }
                    }, prefersSheetOnPhone: true) {
                        Image(systemName: "chevron.down.circle")
                            .foregroundStyle(.secondary)
                    }
                    .help("Select from previously used cameras")
                }
            }
        }

        // Framelines - Always editable
        HStack {
            Text("Framelines")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)

            HStack(spacing: 4) {
                DebouncedTextField("Framelines", text: $shot.framelines)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)

                // Show suggestions menu if there are previous values
                if !previousFrameLinesValues.isEmpty {
                    ChipMenu(items: previousFrameLinesValues.map { v in
                        ChipMenuItem(title: v) { shot.framelines = v }
                    }, prefersSheetOnPhone: true) {
                        Image(systemName: "chevron.down.circle")
                            .foregroundStyle(.secondary)
                    }
                    .help("Select from previously used framelines")
                }
            }
        }

        // Lens - Always editable
        HStack {
            Text("Lens")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)

            HStack(spacing: 4) {
                DebouncedTextField("Lens name", text: $shot.lensPreset)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)

                // Show suggestions menu if there are previous values
                if !previousLensValues.isEmpty {
                    ChipMenu(items: previousLensValues.map { v in
                        ChipMenuItem(title: v) { shot.lensPreset = v }
                    }, prefersSheetOnPhone: true) {
                        Image(systemName: "chevron.down.circle")
                            .foregroundStyle(.secondary)
                    }
                    .help("Select from previously used lenses")
                }
            }
        }

        filmToolsSection
    }
    }

    // Film-length calculator tools live here, in Camera Information.
    @ViewBuilder
    private var filmToolsSection: some View {
        ForEach(shot.orderedCustomInfo.filter { $0.kind == "filmstock" }) { item in
            FilmStockRow(item: item) { deleteCustomInfo(item) }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // The shot number, nickname and size/type/grip already appear in
                // the shots list, so the detail pane goes straight to the cards.

                // Setup + camera, unified into one card.
                combinedDetailCard
                    .padding(.horizontal)

                // Script coverage, as its own card like the references.
                scriptCoverageStandaloneCard
                    .padding(.horizontal)

                // References: each is a photo or a video with its own optional
                // top-down map. A shot can carry as many as it needs.
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(shot.orderedReferences.enumerated()), id: \.element.uid) { index, reference in
                        ReferenceCardView(
                            reference: reference,
                            index: index + 1,
                            totalCount: shot.references.count,
                            onDelete: { deleteReference(reference) }
                        )
                    }

                    // Full-width and large so it can't be overlooked.
                    Button(action: addReference) { addReferenceLabel }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }
                .padding(.horizontal)
                
                Spacer()
            }
            .padding(.vertical)
            // Tapping/clicking empty space in the editor confirms and dismisses the
            // active text field.
            .contentShape(Rectangle())
            .onTapGesture { PlatformKeyboard.dismiss() }
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear {
            // Show second type dropdown if a second type is already set
            showSecondType = shot.hasSecondType
            // Show third type dropdown if a third type is already set
            showThirdType = shot.hasThirdType
            // Show second size dropdown if a second size is already set
            showSecondSize = shot.hasSecondSize
        }
        .onChange(of: shot.id) { _, _ in
            // Each reference card owns its own pickers now; only the
            // shot-level toggles need resetting here.
            showSecondType = shot.hasSecondType
            showThirdType = shot.hasThirdType
            showSecondSize = shot.hasSecondSize
        }
        .sheet(isPresented: $showingCardSettings) {
            if let project = shot.scene?.resolvedProject {
                ShotCardSettingsSheet(project: project)
            }
        }
    }

}

/// Shared card chrome for the shot-detail cards (setup/camera, script coverage),
/// so they match each other and the reference cards.
private struct DetailCardChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
            )
    }
}

/// A whole-number text field that clears when you click/tap into it (so you type
/// fresh instead of editing the old value) and commits every keystroke straight to
/// the binding — so there's no separate "confirm" step (which the iPad number pad,
/// with no Return key, otherwise lacks). Leaving it empty keeps the current value.
private struct NumericField: View {
    @Binding var value: Int
    var width: CGFloat = 60
    var alignment: TextAlignment = .leading
    var placeholder: String = ""

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .frame(width: width)
            .multilineTextAlignment(alignment)
            #if os(iOS)
            .keyboardType(.numberPad)
            #endif
            .focused($focused)
            .onAppear { text = display(value) }
            // Keep the field in sync if the value changes elsewhere (e.g. a CineStager
            // import), but never yank text out from under an active edit.
            .onChange(of: value) { _, newValue in if !focused { text = display(newValue) } }
            .onChange(of: focused) { _, isFocused in
                if isFocused { text = "" }          // clear on focus — type fresh
                else { text = display(value) }      // resync display when leaving
            }
            .onChange(of: text) { _, newText in
                let digits = newText.filter(\.isNumber)
                if digits != newText { text = digits; return }
                // Live commit — but only a real change: seeding the text on appear
                // would otherwise re-write the same value, dirtying the shot just by
                // opening it (and a dirty object misses iCloud refreshes).
                if let n = Int(digits), n != value { value = n } // empty keeps current value
            }
    }

    private func display(_ v: Int) -> String { v == 0 ? "" : String(v) }
}

/// Decimal sibling of `NumericField` (clears on focus, commits live) for `Double`
/// values — allows digits and a single decimal point.
private struct DecimalField: View {
    @Binding var value: Double
    var width: CGFloat = 60
    var alignment: TextAlignment = .leading
    var placeholder: String = ""

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .frame(width: width)
            .multilineTextAlignment(alignment)
            #if os(iOS)
            .keyboardType(.decimalPad)
            #endif
            .focused($focused)
            .onAppear { text = display(value) }
            .onChange(of: value) { _, newValue in if !focused { text = display(newValue) } }
            .onChange(of: focused) { _, isFocused in
                if isFocused { text = "" } else { text = display(value) }
            }
            .onChange(of: text) { _, newText in
                let filtered = sanitize(newText)
                if filtered != newText { text = filtered; return }
                // Live commit, only on a real change (see NumericField).
                if let n = Double(filtered), n != value { value = n } // empty/"." keeps current
            }
    }

    private func display(_ v: Double) -> String {
        if v == 0 { return "" }
        return v == v.rounded() ? String(Int(v)) : String(v)
    }
    /// Digits plus at most one decimal point.
    private func sanitize(_ s: String) -> String {
        var seenDot = false
        return String(s.filter { c in
            if c.isNumber { return true }
            if c == ".", !seenDot { seenDot = true; return true }
            return false
        })
    }
}
