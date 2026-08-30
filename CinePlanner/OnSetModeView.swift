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
    #if os(iOS)
    /// Drives the Live Activity Start/Stop control.
    @State private var live = OnSetLiveActivityController.shared
    #endif

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
            // macOS: the title bar is hidden here, so let the top row ride up into
            // that space instead of leaving a gap. iOS keeps the safe area so the
            // top bar clears the notch/status bar.
            #if os(macOS)
            .ignoresSafeArea(.container, edges: .top)
            #endif
        }
        .sheet(isPresented: $showSchedule) {
            if let project { ShootingScheduleView(project: project, version: version) }
        }
        .sheet(item: $sceneForMap) { scene in
            SceneMapViewerSheet(scene: scene)
        }
        #if os(iOS)
        // Starting/stopping the Live Activity is explicit (the broadcast button in
        // the top bar). Here we just adopt an already-running one so the control
        // reflects it, and keep a running activity pointed at the viewed day.
        .onAppear { live.reconnect(versionUID: version.uid) }
        .onChange(of: selectedDayUID) { _, _ in if let day = selectedDay { live.setDay(day) } }
        #endif
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { onClose() } label: {
                Label("Done", systemImage: "xmark")
                    .labelStyle(.iconOnly)
            }
            .fontWeight(.semibold)
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                #if os(iOS)
                // Start/Stop the Lock Screen + Dynamic Island Live Activity for the
                // day currently shown. Hidden where Live Activities aren't available
                // (iPad, or turned off for the app).
                if live.isAvailable {
                    Button { toggleLive() } label: {
                        Image(systemName: live.isRunning ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(live.isRunning ? Color.red : Color.secondary)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(live.isRunning ? Color.red.opacity(0.14) : Color.secondary.opacity(0.12)))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedDay == nil)
                    .help(live.isRunning ? "Stop the Live Activity" : "Show this day on the Lock Screen (Live Activity)")
                }
                #endif
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
            }
        }
        // Centered as an overlay so "On Set" sits at the true horizontal middle,
        // independent of the differing widths of the leading/trailing controls.
        .overlay {
            Text("On Set").font(.headline)
                .allowsHitTesting(false)
        }
        .padding(.horizontal, 16)
        #if os(macOS)
        // The title bar is hidden and content rides to the top, so add a little top
        // breathing room; the traffic lights are hidden here, so no leading inset.
        .padding(.top, 12)
        .padding(.bottom, 10)
        #else
        .padding(.vertical, 10)
        #endif
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

    private func save() {
        try? modelContext.save()
        #if os(iOS)
        OnSetLiveActivityController.shared.update()
        #endif
    }

    #if os(iOS)
    private func toggleLive() {
        if live.isRunning {
            live.end()
        } else if let day = selectedDay {
            live.start(version: version, day: day)
        }
    }
    #endif
}

// MARK: - Shot row

private struct OnSetShotRow: View {
    @Bindable var shot: Shot
    let locked: Bool
    let isNext: Bool
    var onChange: () -> Void

    /// Presents the framing reference in a popup viewer.
    @State private var showFramingSheet = false

    var body: some View {
        Group {
            if isNext {
                expandedCard
            } else {
                compactRow
            }
        }
        .sheet(isPresented: $showFramingSheet) {
            if let framing = framingImage {
                FramingViewerSheet(image: framing, title: "Shot \(shot.displayNumber)")
            }
        }
    }

    /// A tappable REF pill — same look as the scene header's MAP pill — shown when
    /// the shot has a reference still; opens it in the popup viewer.
    @ViewBuilder
    private var refPill: some View {
        if framingImage != nil {
            Button { showFramingSheet = true } label: {
                Text("REF")
                    .font(.system(size: 10.5, weight: .bold)).kerning(0.3)
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.14)))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Compact row — every shot except the one being shot now.

    private var compactRow: some View {
        HStack(spacing: 10) {
            Button { toggleDone() } label: { checkCircle }
                .buttonStyle(.plain).disabled(locked)

            Text(shot.displayNumber)
                .font(.system(size: 15, weight: .bold)).monospacedDigit()
                .padding(.horizontal, 8).padding(.vertical, 4)
                .frame(minWidth: 44)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
                .foregroundStyle(Color.primary)

            infoLine

            Spacer(minLength: 6)

            refPill
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.platformTextBackground)
            .shadow(color: .black.opacity(0.06), radius: 5, y: 1))
        .opacity(shot.isShot ? 0.6 : 1)
        .contentShape(Rectangle())
        .onTapGesture { toggleDone() }
    }

    // MARK: Expanded card — the current setup, with every field laid out.

    private var expandedCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header: check · number · nickname · NOW badge.
            HStack(spacing: 10) {
                Button { toggleDone() } label: { checkCircle }
                    .buttonStyle(.plain).disabled(locked)
                Text(shot.displayNumber)
                    .font(.system(size: 16, weight: .bold)).monospacedDigit()
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .frame(minWidth: 46)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.14)))
                    .foregroundStyle(Color.accentColor)
                if hasNick {
                    Text(shot.nickname)
                        .font(.system(size: 16, weight: .bold))
                        .lineLimit(2)
                }
                Spacer(minLength: 6)
                refPill
                Text("NOW")
                    .font(.system(size: 9.5, weight: .heavy)).kerning(0.5)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor))
            }

            // Labelled spec fields — only those that are set.
            let items = detailItems
            if !items.isEmpty {
                FlowLayout(spacing: 18) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.0)
                                .font(.system(size: 9, weight: .heavy)).kerning(0.4)
                                .foregroundStyle(.tertiary)
                            Text(item.1)
                                .font(.system(size: 14, weight: .semibold))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            // Free-text blocks: notes, extra info, and any custom fields.
            if !trimmed(shot.shotInformation).isEmpty {
                detailBlock("NOTES", shot.shotInformation)
            }
            if !trimmed(shot.extraInfo).isEmpty {
                detailBlock("MORE", shot.extraInfo)
            }
            ForEach(shot.orderedCustomInfo, id: \.uid) { info in
                if !trimmed(info.exportValue).isEmpty {
                    detailBlock(info.exportLabel.uppercased(), info.exportValue)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.platformTextBackground)
            .shadow(color: .black.opacity(0.08), radius: 6, y: 1))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.accentColor, lineWidth: 2))
        .opacity(shot.isShot ? 0.6 : 1)
    }

    private var hasNick: Bool { !trimmed(shot.nickname).isEmpty }
    private func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The framing reference to preview: the first reference with an image, else
    /// the legacy shot photo. Nil when the shot has no still.
    private var framingImage: PlatformImage? {
        if let data = shot.orderedReferences.first(where: { $0.imageData != nil })?.imageData,
           let img = PlatformImage(data: data) { return img }
        if let data = shot.photo1Data, let img = PlatformImage(data: data) { return img }
        return nil
    }

    private var lensText: String {
        guard shot.lensfocal > 0 else { return "" }
        return shot.lensIsPrime ? "\(shot.lensfocal)mm" : "\(shot.lensfocal)–\(shot.lensfocalEnd)mm"
    }

    /// Labelled spec values for the expanded card — each included only when set.
    private var detailItems: [(String, String)] {
        var out: [(String, String)] = []
        let size = [shot.sizeShort, shot.secondSizeShort].filter { !$0.isEmpty }.joined(separator: " / ")
        if !size.isEmpty { out.append(("SIZE", size)) }
        let type = [shot.typeShort, shot.secondTypeShort, shot.thirdTypeShort]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        if !type.isEmpty { out.append(("TYPE", type)) }
        if !lensText.isEmpty { out.append(("LENS", lensText)) }
        if shot.hasGrip { out.append(("GRIP", shot.gripName)) }
        return out
    }

    private func detailBlock(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .heavy)).kerning(0.4)
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Nickname first, then the spec (same font), both on one line. The grip joins
    /// the spec with the same " · " separator as size/type/lens.
    private var infoLine: some View {
        let hasNick = !shot.nickname.trimmingCharacters(in: .whitespaces).isEmpty
        // Size · type · lens · grip.
        let spec = [shot.shortSpec, shot.hasGrip ? shot.gripName : ""]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        return HStack(spacing: 8) {
            if hasNick {
                Text(shot.nickname)
                    .foregroundStyle(.primary)
                    .layoutPriority(1)
            }
            if !spec.isEmpty {
                Text(spec)
                    .foregroundStyle(hasNick ? .secondary : .primary)
            }
            if !hasNick && spec.isEmpty {
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
        // A clear-filled circle isn't reliably hit-testable; give the whole 26pt
        // area (plus a little slop) an explicit tap shape so the circle can be
        // tapped directly — the current-shot card has no other check-off control.
        .padding(6)
        .contentShape(Circle())
        .padding(-6)
    }

    private func toggleDone() {
        guard !locked else { return }
        shot.isShot.toggle()
        onChange()
    }
}

// MARK: - Framing reference viewer

/// Shows a shot's framing reference still in a popup, sized to the image — mirrors
/// `SceneMapViewerSheet`: on macOS the window pins to the image's width; on iOS the
/// sheet uses a content-height detent so it's no taller than header + image.
private struct FramingViewerSheet: View {
    let image: PlatformImage
    let title: String
    @Environment(\.dismiss) private var dismiss

    private let pad: CGFloat = 16
    /// Measured on iOS so the image fits the sheet's actual width.
    @State private var sheetWidth: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(pad)
            Divider()
            Image(platformImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: displaySize.width, height: displaySize.height)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(pad)
                .frame(maxWidth: .infinity)
                .background(Color.platformGroupedBackground)
        }
        #if os(macOS)
        .frame(width: displaySize.width + pad * 2)
        .frame(minHeight: 300)
        #else
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { sheetWidth = geo.size.width }
                .onChange(of: geo.size.width) { _, w in sheetWidth = w }
        })
        .presentationDragIndicator(.visible)
        .applyRefSheetSizing(isPhone: DeviceLayout.isPhone,
                             phoneHeight: headerHeight + displaySize.height + pad * 2)
        #endif
    }

    /// The image's aspect ratio (falls back to square if unknown).
    private var aspect: CGFloat {
        image.size.width > 0 && image.size.height > 0 ? image.size.width / image.size.height : 1
    }

    private var headerHeight: CGFloat { 55 }

    /// The size to render the image at. Mac and iPad use a fixed max box (the sheet
    /// is sized to fit it); iPhone fits the measured sheet width.
    private var displaySize: CGSize {
        #if os(macOS)
        return fitted(maxW: 760, maxH: 620)
        #else
        if DeviceLayout.isPhone {
            let available = (sheetWidth > 0 ? sheetWidth : 380) - pad * 2
            var w = max(available, 120), h = w / aspect
            let maxH: CGFloat = 560
            if h > maxH { h = maxH; w = maxH * aspect }
            if w > available { w = available; h = available / aspect }
            return CGSize(width: w.rounded(), height: h.rounded())
        } else {
            // iPad: a large box; the sheet grows to fit it (see applyRefSheetSizing).
            return fitted(maxW: 900, maxH: 720)
        }
        #endif
    }

    /// Largest w×h with the image's aspect that fits inside maxW×maxH.
    private func fitted(maxW: CGFloat, maxH: CGFloat) -> CGSize {
        var w = maxW, h = maxW / aspect
        if h > maxH { h = maxH; w = maxH * aspect }
        return CGSize(width: w.rounded(), height: h.rounded())
    }
}

#if os(iOS)
private extension View {
    /// iPhone: a content-height detent. iPad: size the sheet to fit its content
    /// (so a large reference image gets a large popup, not a fixed form sheet).
    @ViewBuilder
    func applyRefSheetSizing(isPhone: Bool, phoneHeight: CGFloat) -> some View {
        if isPhone {
            self.presentationDetents([.height(phoneHeight)])
        } else if #available(iOS 18.0, *) {
            self.presentationSizing(.fitted)
        } else {
            self
        }
    }
}
#endif

// MARK: - Read-only map viewer

/// Shows a scene's map for viewing only — no editing. Reuses the static
/// `SceneMapExportView` (the same non-interactive rendering used by the web/PDF
/// export) so On-Set Mode can glance at a map without risk of changing it.
private struct SceneMapViewerSheet: View {
    let scene: Scene
    @Environment(\.dismiss) private var dismiss

    private let mapPadding: CGFloat = 16
    /// The sheet's own width, measured on iOS so the map can fit it exactly (iPad's
    /// form sheet is much narrower than a Mac window; a fixed width would clip).
    @State private var sheetWidth: CGFloat = 0

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
            mapArea(size: displayMapSize)
        }
        #if os(macOS)
        // Mac: pin the window to the map's own width (+ padding); height follows.
        .frame(width: displayMapSize.width + mapPadding * 2)
        .frame(minHeight: 300)
        #else
        // iOS/iPadOS: measure the sheet width so the map fits it, and use a
        // content-sized detent so the sheet is no taller than header + map.
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { sheetWidth = geo.size.width }
                .onChange(of: geo.size.width) { _, w in sheetWidth = w }
        })
        .presentationDetents([.height(headerHeight + displayMapSize.height + mapPadding * 2)])
        .presentationDragIndicator(.visible)
        #endif
    }

    @ViewBuilder
    private func mapArea(size: CGSize) -> some View {
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
                labels: cameraLabels(doc), size: size,
                metersWide: scene.sceneMapMetersWide,
                cameraMeters: scene.sceneMapCameraSizeMeters,
                viewableMarkers: scene.sceneMapViewableMarkerSize)
            .frame(width: size.width, height: size.height)
            // View-only: kill the markers' drag gestures so nothing can be moved
            // (their onMove is a no-op, so a drag would just snap back).
            .allowsHitTesting(false)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(mapPadding)
            .frame(maxWidth: .infinity)
            .background(Color.platformGroupedBackground)
        }
    }

    /// The map's aspect (background aspect, or square for floor-plan/grid maps).
    private var mapAspect: CGFloat {
        let background = scene.sceneMapBackgroundData.flatMap(PlatformImage.init(data:))
        if let bg = background, bg.size.width > 0, bg.size.height > 0 {
            return bg.size.width / bg.size.height
        }
        return 1
    }

    /// Estimated header height (title, optional nickname, padding + divider) — used
    /// to size the iOS content detent.
    private var headerHeight: CGFloat {
        scene.nickname.trimmingCharacters(in: .whitespaces).isEmpty ? 55 : 76
    }

    /// The concrete size to render the map at. Mac uses a fixed max box; iOS fits
    /// the measured sheet width (capped in height so tall maps don't overflow).
    private var displayMapSize: CGSize {
        let aspect = mapAspect
        #if os(macOS)
        let maxW: CGFloat = 760
        let maxH: CGFloat = 620
        var w = maxW
        var h = maxW / aspect
        if h > maxH { h = maxH; w = maxH * aspect }
        return CGSize(width: w.rounded(), height: h.rounded())
        #else
        // Fit the measured sheet width; before the first measurement fall back to a
        // sensible width so the initial detent isn't tiny.
        let available = (sheetWidth > 0 ? sheetWidth : 380) - mapPadding * 2
        var w = max(available, 120)
        var h = w / aspect
        let maxH: CGFloat = 560   // keep the sheet from running the full screen height
        if h > maxH { h = maxH; w = maxH * aspect }
        if w > available { w = available; h = available / aspect }
        return CGSize(width: w.rounded(), height: h.rounded())
        #endif
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

#if os(macOS)
import AppKit

/// When `active`, makes the host window's content run the full height under a
/// transparent title bar, so On-Set Mode fills the window to the very top; the
/// standard title bar is restored when `active` goes false. Attached to the
/// always-present root (ProjectListView) so it reliably holds a window reference —
/// the traffic-light buttons stay visible and functional over the top bar.
struct OnSetWindowFiller: NSViewRepresentable {
    let active: Bool

    final class Coordinator {
        weak var window: NSWindow?
        var savedTransparent: Bool?
        var savedTitleVisibility: NSWindow.TitleVisibility?
        var hadFullSizeContent: Bool?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        let active = self.active
        DispatchQueue.main.async {
            let c = context.coordinator
            guard let window = nsView.window else { return }
            c.window = window
            if active {
                // Capture the originals once, on the way in.
                if c.savedTransparent == nil {
                    c.savedTransparent = window.titlebarAppearsTransparent
                    c.savedTitleVisibility = window.titleVisibility
                    c.hadFullSizeContent = window.styleMask.contains(.fullSizeContentView)
                }
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
                window.styleMask.insert(.fullSizeContentView)
            } else {
                if let t = c.savedTransparent { window.titlebarAppearsTransparent = t }
                if let v = c.savedTitleVisibility { window.titleVisibility = v }
                if c.hadFullSizeContent == false { window.styleMask.remove(.fullSizeContentView) }
                c.savedTransparent = nil
                c.savedTitleVisibility = nil
                c.hadFullSizeContent = nil
            }
        }
    }
}
#endif
