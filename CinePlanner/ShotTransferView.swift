//
//  ShotTransferView.swift
//  CinePlanner
//
//  Transfers planned shots between script versions: matches the scenes of an
//  older script version to the scenes of a newly imported one and copies the
//  shots across.

import SwiftUI
import SwiftData

// MARK: - Scene Matching

enum SceneMatcher {

    /// Normalized word tokens of a scene's location name, for fuzzy comparison.
    /// Diacritics are folded so "CAFÉ" and "CAFE" compare equal across versions.
    static func locationTokens(_ name: String) -> Set<String> {
        let cleaned = name
            .folding(options: [.diacriticInsensitive], locale: nil)
            .uppercased()
        let words = cleaned.components(separatedBy: CharacterSet.alphanumerics.inverted)
        return Set(words.filter { $0.count > 1 })
    }

    /// Similarity score between a scene of the old version and one of the new.
    /// Scene number identity and location-name overlap dominate; INT/EXT and
    /// day/night agreement are small tie-breakers.
    static func score(source: Scene, target: Scene) -> Double {
        var score = 0.0

        if source.sceneNumber == target.sceneNumber {
            score += source.suffix == target.suffix ? 2.0 : 1.0
        }

        let a = locationTokens(source.nickname)
        let b = locationTokens(target.nickname)
        if !a.isEmpty && !b.isEmpty {
            let overlap = Double(a.intersection(b).count)
            let union = Double(a.union(b).count)
            score += 2.5 * (overlap / union)
        }

        if source.isInterior == target.isInterior { score += 0.25 }
        if source.isDay == target.isDay { score += 0.25 }
        return score
    }

    /// Greedy one-to-one matching, best-scoring pairs first. Pairs must reach
    /// `threshold` to be matched at all, so unrelated scenes stay unmatched.
    static func autoMatch(sources: [Scene], targets: [Scene], threshold: Double = 1.5) -> [Scene: Scene] {
        var candidates: [(score: Double, source: Scene, target: Scene)] = []
        for target in targets {
            for source in sources {
                let s = score(source: source, target: target)
                if s >= threshold {
                    candidates.append((s, source, target))
                }
            }
        }
        candidates.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            // Tie-break: prefer pairs that sit at similar positions in the script
            return abs(lhs.source.sortOrder - lhs.target.sortOrder) < abs(rhs.source.sortOrder - rhs.target.sortOrder)
        }

        var usedSources = Set<Scene>()
        var usedTargets = Set<Scene>()
        var result: [Scene: Scene] = [:] // target → source
        for candidate in candidates {
            if usedSources.contains(candidate.source) || usedTargets.contains(candidate.target) { continue }
            result[candidate.target] = candidate.source
            usedSources.insert(candidate.source)
            usedTargets.insert(candidate.target)
        }
        return result
    }

    /// Copies all shots of `source` into `target` (appended after any existing
    /// shots) and returns how many were copied. Coverage selections are not
    /// copied — they reference the source version's PDF pages.
    @discardableResult
    static func copyShots(from source: Scene, to target: Scene) -> Int {
        let sourceShots = source.shots.sorted { $0.shotNumber < $1.shotNumber }
        guard !sourceShots.isEmpty else { return 0 }

        var nextNumber = target.shots.map(\.shotNumber).max() ?? 0
        for shot in sourceShots {
            nextNumber += 1
            let copy = shot.duplicate()
            copy.shotNumber = nextNumber
            copy.scene = target
            target.shots.append(copy)
        }
        return sourceShots.count
    }

    static func displayName(_ scene: Scene) -> String {
        let name = scene.nickname.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Untitled" : name
    }
}

// MARK: - Transfer Window

/// The transfer window: scenes of a selectable older script version on the
/// left, scenes of the (new) target version on the right. Matches are
/// pre-assigned automatically and can be corrected per scene before copying.
struct ShotTransferView: View {
    @Environment(\.dismiss) private var dismiss
    let project: Project
    let targetVersion: ScriptVersion

    @State private var sourceVersion: ScriptVersion?
    // Keyed by persistent IDs (target → source), not Scene objects: SwiftData can
    // hand back re-faulted Scene instances on re-render, which would make an
    // object-keyed dictionary silently miss and the matches appear to vanish.
    @State private var assignments: [PersistentIdentifier: PersistentIdentifier] = [:]

    init(project: Project, targetVersion: ScriptVersion) {
        self.project = project
        self.targetVersion = targetVersion

        // Resolve the default source version and pre-compute the auto-match here,
        // so the matches are already filled in on the very first render (relying on
        // onAppear left a window where the list rendered empty).
        let candidates = (targetVersion.episode?.orderedVersions ?? [])
            .filter { $0 !== targetVersion && !$0.scenes.isEmpty }
        let initialSource = candidates.last(where: { $0.totalShotCount > 0 }) ?? candidates.last
        _sourceVersion = State(initialValue: initialSource)
        _assignments = State(initialValue: Self.autoMatchIDs(from: initialSource, targets: targetVersion.orderedScenes))
    }

    private var sourceCandidates: [ScriptVersion] {
        (targetVersion.episode?.orderedVersions ?? []).filter { $0 !== targetVersion && !$0.scenes.isEmpty }
    }

    private var sourceScenes: [Scene] { sourceVersion?.orderedScenes ?? [] }
    private var targetScenes: [Scene] { targetVersion.orderedScenes }

    private var sourceScenesByID: [PersistentIdentifier: Scene] {
        Dictionary(sourceScenes.map { ($0.persistentModelID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The source scene currently assigned to a target scene, if any.
    private func sourceScene(for target: Scene) -> Scene? {
        guard let sourceID = assignments[target.persistentModelID] else { return nil }
        return sourceScenesByID[sourceID]
    }

    private var shotsToCopy: Int {
        targetScenes.reduce(0) { $0 + (sourceScene(for: $1)?.shots.count ?? 0) }
    }

    private var scenesToCopy: Int {
        targetScenes.filter { !(sourceScene(for: $0)?.shots.isEmpty ?? true) }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 10) {
                Text("Copy Shots from a Previous Script Version")
                    .font(.title2)
                    .fontWeight(.semibold)

                HStack(spacing: 8) {
                    Text("Copy from:")
                        .foregroundStyle(.secondary)
                    Picker("Copy from", selection: $sourceVersion) {
                        ForEach(sourceCandidates, id: \.persistentModelID) { version in
                            Text("\(version.name) (\(version.totalShotCount) shots)")
                                .tag(version as ScriptVersion?)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 260)

                    Spacer()

                    Text("Matched scenes are pre-filled — adjust any match on the right before copying.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)

            Divider()

            // Two columns: source scenes left, target scenes right
            HStack(spacing: 0) {
                sourceColumn
                    .frame(maxWidth: .infinity)
                Divider()
                targetColumn
                    .frame(maxWidth: .infinity)
            }

            Divider()

            // Footer
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(shotsToCopy) shot\(shotsToCopy == 1 ? "" : "s") will be copied into \(scenesToCopy) scene\(scenesToCopy == 1 ? "" : "s").")
                        .font(.subheadline)
                    Text("Script coverage selections are not copied — they belong to the old script's pages.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button("Copy Shots") { performCopy() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(shotsToCopy == 0)
            }
            .padding(16)
        }
        .frame(width: 980, height: 640)
        // Initial source + matches are set in init(); this only re-matches when the
        // user picks a different source version.
        .onChange(of: sourceVersion) { _, newValue in
            autoMatch(from: newValue)
        }
    }

    // MARK: Columns

    private var sourceColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(sourceVersion.map { "Scenes in \($0.name)" } ?? "No source version")
                .font(.headline)
                .padding(12)

            Divider()

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(sourceScenes, id: \.persistentModelID) { scene in
                        sourceRow(scene)
                    }
                }
                .padding(10)
            }
        }
    }

    @ViewBuilder
    private func sourceRow(_ scene: Scene) -> some View {
        let isAssigned = assignments.values.contains(scene.persistentModelID)
        HStack(spacing: 8) {
            sceneBadge(scene)
            Text(SceneMatcher.displayName(scene))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if scene.shots.isEmpty {
                Text("no shots")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Text("\(scene.shots.count) shot\(scene.shots.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Image(systemName: isAssigned ? "arrow.right.circle.fill" : "circle.dotted")
                .foregroundStyle(isAssigned ? Color.accentColor : Color.secondary.opacity(0.5))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isAssigned ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .opacity(scene.shots.isEmpty ? 0.6 : 1)
    }

    private var targetColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Scenes in \(targetVersion.name) (new)")
                .font(.headline)
                .padding(12)

            Divider()

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(targetScenes, id: \.persistentModelID) { scene in
                        targetRow(scene)
                    }
                }
                .padding(10)
            }
        }
    }

    @ViewBuilder
    private func targetRow(_ target: Scene) -> some View {
        let source = sourceScene(for: target)
        HStack(spacing: 8) {
            sceneBadge(target)
            Text(SceneMatcher.displayName(target))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            Menu {
                Button("Don't copy") {
                    assignments[target.persistentModelID] = nil
                }
                Divider()
                ForEach(sourceScenes.filter { !$0.shots.isEmpty }, id: \.persistentModelID) { candidate in
                    Button {
                        assign(candidate, to: target)
                    } label: {
                        Text("Scene \(candidate.sceneNumber)\(candidate.suffix) — \(SceneMatcher.displayName(candidate)) (\(candidate.shots.count) shot\(candidate.shots.count == 1 ? "" : "s"))")
                    }
                }
            } label: {
                if let source {
                    Label(
                        "Scene \(source.sceneNumber)\(source.suffix) (\(source.shots.count) shot\(source.shots.count == 1 ? "" : "s"))",
                        systemImage: "arrow.left"
                    )
                    .foregroundStyle(source.shots.isEmpty ? Color.secondary : Color.accentColor)
                } else {
                    Label("No match", systemImage: "minus.circle")
                        .foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background((source != nil && !(source?.shots.isEmpty ?? true)) ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func sceneBadge(_ scene: Scene) -> some View {
        HStack(spacing: 4) {
            Text("Scene \(scene.sceneNumber)\(scene.suffix)")
                .font(.subheadline)
                .fontWeight(.semibold)
                .fixedSize()
            Text(scene.isInterior ? "INT" : "EXT")
                .font(.caption2)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.secondary.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
    }

    // MARK: Actions

    /// Auto-match source scenes to target scenes, returned as a persistent-ID map.
    private static func autoMatchIDs(from source: ScriptVersion?, targets: [Scene]) -> [PersistentIdentifier: PersistentIdentifier] {
        let match = SceneMatcher.autoMatch(sources: source?.orderedScenes ?? [], targets: targets)
        return Dictionary(
            match.map { ($0.key.persistentModelID, $0.value.persistentModelID) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private func autoMatch(from source: ScriptVersion?) {
        assignments = Self.autoMatchIDs(from: source, targets: targetScenes)
    }

    /// Assigns a source scene to a target, keeping the mapping one-to-one.
    private func assign(_ source: Scene, to target: Scene) {
        let sourceID = source.persistentModelID
        let targetID = target.persistentModelID
        // Drop any other target already pointing at this source.
        for (existingTarget, existingSource) in assignments where existingSource == sourceID && existingTarget != targetID {
            assignments[existingTarget] = nil
        }
        assignments[targetID] = sourceID
    }

    private func performCopy() {
        for target in targetScenes {
            guard let source = sourceScene(for: target), !source.shots.isEmpty else { continue }
            SceneMatcher.copyShots(from: source, to: target)
        }
        dismiss()
    }
}

// MARK: - Single Scene Import

/// Manual per-scene transfer: copies the shots of one scene from another
/// script version into the currently selected scene.
struct SingleSceneShotImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let project: Project
    let targetScene: Scene

    @State private var sourceVersion: ScriptVersion?
    // Keyed by persistent ID for stability across SwiftData re-faults (see ShotTransferView).
    @State private var selectedSourceID: PersistentIdentifier?

    private var sourceCandidates: [ScriptVersion] {
        (targetScene.scriptVersion?.episode?.orderedVersions ?? [])
            .filter { $0 !== targetScene.scriptVersion && $0.totalShotCount > 0 }
    }

    private var sourceScenes: [Scene] {
        (sourceVersion?.orderedScenes ?? []).filter { !$0.shots.isEmpty }
    }

    private var selectedSourceScene: Scene? {
        sourceScenes.first { $0.persistentModelID == selectedSourceID }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Import Shots from a Different Script Version")
                    .font(.title3)
                    .fontWeight(.semibold)

                Text("Copies the shots of the chosen scene into Scene \(targetScene.sceneNumber)\(targetScene.suffix) — \(SceneMatcher.displayName(targetScene)).")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Text("From version:")
                        .foregroundStyle(.secondary)
                    Picker("From version", selection: $sourceVersion) {
                        ForEach(sourceCandidates, id: \.persistentModelID) { version in
                            Text("\(version.name) (\(version.totalShotCount) shots)")
                                .tag(version as ScriptVersion?)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 240)
                    Spacer()
                }
            }
            .padding(16)

            Divider()

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(sourceScenes, id: \.persistentModelID) { scene in
                        let isSelected = scene.persistentModelID == selectedSourceID
                        Button {
                            selectedSourceID = scene.persistentModelID
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                                Text("Scene \(scene.sceneNumber)\(scene.suffix)")
                                    .fontWeight(.semibold)
                                    .fixedSize()
                                Text(SceneMatcher.displayName(scene))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: 4)
                                Text("\(scene.shots.count) shot\(scene.shots.count == 1 ? "" : "s")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(isSelected ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .contentShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(10)
            }

            Divider()

            HStack {
                Text("Script coverage selections are not copied.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(copyButtonTitle) {
                    if let source = selectedSourceScene {
                        SceneMatcher.copyShots(from: source, to: targetScene)
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selectedSourceScene == nil)
            }
            .padding(16)
        }
        .frame(width: 560, height: 520)
        .onAppear {
            let resolved = sourceVersion ?? sourceCandidates.last
            sourceVersion = resolved
            preselectBestMatch(in: resolved)
        }
        .onChange(of: sourceVersion) { _, newValue in
            preselectBestMatch(in: newValue)
        }
    }

    private var copyButtonTitle: String {
        if let source = selectedSourceScene {
            return "Copy \(source.shots.count) Shot\(source.shots.count == 1 ? "" : "s")"
        }
        return "Copy Shots"
    }

    /// Preselects the source scene that best matches the target scene.
    private func preselectBestMatch(in source: ScriptVersion?) {
        let candidates = (source?.orderedScenes ?? []).filter { !$0.shots.isEmpty }
        let best = candidates
            .map { (scene: $0, score: SceneMatcher.score(source: $0, target: targetScene)) }
            .filter { $0.score >= 1.5 }
            .max { $0.score < $1.score }
        selectedSourceID = best?.scene.persistentModelID
    }
}
