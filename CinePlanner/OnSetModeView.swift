//
//  OnSetModeView.swift
//  CinePlanner
//
//  On-Set Mode: the shooting day made live. Not for planning — for the moments
//  between setups. Opens on today's shooting day and shows its scenes as a
//  check-off list: tap a shot when it's in the can, log takes, circle the keeper.
//  Mirrors the app's own light look (scene headers, INT/DAY tags, sun pills).
//

import SwiftUI
import SwiftData

/// Drives On-Set Mode as a top-level, full-window mode. Setting `version` shows it
/// over everything (sidebar included); clearing it returns to the editor.
@Observable
final class OnSetController {
    var version: ScriptVersion?
}

struct OnSetModeView: View {
    let version: ScriptVersion
    var onClose: () -> Void
    @Environment(\.modelContext) private var modelContext

    @State private var selectedDayUID: String?
    @State private var locked = false
    @State private var showSchedule = false
    /// Scene whose map is shown in a sheet (via the scene header's MAP tag).
    @State private var sceneForMap: Scene?

    private var project: Project? { version.episode?.project }
    private var isSeries: Bool { project?.isSeries == true }

    private var days: [ShootingDay] {
        version.shootingDays.sorted { $0.sortOrder < $1.sortOrder }
    }

    /// The day being shot: the one dated today if there is one, else the first.
    private var selectedDay: ShootingDay? {
        if let uid = selectedDayUID, let d = days.first(where: { $0.uid == uid }) { return d }
        let cal = Calendar.current
        if let today = days.first(where: { d in d.date.map { cal.isDateInToday($0) } ?? false }) { return today }
        return days.first
    }

    /// Every shot scheduled on the selected day, in shoot order.
    private var dayShots: [Shot] {
        selectedDay?.orderedEntries.flatMap { $0.resolvedShots } ?? []
    }
    private var doneCount: Int { dayShots.filter { $0.isShot }.count }
    /// uid of the next open setup — the one to highlight.
    private var nextShotUID: String? { dayShots.first { !$0.isShot }?.uid }

    var body: some View {
        ZStack {
            // Fills edge-to-edge (under the status bar); the content stays in the
            // safe area so the top bar clears the notch.
            Color.platformGroupedBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                Divider()
                if days.isEmpty {
                    emptyState
                } else {
                    ScrollView { content }
                }
            }
        }
        .sheet(isPresented: $showSchedule) {
            if let project { ShootingScheduleView(project: project, version: version) }
        }
        .sheet(item: $sceneForMap) { scene in
            SceneMapViewerSheet(scene: scene)
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { onClose() } label: {
                Label("Done", systemImage: "xmark")
                    .labelStyle(.titleAndIcon)
            }
            .fontWeight(.semibold)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Text("On Set").font(.headline)
                Text("LIVE")
                    .font(.system(size: 10, weight: .heavy)).kerning(0.6)
                    .foregroundStyle(Color.orange)
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                if project != nil {
                    Button { showSchedule = true } label: {
                        Image(systemName: "calendar")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(Color.secondary.opacity(0.12)))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Open the shooting schedule")
                }
                Button { locked.toggle() } label: {
                    Image(systemName: locked ? "lock.fill" : "lock.open")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(locked ? Color.secondary : Color.accentColor)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.secondary.opacity(0.12)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(locked ? "Plan locked — tap to allow changes" : "Editing unlocked — tap to lock the plan")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Project + episode
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(project?.filmName ?? "Shot List")
                    .font(.system(size: 22, weight: .bold))
                if isSeries, let title = version.episode?.title {
                    Text(title).font(.subheadline).foregroundStyle(.secondary)
                }
            }

            if let day = selectedDay { dayHeader(day) }
            progress

            ForEach(selectedDay?.orderedEntries ?? [], id: \.uid) { entry in
                sceneGroup(entry)
            }

            Text("Opens on today · works offline · syncs when signal returns")
                .font(.caption2).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 4)
        }
        .padding(16)
    }

    // MARK: - Day header

    @ViewBuilder
    private func dayHeader(_ day: ShootingDay) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if days.count > 1 {
                    Menu {
                        ForEach(days, id: \.uid) { d in
                            Button { selectedDayUID = d.uid } label: {
                                if d.uid == day.uid { Label(dayLabel(d), systemImage: "checkmark") }
                                else { Text(dayLabel(d)) }
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text("Day \(day.sortOrder + 1)").font(.system(size: 19, weight: .bold))
                            Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                } else {
                    Text("Day \(day.sortOrder + 1)").font(.system(size: 19, weight: .bold))
                }
                if let date = day.date {
                    Text(date.formatted(.dateTime.weekday(.wide).day().month(.wide).year()))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }

            if let sun = ScheduleSummary.daylightTimes(for: day) {
                FlowLayout(spacing: 6) {
                    sunTag("Sunrise", sun.sunrise, gold: false)
                    sunTag("Golden", sun.goldenMorning, gold: true)
                    sunTag("Golden", sun.goldenEvening, gold: true)
                    sunTag("Sunset", sun.sunset, gold: false)
                }
            }

            Rectangle().fill(Color.accentColor).frame(height: 2).clipShape(Capsule())
        }
    }

    private func dayLabel(_ d: ShootingDay) -> String {
        var s = "Day \(d.sortOrder + 1)"
        if let date = d.date { s += " · " + date.formatted(.dateTime.day().month(.abbreviated)) }
        return s
    }

    private static let goldenTint = Color(red: 0.80, green: 0.55, blue: 0.05)

    private func sunTag(_ label: String, _ value: String, gold: Bool) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.caption2.weight(.bold)).foregroundStyle(gold ? Self.goldenTint : .primary)
            Text(value).font(.caption2).foregroundStyle(.secondary)
        }
        .fixedSize()
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(gold ? Self.goldenTint.opacity(0.16) : Color.accentColor.opacity(0.12)))
    }

    // MARK: - Progress

    private var progress: some View {
        let total = dayShots.count
        let done = doneCount
        let setups = selectedDay?.orderedEntries.count ?? 0
        let setupsDone = (selectedDay?.orderedEntries ?? []).filter { entry in
            !entry.resolvedShots.isEmpty && entry.resolvedShots.allSatisfy { $0.isShot }
        }.count
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(done)").font(.system(size: 15, weight: .bold)).monospacedDigit()
                Text("of \(total) shots done").font(.subheadline).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text("\(setupsDone) / \(setups) scenes")
                    .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                    Capsule().fill(Color.accentColor)
                        .frame(width: total == 0 ? 0 : geo.size.width * CGFloat(done) / CGFloat(total))
                        .animation(.easeInOut(duration: 0.3), value: done)
                }
            }
            .frame(height: 8)
        }
    }

    // MARK: - Scene group

    @ViewBuilder
    private func sceneGroup(_ entry: ScheduleEntry) -> some View {
        if let scene = entry.scene {
            let shots = entry.resolvedShots
            let done = shots.filter { $0.isShot }.count
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Text("Scene \(scene.sceneNumber)\(scene.suffix)")
                        .font(.system(size: 17, weight: .bold))
                    tag(scene.isInterior ? "INT" : "EXT", tint: nil)
                    tag(scene.isDay ? "DAY" : "NIGHT", tint: scene.isDay ? Color.accentColor : Color.orange)
                    if !scene.nickname.isEmpty {
                        Text(scene.nickname.uppercased())
                            .font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    // A MAP tag — same size as INT/DAY — but tappable: opens the map
                    // for viewing (read-only). Sits by the shot counter on the right.
                    Button { sceneForMap = scene } label: {
                        tag("MAP", tint: Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    Text("\(done)/\(shots.count)")
                        .font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                }
                VStack(spacing: 8) {
                    ForEach(shots, id: \.uid) { shot in
                        OnSetShotRow(shot: shot, locked: locked, isNext: shot.uid == nextShotUID) { save() }
                    }
                }
            }
        }
    }

    private func tag(_ text: String, tint: Color?) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .bold)).kerning(0.3)
            .foregroundStyle(tint ?? Color.secondary)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 6).fill((tint ?? Color.secondary).opacity(0.14)))
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 40)).foregroundStyle(.secondary)
            Text("No shooting days yet").font(.headline)
            Text("Build a schedule first — arrange your scenes into shooting days, then come back here to shoot them.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func save() { try? modelContext.save() }
}

// MARK: - Shot row

private struct OnSetShotRow: View {
    @Bindable var shot: Shot
    let locked: Bool
    let isNext: Bool
    var onChange: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // Check / rolling circle
            Button { toggleDone() } label: { checkCircle }
                .buttonStyle(.plain).disabled(locked)

            Text(shot.displayNumber)
                .font(.system(size: 15, weight: .bold)).monospacedDigit()
                .padding(.horizontal, 8).padding(.vertical, 4)
                .frame(minWidth: 44)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(isNext ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.08)))
                .foregroundStyle(isNext ? Color.accentColor : Color.primary)

            infoLine

            Spacer(minLength: 6)

            if isNext {
                Text("NEXT")
                    .font(.system(size: 9.5, weight: .heavy)).kerning(0.5)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.platformTextBackground)
            .shadow(color: .black.opacity(0.06), radius: 5, y: 1))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .stroke(isNext ? Color.accentColor : Color.clear, lineWidth: 2))
        .opacity(shot.isShot ? 0.6 : 1)
        .contentShape(Rectangle())
        .onTapGesture { toggleDone() }
    }

    /// Nickname first, then the spec (same font), both on one line.
    private var infoLine: some View {
        let hasNick = !shot.nickname.trimmingCharacters(in: .whitespaces).isEmpty
        let hasSpec = !shot.shortSpec.isEmpty
        return HStack(spacing: 8) {
            if hasNick {
                Text(shot.nickname)
                    .foregroundStyle(.primary)
                    .layoutPriority(1)
            }
            if hasSpec {
                Text(shot.shortSpec)
                    .foregroundStyle(hasNick ? .secondary : .primary)
            }
            if !hasNick && !hasSpec {
                Text("—").foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 14, weight: .semibold))
        .lineLimit(1)
        .strikethrough(shot.isShot, color: .secondary.opacity(0.5))
    }

    private var checkCircle: some View {
        ZStack {
            Circle()
                .fill(shot.isShot ? Color.green : Color.clear)
                .frame(width: 26, height: 26)
            Circle()
                .stroke(shot.isShot ? Color.green : Color.secondary.opacity(0.4), lineWidth: 2)
                .frame(width: 26, height: 26)
            if shot.isShot {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
            }
        }
    }

    private func toggleDone() {
        guard !locked else { return }
        shot.isShot.toggle()
        onChange()
    }
}

// MARK: - Read-only map viewer

/// Shows a scene's map for viewing only — no editing. Reuses the static
/// `SceneMapExportView` (the same non-interactive rendering used by the web/PDF
/// export) so On-Set Mode can glance at a map without risk of changing it.
private struct SceneMapViewerSheet: View {
    let scene: Scene
    @Environment(\.dismiss) private var dismiss

    private let mapPadding: CGFloat = 16

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Scene \(scene.sceneNumber)\(scene.suffix)")
                        .font(.headline)
                    if !scene.nickname.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text(scene.nickname)
                            .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            mapArea
        }
        // Pin the window to the map's own width (+ padding) so the map is never
        // clipped, and let the height follow its content.
        .frame(width: mapSize.width + mapPadding * 2)
        .frame(minHeight: 300)
    }

    @ViewBuilder
    private var mapArea: some View {
        let doc = SceneMapDoc.load(from: scene.sceneMapJSON)
        let plan = FloorPlan.load(from: scene.sceneFloorPlanJSON)
        let background = scene.sceneMapBackgroundData.flatMap(PlatformImage.init(data:))
        let isEmpty = doc.elements.isEmpty && doc.furniture.isEmpty && plan.isEmpty && background == nil

        if isEmpty {
            ContentUnavailableView(
                "No Map",
                systemImage: "map",
                description: Text("This scene doesn't have a map yet."))
            .frame(maxWidth: .infinity, minHeight: 220)
        } else {
            SceneMapExportView(
                doc: doc, plan: plan, background: background,
                labels: cameraLabels(doc), size: mapSize,
                metersWide: scene.sceneMapMetersWide,
                cameraMeters: scene.sceneMapCameraSizeMeters,
                viewableMarkers: scene.sceneMapViewableMarkerSize)
            .frame(width: mapSize.width, height: mapSize.height)
            // View-only: kill the markers' drag gestures so nothing can be moved
            // (their onMove is a no-op, so a drag would just snap back).
            .allowsHitTesting(false)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(mapPadding)
            .frame(maxWidth: .infinity)
            .background(Color.platformGroupedBackground)
        }
    }

    /// A concrete size for the map: the largest box matching the map's aspect that
    /// fits within sensible bounds. Drives both the map frame and the window width,
    /// so the two always agree (no clipping, no dead space).
    private var mapSize: CGSize {
        let background = scene.sceneMapBackgroundData.flatMap(PlatformImage.init(data:))
        let aspect: CGFloat
        if let bg = background, bg.size.width > 0, bg.size.height > 0 {
            aspect = bg.size.width / bg.size.height
        } else {
            aspect = 1 // floor-plan / grid maps render square
        }
        let maxW: CGFloat = DeviceLayout.isPhone ? 340 : 760
        let maxH: CGFloat = DeviceLayout.isPhone ? 460 : 620
        var w = maxW
        var h = maxW / aspect
        if h > maxH { h = maxH; w = maxH * aspect }
        return CGSize(width: w.rounded(), height: h.rounded())
    }

    /// Camera markers show their shot's current number; characters stay blank —
    /// mirrors the exporter's label logic.
    private func cameraLabels(_ doc: SceneMapDoc) -> [UUID: String] {
        var labels: [UUID: String] = [:]
        for element in doc.elements where element.kind == .camera {
            if let uid = element.shotUID, let shot = scene.shots.first(where: { $0.uid == uid }) {
                labels[element.id] = shot.displayNumber
            } else if !element.label.isEmpty {
                labels[element.id] = element.label
            }
        }
        return labels
    }
}
