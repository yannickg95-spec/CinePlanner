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

    var body: some View {
        NavigationStack {
            Group {
                if isPhone { phoneLayout } else { boardLayout }
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
                ToolbarItem(placement: .topBarLeading) { shareButton }
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
                #else
                ToolbarItem(placement: .cancellationAction) {
                    Button { addDay() } label: { Label("Add Day", systemImage: "calendar.badge.plus") }
                }
                ToolbarItem { shareButton }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { save(); dismiss() }
                }
                #endif
            }
        }
        .frame(minWidth: isPhone ? nil : 900, minHeight: isPhone ? nil : 600)
    }

    private var shareButton: some View {
        ShareLink(item: scheduleText()) {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .disabled(version.shootingDays.isEmpty)
    }

    // MARK: - Wide board (iPad / Mac)

    private var boardLayout: some View {
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
                        addDayColumnButton
                    }
                    .padding(12)
                }
            }
        }
    }

    private var scenePalette: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Scenes")
                .font(.headline)
                .padding(.horizontal, 12).padding(.vertical, 10)
            Divider()
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
                Text("\(count)")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(Circle().fill(count > 0 ? Color.accentColor : .secondary))
                    .help("Placed on \(count) day\(count == 1 ? "" : "s")")
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
                    ForEach(day.orderedEntries, id: \.uid) { entry in
                        stripRow(entry)
                            .draggable("entry:\(entry.uid)")
                            .dropDestination(for: String.self) { items, _ in
                                handleDrop(items, on: day, before: entry); return true
                            }
                    }
                    // Tail drop zone (append to the end of this day).
                    Color.clear.frame(height: 28)
                        .dropDestination(for: String.self) { items, _ in
                            handleDrop(items, on: day, before: nil); return true
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
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Day \(day.sortOrder + 1)").font(.subheadline.bold())
                TextField("Label", text: Binding(
                    get: { day.title }, set: { day.title = $0; save() }))
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Menu {
                Button { moveDay(day, by: -1) } label: { Label("Move Left", systemImage: "arrow.left") }
                    .disabled(day.sortOrder == 0)
                Button { moveDay(day, by: 1) } label: { Label("Move Right", systemImage: "arrow.right") }
                    .disabled(day.sortOrder >= version.shootingDays.count - 1)
                Divider()
                Button(role: .destructive) { deleteDay(day) } label: { Label("Delete Day", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    private func stripRow(_ entry: ScheduleEntry) -> some View {
        guard let scene = entry.scene else { return AnyView(EmptyView()) }
        return AnyView(
            HStack(spacing: 8) {
                sceneTag(scene)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Scene \(scene.sceneNumber)\(scene.suffix)")
                        .font(.subheadline.weight(.semibold)).lineLimit(1)
                    if !scene.nickname.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text(scene.nickname).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if !entry.note.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text(entry.note).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12)))
            .contentShape(Rectangle())
            .contextMenu { stripMenu(entry) }
        )
    }

    @ViewBuilder
    private func stripMenu(_ entry: ScheduleEntry) -> some View {
        Button { editNoteFor = entry; noteDraft = entry.note } label: {
            Label("Edit Note…", systemImage: "text.badge.plus")
        }
        if version.shootingDays.count > 1, let current = entry.day {
            Menu {
                ForEach(version.orderedShootingDays.filter { $0 !== current }) { d in
                    Button("Day \(d.sortOrder + 1)\(d.title.isEmpty ? "" : " · \(d.title)")") {
                        moveEntry(entry, to: d, before: nil)
                    }
                }
            } label: { Label("Move to Day", systemImage: "arrow.right.square") }
        }
        Divider()
        Button(role: .destructive) { deleteEntry(entry) } label: { Label("Remove", systemImage: "trash") }
    }

    private var addDayColumnButton: some View {
        Button { addDay() } label: {
            VStack(spacing: 6) {
                Image(systemName: "calendar.badge.plus").font(.title2)
                Text("Add Day").font(.caption)
            }
            .frame(width: 120).frame(maxHeight: .infinity)
            .foregroundStyle(.secondary)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5]))
                .foregroundStyle(Color.secondary.opacity(0.4)))
        }
        .buttonStyle(.plain)
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
            ForEach(version.orderedShootingDays) { day in
                Section {
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
                    HStack {
                        Text("Day \(day.sortOrder + 1)")
                        if !day.title.isEmpty { Text("· \(day.title)").foregroundStyle(.secondary) }
                        Spacer()
                        Menu {
                            Button { renameDayFor = day; dayTitleDraft = day.title } label: {
                                Label("Rename Day…", systemImage: "pencil")
                            }
                            Button(role: .destructive) { deleteDay(day) } label: {
                                Label("Delete Day", systemImage: "trash")
                            }
                        } label: { Image(systemName: "ellipsis.circle") }
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
        .overlay {
            if version.shootingDays.isEmpty && !version.orderedScenes.isEmpty {
                ContentUnavailableView {
                    Label("No shooting days yet", systemImage: "calendar")
                } description: {
                    Text("Tap the calendar button to add your first day.")
                }
            }
        }
        .alert("Rename Day", isPresented: Binding(get: { renameDayFor != nil }, set: { if !$0 { renameDayFor = nil } })) {
            TextField("Label", text: $dayTitleDraft)
            Button("Save") { renameDayFor?.title = dayTitleDraft; save(); renameDayFor = nil }
            Button("Cancel", role: .cancel) { renameDayFor = nil }
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
            HStack(spacing: 8) {
                sceneTag(scene)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Scene \(scene.sceneNumber)\(scene.suffix)").font(.body.weight(.medium)).lineLimit(1)
                    if !entry.note.isEmpty {
                        Text(entry.note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    } else if !scene.nickname.isEmpty {
                        Text(scene.nickname).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
            }
            .contextMenu {
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
    @State private var renameDayFor: ShootingDay?
    @State private var dayTitleDraft = ""
    @State private var editNoteFor: ScheduleEntry?
    @State private var noteDraft = ""

    // MARK: - Shared bits

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

    // MARK: - Export

    private func scheduleText() -> String {
        let df = DateFormatter(); df.dateStyle = .medium
        var lines: [String] = []
        lines.append("\(project.filmName) — Shooting Schedule")
        if !version.name.isEmpty { lines.append(version.name) }
        lines.append("")
        for day in version.orderedShootingDays {
            var header = "DAY \(day.sortOrder + 1)"
            if !day.title.isEmpty { header += " — \(day.title)" }
            if let date = day.date { header += " (\(df.string(from: date)))" }
            lines.append(header)
            let entries = day.orderedEntries
            if entries.isEmpty {
                lines.append("  (no scenes)")
            } else {
                for (i, e) in entries.enumerated() {
                    guard let s = e.scene else { continue }
                    var row = "  \(i + 1). Scene \(s.sceneNumber)\(s.suffix) — \(s.isInterior ? "INT" : "EXT") \(s.isDay ? "DAY" : "NIGHT")"
                    if !s.nickname.trimmingCharacters(in: .whitespaces).isEmpty { row += " · \(s.nickname)" }
                    let shots = s.shots.count
                    row += "  [\(shots) shot\(shots == 1 ? "" : "s")]"
                    if !e.note.trimmingCharacters(in: .whitespaces).isEmpty { row += " — \(e.note)" }
                    lines.append(row)
                }
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
