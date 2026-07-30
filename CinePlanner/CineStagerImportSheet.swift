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
import AppKit

struct CineStagerImportSheet: View {
    /// Supplies the reference to fill, called only once the user confirms a
    /// choice — so picking "Add Shot from CineStager" creates the new shot only
    /// on import, not when the sheet is cancelled.
    let provideReference: () -> ShotReference
    @Environment(\.dismiss) private var dismiss

    @StateObject private var library = CineStagerLibrary()
    @State private var selectedID: UUID?
    @State private var isImporting = false
    @State private var grouping: Grouping = .latest

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
        .frame(width: 720, height: 620)
        .task { await library.refresh() }
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
            Text("Shots you framed in CineStager, synced from iCloud. Pick one to use as this reference.")
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
        let isSelected = selectedID == shot.id
        return Button {
            selectedID = isSelected ? nil : shot.id   // single-select
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
            Button("Use This Shot") { useSelected() }
                .buttonStyle(.borderedProminent)
                .disabled(selectedID == nil || isImporting)
        }
        .padding(16)
    }

    // MARK: - Import

    private func useSelected() {
        guard let cs = library.shots.first(where: { $0.id == selectedID }) else { return }
        isImporting = true
        let reference = provideReference()
        Task { @MainActor in
            await fill(reference, from: cs)
            await populateSceneMap(for: reference, from: cs)
            try? reference.modelContext?.save()
            isImporting = false
            dismiss()
        }
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
        if cs.hasMap, let mapData = await library.data(at: library.mapURL(for: cs)) {
            ref.mapData = mapData
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

        // Seed the parent shot's camera fields if empty, like a photo import does.
        if let shot = ref.shot {
            if shot.camera.isEmpty { shot.camera = cs.cameraFamily }
            if shot.format.isEmpty { shot.format = cs.cameraFormat }
            if let lines = cs.framelines, shot.framelines.isEmpty { shot.framelines = lines }
            if let lens = cs.lensPresetName, shot.lensPreset.isEmpty { shot.lensPreset = lens }
            if let focal = cs.focalLengthMM, focal > 0, shot.lensfocal == 0 {
                shot.lensfocal = focal
                shot.lensIsPrime = true
            }
        }
    }

    /// Populates the parent scene's top-down map: the clean location map as the
    /// background, plus a camera marker (named for this shot) and mannequin
    /// markers read from the top-down map image's embedded coordinates.
    private func populateSceneMap(for ref: ShotReference, from cs: CineStagerShot) async {
        guard let scene = ref.shot?.scene else { return }

        // Background: the marker-free location map (only set if the scene doesn't
        // already have one, so re-imports don't clobber a customized background).
        if scene.sceneMapBackgroundData == nil,
           let clean = await library.data(at: library.cleanMapURL(for: cs)) {
            scene.sceneMapBackgroundData = clean
        }

        // Marker coordinates live in the top-down map image's EXIF.
        guard let mapData = await library.data(at: library.mapURL(for: cs)),
              let markers = CineStagerMapMetadata.markers(from: mapData) else { return }

        var doc = SceneMapDoc.load(from: scene.sceneMapJSON)
        let hadCharacters = doc.elements.contains { $0.kind == .character }

        if let cam = markers.camera {
            var element = MapElement(kind: .camera, x: cam.u, y: cam.v)
            element.label = ref.shot?.displayNumber ?? "Cam"
            element.shotUID = ref.shot?.uid
            element.colorHex = "#FF9500"
            if let rot = cam.rotationDeg { element.rotation = rot }
            doc.elements.append(element)
        }

        // Seed the people once — mannequins are shared across a scene's shots, so
        // only the first CineStager import that has them adds them.
        if !hadCharacters {
            for (index, mannequin) in markers.mannequins.enumerated() {
                var element = MapElement(kind: .character, x: mannequin.u, y: mannequin.v)
                element.label = markers.mannequins.count > 1 ? "Mannequin \(index + 1)" : "Mannequin"
                element.colorHex = "#4C8DFF"
                if let rot = mannequin.rotationDeg { element.rotation = rot }
                doc.elements.append(element)
            }
        }

        scene.sceneMapJSON = doc.jsonString
    }
}

// MARK: - Thumbnail

/// Loads a shot's thumbnail bytes from iCloud on demand.
private struct CineStagerThumbnail: View {
    let library: CineStagerLibrary
    let shot: CineStagerShot
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
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
            if let data = await library.thumbnailData(for: shot), let ns = NSImage(data: data) {
                image = ns
            }
        }
    }
}
