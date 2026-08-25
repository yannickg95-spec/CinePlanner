//
//  ShootingScheduleView.swift
//  CinePlanner
//
//  The shooting schedule: a version's scenes arranged into shooting days, in
//  shoot order. A scene can sit on more than one day (split across days); each
//  placement is a `ScheduleEntry` strip carrying an optional note.
//
//  Wide (iPad/Mac): a board — a scene palette on the left, day columns on the
//  right, with drag-and-drop to place, reorder, and move strips. iPhone: a
//  sectioned list, reordered in edit mode with "Add scene" / "Move to day" menus.
//

import SwiftUI
import SwiftData

struct ShootingScheduleView: View {
    let project: Project
    @Bindable var version: ScriptVersion
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    private var isPhone: Bool { DeviceLayout.isPhone }

    /// Drag feedback: the strip we'd drop before, or the day whose end we'd append to.
    @State private var dropBeforeUID: String?
    @State private var dropTailDay: String?

    /// The accent insertion line shown between strips while dragging.
    private var insertionLine: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(Color.accentColor)
            .frame(height: 3)
            .padding(.horizontal, 2)
            .offset(y: -4)
    }

    /// Scenes not yet placed on any day.
    private var unscheduledScenes: [Scene] {
        version.orderedScenes.filter { scene in
            !version.shootingDays.contains { $0.entries.contains { $0.scene === scene } }
        }
    }

    /// How many days a scene is currently placed on (for the palette badge).
    private func placementCount(_ scene: Scene) -> Int {
        version.shootingDays.reduce(0) { total, day in
            total + day.entries.filter { $0.scene === scene }.count
        }
    }

    /// Scenes that are scheduled but whose strips don't cover all their shots — some
    /// shots aren't planned on any day.
    private var scenesMissingShots: [Scene] {
        version.orderedScenes.filter { scene in
            guard !scene.shots.isEmpty else { return false }
            var placed = Set<String>()
            var scheduled = false
            for day in version.shootingDays {
                for e in day.entries where e.scene === scene {
                    scheduled = true
                    for s in e.resolvedShots { placed.insert(s.uid) }
                }
            }
            return scheduled && placed.count < scene.shots.count
        }
    }

    private func sceneList(_ scenes: [Scene]) -> String {
        let nums = scenes.prefix(8).map { "\($0.sceneNumber)\($0.suffix)" }
        return nums.joined(separator: ", ") + (scenes.count > 8 ? "…" : "")
    }

    /// A warning strip listing scenes not scheduled and scenes missing shots.
    @ViewBuilder
    private var unscheduledBanner: some View {
        let none = unscheduledScenes
        let missing = scenesMissingShots
        if !none.isEmpty || !missing.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                if !none.isEmpty {
                    Label("\(none.count) scene\(none.count == 1 ? "" : "s") not scheduled: \(sceneList(none))",
                          systemImage: "exclamationmark.triangle.fill")
                }
                if !missing.isEmpty {
                    Label("\(missing.count) scene\(missing.count == 1 ? "" : "s") missing shots: \(sceneList(missing))",
                          systemImage: "exclamationmark.circle.fill")
                }
            }
            .font(.caption)
            .foregroundStyle(.orange)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12))
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isPhone { phoneLayout } else { boardLayout }
            }
            .sheet(item: $shotSelectFor) { entry in
                if let scene = entry.scene {
                    ScheduleShotPicker(entry: entry, scene: scene, onDone: save)
                }
            }
            .sheet(item: $editDayNoteFor) { day in
                NavigationStack {
                    TextEditor(text: $dayNoteDraft)
                        .font(.body)
                        .padding(10)
                        .navigationTitle("Day \(day.sortOrder + 1) Note")
                        #if os(iOS)
                        .navigationBarTitleDisplayMode(.inline)
                        #endif
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel") { editDayNoteFor = nil }
                            }
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Save") { day.notes = dayNoteDraft; save(); editDayNoteFor = nil }
                            }
                        }
                }
                .frame(minWidth: 380, minHeight: 260)
            }
            .navigationTitle("Shooting Schedule")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { save(); dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button { addDay() } label: { Label("Add Day", systemImage: "calendar.badge.plus") }
                }
                #else
                ToolbarItem(placement: .cancellationAction) {
                    Button { addDay() } label: { Label("Add Day", systemImage: "calendar.badge.plus") }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { save(); dismiss() }
                }
                #endif
            }
        }
        .frame(minWidth: isPhone ? nil : 1100, idealWidth: isPhone ? nil : 1500,
               maxWidth: isPhone ? nil : .infinity,
               minHeight: isPhone ? nil : 640, idealHeight: isPhone ? nil : 920,
               maxHeight: isPhone ? nil : .infinity)
    }

    // MARK: - Wide board (iPad / Mac)

    private var boardLayout: some View {
        VStack(spacing: 0) {
            unscheduledBanner
            HStack(spacing: 0) {
            scenePalette
                .frame(width: 240)
            Divider()
            if version.shootingDays.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(version.orderedShootingDays) { day in
                            dayColumn(day)
                        }
                    }
                    .padding(12)
                }
            }
            }
        }
    }

    private var scenePalette: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(version.orderedScenes, id: \.uid) { scene in
                        paletteRow(scene)
                            .draggable("scene:\(scene.uid)")
                    }
                }
                .padding(10)
            }
        }
        .background(Color.platformControlBackground)
    }

    private func paletteRow(_ scene: Scene) -> some View {
        HStack(spacing: 8) {
            sceneTag(scene)
            VStack(alignment: .leading, spacing: 1) {
                Text("Scene \(scene.sceneNumber)\(scene.suffix)")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if !scene.nickname.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(scene.nickname).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            let count = placementCount(scene)
            if count > 0 {
                Image(systemName: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.green)
                    .help("Scheduled — placed on \(count) day\(count == 1 ? "" : "s")")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.10)))
        .contentShape(Rectangle())
    }

    private func dayColumn(_ day: ShootingDay) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            dayHeader(day)
            Divider()
            ScrollView {
                LazyVStack(spacing: 6) {
                    dayNotesCard(day)
                    ForEach(day.orderedEntries, id: \.uid) { entry in
                        stripRow(entry)
                            .overlay(alignment: .top) {
                                if dropBeforeUID == entry.uid { insertionLine }
                            }
                            .draggable("entry:\(entry.uid)")
                            .dropDestination(for: String.self) { items, _ in
                                dropBeforeUID = nil; dropTailDay = nil
                                handleDrop(items, on: day, before: entry); return true
                            } isTargeted: { targeted in
                                if targeted { dropBeforeUID = entry.uid; dropTailDay = nil }
                                else if dropBeforeUID == entry.uid { dropBeforeUID = nil }
                            }
                    }
                    // Tail drop zone (append to the end of this day).
                    Color.clear.frame(height: 28)
                        .overlay(alignment: .top) {
                            if dropTailDay == day.uid { insertionLine }
                        }
                        .dropDestination(for: String.self) { items, _ in
                            dropBeforeUID = nil; dropTailDay = nil
                            handleDrop(items, on: day, before: nil); return true
                        } isTargeted: { targeted in
                            if targeted { dropTailDay = day.uid; dropBeforeUID = nil }
                            else if dropTailDay == day.uid { dropTailDay = nil }
                        }
                }
                .padding(8)
            }
        }
        .frame(width: 230)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.platformControlBackground))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2)))
        .dropDestination(for: String.self) { items, _ in
            handleDrop(items, on: day, before: nil); return true
        }
    }

    private func dayHeader(_ day: ShootingDay) -> some View {
        VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
            Text("Day \(day.sortOrder + 1)").font(.title3.bold())
            dayDateControl(day)
            Spacer(minLength: 0)
            Menu {
                Button { moveDay(day, by: -1) } label: { Label("Move Left", systemImage: "arrow.left") }
                    .disabled(day.sortOrder == 0)
                Button { moveDay(day, by: 1) } label: { Label("Move Right", systemImage: "arrow.right") }
                    .disabled(day.sortOrder >= version.shootingDays.count - 1)
                if day.date != nil {
                    Button { day.date = nil; save() } label: { Label("Remove Date", systemImage: "calendar.badge.minus") }
                }
                Divider()
                Button(role: .destructive) { deleteDay(day) } label: { Label("Delete Day", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        dayMeta(day)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    /// Load totals (scenes/shots) and daylight tags for a day.
    @ViewBuilder
    private func dayMeta(_ day: ShootingDay) -> some View {
        let t = ScheduleSummary.totals(for: day)
        VStack(alignment: .leading, spacing: 5) {
            Text("\(t.setups) scene\(t.setups == 1 ? "" : "s") · \(t.shots) shot\(t.shots == 1 ? "" : "s")")
                .font(.caption2).foregroundStyle(.secondary)
            if let sun = ScheduleSummary.daylightTimes(for: day) {
                FlowLayout(spacing: 5) {
                    sunTag("Sunrise", sun.sunrise, labelColor: .primary, background: Color.accentColor.opacity(0.12))
                    sunTag("Sunset", sun.sunset, labelColor: .primary, background: Color.accentColor.opacity(0.12))
                    sunTag("Golden", sun.goldenMorning, labelColor: Self.goldenTint, background: Self.goldenTint.opacity(0.16))
                    sunTag("Golden", sun.goldenEvening, labelColor: Self.goldenTint, background: Self.goldenTint.opacity(0.16))
                }
            }
        }
    }

    private static let goldenTint = Color(red: 0.80, green: 0.55, blue: 0.05)

    /// A small tinted pill with a bold label and its time(s) — mirrors the web tags.
    private func sunTag(_ label: String, _ value: String, labelColor: Color, background: Color) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.caption2.weight(.bold)).foregroundStyle(labelColor)
            Text(value).font(.caption2).foregroundStyle(.secondary)
        }
        .fixedSize()
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(Capsule().fill(background))
    }

    /// Date control for a day — a tinted calendar chip that opens a graphical picker.
    private func dayDateControl(_ day: ShootingDay) -> some View {
        DayDateChip(day: day, onChange: save)
    }

    private func stripRow(_ entry: ScheduleEntry) -> some View {
        guard let scene = entry.scene else { return AnyView(EmptyView()) }
        return AnyView(
            HStack(alignment: .top, spacing: 8) {
                sceneTag(scene)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Scene \(scene.sceneNumber)\(scene.suffix)")
                        .font(.subheadline.weight(.semibold)).lineLimit(1)
                    if !scene.nickname.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text(scene.nickname).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if entry.isPartialScene {
                        partialShotList(entry)
                    }
                    if !entry.note.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text(entry.note).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    sunWarningTag(for: entry)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12)))
            .overlay(alignment: .topTrailing) {
                if hasShotConflict(entry, duplicates: duplicatedShotUIDs) { conflictBadge(for: entry) }
            }
            .contentShape(Rectangle())
            .contextMenu { stripMenu(entry) }
        )
    }

    @ViewBuilder
    private func stripMenu(_ entry: ScheduleEntry) -> some View {
        if let scene = entry.scene, !scene.shots.isEmpty {
            Button { shotSelectFor = entry } label: {
                Label("Select Shots…", systemImage: "checklist")
            }
        }
        Button { editNoteFor = entry; noteDraft = entry.note } label: {
            Label("Edit Note…", systemImage: "text.badge.plus")
        }
        if version.shootingDays.count > 1, let current = entry.day {
            Menu {
                ForEach(version.orderedShootingDays.filter { $0 !== current }) { d in
                    Button(d.displayTitle) {
                        moveEntry(entry, to: d, before: nil)
                    }
                }
            } label: { Label("Move to Day", systemImage: "arrow.right.square") }
        }
        Divider()
        Button(role: .destructive) { deleteEntry(entry) } label: { Label("Remove", systemImage: "trash") }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "calendar").font(.largeTitle).foregroundStyle(.secondary)
            Text("No shooting days yet").font(.headline)
            Text("Add a day, then drag scenes from the left into it.")
                .font(.subheadline).foregroundStyle(.secondary)
            Button { addDay() } label: { Label("Add Day", systemImage: "calendar.badge.plus") }
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - iPhone layout

    private var phoneLayout: some View {
        List {
            if !unscheduledScenes.isEmpty || !scenesMissingShots.isEmpty {
                Section { unscheduledBanner.listRowInsets(EdgeInsets()) }
            }
            if version.shootingDays.isEmpty {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("No shooting days yet").font(.headline)
                            Text("Tap the calendar button to add your first day.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "calendar.badge.plus").foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(version.orderedShootingDays) { day in
                Section {
                    dayNotesCard(day)
                    ForEach(day.orderedEntries, id: \.uid) { entry in
                        phoneStripRow(entry)
                    }
                    .onMove { from, to in reorderEntries(in: day, from: from, to: to) }
                    .onDelete { offsets in deleteEntries(in: day, at: offsets) }

                    Menu {
                        let available = version.orderedScenes
                        if available.isEmpty {
                            Text("No scenes")
                        } else {
                            ForEach(available, id: \.uid) { scene in
                                Button {
                                    addScene(scene, to: day)
                                } label: {
                                    Text("Scene \(scene.sceneNumber)\(scene.suffix)\(scene.nickname.isEmpty ? "" : " — \(scene.nickname)")")
                                }
                            }
                        }
                    } label: {
                        Label("Add Scene", systemImage: "plus.circle")
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("Day \(day.sortOrder + 1)").font(.headline)
                            dayDateControl(day)
                            Spacer()
                            Menu {
                                if day.date != nil {
                                    Button { day.date = nil; save() } label: {
                                        Label("Remove Date", systemImage: "calendar.badge.minus")
                                    }
                                }
                                Button(role: .destructive) { deleteDay(day) } label: {
                                    Label("Delete Day", systemImage: "trash")
                                }
                            } label: { Image(systemName: "ellipsis.circle") }
                        }
                        dayMeta(day)
                    }
                }
            }

            if !unscheduledScenes.isEmpty {
                Section("Unscheduled") {
                    ForEach(unscheduledScenes, id: \.uid) { scene in
                        HStack(spacing: 8) {
                            sceneTag(scene)
                            Text("Scene \(scene.sceneNumber)\(scene.suffix)\(scene.nickname.isEmpty ? "" : " — \(scene.nickname)")")
                                .lineLimit(1)
                            Spacer()
                            if version.shootingDays.isEmpty {
                                Text("Add a day first").font(.caption).foregroundStyle(.secondary)
                            } else {
                                Menu {
                                    ForEach(version.orderedShootingDays) { d in
                                        Button("Day \(d.sortOrder + 1)") { addScene(scene, to: d) }
                                    }
                                } label: { Image(systemName: "plus.circle") }
                            }
                        }
                    }
                }
            }
        }
        .alert("Strip Note", isPresented: Binding(get: { editNoteFor != nil }, set: { if !$0 { editNoteFor = nil } })) {
            TextField("Note", text: $noteDraft)
            Button("Save") { editNoteFor?.note = noteDraft; save(); editNoteFor = nil }
            Button("Cancel", role: .cancel) { editNoteFor = nil }
        }
    }

    private func phoneStripRow(_ entry: ScheduleEntry) -> some View {
        guard let scene = entry.scene else { return AnyView(EmptyView()) }
        return AnyView(
            HStack(alignment: .top, spacing: 8) {
                sceneTag(scene)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Scene \(scene.sceneNumber)\(scene.suffix)").font(.body.weight(.medium)).lineLimit(1)
                    if !entry.note.isEmpty {
                        Text(entry.note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    } else if !scene.nickname.isEmpty {
                        Text(scene.nickname).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if entry.isPartialScene {
                        partialShotList(entry)
                    }
                    sunWarningTag(for: entry)
                }
                Spacer()
                if hasShotConflict(entry, duplicates: duplicatedShotUIDs) { conflictBadge(for: entry) }
            }
            .contextMenu {
                if !scene.shots.isEmpty {
                    Button { shotSelectFor = entry } label: { Label("Select Shots…", systemImage: "checklist") }
                }
                Button { editNoteFor = entry; noteDraft = entry.note } label: { Label("Edit Note…", systemImage: "text.badge.plus") }
                if version.shootingDays.count > 1, let current = entry.day {
                    Menu {
                        ForEach(version.orderedShootingDays.filter { $0 !== current }) { d in
                            Button("Day \(d.sortOrder + 1)") { moveEntry(entry, to: d, before: nil) }
                        }
                    } label: { Label("Move to Day", systemImage: "arrow.right.square") }
                }
            }
        )
    }

    // Alerts / editing state
    @State private var editNoteFor: ScheduleEntry?
    @State private var noteDraft = ""
    @State private var shotSelectFor: ScheduleEntry?
    @State private var editDayNoteFor: ShootingDay?
    @State private var dayNoteDraft = ""

    /// An optional note card at the top of a day's scenes. Shows the note (tap to
    /// edit) when set, otherwise a subtle "Add note" button.
    @ViewBuilder
    private func dayNotesCard(_ day: ShootingDay) -> some View {
        if !day.notes.trimmingCharacters(in: .whitespaces).isEmpty {
            Button { editDayNoteFor = day; dayNoteDraft = day.notes } label: {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "note.text").font(.caption2).foregroundStyle(.secondary)
                    Text(day.notes).font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.yellow.opacity(0.16)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button { editDayNoteFor = day; dayNoteDraft = day.notes } label: {
                    Label("Edit Note…", systemImage: "pencil")
                }
                Button(role: .destructive) { day.notes = ""; save() } label: {
                    Label("Remove Note", systemImage: "trash")
                }
            }
        } else {
            Button { editDayNoteFor = day; dayNoteDraft = "" } label: {
                Label("Add note", systemImage: "note.text.badge.plus")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Shared bits

    /// The shots this strip covers when it's a partial scene, stacked one per line —
    /// shot number plus nickname · size · type — inside the scene card.
    @ViewBuilder
    private func partialShotList(_ entry: ScheduleEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(entry.resolvedShots, id: \.uid) { shot in
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(shot.displayNumber)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.accentColor)
                        .fixedSize()
                    let line = shotLine(shot)
                    if !line.isEmpty {
                        Text(line).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
        .padding(.top, 1)
    }

    /// nickname · size · type for a shot (each part omitted when empty).
    private func shotLine(_ shot: Shot) -> String {
        var parts: [String] = []
        let nick = shot.nickname.trimmingCharacters(in: .whitespaces)
        if !nick.isEmpty { parts.append(nick) }
        if shot.hasSize { parts.append(shot.sizeShort) }
        if shot.hasType { parts.append(shot.typeShort) }
        return parts.joined(separator: " · ")
    }

    /// Shots planned on more than one strip (any day). Empty selection counts as the
    /// whole scene, so scheduling the same full scene twice flags every shot.
    private var duplicatedShotUIDs: Set<String> {
        var counts: [String: Int] = [:]
        for day in version.shootingDays {
            for entry in day.entries {
                for shot in entry.resolvedShots { counts[shot.uid, default: 0] += 1 }
            }
        }
        return Set(counts.filter { $0.value >= 2 }.keys)
    }

    /// True when any of this strip's shots is also planned on another strip.
    private func hasShotConflict(_ entry: ScheduleEntry, duplicates: Set<String>) -> Bool {
        guard !duplicates.isEmpty else { return false }
        return entry.resolvedShots.contains { duplicates.contains($0.uid) }
    }

    /// Per shot in this strip that's double-booked, which other days also carry it.
    private func conflictDetails(_ entry: ScheduleEntry) -> [(shot: String, days: [String])] {
        let dupes = duplicatedShotUIDs
        guard !dupes.isEmpty else { return [] }
        var result: [(String, [String])] = []
        for shot in entry.resolvedShots where dupes.contains(shot.uid) {
            var days: [String] = []
            for day in version.orderedShootingDays {
                for other in day.orderedEntries where other !== entry {
                    if other.resolvedShots.contains(where: { $0.uid == shot.uid }),
                       !days.contains(day.displayTitle) {
                        days.append(day.displayTitle)
                    }
                }
            }
            if !days.isEmpty { result.append((shot.displayNumber, days)) }
        }
        return result
    }

    /// The red "also planned on another day" badge — tap to see which shots and days.
    private func conflictBadge(for entry: ScheduleEntry) -> some View {
        ConflictBadgeButton(details: conflictDetails(entry))
    }

    /// The scene's sun-seeker date when it differs from this strip's shoot date, as a
    /// short label — nil when there's no date, no sun date chosen, or they match.
    private func sunMismatch(for entry: ScheduleEntry) -> String? {
        guard let scene = entry.scene, let shootDate = entry.day?.date else { return nil }
        let sun = scene.sunSettings
        guard sun.dateEpoch != nil else { return nil }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = sun.timeZone
        guard !cal.isDate(sun.date, inSameDayAs: shootDate) else { return nil }
        let f = DateFormatter(); f.timeZone = sun.timeZone; f.dateStyle = .medium
        return f.string(from: sun.date)
    }

    /// An in-card warning when this scene's sun-seeker date doesn't match the shoot
    /// date, with a one-tap fix. Empty view when they line up.
    @ViewBuilder
    private func sunWarningTag(for entry: ScheduleEntry) -> some View {
        if let sunDate = sunMismatch(for: entry) {
            let shootLabel = entry.day?.date.map {
                let f = DateFormatter(); f.dateStyle = .medium; return f.string(from: $0)
            } ?? ""
            WarningPopoverButton(
                symbol: "sun.max.trianglebadge.exclamationmark.fill",
                tint: .orange,
                title: "Sun date differs from the shoot date",
                lines: ["Sun seeker set to \(sunDate)"],
                actionTitle: "Set sun date to \(shootLabel)",
                action: { fixSunDate(for: entry) },
                inlineLabel: "Sun date off")
        }
    }

    /// Set this scene's sun-seeker date to the strip's shoot date (noon, in the
    /// scene's timezone, to avoid day-boundary drift).
    private func fixSunDate(for entry: ScheduleEntry) {
        guard let scene = entry.scene, let shootDate = entry.day?.date else { return }
        var sun = scene.sunSettings
        var cal = Calendar(identifier: .gregorian); cal.timeZone = sun.timeZone
        sun.dateEpoch = cal.startOfDay(for: shootDate).addingTimeInterval(12 * 3600).timeIntervalSince1970
        scene.sunSettings = sun
        save()
    }

    private func sceneTag(_ scene: Scene) -> some View {
        VStack(spacing: 2) {
            Text(scene.isInterior ? "INT" : "EXT").font(.caption2.bold())
            Text(scene.isDay ? "DAY" : "NGT").font(.caption2.bold())
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 5).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(scene.isDay ? Color.blue.opacity(0.8) : Color.orange.opacity(0.9)))
    }

    // MARK: - Drag-drop handling (wide board)

    /// A dropped payload is "scene:<uid>" (from the palette → new strip) or
    /// "entry:<uid>" (an existing strip being moved). `before` is the strip to
    /// insert ahead of, or nil to append.
    private func handleDrop(_ items: [String], on day: ShootingDay, before: ScheduleEntry?) {
        guard let payload = items.first else { return }
        if payload.hasPrefix("scene:") {
            let uid = String(payload.dropFirst("scene:".count))
            guard let scene = version.orderedScenes.first(where: { $0.uid == uid }) else { return }
            addScene(scene, to: day, before: before)
        } else if payload.hasPrefix("entry:") {
            let uid = String(payload.dropFirst("entry:".count))
            guard let entry = allEntries().first(where: { $0.uid == uid }) else { return }
            moveEntry(entry, to: day, before: before)
        }
    }

    private func allEntries() -> [ScheduleEntry] {
        version.shootingDays.flatMap { $0.entries }
    }

    // MARK: - Mutations

    private func addDay() {
        let day = ShootingDay(sortOrder: version.shootingDays.count)
        day.scriptVersion = version
        context.insert(day)
        version.shootingDays.append(day)
        save()
    }

    private func deleteDay(_ day: ShootingDay) {
        context.delete(day)                       // cascade removes its entries
        version.shootingDays.removeAll { $0 === day }
        renumberDays()
        save()
    }

    private func moveDay(_ day: ShootingDay, by delta: Int) {
        var days = version.orderedShootingDays
        guard let i = days.firstIndex(where: { $0 === day }) else { return }
        let j = i + delta
        guard j >= 0, j < days.count else { return }
        days.swapAt(i, j)
        for (idx, d) in days.enumerated() { d.sortOrder = idx }
        save()
    }

    private func renumberDays() {
        for (idx, d) in version.orderedShootingDays.enumerated() { d.sortOrder = idx }
    }

    private func addScene(_ scene: Scene, to day: ShootingDay, before: ScheduleEntry? = nil) {
        let entry = ScheduleEntry(scene: scene, sortOrder: day.entries.count)
        entry.day = day
        context.insert(entry)
        day.entries.append(entry)
        if let before { insert(entry, in: day, before: before) } else { reindex(day) }
        save()
    }

    private func moveEntry(_ entry: ScheduleEntry, to day: ShootingDay, before: ScheduleEntry?) {
        guard entry !== before else { return }
        let source = entry.day
        if source !== day {
            source?.entries.removeAll { $0 === entry }
            entry.day = day
            if !day.entries.contains(where: { $0 === entry }) { day.entries.append(entry) }
            if let source { reindex(source) }
        }
        insert(entry, in: day, before: before)
        save()
    }

    /// Order `entry` within `day` just before `before` (or at the end), then reindex.
    private func insert(_ entry: ScheduleEntry, in day: ShootingDay, before: ScheduleEntry?) {
        var ordered = day.orderedEntries.filter { $0 !== entry }
        if let before, let idx = ordered.firstIndex(where: { $0 === before }) {
            ordered.insert(entry, at: idx)
        } else {
            ordered.append(entry)
        }
        for (i, e) in ordered.enumerated() { e.sortOrder = i }
    }

    private func reindex(_ day: ShootingDay) {
        for (i, e) in day.orderedEntries.enumerated() { e.sortOrder = i }
    }

    private func reorderEntries(in day: ShootingDay, from: IndexSet, to: Int) {
        var ordered = day.orderedEntries
        ordered.move(fromOffsets: from, toOffset: to)
        for (i, e) in ordered.enumerated() { e.sortOrder = i }
        save()
    }

    private func deleteEntries(in day: ShootingDay, at offsets: IndexSet) {
        let ordered = day.orderedEntries
        for i in offsets { if ordered.indices.contains(i) { deleteEntry(ordered[i], save: false) } }
        reindex(day)
        save()
    }

    private func deleteEntry(_ entry: ScheduleEntry, save doSave: Bool = true) {
        entry.day?.entries.removeAll { $0 === entry }
        context.delete(entry)
        if doSave { save() }
    }

    private func save() { try? context.save() }
}

// MARK: - Day date chip

/// A tinted calendar chip showing a day's date (or "Add date"), opening a
/// graphical date picker in a popover. Reads nicer than a bare system picker.
private struct DayDateChip: View {
    @Bindable var day: ShootingDay
    var onChange: () -> Void
    @State private var showPicker = false

    private static let fmt: DateFormatter = {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("EEEdMMM"); return f
    }()

    private var hasDate: Bool { day.date != nil }

    var body: some View {
        Button { showPicker = true } label: {
            HStack(spacing: 4) {
                Image(systemName: "calendar")
                Text(day.date.map { Self.fmt.string(from: $0) } ?? "Add date")
                    .lineLimit(1)
            }
            .font(.caption)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(Color.secondary.opacity(0.12)))
            .foregroundStyle(.secondary)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPicker) {
            VStack(spacing: 10) {
                DatePicker("Shoot date",
                           selection: Binding(get: { day.date ?? Date() },
                                              set: { day.date = $0; onChange() }),
                           displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .frame(width: 300)
                if hasDate {
                    Divider()
                    Button(role: .destructive) {
                        day.date = nil; onChange(); showPicker = false
                    } label: {
                        Label("Remove Date", systemImage: "calendar.badge.minus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(14)
            .presentationCompactAdaptation(.popover)
        }
    }
}

// MARK: - Shot picker (which shots are shot on this day)

/// Lets the user choose which of a scene's shots this strip covers. All selected
/// (or none touched) means the whole scene, stored as an empty list so a strip
/// defaults to the full scene.
private struct ScheduleShotPicker: View {
    @Bindable var entry: ScheduleEntry
    let scene: Scene
    var onDone: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String>

    init(entry: ScheduleEntry, scene: Scene, onDone: @escaping () -> Void) {
        self.entry = entry
        self.scene = scene
        self.onDone = onDone
        let all = Set(scene.orderedShots.map { $0.uid })
        _selected = State(initialValue: entry.selectedShotUIDs.isEmpty ? all : Set(entry.selectedShotUIDs))
    }

    private var allUIDs: [String] { scene.orderedShots.map { $0.uid } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(scene.orderedShots, id: \.uid) { shot in
                        Button { toggle(shot.uid) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: selected.contains(shot.uid) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected.contains(shot.uid) ? Color.accentColor : .secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("Shot \(shot.displayNumber)").font(.body)
                                    let sub = shotSubtitle(shot)
                                    if !sub.isEmpty {
                                        Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    HStack {
                        Text("Shot on this day")
                        Spacer()
                        Button("All") { selected = Set(allUIDs) }
                            .font(.caption)
                            .disabled(selected.count == allUIDs.count)
                    }
                } footer: {
                    Text("Leave every shot selected to shoot the whole scene on this day.")
                }
            }
            .navigationTitle("Scene \(scene.sceneNumber)\(scene.suffix) Shots")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { commit(); dismiss() }
                }
            }
        }
        .frame(minWidth: 340, minHeight: 420)
    }

    private func shotSubtitle(_ shot: Shot) -> String {
        var parts: [String] = []
        if !shot.nickname.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(shot.nickname) }
        if shot.hasSize { parts.append(shot.sizeShort) }
        if shot.hasType { parts.append(shot.typeShort) }
        return parts.joined(separator: " · ")
    }

    private func toggle(_ uid: String) {
        if selected.contains(uid) { selected.remove(uid) } else { selected.insert(uid) }
    }

    private func commit() {
        // Whole scene (all, or accidentally none) → store empty; otherwise the
        // subset in scene order.
        if selected.isEmpty || selected.count == allUIDs.count {
            entry.selectedShotUIDs = []
        } else {
            entry.selectedShotUIDs = allUIDs.filter { selected.contains($0) }
        }
        onDone()
    }
}

// MARK: - Conflict badge

/// The red double-booking badge; tapping it opens a popover naming the clashing
/// shots and the other days they're on.
private struct ConflictBadgeButton: View {
    let details: [(shot: String, days: [String])]
    @State private var show = false

    var body: some View {
        Button { show = true } label: {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.white, .red)
                .padding(3)
        }
        .buttonStyle(.plain)
        .help("Some of these shots are also planned on another day")
        .popover(isPresented: $show) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Also planned on another day", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)
                if details.isEmpty {
                    Text("Some of these shots are scheduled on more than one day.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(details.indices, id: \.self) { i in
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text("Shot \(details[i].shot)")
                                .font(.caption.weight(.semibold))
                            Text("also on \(details[i].days.joined(separator: ", "))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(12)
            .frame(minWidth: 240, alignment: .leading)
            .presentationCompactAdaptation(.popover)
        }
    }
}

/// A small tinted warning icon that opens a popover with a title and detail lines.
private struct WarningPopoverButton: View {
    let symbol: String
    let tint: Color
    let title: String
    let lines: [String]
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var inlineLabel: String? = nil
    @State private var show = false

    var body: some View {
        Button { show = true } label: {
            if let inlineLabel {
                HStack(spacing: 3) {
                    Image(systemName: symbol)
                    Text(inlineLabel)
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(tint.opacity(0.16)))
            } else {
                Image(systemName: symbol).font(.footnote).foregroundStyle(tint)
            }
        }
        .buttonStyle(.plain)
        .help(title)
        .popover(isPresented: $show) {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(tint)
                ForEach(lines.indices, id: \.self) { i in
                    Text(lines[i]).font(.caption).foregroundStyle(.secondary)
                }
                if let actionTitle, let action {
                    Divider()
                    Button {
                        action(); show = false
                    } label: {
                        Label(actionTitle, systemImage: "calendar.badge.checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .padding(12)
            .frame(minWidth: 240, alignment: .leading)
            .presentationCompactAdaptation(.popover)
        }
    }
}

// MARK: - Flow layout

/// A minimal wrapping layout: lays subviews left-to-right, wrapping to the next
/// row when the proposed width runs out. Used for the daylight tags so they wrap
/// inside a narrow day column instead of overflowing.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(widest, maxWidth), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
                       proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
