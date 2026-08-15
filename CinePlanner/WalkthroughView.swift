//
//  WalkthroughView.swift
//  CinePlanner
//
//  A paged, visual "how it works" guide. Opened from the ? button, and shown
//  once automatically on first launch. Each step is a hero symbol plus a short
//  explanation — no image assets, so it always renders.
//

import SwiftUI

struct WalkthroughView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0

    private struct Step: Identifiable {
        let id = UUID()
        let symbol: String
        let tint: Color
        let title: String
        let detail: String
    }

    private let steps: [Step] = [
        Step(symbol: "film.stack", tint: .accentColor,
             title: "Welcome to CinePlanner",
             detail: "Plan every shot from your script, then share a clean, filterable shot list with your crew. Here's a quick tour."),
        Step(symbol: "folder.badge.plus", tint: .blue,
             title: "Projects",
             detail: "Start a project from a script PDF, or import one you've been sent. A project can be a single film, or a series with episodes and multiple script versions."),
        Step(symbol: "doc.text.magnifyingglass", tint: .purple,
             title: "Script & scenes",
             detail: "Your script sits beside the scene list. Break each scene into shots, and mark the exact lines a shot covers right on the PDF."),
        Step(symbol: "camera.aperture", tint: .orange,
             title: "Set up each shot",
             detail: "Give a shot its size, type, focal length, grip and camera info. Add a second size or type, or a zoom range, whenever a shot needs it."),
        Step(symbol: "photo.on.rectangle.angled", tint: .pink,
             title: "Add references",
             detail: "Attach reference photos or video, a top-down map, and a short note to each shot — so everyone sees the intended frame at a glance."),
        Step(symbol: "arkit", tint: CineStagerImportSheet.cineStagerBlue,
             title: "Better together with CineStager",
             detail: "Scout and frame your shots in AR on location with CineStager, then pull them straight into a scene. Tap “Add Shot from CineStager” to browse your AR captures — they sync over automatically."),
        Step(symbol: "wand.and.stars", tint: CineStagerImportSheet.cineStagerBlue,
             title: "Everything comes across",
             detail: "A CineStager shot arrives complete: the framing photo or clip, camera body and format, lens, focal length, sensor size, framelines, tilt and height — and CinePlanner even estimates the shot's size and type for you."),
        Step(symbol: "map", tint: .mint,
             title: "Top-down blocking maps",
             detail: "Every scene gets a blocking map. CineStager drops in the real camera and actor positions with each camera's field-of-view cone; add a satellite map of your location and drag markers to plan your coverage."),
        Step(symbol: "globe", tint: .green,
             title: "Export & publish",
             detail: "Export a PDF, a self-contained webpage, or plain text — or Publish to Web to put a shareable shot list online through your own GitHub account."),
        Step(symbol: "icloud", tint: .teal,
             title: "Safe and in sync",
             detail: "Your projects sync across your Mac and iPad through iCloud, and CinePlanner snapshots your data at every launch — use “Restore from Backup” to roll back anytime."),
    ]

    private var step: Step { steps[index] }
    private var isLast: Bool { index == steps.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("How CinePlanner works")
                    .font(.headline)
                Spacer()
                Button("Skip") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding(16)

            Divider()

            // Hero + copy for the current step.
            VStack(spacing: 22) {
                ZStack {
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .fill(step.tint.opacity(0.15))
                        .frame(width: 148, height: 148)
                    Image(systemName: step.symbol)
                        .font(.system(size: 62, weight: .regular))
                        .foregroundStyle(step.tint)
                        .symbolRenderingMode(.hierarchical)
                }

                VStack(spacing: 10) {
                    Text(step.title)
                        .font(.title2).fontWeight(.semibold)
                        .multilineTextAlignment(.center)
                    Text(step.detail)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 420)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 30)
            .id(index)                                   // re-runs the transition per step
            .transition(.opacity)

            // Page dots + navigation.
            VStack(spacing: 16) {
                HStack(spacing: 7) {
                    ForEach(steps.indices, id: \.self) { i in
                        Circle()
                            .fill(i == index ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 7, height: 7)
                    }
                }

                HStack {
                    Button("Back") { withAnimation(.easeInOut(duration: 0.2)) { index -= 1 } }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .disabled(index == 0)
                        .opacity(index == 0 ? 0 : 1)

                    Spacer()

                    Button(isLast ? "Get Started" : "Next") {
                        if isLast { dismiss() }
                        else { withAnimation(.easeInOut(duration: 0.2)) { index += 1 } }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .frame(width: 560, height: 560)
    }
}
