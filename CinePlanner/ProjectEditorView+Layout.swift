//
//  ProjectEditorView+Layout.swift
//  CinePlanner
//
//  The regular-width layout: the episode and version bar, and the resizable columns.
//

import SwiftUI
import SwiftData
import PhotosUI
import PDFKit

extension ProjectEditorView {
    // MARK: - Editor View

    var editorView: some View {
        VStack(spacing: 0) {
            // iPhone builds its own header (title + buttons + versions) inside
            // compactColumns; iPad/Mac keep the shared context bar here.
            if !isPhoneLayout {
                contextBar
                Divider()
            }
            editorColumns
        }
    }

    // MARK: - Context Bar (episode + script versions in one row)

    var contextBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // Episodes collapse into a menu so a 12-episode show stays compact
                if project.isSeries {
                    episodeMenu
                    Divider().frame(height: 18)
                }

                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundStyle(.secondary)
                Text("Script Version:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                ForEach(currentVersions, id: \.uid) { version in
                    versionTab(for: version)
                }

                Button {
                    addNewVersion()
                } label: {
                    Label("New Version", systemImage: "plus")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Add a new script version and import an updated screenplay")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color.platformControlBackground)
    }

    var episodeMenu: some View {
        ChipMenu(items:
            project.orderedEpisodes.map { episode in
                ChipMenuItem(title: episode.title, isSelected: selectedEpisode === episode) {
                    selectedEpisode = episode
                }
            }
            + [
                .divider,
                ChipMenuItem(title: "New Episode…", systemImage: "plus") { addEpisode() },
                ChipMenuItem(title: "Rename Episode…", systemImage: "pencil",
                             isDisabled: selectedEpisode == nil) {
                    if let episode = selectedEpisode {
                        renameText = episode.title
                        episodeToRename = episode
                    }
                },
                ChipMenuItem(title: "Delete Episode…", systemImage: "trash", role: .destructive,
                             isDisabled: project.episodes.count <= 1) {
                    episodePendingDeletion = selectedEpisode
                },
            ],
            // Opens below the button — it sits near the top of the window, so there's
            // little room above for the popover.
            arrowEdge: .top
        ) {
            HStack(spacing: 6) {
                Image(systemName: "tv")
                    .font(.caption)
                Text(selectedEpisode?.title ?? "Episode")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                if let shots = selectedEpisode?.totalShotCount, shots > 0 {
                    Text("\(shots) shots")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .fixedSize()
        .help("Switch episode, or add/rename/delete episodes")
    }

    @ViewBuilder
    func versionTab(for version: ScriptVersion) -> some View {
        let isSelected = selectedVersion === version
        Button {
            selectedVersion = version
        } label: {
            HStack(spacing: 6) {
                Text(version.name)
                    .font(.subheadline)
                    .fontWeight(isSelected ? .semibold : .regular)
                // iPhone keeps the chips compact — the per-version shot count is dropped.
                if !DeviceLayout.isPhone, version.totalShotCount > 0 {
                    Text("\(version.totalShotCount) shots")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
            .overlay(
                Capsule().stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: 1)
            )
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                renameText = version.name
                versionToRename = version
            } label: {
                Text("Rename…")
            }
            Divider()
            Button(role: .destructive) {
                versionPendingDeletion = version
            } label: {
                Text("Delete Version…")
            }
            .disabled(currentVersions.count <= 1)
        }
    }

    /// Sum of the columns' minimum widths (scenes + shots + detail + script + dividers).
    /// Keeps the window from ever being narrower than the layout needs — otherwise
    /// the columns get squeezed into (and clipped by) one another.
    var minimumEditorWidth: CGFloat {
        // Uses each pane's *minimum* (not its preferred width) so the window can
        // still shrink to fit smaller displays.
        (Self.sideColumnWidth * 2) + Self.paneMinWidth + Self.detailPaneMinWidth + Self.dividerAllowance
    }

    /// Scenes and shots share one fixed width. Both have predictable row content
    /// — the scene tag line ("EXT" + "NIGHT" + a three-digit shot count) is the
    /// widest thing either shows — so neither needs a resize handle, and a shared
    /// value keeps the two lists aligned with each other.
    static let sideColumnWidth: CGFloat = 190
    static let dividerAllowance: CGFloat = 12

    // Shot details and script split the space left over from the fixed columns.
    // Default 50/50; the divider may move up to 20% of the pair either way.
    static let scriptSplitDefault: CGFloat = 0.5
    static let scriptSplitMinFraction: CGFloat = 0.30
    static let scriptSplitMaxFraction: CGFloat = 0.70
    /// Script pane minimum — low, so the script can shrink to 30% (letting the
    /// details pane grow) on normal windows.
    static let paneMinWidth: CGFloat = 200
    /// Details pane minimum — set by its content (labelled fields), so the script
    /// only grows past 50% when the window is wide enough to leave this much room.
    static let detailPaneMinWidth: CGFloat = 340
    /// Shared height for the detail tab header and the script pane header.
    static let paneHeaderHeight: CGFloat = 44

    /// Space the details and script panes divide between them.
    func combinedPaneWidth(available: CGFloat) -> CGFloat {
        max(0, available - (Self.sideColumnWidth * 2) - Self.dividerAllowance)
    }

    /// The width range the script pane may be dragged to at the current window
    /// size: the ±20% band, clamped so neither pane drops below its minimum.
    func scriptWidthBounds(available: CGFloat) -> (min: CGFloat, max: CGFloat) {
        let combined = combinedPaneWidth(available: available)
        let low = max(Self.paneMinWidth, combined * Self.scriptSplitMinFraction)
        let high = min(combined - Self.detailPaneMinWidth, combined * Self.scriptSplitMaxFraction)
        return (min(low, high), max(low, high))
    }

    /// Derives the script pane's width from the stored fraction, clamped to the
    /// allowed band — so the split holds its proportion as the window resizes.
    func applyScriptSplit(available: CGFloat) {
        let combined = combinedPaneWidth(available: available)
        guard combined > 0 else { return }
        let bounds = scriptWidthBounds(available: available)
        scriptWidth = min(max(combined * scriptFraction, bounds.min), bounds.max)
    }

    @ViewBuilder
    var editorColumns: some View {
        if isPhoneLayout {
            compactColumns
        } else {
            regularColumns
        }
    }

    /// iPad + Mac: the resizable multi-column layout (unchanged).
    var regularColumns: some View {
        GeometryReader { geo in
            // On iPad in portrait there isn't room for three columns, so the script
            // pane is hidden — leaving Scenes and Shots/Scene Map. macOS always
            // shows it.
            #if os(iOS)
            let showScript = geo.size.width >= geo.size.height
            #else
            let showScript = true
            #endif
            editorColumnStack(available: geo.size.width, showScript: showScript)
                .onAppear {
                    // Seed here, right before deriving the width, so the order
                    // relative to the view's own onAppear can't matter.
                    scriptFraction = min(max(CGFloat(project.scriptSplitFraction),
                                             Self.scriptSplitMinFraction), Self.scriptSplitMaxFraction)
                    applyScriptSplit(available: geo.size.width)
                }
                .onChange(of: geo.size.width) { _, newWidth in
                    // Re-derive from the fraction so the split holds as the window resizes.
                    applyScriptSplit(available: newWidth)
                }
        }
        #if os(macOS)
        // Keep the macOS window from shrinking below what the columns need. On iPad
        // the editor sizes to the screen instead (forcing this width would overflow
        // a portrait iPad and leave the divider no room to move).
        .frame(minWidth: minimumEditorWidth, minHeight: 700)
        #endif
    }
}

struct ResizableDivider: View {
    @Binding var width: CGFloat
    let minWidth: CGFloat
    let maxWidth: CGFloat
    /// When the resized pane sits to the *right* of the divider, dragging left
    /// should make it wider — so the translation is inverted.
    var invertDrag: Bool = false
    /// Called once when the drag ends, so the width can be persisted without
    /// writing to the store on every frame of the drag.
    var onCommit: ((CGFloat) -> Void)? = nil
    
    @State private var isDragging = false
    @State private var dragStartWidth: CGFloat?

    var body: some View {
        Rectangle()
            .fill(Color.secondary.opacity(isDragging ? 0.3 : 0.2))
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .overlay {
                // Hit area wider than the 1pt line so it's easy to grab — and wider
                // still on iPad, where a fingertip needs a bigger target than a cursor.
                #if os(iOS)
                let hitWidth: CGFloat = 36
                #else
                let hitWidth: CGFloat = 12
                #endif
                ZStack {
                    Rectangle()
                        .fill(Color.clear)
                        .frame(width: hitWidth)
                        .contentShape(Rectangle())
                    // A visible grip pill with three dots, so it's obvious the
                    // divider can be dragged. Doesn't intercept the drag itself.
                    RoundedRectangle(cornerRadius: 3.5)
                        .fill(.regularMaterial)
                        .overlay(RoundedRectangle(cornerRadius: 3.5)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5))
                        .overlay {
                            VStack(spacing: 3) {
                                ForEach(0..<3, id: \.self) { _ in
                                    Circle().fill(Color.secondary.opacity(0.6))
                                        .frame(width: 2.5, height: 2.5)
                                }
                            }
                        }
                        .frame(width: 7, height: 46)
                        .shadow(color: .black.opacity(0.12), radius: 1.5, y: 0.5)
                        .opacity(isDragging ? 1 : 0.9)
                        .allowsHitTesting(false)
                }
            }
            .onHover { hovering in
                // Pointer feedback for the drag handle — macOS only (no cursor on iPad).
                #if os(macOS)
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
                #endif
            }
            .gesture(
                // MUST be measured in a coordinate space that doesn't move with the
                // divider. In the default `.local` space, widening the column shifts
                // the divider, which changes the reported translation, which resizes
                // again — a feedback loop that makes the drag oscillate.
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        // `translation` is cumulative from the start of the drag, so it
                        // must be applied to the width as it was when the drag began —
                        // adding it to the running width compounds and snaps to the limit.
                        if dragStartWidth == nil { dragStartWidth = width }
                        isDragging = true
                        let base = dragStartWidth ?? width
                        let delta = invertDrag ? -value.translation.width : value.translation.width
                        width = min(max(base + delta, minWidth), maxWidth)
                    }
                    .onEnded { _ in
                        isDragging = false
                        dragStartWidth = nil
                        onCommit?(width)
                    }
            )
    }
}
