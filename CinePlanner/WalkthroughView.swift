//
//  WalkthroughView.swift
//  CinePlanner
//
//  A paged, animated "how it works" guide. Opened from the ? button, and shown
//  once automatically on first launch. Each step pairs a hand-built, animated
//  SwiftUI vignette (a mock of the real UI — AR viewfinder, blocking map, shot
//  card…) with a short explanation. Everything is drawn from shapes + SF Symbols
//  (plus the CineStager logo asset), so it always renders on Mac and iPad with no
//  screenshot assets to ship or keep in sync.
//

import SwiftUI

struct WalkthroughView: View {
    @Environment(\.dismiss) private var dismiss
    /// iPhone: the walkthrough fills its full-screen sheet instead of the fixed
    /// iPad/Mac card size.
    private var isCompact: Bool { DeviceLayout.isPhone }
    @State private var index = 0

    enum StepKind {
        case welcome, projects, script, shot, references
        case cinestager, metadata, blockingMap, schedule, onSet, export, sync
    }

    private struct Step: Identifiable {
        let id = UUID()
        let kind: StepKind
        let tint: Color
        let title: String
        let detail: String
    }

    private static let csBlue = CineStagerImportSheet.cineStagerBlue

    private let steps: [Step] = [
        Step(kind: .welcome, tint: .accentColor,
             title: "Welcome to CinePlanner",
             detail: "Plan every shot from your script, then share a clean, filterable shot list with your crew. Here's a quick tour."),
        Step(kind: .projects, tint: .blue,
             title: "Projects",
             detail: "Start a project from a script PDF, or import one you've been sent. A project can be a single film, or a series with episodes and multiple script versions."),
        Step(kind: .script, tint: .purple,
             title: "Script & scenes",
             detail: "Your script sits beside the scene list. Break each scene into shots, and mark the exact lines a shot covers right on the PDF."),
        Step(kind: .shot, tint: .orange,
             title: "Set up each shot",
             detail: "Give a shot its size, type, focal length, grip and camera info. Add a second size or type, or a zoom range, whenever a shot needs it."),
        Step(kind: .references, tint: .pink,
             title: "Add references",
             detail: "Attach reference photos or video, a top-down map, and a short note to each shot — so everyone sees the intended frame at a glance."),
        Step(kind: .cinestager, tint: csBlue,
             title: "Better together with CineStager",
             detail: "Scout and frame your shots in AR on location with CineStager, then pull them straight into a scene. Tap “Add Shot from CineStager” to browse your AR captures — they sync over automatically."),
        Step(kind: .metadata, tint: csBlue,
             title: "Everything comes across",
             detail: "A CineStager shot arrives complete: the framing photo or clip, camera body and format, lens, focal length, sensor size, framelines, tilt and height — and CinePlanner even estimates the shot's size and type for you."),
        Step(kind: .blockingMap, tint: .mint,
             title: "Top-down blocking maps",
             detail: "Every scene gets a blocking map. CineStager drops in the real camera and actor positions with each camera's field-of-view cone; add a satellite map of your location and drag markers to plan your coverage."),
        Step(kind: .schedule, tint: .indigo,
             title: "Plan your shoot days",
             detail: "Group your scenes and shots into shooting days and reorder them freely. Each day shows the location's sunrise, sunset and golden hour, so you can plan around the light."),
        Step(kind: .onSet, tint: .red,
             title: "Shoot with On-Set mode",
             detail: "On the day, switch to On-Set mode: the shot you're on is shown big with everything you need, and you tick each one off as you get it. On iPhone a Live Activity keeps the current shot on your Lock Screen."),
        Step(kind: .export, tint: .green,
             title: "Export & publish",
             detail: "Export a PDF, a self-contained webpage, or plain text — or Publish to Web to put a shareable shot list online through your own GitHub account."),
        Step(kind: .sync, tint: .teal,
             title: "Safe and in sync",
             detail: "Your projects sync across your Mac and iPad through iCloud, and CinePlanner snapshots your data at every launch — use “Restore from Backup” to roll back anytime."),
    ]

    private var step: Step { steps[index] }
    private var isLast: Bool { index == steps.count - 1 }

    var body: some View {
        ZStack {
            Color.platformControlBackground.ignoresSafeArea()
            AmbientBackground(tint: step.tint).ignoresSafeArea()

            VStack(spacing: 0) {
                header

                VStack(spacing: 24) {
                    illustration(step.kind)
                        .frame(height: 250)
                        .frame(maxWidth: .infinity)

                    VStack(spacing: 10) {
                        Text(step.title)
                            .font(.system(.title, design: .rounded)).fontWeight(.bold)
                            .multilineTextAlignment(.center)
                        Text(step.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 440)
                    }
                    .appear(0.08)
                }
                .padding(.horizontal, 36)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(index)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(y: 16)),
                    removal: .opacity.combined(with: .offset(y: -12))))

                footer
            }
        }
        // iPhone (compact) fills its full-screen sheet; iPad/Mac keep the fixed card.
        .frame(maxWidth: isCompact ? .infinity : nil, maxHeight: isCompact ? .infinity : nil)
        .frame(width: isCompact ? nil : 560, height: isCompact ? nil : 660)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 24)
                .onEnded { v in
                    if v.translation.width < -50 { advance() }
                    else if v.translation.width > 50 { goBack() }
                }
        )
    }

    // MARK: - Navigation

    private func advance() {
        if isLast { dismiss() }
        else { withAnimation(.easeInOut(duration: 0.4)) { index += 1 } }
    }
    private func goBack() {
        guard index > 0 else { return }
        withAnimation(.easeInOut(duration: 0.4)) { index -= 1 }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack {
            Label("Getting Started", systemImage: "sparkles")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Skip") { dismiss() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
    }

    private var footer: some View {
        VStack(spacing: 18) {
            HStack(spacing: 7) {
                ForEach(steps.indices, id: \.self) { i in
                    Capsule()
                        .fill(i == index ? step.tint : Color.secondary.opacity(0.28))
                        .frame(width: i == index ? 22 : 7, height: 7)
                        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: index)
                }
            }

            if isCompact {
                // iPhone: a balanced two-button bar — matching capsules that split the
                // width, rather than a small plain "Back" opposite a big filled "Next".
                HStack(spacing: 12) {
                    if index > 0 {
                        Button { goBack() } label: {
                            Label("Back", systemImage: "chevron.left")
                                .fontWeight(.semibold)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .tint(.secondary)
                    }
                    nextButton(fullWidth: true)
                }
            } else {
                HStack {
                    Button { goBack() } label: {
                        Label("Back", systemImage: "chevron.left").labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .opacity(index == 0 ? 0 : 1)
                    .disabled(index == 0)

                    Spacer()

                    nextButton(fullWidth: false)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, isCompact ? 28 : 22)
        .padding(.top, 4)
    }

    private func nextButton(fullWidth: Bool) -> some View {
        Button { advance() } label: {
            HStack(spacing: 6) {
                Text(isLast ? "Get Started" : "Next")
                if !isLast { Image(systemName: "chevron.right") }
            }
            .fontWeight(.semibold)
            .frame(maxWidth: fullWidth ? .infinity : nil)
        }
        .buttonStyle(.borderedProminent)
        .tint(step.tint)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
    }

    // MARK: - Illustrations

    @ViewBuilder
    private func illustration(_ kind: StepKind) -> some View {
        switch kind {
        case .welcome:     WelcomeIllo()
        case .projects:    ProjectsIllo()
        case .script:      ScriptIllo()
        case .shot:        ShotIllo()
        case .references:  ReferencesIllo()
        case .cinestager:  CineStagerIllo()
        case .metadata:    MetadataIllo()
        case .blockingMap: BlockingMapIllo()
        case .schedule:    ScheduleIllo()
        case .onSet:       OnSetIllo()
        case .export:      ExportIllo()
        case .sync:        SyncIllo()
        }
    }
}

// MARK: - Ambient animated background

private struct AmbientBackground: View {
    let tint: Color
    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            ZStack {
                orb(tint, 320, x: CGFloat(sin(t * 0.24)) * 55 - 140, y: CGFloat(cos(t * 0.2)) * 45 - 150)
                orb(tint.mixedWithWhite(0.35), 280, x: CGFloat(cos(t * 0.21)) * 60 + 150, y: CGFloat(sin(t * 0.27)) * 50 + 170)
                orb(tint, 220, x: CGFloat(sin(t * 0.3)) * 70 + 120, y: CGFloat(cos(t * 0.26)) * 55 - 140)
            }
        }
        .animation(.easeInOut(duration: 0.7), value: tint)
        .allowsHitTesting(false)
    }
    private func orb(_ c: Color, _ s: CGFloat, x: CGFloat, y: CGFloat) -> some View {
        Circle().fill(c.opacity(0.32)).frame(width: s, height: s).blur(radius: 72).offset(x: x, y: y)
    }
}

// MARK: - Illustration: Welcome (fanned film cards)

private struct WelcomeIllo: View {
    var body: some View {
        ZStack {
            // Soft glow behind the app icon.
            Circle()
                .fill(Color.accentColor.opacity(0.28))
                .frame(width: 190, height: 190)
                .blur(radius: 40)
            // The logo art is the bars on their own; sit them on a white app-icon
            // tile so the Welcome card reads like the app's icon.
            RoundedRectangle(cornerRadius: 33, style: .continuous)
                .fill(.white)
                .frame(width: 148, height: 148)
                .overlay(
                    // The SVG already carries the icon's internal margins, so it
                    // fills the tile like the real app icon (no extra padding).
                    Image("CinePlannerLogo")
                        .resizable().scaledToFit()
                        .padding(6)
                )
                .shadow(color: .black.opacity(0.22), radius: 18, y: 12)
                .appear()
        }
    }
}

// MARK: - Illustration: Projects (card row)

private struct ProjectsIllo: View {
    private let tints: [Color] = [.blue, .purple, .pink]
    var body: some View {
        HStack(spacing: 14) {
            ForEach(0..<3, id: \.self) { i in
                VStack(alignment: .leading, spacing: 9) {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(LinearGradient(colors: [tints[i], tints[i].opacity(0.55)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 96, height: 66)
                        .overlay(Image(systemName: "film")
                            .font(.title3).foregroundStyle(.white.opacity(0.95)))
                    Capsule().fill(.secondary.opacity(0.35)).frame(width: 74, height: 8)
                    Capsule().fill(.secondary.opacity(0.22)).frame(width: 50, height: 6)
                }
                .padding(11)
                .glassCard()
                .appear(Double(i) * 0.1)
            }
        }
    }
}

// MARK: - Illustration: Script & scenes

private struct ScriptIllo: View {
    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(0..<7, id: \.self) { i in
                    let marked = (i == 2 || i == 3)
                    Capsule()
                        .fill(marked ? Color.purple.opacity(0.65) : Color.secondary.opacity(0.28))
                        .frame(width: marked ? 150 : [120, 96, 140, 110, 130, 84, 118][i], height: 9)
                }
            }
            .padding(16)
            .frame(width: 190, height: 190, alignment: .topLeading)
            .glassCard()
            .appear()

            VStack(spacing: 8) {
                ForEach(0..<4, id: \.self) { i in
                    HStack(spacing: 8) {
                        Text("\(i + 1)")
                            .font(.caption2.bold().monospacedDigit())
                            .frame(width: 20, height: 20)
                            .background(i == 0 ? Color.purple : Color.secondary.opacity(0.25), in: Circle())
                            .foregroundStyle(i == 0 ? .white : .secondary)
                        Capsule().fill(.secondary.opacity(0.3)).frame(width: 74, height: 8)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(i == 0 ? Color.purple.opacity(0.14) : .clear,
                                in: RoundedRectangle(cornerRadius: 8))
                    .appear(0.1 + Double(i) * 0.06)
                }
            }
            .frame(width: 130)
        }
    }
}

// MARK: - Illustration: Shot spec card

private struct ShotIllo: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text("1A")
                    .font(.headline.monospaced())
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(Color.orange, in: RoundedRectangle(cornerRadius: 7))
                    .foregroundStyle(.white)
                Capsule().fill(.secondary.opacity(0.3)).frame(width: 120, height: 9)
                Spacer()
                Image(systemName: "camera.aperture").font(.title2).foregroundStyle(.orange)
            }
            WKChipRow(items: [("Medium", .orange), ("Two Shot", .orange)], baseDelay: 0.12)
            WKChipRow(items: [("35 mm", .blue), ("Dolly", .blue), ("ARRI", .blue)], baseDelay: 0.24)
        }
        .padding(18)
        .frame(width: 320)
        .glassCard()
        .appear()
    }
}

// MARK: - Illustration: References

private struct ReferencesIllo: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(colors: [Color.pink.opacity(0.55), Color.purple.opacity(0.5)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 280, height: 180)
                .overlay(shimmer)
                .overlay(alignment: .topLeading) {
                    Image(systemName: "photo").foregroundStyle(.white.opacity(0.9)).padding(12)
                }
                .overlay {
                    Image(systemName: "play.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.black.opacity(0.7))
                        .frame(width: 56, height: 56)
                        .background(.white.opacity(0.92), in: Circle())
                        .shadow(radius: 8, y: 4)
                }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 14, y: 10)

            HStack(spacing: 6) {
                Image(systemName: "note.text")
                Text("“Handheld, slow push-in”").italic()
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
            .offset(y: 104)
            .appear(0.2)
        }
    }
    private var shimmer: some View {
        TimelineView(.animation) { tl in
            let p = (sin(tl.date.timeIntervalSinceReferenceDate * 1.2) + 1) / 2   // 0…1
            LinearGradient(colors: [.clear, .white.opacity(0.35), .clear],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .frame(width: 90)
                .offset(x: CGFloat(p) * 340 - 170)
                .blendMode(.plusLighter)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Illustration: CineStager logo

private struct CineStagerIllo: View {
    private let blue = CineStagerImportSheet.cineStagerBlue
    var body: some View {
        ZStack {
            Circle()
                .fill(blue.opacity(0.30))
                .frame(width: 200, height: 200)
                .blur(radius: 44)
            // The logo mark on a white app-icon tile, matching the Welcome card.
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .fill(.white)
                .frame(width: 152, height: 152)
                .overlay(
                    Image("CineStagerLogo")
                        .resizable().scaledToFit()
                        .padding(6)
                )
                .shadow(color: blue.opacity(0.40), radius: 22, y: 12)
                .appear()
        }
    }
}

// MARK: - Illustration: Metadata fills in

private struct MetadataIllo: View {
    private let blue = CineStagerImportSheet.cineStagerBlue
    private var rows: [[String]] {
        [["ARRI Alexa 35", "4.6K"], ["35 mm", "Super 35", "2.39:1"], ["Medium", "Two Shot", "Tilt 3°"]]
    }
    var body: some View {
        VStack(spacing: 12) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: 10) {
                    ForEach(rows[r].indices, id: \.self) { c in
                        let delay = 0.08 * Double(r * 3 + c)
                        chip(rows[r][c], (r + c).isMultiple(of: 2) ? blue : .accentColor)
                            .appear(delay)
                    }
                }
            }
        }
        .padding(20)
        .glassCard()
        .overlay(alignment: .topTrailing) {
            Image(systemName: "wand.and.stars")
                .font(.title3).foregroundStyle(blue)
                .padding(12)
        }
        .appear()
    }
    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background(color.opacity(0.16), in: Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(0.35)))
            .foregroundStyle(color)
    }
}

// MARK: - Illustration: Blocking map with live FOV cone

private struct BlockingMapIllo: View {
    // The camera's colour, matching the app's default camera marker (#FF9500).
    private let camColor = Color(hex: "#FF9500")
    var body: some View {
        let W: CGFloat = 330, H: CGFloat = 214
        return ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.20, green: 0.42, blue: 0.30),
                                              Color(red: 0.10, green: 0.26, blue: 0.19)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            MapGrid().stroke(.white.opacity(0.07), lineWidth: 1)

            // Actors — the real head-and-shoulders markers, facing the camera.
            WKCharacterMarker(color: Color(hex: "#4C8DFF"))
                .scaleEffect(1.1).rotationEffect(.degrees(180))
                .position(x: W / 2 - 46, y: 78).appear(0.15)
            WKCharacterMarker(color: Color(hex: "#AF52DE"))
                .scaleEffect(1.1).rotationEffect(.degrees(180))
                .position(x: W / 2 + 40, y: 94).appear(0.22)

            // Camera marker near the bottom, facing up.
            WKCameraMarker(color: camColor)
                .scaleEffect(1.2)
                .position(x: W / 2, y: H - 40)
                .appear(0.05)
        }
        .frame(width: W, height: H)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 14, y: 10)
        .appear()
    }
}

/// The app's camera marker: a `video.fill` glyph with a white outline halo,
/// slimmed to 85% across its facing axis and pointing up at rotation 0.
private struct WKCameraMarker: View {
    var color: Color
    private let side: CGFloat = 26
    var body: some View {
        ZStack {
            ForEach(0..<16, id: \.self) { i in
                Image(systemName: "video.fill")
                    .resizable().scaledToFit()
                    .frame(width: side, height: side)
                    .foregroundStyle(.white)
                    .offset(x: 1.6 * cos(CGFloat(i) / 16 * 2 * .pi),
                            y: 1.6 * sin(CGFloat(i) / 16 * 2 * .pi))
            }
            Image(systemName: "video.fill")
                .resizable().scaledToFit()
                .frame(width: side, height: side)
                .foregroundStyle(color)
        }
        .scaleEffect(x: 1, y: 0.85)
        .rotationEffect(.degrees(-90))
        .shadow(color: .black.opacity(0.22), radius: 1, y: 0.5)
    }
}

/// The app's character marker: top-down head and shoulders (an ellipse plus a
/// head circle nudged toward the facing direction), facing up at rotation 0.
private struct WKCharacterMarker: View {
    var color: Color
    var body: some View {
        ZStack {
            Ellipse().fill(color)
                .overlay(Ellipse().stroke(.white, lineWidth: 2))
                .frame(width: 30, height: 11)
            Circle().fill(color)
                .overlay(Circle().stroke(.white, lineWidth: 2))
                .frame(width: 15, height: 15)
                .offset(y: -2)
        }
    }
}

private struct MapGrid: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let step: CGFloat = 30
        var x = rect.minX
        while x <= rect.maxX { p.move(to: CGPoint(x: x, y: rect.minY)); p.addLine(to: CGPoint(x: x, y: rect.maxY)); x += step }
        var y = rect.minY
        while y <= rect.maxY { p.move(to: CGPoint(x: rect.minX, y: y)); p.addLine(to: CGPoint(x: rect.maxX, y: y)); y += step }
        return p
    }
}

// MARK: - Illustration: Export & publish

// MARK: - Illustration: shooting schedule

private struct ScheduleIllo: View {
    var body: some View {
        HStack(spacing: 16) {
            dayCard("Day 1", ["1.1", "1.2", "2.3"], 0)
            dayCard("Day 2", ["4.1", "5.2"], 0.14)
        }
    }

    private func dayCard(_ title: String, _ shots: [String], _ delay: Double) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Text(title).font(.subheadline.weight(.bold))
                Spacer(minLength: 6)
                Image(systemName: "sunrise.fill").font(.caption2).foregroundStyle(.orange)
                Image(systemName: "sunset.fill").font(.caption2).foregroundStyle(.indigo)
            }
            // Golden-hour band.
            Capsule()
                .fill(LinearGradient(colors: [.orange.opacity(0.7), .yellow.opacity(0.5)],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(height: 5)
            ForEach(shots.indices, id: \.self) { i in
                HStack(spacing: 7) {
                    Text(shots[i])
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.indigo)
                    Capsule().fill(.secondary.opacity(0.25)).frame(height: 6)
                }
            }
        }
        .padding(14)
        .frame(width: 120, height: 150)
        .glassCard()
        .appear(delay)
    }
}

// MARK: - Illustration: On-Set mode

private struct OnSetIllo: View {
    var body: some View {
        VStack(spacing: 10) {
            // The current shot, shown big.
            HStack(spacing: 12) {
                Text("1.2")
                    .font(.title3.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(.red))
                VStack(alignment: .leading, spacing: 4) {
                    Text("NOW").font(.caption2.weight(.bold)).foregroundStyle(.red)
                    Capsule().fill(.secondary.opacity(0.35)).frame(width: 96, height: 7)
                    Capsule().fill(.secondary.opacity(0.25)).frame(width: 66, height: 7)
                }
                Spacer(minLength: 4)
                Image(systemName: "checkmark.circle.fill")
                    .font(.title).foregroundStyle(.white, .green)
            }
            .padding(14)
            .frame(width: 250)
            .glassCard()
            .appear()

            // Upcoming shots, ticked off as you go.
            ForEach(Array(["1.3", "1.4"].enumerated()), id: \.offset) { i, num in
                HStack(spacing: 10) {
                    Image(systemName: "circle").font(.body).foregroundStyle(.secondary)
                    Text(num).font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(.secondary)
                    Capsule().fill(.secondary.opacity(0.2)).frame(height: 6)
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .frame(width: 250)
                .glassCard(12)
                .appear(0.14 + Double(i) * 0.08)
            }
        }
    }
}

private struct ExportIllo: View {
    var body: some View {
        HStack(spacing: 30) {
            VStack(spacing: 7) {
                Image(systemName: "square.and.arrow.up")
                    .font(.title2).foregroundStyle(.green)
                ForEach(0..<4, id: \.self) { i in
                    Capsule().fill(.secondary.opacity(i == 0 ? 0.4 : 0.25))
                        .frame(width: i == 0 ? 60 : 74, height: 7)
                }
            }
            .padding(18)
            .frame(width: 118, height: 150)
            .glassCard()
            .appear()

            VStack(alignment: .leading, spacing: 14) {
                exportRow("doc.richtext", "PDF", .red, 0.12)
                exportRow("globe", "Web", .green, 0.24)
                exportRow("doc.plaintext", "Text", .gray, 0.36)
            }
        }
    }
    private func exportRow(_ symbol: String, _ label: String, _ color: Color, _ delay: Double) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(color)
                Text(label).font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 13).padding(.vertical, 9)
            .glassCard(12)
        }
        .appear(delay)
    }
}

// MARK: - Illustration: iCloud sync

private struct SyncIllo: View {
    var body: some View {
        ZStack {
            TimelineView(.animation) { tl in
                Circle()
                    .trim(from: 0, to: 0.72)
                    .stroke(.teal.opacity(0.55),
                            style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: [2, 12]))
                    .frame(width: 156, height: 156)
                    .rotationEffect(.degrees(tl.date.timeIntervalSinceReferenceDate * 55))
            }
            Image(systemName: "icloud.fill")
                .font(.system(size: 60))
                .foregroundStyle(.teal)
                .appear()

            device("desktopcomputer").offset(x: -132).appear(0.1)
            device("ipad").offset(x: 132).appear(0.16)

            Image(systemName: "checkmark.circle.fill")
                .font(.title)
                .foregroundStyle(.white, .green)
                .background(Circle().fill(Color.platformControlBackground).padding(3))
                .offset(y: 66)
                .appear(0.3)
        }
    }
    private func device(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 34))
            .foregroundStyle(.secondary)
            .padding(12)
            .glassCard(14)
    }
}

// MARK: - Small shared pieces

/// A horizontal row of pill chips that pop in one after another.
private struct WKChipRow: View {
    let items: [(String, Color)]
    let baseDelay: Double
    var body: some View {
        HStack(spacing: 8) {
            ForEach(items.indices, id: \.self) { i in
                Text(items[i].0)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 11).padding(.vertical, 6)
                    .background(items[i].1.opacity(0.16), in: Capsule())
                    .overlay(Capsule().strokeBorder(items[i].1.opacity(0.35)))
                    .foregroundStyle(items[i].1)
                    .appear(baseDelay + Double(i) * 0.08)
            }
        }
    }
}

private extension View {
    /// A frosted card background with a hairline border and soft shadow.
    func glassCard(_ radius: CGFloat = 16) -> some View {
        self
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.16), radius: 14, y: 8)
    }

    /// Springs the view in (fade + rise + slight scale) once it mounts, after
    /// `delay`. Because each step's content is re-created with `.id(index)`, this
    /// re-runs every time the user turns to the page.
    func appear(_ delay: Double = 0) -> some View { modifier(AppearMod(delay: delay)) }
}

private struct AppearMod: ViewModifier {
    let delay: Double
    @State private var on = false
    func body(content: Content) -> some View {
        content
            .opacity(on ? 1 : 0)
            .scaleEffect(on ? 1 : 0.9)
            .offset(y: on ? 0 : 14)
            .onAppear {
                withAnimation(.spring(response: 0.55, dampingFraction: 0.8).delay(delay)) { on = true }
            }
    }
}
