//
//  ProjectEditorView+Toolbar.swift
//  CinePlanner
//
//  The project editor's toolbar: title, export, schedule and on-set buttons.
//

import SwiftUI
import SwiftData
import PhotosUI
import PDFKit

extension ProjectEditorView {
    // MARK: - Toolbar Views
    
    var titleView: some View {
        Text(project.filmName)
            .font(.title2)
            .fontWeight(.bold)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
    }
    
    /// The GitHub published-page indicator (when published) plus the Export button.
    @ViewBuilder
    /// iPad's toolbar group — all four controls at an even 8pt. (macOS uses separate
    /// toolbar items instead; see the `.toolbar` block.)
    var exportToolbarGroup: some View {
        HStack(spacing: 8) {
            onSetButton
            scheduleButton
            if let url = publishedURL {
                publishedPageMenu(url: url)
            }
            exportButton
        }
    }

    /// Primary export action — an accent capsule matching the version tabs
    /// and the chips used elsewhere in the app.
    var exportButton: some View {
        Button {
            showExportSheet = true
        } label: {
            if isPhoneLayout {
                // iPhone: an icon-only accent circle (matching the GitHub button) to
                // save room in the toolbar row.
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.accentColor.opacity(0.14)))
                    .overlay(Circle().stroke(Color.accentColor.opacity(0.35), lineWidth: 1))
                    .contentShape(Circle())
            } else {
                Text("Export")
                    .font(.body)
                    .fontWeight(.semibold)
                    .lineLimit(1).fixedSize()
                    .padding(.horizontal, 22)
                    .padding(.vertical, 10)
                    .foregroundStyle(Color.accentColor)
                    .background(Color.accentColor.opacity(0.14))
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color.accentColor.opacity(0.35), lineWidth: 1))
                    .contentShape(Capsule())
            }
        }
        .buttonStyle(.plain)
        .help("Export this shot list as PDF, text, or a web page with media")
    }

    /// Opens the shooting-schedule board for the selected version. Built to match
    /// the published-page GitHub button (same 36pt circle, secondary glyph) so the
    /// two toolbar circles are identical in size and color, on every platform.
    var scheduleButton: some View {
        Button { showScheduleSheet = true } label: {
            Image(systemName: "calendar")
                .accessibilityLabel("Shooting schedule")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color.secondary.opacity(0.12)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Plan shooting days and arrange scenes in shoot order")
        .disabled(selectedVersion == nil)
    }

    /// Opens On-Set Mode — today's shooting day as a live check-off list. Matches
    /// the schedule/GitHub buttons (36pt circle, secondary glyph).
    var onSetButton: some View {
        Button { onSet.version = selectedVersion } label: {
            Image(systemName: "film")
                .accessibilityLabel("On Set mode")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color.secondary.opacity(0.12)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("On-Set Mode — shoot today's day and check off setups as you go")
        .disabled(selectedVersion == nil)
    }

    @ViewBuilder
    var actionButtons: some View {
        if selectedScenes.count == 1, let scene = selectedScene, !otherVersionsWithShots.isEmpty {
            Button {
                modelContext.saveReporting() // stable IDs before matching
                sceneForShotImport = scene
            } label: {
                Label("Import Shots…", systemImage: "square.and.arrow.down.on.square")
            }
            .help("Copy the shots of a scene from a different script version into this scene")
        }
    }
}

struct TitleAndIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
                .font(.body)
            configuration.title
                .font(.body)
        }
    }
}
