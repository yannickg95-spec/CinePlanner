//
//  CineStagerImportSheet.swift
//  CinePlanner
//
//  Browse the CineStager AR shot library (synced via its iCloud Drive container)
//  and import chosen shots into a scene as new shots — image, top-down map and
//  camera/pose metadata all filled in automatically.
//

import SwiftUI
import SwiftData

struct CineStagerImportSheet: View {
    /// Supplies the reference to fill, called only once the user confirms a
    /// choice — so picking "Add Shot from CineStager" creates the new shot only
    /// on import, not when the sheet is cancelled.
    let provideReference: () -> ShotReference
    @Environment(\.dismiss) private var dismiss

    @StateObject private var library = CineStagerLibrary()
    @State private var selectedIDs: Set<UUID> = []
    @State private var isImporting = false
    @State private var grouping: Grouping = .latest
    /// Set when an import would overwrite an existing scene map, so we can ask
    /// first whether to replace it or keep the current one.
    @State private var mapConflict: PendingMapImport?

    /// An import paused on the "replace the scene map?" question.
    private struct PendingMapImport {
        let reference: ShotReference
        let cs: CineStagerShot
        let cleanData: Data?
    }

    /// CineStager's brand blue (#3ECFFF).
    static let cineStagerBlue = Color(red: 0.243, green: 0.812, blue: 1.0)

    enum Grouping: String, CaseIterable, Identifiable {
        case latest = "Latest"
        case location = "Location"
        var id: String { rawValue }
    }

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 14)]

    /// Shots grouped by CineStager location model, named groups first (A→Z) and
    /// "No location" last; newest within each group.
    private var locationGroups: [(name: String, shots: [CineStagerShot])] {
        let grouped = Dictionary(grouping: library.shots) { shot -> String in
            let loc = shot.locationModelName?.trimmingCharacters(in: .whitespaces) ?? ""
            return loc.isEmpty ? "No location" : loc
        }
        return grouped
            .map { (name: $0.key, shots: $0.value.sorted { $0.timestamp > $1.timestamp }) }
            .sorted { a, b in
                if a.name == "No location" { return false }
                if b.name == "No location" { return true }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        #if os(macOS)
        .adaptiveSheetFrame(width: 720, height: 620)
        #endif
        .task { await library.refresh() }
        .alert("Replace scene map?", isPresented: Binding(
            get: { mapConflict != nil },
            set: { if !$0 { mapConflict = nil; isImporting = false } }
        ), presenting: mapConflict) { item in
            Button("Replace with CineStager Map", role: .destructive) {
                Task { @MainActor in
                    await finishImport(item.reference, from: item.cs,
                                       cleanData: item.cleanData, replaceBackground: true)
                }
            }
            Button("Keep My Scene Map", role: .cancel) {
                Task { @MainActor in
                    await finishImport(item.reference, from: item.cs,
                                       cleanData: item.cleanData, replaceBackground: false)
                }
            }
        } message: { _ in
            Text("This scene already has a scene map. Replace it with the map image "
                 + "from CineStager, or keep the one you have? The shot's camera is "
                 + "added to the map either way.")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Import from CineStager")
                    .font(.title2).fontWeight(.semibold)
                Spacer()
                if library.state == .loaded {
                    Button {
                        Task { await library.refresh() }
                    } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Reload the library from iCloud")
                }
            }
            Text("Shots you framed in CineStager, synced from iCloud. Select one or more to add as new shots.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if library.state == .loaded && !library.shots.isEmpty {
                Picker("Organize by", selection: $grouping) {
                    ForEach(Grouping.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 220)
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch library.state {
        case .loading:
            centered { ProgressView("Loading your CineStager library…") }
        case .unavailable:
            unavailableState
        case .loaded where library.shots.isEmpty:
            centered {
                ContentUnavailableView("No CineStager shots",
                                       systemImage: "camera.metering.unknown",
                                       description: Text("Capture shots in CineStager and they'll appear here once iCloud syncs."))
            }
        case .loaded:
            ScrollView {
                if grouping == .latest {
                    shotGrid(library.shots)
                        .padding(16)
                } else {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        ForEach(locationGroups, id: \.name) { group in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 6) {
                                    Text(group.name)
                                        .font(.headline)
                                    Text("\(group.shots.count)")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                shotGrid(group.shots)
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

    private func shotGrid(_ shots: [CineStagerShot]) -> some View {
        LazyVGrid(columns: columns, spacing: 14) {
            ForEach(shots) { cell($0) }
        }
    }

    private func cell(_ shot: CineStagerShot) -> some View {
        let isSelected = selectedIDs.contains(shot.id)
        return Button {
            if isSelected { selectedIDs.remove(shot.id) } else { selectedIDs.insert(shot.id) }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    // A fixed-aspect box defines the cell; the thumbnail fills it
                    // and is clipped to the box, so images can't overflow into
                    // neighbours.
                    Color.clear
                        .aspectRatio(4.0 / 3.0, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .overlay { CineStagerThumbnail(library: library, shot: shot) }
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.2),
                                        lineWidth: isSelected ? 2.5 : 1)
                        )

                    HStack(spacing: 4) {
                        if shot.isVideo { badge("video") }
                        if shot.hasMap { badge("map") }
                    }
                    .padding(6)

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.white, Color.accentColor)
                            .padding(6)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    }
                }

                Text(captionLine(shot))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }

    private func badge(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2).fontWeight(.semibold)
            .foregroundStyle(.white)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(.black.opacity(0.55))
            .clipShape(Capsule())
    }

    /// "32mm · FFc 5K · AR"
    private func captionLine(_ shot: CineStagerShot) -> String {
        var parts: [String] = []
        if let f = shot.focalLengthMM, f > 0 { parts.append("\(f)mm") }
        if !shot.cameraFormat.isEmpty { parts.append(shot.cameraFormat) }
        if shot.mode == "ar" { parts.append("AR") }
        return parts.isEmpty ? shot.cameraFamily : parts.joined(separator: " · ")
    }

    private var unavailableState: some View {
        centered {
            VStack(spacing: 14) {
                Image(systemName: "icloud.slash")
                    .font(.system(size: 46))
                    .foregroundStyle(.secondary)
                Text("CineStager library not connected")
                    .font(.headline)
                Text("""
                To load your AR shots, CinePlanner needs access to CineStager's iCloud container. In Xcode → the app target → Signing & Capabilities, add the iCloud capability, enable iCloud Documents, and add the container:
                """)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text(CineStagerLibrary.containerID)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .padding(8)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                Text("Also make sure you're signed into the same iCloud account as CineStager.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Try Again") { Task { await library.refresh() } }
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: 440)
        }
    }

    private func centered<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if isImporting {
                ProgressView().controlSize(.small)
                Text("Importing… downloading media from iCloud.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(addButtonTitle) { useSelected() }
                .buttonStyle(.borderedProminent)
                .disabled(selectedIDs.isEmpty || isImporting)
        }
        .padding(16)
    }

    // MARK: - Import

    private var addButtonTitle: String {
        selectedIDs.count > 1 ? "Add \(selectedIDs.count) Shots" : "Add Shot"
    }

    private func useSelected() {
        // Oldest first, so the added shots read in capture order.
        let selected = library.shots
            .filter { selectedIDs.contains($0.id) }
            .sorted { $0.timestamp < $1.timestamp }
        guard !selected.isEmpty else { return }
        isImporting = true
        if selected.count == 1 {
            importOne(selected[0])
        } else {
            importBatch(selected)
        }
    }

    /// Single-shot import — keeps the "replace the scene map?" prompt.
    private func importOne(_ cs: CineStagerShot) {
        let reference = provideReference()
        Task { @MainActor in
            await fill(reference, from: cs)
            let cleanData = cs.hasMap ? await library.data(at: library.cleanMapURL(for: cs)) : nil
            let scene = reference.shot?.scene
            let existingMap = scene?.sceneMapBackgroundData
            // Same location as the scene's current map? Then it's effectively the
            // same map (CineStager renders a fresh clean image per capture, so the
            // bytes differ) — just add the markers, no prompt.
            let newLocation = cs.locationModelName?.trimmingCharacters(in: .whitespaces)
            let otherRefsSameLocation = scene?.shots
                .flatMap { $0.references }
                .contains { $0 !== reference && $0.mapLocationModel == newLocation } ?? false
            let sameLocation = newLocation?.isEmpty == false
                && (scene?.sceneMapLocation == newLocation || otherRefsSameLocation)
            if let existingMap, let cleanData, existingMap != cleanData, !sameLocation {
                mapConflict = PendingMapImport(reference: reference, cs: cs, cleanData: cleanData)
            } else {
                await finishImport(reference, from: cs, cleanData: cleanData, replaceBackground: false)
            }
        }
    }

    /// Batch import: create a new shot for each selected CineStager shot. The
    /// scene keeps its existing map (or takes the first one if it has none) — no
    /// per-shot replace prompt, which would be tedious across many shots.
    private func importBatch(_ shots: [CineStagerShot]) {
        Task { @MainActor in
            for cs in shots {
                let reference = provideReference()
                await fill(reference, from: cs)
                let cleanData = cs.hasMap ? await library.data(at: library.cleanMapURL(for: cs)) : nil
                await populateSceneMap(for: reference, from: cs, cleanData: cleanData, replaceBackground: false)
                try? reference.modelContext?.save()
            }
            isImporting = false
            dismiss()
        }
    }

    /// Adds the shot's markers to the scene map, sets the background per the
    /// caller's choice, saves, and closes the sheet.
    private func finishImport(_ ref: ShotReference, from cs: CineStagerShot,
                              cleanData: Data?, replaceBackground: Bool) async {
        await populateSceneMap(for: ref, from: cs, cleanData: cleanData, replaceBackground: replaceBackground)
        try? ref.modelContext?.save()
        isImporting = false
        mapConflict = nil
        dismiss()
    }

    /// Populates `ref` (and its parent shot's empty camera fields) from a
    /// CineStager shot — media, top-down map, and pose/camera metadata.
    private func fill(_ ref: ShotReference, from cs: CineStagerShot) async {
        if let media = await library.data(at: library.imageURL(for: cs)) {
            if cs.isVideo {
                ref.videoData = media
                let ext = (cs.fileName as NSString).pathExtension.lowercased()
                ref.videoExtension = ext.isEmpty ? "mp4" : ext
                ref.imageData = nil
            } else {
                ref.imageData = media
                ref.videoData = nil
                ref.videoExtension = nil
            }
        }
        var mapData: Data?
        if cs.hasMap, let data = await library.data(at: library.mapURL(for: cs)) {
            mapData = data
            ref.mapData = data
            // Read the top-down map's own EXIF (location + camera physical size)
            // so its metadata card is populated, the same as a dragged-in map.
            if let m = EXIFExtractor.extractMetadata(from: data) {
                ref.mapCameraPhysicalWidth = m.cameraPhysicalWidth
                ref.mapCameraPhysicalLength = m.cameraPhysicalLength
                ref.mapLocationModel = m.locationModel
                ref.mapLocationWidth = m.locationWidth
                ref.mapLocationLength = m.locationLength
                ref.mapLocationHeight = m.locationHeight
            }
        }

        // Guess the shot size when it has none: prefer the geometric estimate
        // (camera↔mannequin distance + focal length), reliable even for mannequin
        // renders; fall back to Vision on the still photo.
        if let shot = ref.shot, !shot.hasSize {
            var size: ShotSize?
            if let focal = cs.focalLengthMM, focal > 0 {
                // Preferred: the subject distance CineStager exports directly
                // (works without a top-down map / location model).
                if let dist = cs.subjectDistanceM, dist > 0 {
                    size = ShotSizeEstimator.size(distanceM: dist, focalMM: Double(focal),
                                                  sensorHeightMM: cs.sensorHeightMM)
                } else if let mapData,   // fallback: measure it from the map's world coords
                          let markers = CineStagerMapMetadata.markers(from: mapData),
                          let camera = markers.camera {
                    size = ShotSizeEstimator.geometricEstimate(camera: camera,
                                                               mannequins: markers.mannequins,
                                                               focalMM: Double(focal),
                                                               sensorHeightMM: cs.sensorHeightMM)
                }
            }
            if size == nil, let img = ref.imageData {   // last resort: Vision on the still
                size = await Task.detached { ShotSizeEstimator.estimate(from: img) }.value
            }
            if let size, size != .none { shot.sizeName = size.rawValue }
        }

        // Guess the type (Single / Two Shot / …) from how many people the still
        // frames, when the shot has none. Best-effort; the user can override.
        if let shot = ref.shot, !shot.hasType, let img = ref.imageData {
            let type = await Task.detached { ShotTypeEstimator.estimate(from: img) }.value
            if let type, !shot.hasType { shot.typeName = type.rawValue }
        }

        ref.captureID = cs.captureID
        ref.mapCaptureID = cs.captureID          // same capture → "Matched" chip lights up
        ref.cameraFamily = cs.cameraFamily
        ref.cameraFormat = cs.cameraFormat
        ref.framelines = cs.framelines
        ref.focalLength = cs.focalLengthMM.map(Double.init)
        ref.lensPreset = cs.lensPresetName
        // CineStager pitch/roll map to CinePlanner's horizon/tilt (its fields are
        // annotated "Previously pitch"/"Previously roll").
        ref.horizon = cs.pitchDeg
        ref.tilt = cs.rollDeg
        ref.height = cs.heightCM
        ref.captureType = cs.type
        ref.dateTimeOriginal = cs.timestamp

        // Seed the parent shot's camera fields. The CineStager values lead: they
        // overwrite a field that's empty OR still holds the project default, but
        // never a value the user typed. Any field the import leaves empty then
        // falls back to the project default.
        if let shot = ref.shot {
            let project = shot.scene?.resolvedProject
            let defCamera = project?.defaultCamera ?? ""
            let defFramelines = project?.defaultFramelines ?? ""
            let defLens = project?.defaultLens ?? ""
            let csCamera = Shot.combinedCamera(cs.cameraFamily, cs.cameraFormat)
            if !csCamera.isEmpty, shot.camera.isEmpty || shot.camera == defCamera {
                shot.camera = csCamera
            }
            if let lines = cs.framelines, shot.framelines.isEmpty || shot.framelines == defFramelines {
                shot.framelines = lines
            }
            if let lens = cs.lensPresetName, shot.lensPreset.isEmpty || shot.lensPreset == defLens {
                shot.lensPreset = lens
            }
            if let focal = cs.focalLengthMM, focal > 0, shot.lensfocal == 0 {
                shot.lensfocal = focal
                shot.lensIsPrime = true
            }
            if let sensor = cs.sensorWidthMM, sensor > 0, shot.sensorWidthMM == nil {
                shot.sensorWidthMM = sensor
            }
            // Fill any field the import left empty with the project default.
            if shot.camera.isEmpty { shot.camera = defCamera }
            if shot.framelines.isEmpty { shot.framelines = defFramelines }
            if shot.lensPreset.isEmpty { shot.lensPreset = defLens }
        }
    }

    /// Populates the parent scene's top-down map: the clean location map as the
    /// background, plus a camera marker (named for this shot) and mannequin
    /// markers read from the top-down map image's embedded coordinates.
    private func populateSceneMap(for ref: ShotReference, from cs: CineStagerShot,
                                  cleanData: Data?, replaceBackground: Bool) async {
        guard let scene = ref.shot?.scene else { return }

        // Background: the marker-free location map. Set it when the scene has none,
        // or when the user chose to replace an existing one; otherwise leave the
        // scene's current map untouched.
        ref.mapCleanData = cleanData   // keep the clean map for later re-adds
        if let clean = cleanData, scene.sceneMapBackgroundData == nil || replaceBackground {
            scene.sceneMapBackgroundData = clean
            scene.sceneMapBackgroundIsSatellite = false
            // Remember which location this map is, so another shot of the same
            // location adds its markers without a replace prompt.
            let loc = cs.locationModelName?.trimmingCharacters(in: .whitespaces)
            scene.sceneMapLocation = (loc?.isEmpty == false) ? loc : nil
            // Real-world scale: CineStager renders the top-down as a *square* map
            // sized to the room's longer side, so the full map spans
            // max(width, length) metres (verified against the marker world coords).
            // The camera's physical width is exported in cm.
            let span = max(ref.mapLocationWidth ?? 0, ref.mapLocationLength ?? 0)
            scene.sceneMapMetersWide = span > 0 ? span : nil
            scene.sceneMapCameraSizeMeters = (ref.mapCameraPhysicalWidth ?? 0) > 0
                ? ref.mapCameraPhysicalWidth! / 100 : nil
        }

        // Marker coordinates live in the top-down map image's EXIF.
        guard let mapData = await library.data(at: library.mapURL(for: cs)),
              let markers = CineStagerMapMetadata.markers(from: mapData) else { return }

        var doc = SceneMapDoc.load(from: scene.sceneMapJSON)

        if let cam = markers.camera {
            var element = MapElement(kind: .camera, x: cam.u, y: cam.v)
            element.label = ref.shot?.displayNumber ?? "Cam"
            element.shotUID = ref.shot?.uid
            element.colorHex = "#FF9500"
            if let rot = cam.rotationDeg { element.rotation = rot }
            doc.elements.append(element)
        }

        // Add each mannequin, but skip ones that sit on essentially the exact spot
        // of a mannequin already on the map (the same, unmoved mannequin appearing
        // in multiple shots — CineStager exports deterministic coordinates, so an
        // unmoved mannequin repeats to 4 decimals). A mannequin that actually moved
        // between shots is a different position and gets its own marker.
        let sameSpot = 0.004   // ~0.4% of the map — "the same point", not "nearby"
        for mannequin in markers.mannequins {
            let duplicate = doc.elements.contains { element in
                element.kind == .character
                    && abs(element.x - mannequin.u) < sameSpot
                    && abs(element.y - mannequin.v) < sameSpot
            }
            guard !duplicate else { continue }
            var element = MapElement(kind: .character, x: mannequin.u, y: mannequin.v)
            element.colorHex = "#4C8DFF"
            if let rot = mannequin.rotationDeg { element.rotation = rot }
            doc.elements.append(element)
        }

        assignSceneCharacters(to: &doc, scene: scene)
        scene.sceneMapJSON = doc.jsonString
    }

    /// Best-effort: label the scene map's unlabeled mannequins with the scene's
    /// detected characters (in order), tinting each with that character's project
    /// color. Anonymous CineStager mannequins have no identity of their own, so
    /// this is a guess the user can correct via the marker's right-click menu.
    private func assignSceneCharacters(to doc: inout SceneMapDoc, scene: Scene) {
        let names = scene.sceneCharacterNames
        guard !names.isEmpty else { return }
        let projectChars = scene.project?.scriptCharacters ?? []
        func color(for name: String) -> String {
            projectChars.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.colorHex ?? "#4C8DFF"
        }
        var next = 0
        for i in doc.elements.indices
        where doc.elements[i].kind == .character && doc.elements[i].label.isEmpty {
            guard next < names.count else { break }
            doc.elements[i].label = names[next]
            doc.elements[i].colorHex = color(for: names[next])
            next += 1
        }
    }
}

// MARK: - Thumbnail

/// Loads a shot's thumbnail bytes from iCloud on demand.
private struct CineStagerThumbnail: View {
    let library: CineStagerLibrary
    let shot: CineStagerShot
    @State private var image: PlatformImage?

    var body: some View {
        Group {
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Rectangle().fill(Color.secondary.opacity(0.1))
                    ProgressView().controlSize(.small)
                }
            }
        }
        .task(id: shot.id) {
            if let data = await library.thumbnailData(for: shot), let ns = PlatformImage(data: data) {
                image = ns
            }
        }
    }
}
