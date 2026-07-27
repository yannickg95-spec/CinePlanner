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
    let scene: Scene
    @Environment(\.dismiss) private var dismiss

    @StateObject private var library = CineStagerLibrary()
    @State private var selection: Set<UUID> = []
    @State private var isImporting = false
    @State private var importedCount = 0
    @State private var grouping: Grouping = .latest

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

    private var sceneTitle: String {
        var t = "Scene \(scene.sceneNumber)\(scene.suffix)"
        let loc = scene.nickname.trimmingCharacters(in: .whitespaces)
        if !loc.isEmpty { t += " · \(loc)" }
        return t
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
            Text("Shots you framed in CineStager, synced from iCloud. Pick the ones to add to “\(sceneTitle)”.")
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
        let isSelected = selection.contains(shot.id)
        return Button {
            if isSelected { selection.remove(shot.id) } else { selection.insert(shot.id) }
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
            } else if !selection.isEmpty {
                Text("\(selection.count) selected")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(selection.count > 1 ? "Import \(selection.count) Shots" : "Import Shot") {
                importSelected()
            }
            .buttonStyle(.borderedProminent)
            .disabled(selection.isEmpty || isImporting)
        }
        .padding(16)
    }

    // MARK: - Import

    private func importSelected() {
        isImporting = true
        let chosen = library.shots.filter { selection.contains($0.id) }
            .sorted { $0.timestamp < $1.timestamp }   // oldest first → stable shot order
        Task { @MainActor in
            var nextNumber = (scene.shots.map(\.shotNumber).max() ?? 0) + 1
            for cs in chosen {
                await importShot(cs, shotNumber: nextNumber)
                nextNumber += 1
            }
            try? scene.modelContext?.save()
            isImporting = false
            dismiss()
        }
    }

    private func importShot(_ cs: CineStagerShot, shotNumber: Int) async {
        let shot = Shot(shotNumber: shotNumber)
        shot.scene = scene
        // Shot-level camera info, mirroring how a photo import seeds these fields.
        shot.camera = cs.cameraFamily
        shot.format = cs.cameraFormat
        if let lines = cs.framelines { shot.framelines = lines }
        if let lens = cs.lensPresetName { shot.lensPreset = lens }
        if let focal = cs.focalLengthMM, focal > 0 {
            shot.lensfocal = focal
            shot.lensIsPrime = true
        }
        if let loc = cs.locationModelName, !loc.isEmpty { shot.nickname = loc }

        // The reference: media + map + pose/camera metadata.
        let ref = ShotReference(sortOrder: 0)
        ref.shot = shot
        if let media = await library.data(at: library.imageURL(for: cs)) {
            if cs.isVideo {
                ref.videoData = media
                ref.videoExtension = (cs.fileName as NSString).pathExtension.lowercased().isEmpty
                    ? "mp4" : (cs.fileName as NSString).pathExtension.lowercased()
            } else {
                ref.imageData = media
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

        shot.references.append(ref)
        scene.shots.append(shot)
        importedCount += 1
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
