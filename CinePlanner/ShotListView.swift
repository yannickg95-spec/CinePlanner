//
//  ShotListView.swift
//  CinePlanner
//
//  The shot list of a scene: its shots (and coverage aliases from other scenes),
//  adding, reordering, moving and deleting them.
//

import SwiftUI
import SwiftData
import PhotosUI
import AVKit
import UniformTypeIdentifiers
import os

struct ShotListView: View {
    let scene: Scene
    /// Selection tracked by Shot.uid, stable across saves (see SceneListView).
    @Binding var selectedShots: Set<String>
    var onEditShot: ((Shot) -> Void)? = nil
    var onDeleteShots: (([Shot]) -> Void)? = nil
    @State private var showCineStagerImport = false
    @State private var isImportingShotImages = false
    #if os(iOS)
    // iPad lets the user pick the source: Files or the Photos library.
    @State private var isPresentingShotPhotos = false
    @State private var selectedShotPhotos: [PhotosPickerItem] = []
    #endif

    var sortedShots: [Shot] {
        scene.shots.sorted { $0.shotNumber < $1.shotNumber }
    }

    /// The numbering style already in use in this project (kept uniform across all
    /// shots), so a newly added shot matches instead of reverting to the default.
    private var currentNumberingStyle: ShotNumberingStyle {
        scene.shots.first?.numberingStyle
            ?? scene.project?.scenes.first(where: { !$0.shots.isEmpty })?.shots.first?.numberingStyle
            ?? .numbers
    }
    
    var body: some View {
        List(selection: $selectedShots) {
            // Shots from earlier scenes whose coverage runs into this one, shown as
            // read-only aliases at the top — they're edited in their own scene. Each
            // row notes which scene it continues from, so no section title is needed.
            let aliasShots = scene.coverageAliasShots
            if !aliasShots.isEmpty {
                Section {
                    ForEach(aliasShots, id: \.uid) { shot in
                        coverageAliasRow(shot)
                    }
                }
            }
            Section {
                ForEach(sortedShots, id: \.uid) { shot in
                NavigationLink(value: shot) {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Shot \(shot.displayNumber)")
                                .font(.title3)
                                .fontWeight(.semibold)
                                .lineLimit(1)
                            // Nickname on its own line, at the scene-name size.
                            let nickname = shot.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !nickname.isEmpty {
                                Text(nickname)
                                    .font(.headline)
                                    .fontWeight(.regular)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            // Size and type as small labels below the nickname —
                            // side by side when they fit, stacked when they don't.
                            let sizeText = sizeSummary(for: shot)
                            let typeText = typeSummary(for: shot)
                            if sizeText != nil || typeText != nil {
                                ViewThatFits(in: .horizontal) {
                                    HStack(spacing: 4) {
                                        if let sizeText { detailTag(sizeText) }
                                        if let typeText { detailTag(typeText) }
                                    }
                                    VStack(alignment: .leading, spacing: 3) {
                                        if let sizeText { detailTag(sizeText) }
                                        if let typeText { detailTag(typeText) }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        Spacer()
                    }
                }
                .draggable(shot.id.hashValue.description) {
                    // Preview shown while dragging
                    HStack(spacing: 8) {
                        Image(systemName: "camera.circle.fill")
                        Text("Shot \(shot.displayNumber)")
                            .font(.title3)
                            .fontWeight(.semibold)
                    }
                    .padding(8)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .contextMenu {
                    Button {
                        onEditShot?(shot)
                    } label: {
                        Text("Shot Numbering")
                    }
                    Button {
                        duplicateShot(shot)
                    } label: {
                        Text("Duplicate Shot")
                    }
                    Divider()
                    Button(role: .destructive) {
                        onDeleteShots?(deletionTargets(for: shot))
                    } label: {
                        Text(shotDeleteLabel(for: shot))
                    }
                }
                #if os(iOS)
                // Tight row insets so the shot card uses the full column width on iPad.
                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                #endif
            }
            .onDelete(perform: deleteShots)
            .onMove(perform: moveShots)
            }

            // Add-shot actions grouped into one neutral card: a primary "Add Shot"
            // plus the two import sources, split by dividers so it reads as a
            // single control rather than three loose pills.
            VStack(spacing: 0) {
                addSourceRow("Add Shot", systemImage: "plus.circle.fill") {
                    addShot()
                }
                Divider()
                // Bulk add: pick several photos/videos at once — each becomes its
                // own shot (EXIF + size guessed per image).
                #if os(iOS)
                // iPad: a styled dropdown to pick the source — Files or Photos.
                ChipMenu(items: [
                    ChipMenuItem(title: "Choose from Files", systemImage: "folder") {
                        isImportingShotImages = false
                        DispatchQueue.main.async { isImportingShotImages = true }
                    },
                    ChipMenuItem(title: "Choose from Photos", systemImage: "photo.on.rectangle") {
                        isPresentingShotPhotos = true
                    },
                ], width: 240) {
                    addSourceRowLabel("From Images", systemImage: "photo.on.rectangle.angled")
                }
                .fileImporter(isPresented: $isImportingShotImages,
                              allowedContentTypes: [.image, .movie, .video, .quickTimeMovie, .mpeg4Movie],
                              allowsMultipleSelection: true) { result in
                    if case .success(let urls) = result { addShotsFromMedia(urls) }
                }
                .photosPicker(isPresented: $isPresentingShotPhotos, selection: $selectedShotPhotos,
                              matching: .any(of: [.images, .videos]))
                .onChange(of: selectedShotPhotos) { _, items in
                    guard !items.isEmpty else { return }
                    let picked = items
                    selectedShotPhotos = []
                    addShotsFromPhotos(picked)
                }
                #else
                addSourceRow("From Images", systemImage: "photo.on.rectangle.angled") {
                    isImportingShotImages = false
                    DispatchQueue.main.async { isImportingShotImages = true }
                }
                .fileImporter(isPresented: $isImportingShotImages,
                              allowedContentTypes: [.image, .movie, .video, .quickTimeMovie, .mpeg4Movie],
                              allowsMultipleSelection: true) { result in
                    if case .success(let urls) = result { addShotsFromMedia(urls) }
                }
                #endif
                Divider()
                // Add a shot straight from a CineStager AR capture.
                addSourceRow("From CineStager", assetImage: "CineStagerLogo") {
                    showCineStagerImport = true
                }
            }
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
            )
            .padding(.vertical, 4)
            .listRowSeparator(.hidden)
        }
        #if os(iOS)
        // Plain style + tight insets let the shot cards span the full column width
        // on iPad (the default grouped style insets them with side margins).
        .listStyle(.plain)
        // iPad/Mac: the shots column carries the film-name title. On iPhone the
        // pushed scene screen owns the title ("Scene X"), so don't override it.
        .applyIf(!DeviceLayout.isPhone) { $0.navigationTitle(scene.project?.filmName ?? "") }
        #endif
        .sheet(isPresented: $showCineStagerImport) {
            CineStagerImportSheet(provideReference: { makeImportedShotReference() })
        }
        #if os(macOS)
        .onDeleteCommand {
            if !selectedShots.isEmpty {
                onDeleteShots?(sortedShots.filter { selectedShots.contains($0.uid) })
            }
        }
        #endif
    }

    /// Shots a delete action should affect: the whole selection when the
    /// right-clicked shot is part of it, otherwise just that shot.
    private func deletionTargets(for shot: Shot) -> [Shot] {
        selectedShots.contains(shot.uid) ? sortedShots.filter { selectedShots.contains($0.uid) } : [shot]
    }

    private func shotDeleteLabel(for shot: Shot) -> String {
        let count = deletionTargets(for: shot).count
        return count > 1 ? "Delete \(count) Shots" : "Delete Shot"
    }

    /// "WS → MS" — the shot's size (with a second size when set), or nil.
    private func sizeSummary(for shot: Shot) -> String? {
        guard shot.hasSize else { return nil }
        var size = shot.sizeShort
        if shot.hasSecondSize { size += " → " + shot.secondSizeShort }
        return size
    }

    /// A small label chip for a shot detail, matching the scene rows' tag style.
    private func detailTag(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    /// A read-only alias row: a shot from another scene whose coverage runs into
    /// this one. Dimmed and non-interactive — it's edited in its own scene.
    @ViewBuilder
    private func coverageAliasRow(_ shot: Shot) -> some View {
        let sizeText = sizeSummary(for: shot)
        let typeText = typeSummary(for: shot)
        let nickname = shot.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Shot \(shot.displayNumber)")
                    .font(.title3).fontWeight(.semibold).lineLimit(1)
                // Nickname sits where a normal row has it — between number and labels.
                if !nickname.isEmpty {
                    Text(nickname)
                        .font(.headline).fontWeight(.regular).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if sizeText != nil || typeText != nil {
                    HStack(spacing: 4) {
                        if let sizeText { detailTag(sizeText) }
                        if let typeText { detailTag(typeText) }
                    }
                }
                // The "continues from" note goes under the labels.
                if let home = shot.scene {
                    Text("continues from Scene \(home.sceneNumber)\(home.suffix)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .opacity(0.7)
        .selectionDisabled()
        #if os(iOS)
        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
        #endif
    }

    /// The shot's type for the row subtitle — "Static", or "Static + Handheld"
    /// when a shot combines several. Matches how the exports read.
    private func typeSummary(for shot: Shot) -> String? {
        guard shot.hasType else { return nil }
        var text = shot.typeShort
        if shot.hasSecondType { text += " + " + shot.secondTypeShort }
        if shot.hasThirdType { text += " + " + shot.thirdTypeShort }
        return text
    }

    /// One row of the grouped add-shot card: leading icon (SF Symbol or asset),
    /// title, full-width tap target — styled neutrally so the three read as one
    /// control.
    private func addSourceRow(_ title: String,
                              systemImage: String? = nil,
                              assetImage: String? = nil,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            addSourceRowLabel(title, systemImage: systemImage, assetImage: assetImage)
        }
        .buttonStyle(.plain)
    }

    private func addSourceRowLabel(_ title: String,
                                  systemImage: String? = nil,
                                  assetImage: String? = nil) -> some View {
        HStack(spacing: 8) {
            if let assetImage {
                Image(assetImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 15, height: 15)
            } else if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
            }
            Text(title)
                .fontWeight(.medium)
            Spacer(minLength: 0)
        }
        .font(.subheadline)
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// Fill a shot's camera package from the project default — but only fields that
    /// are still empty, so it works both as the seed for a manual shot and as a
    /// gap-filling fallback after an import (which always leads).
    private func applyCameraDefaults(to shot: Shot) {
        guard let project = scene.resolvedProject else { return }
        if shot.camera.isEmpty { shot.camera = project.defaultCamera }
        if shot.framelines.isEmpty { shot.framelines = project.defaultFramelines }
        if shot.lensPreset.isEmpty { shot.lensPreset = project.defaultLens }
        // A new shot inherits the scene-wide film tool, if one is set.
        scene.applyFilmTool(to: shot, context: scene.modelContext)
    }

    private func addShot() {
        // Find the next shot number
        let nextNumber = (sortedShots.last?.shotNumber ?? 0) + 1
        let newShot = Shot(shotNumber: nextNumber)
        newShot.scene = scene
        newShot.numberingStyle = currentNumberingStyle
        applyCameraDefaults(to: newShot)
        scene.shots.append(newShot)
        // Start the shot with one empty reference so its card is open and ready
        // for media, rather than only an "Add Reference" button.
        let reference = ShotReference(sortOrder: 0)
        reference.shot = newShot
        newShot.references.append(reference)
        // Persist now so the new shot — and, on a brand-new project, its new
        // scene — get permanent ids and a settled relationship before the detail
        // pane resolves the selection. Otherwise the very first shot can't be
        // opened until the scene is reselected.
        scene.modelContext?.saveReporting()
        selectedShots = [newShot.uid]
    }

    /// Bulk-adds one shot per picked media file, each with the photo/video as its
    /// first reference (EXIF and a Vision size guess filled per image), mirroring
    /// the multi-select CineStager import. Selects the new shots.
    private func addShotsFromMedia(_ urls: [URL]) {
        var nextNumber = (sortedShots.last?.shotNumber ?? 0) + 1
        var created: [Shot] = []
        for url in urls {
            let newShot = Shot(shotNumber: nextNumber)
            nextNumber += 1
            newShot.scene = scene
            newShot.numberingStyle = currentNumberingStyle
            scene.shots.append(newShot)
            let reference = ShotReference(sortOrder: 0)
            reference.shot = newShot
            newShot.references.append(reference)
            ReferenceMediaLoader.load(mediaAt: url, into: reference)
            // The import (EXIF / Cadrage) leads; the project default only fills
            // fields the import left empty.
            applyCameraDefaults(to: newShot)
            created.append(newShot)
        }
        guard !created.isEmpty else { return }
        scene.modelContext?.saveReporting()
        selectedShots = Set(created.map { $0.uid })
    }

    #if os(iOS)
    /// Bulk add from the Photos library: writes each picked item to a temporary
    /// file so it can reuse the same URL-based media loader as the Files path
    /// (which reads EXIF and guesses size/type), then cleans the temp files up.
    private func addShotsFromPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        Task { @MainActor in
            var urls: [URL] = []
            for item in items {
                guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(ext)
                if (try? data.write(to: url)) != nil { urls.append(url) }
            }
            addShotsFromMedia(urls)
            for url in urls { try? FileManager.default.removeItem(at: url) }
        }
    }
    #endif

    /// Creates a new shot with one empty reference, selects it, and returns that
    /// reference for the CineStager import sheet to fill. Called only when the
    /// user confirms a capture, so cancelling leaves no empty shot behind.
    private func makeImportedShotReference() -> ShotReference {
        let nextNumber = (sortedShots.last?.shotNumber ?? 0) + 1
        let newShot = Shot(shotNumber: nextNumber)
        newShot.scene = scene
        newShot.numberingStyle = currentNumberingStyle
        // No project-camera default here: the CineStager import fills the camera
        // fields (and only falls back to the project default for gaps), so the
        // imported values always lead.
        scene.shots.append(newShot)
        // An imported shot inherits the scene-wide film tool, like any new shot.
        scene.applyFilmTool(to: newShot, context: scene.modelContext)
        let reference = ShotReference(sortOrder: 0)
        reference.shot = newShot
        newShot.references.append(reference)
        scene.modelContext?.saveReporting()
        selectedShots = [newShot.uid]
        return reference
    }

    private func deleteShots(at offsets: IndexSet) {
        let shotsToDelete = offsets.map { sortedShots[$0] }
        for shot in shotsToDelete {
            scene.forgetShot(uid: shot.uid)
            if let index = scene.shots.firstIndex(where: { $0 === shot }) {
                scene.shots.remove(at: index)
            }
        }
        selectedShots.subtract(shotsToDelete.map(\.uid))

        // Renumber all remaining shots
        renumberShots()
    }
    
    private func renumberShots() {
        let shots = scene.shots.sorted { $0.shotNumber < $1.shotNumber }
        for (index, shot) in shots.enumerated() {
            shot.shotNumber = index + 1
        }
    }

    /// Duplicates a shot (all its fields, references and custom info, with fresh
    /// ids) and drops the copy right after the original, renumbering the scene.
    private func duplicateShot(_ shot: Shot) {
        let copy = shot.duplicate()
        copy.scene = scene
        scene.shots.append(copy)
        var ordered = scene.shots.sorted { $0.shotNumber < $1.shotNumber }
        ordered.removeAll { $0 === copy }
        if let index = ordered.firstIndex(where: { $0 === shot }) {
            ordered.insert(copy, at: index + 1)
        } else {
            ordered.append(copy)
        }
        for (index, s) in ordered.enumerated() { s.shotNumber = index + 1 }
        scene.modelContext?.saveReporting()
        selectedShots = [copy.uid]
    }
    
    private func moveShots(from source: IndexSet, to destination: Int) {
        var revisedShots = sortedShots
        revisedShots.move(fromOffsets: source, toOffset: destination)
        
        // Update shot numbers based on new order
        for (index, shot) in revisedShots.enumerated() {
            shot.shotNumber = index + 1
        }
    }
}
