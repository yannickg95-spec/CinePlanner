//
//  ReferenceCardView.swift
//  CinePlanner
//
//  One reference belonging to a shot: a photo or a video, optionally paired
//  with its own top-down map. Each card owns its pickers and metadata
//  extraction, so a shot can carry as many references as it needs.
//

import SwiftUI
import SwiftData
import PhotosUI
import AppKit
import UniformTypeIdentifiers

struct ReferenceCardView: View {
    @Bindable var reference: ShotReference
    let index: Int
    let totalCount: Int
    var onDelete: () -> Void

    @State private var isImportingImage = false
    @State private var isImportingMap = false
    @State private var previewImage: NSImage?
    @State private var previewTitle = ""

    /// Images cap at this width; metadata beneath them matches.
    private static let mediaMaxWidth: CGFloat = 700

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            // Photo and map side by side in equal columns, so both image boxes
            // are the same size and each metadata block is as wide as its picture.
            HStack(alignment: .top, spacing: 16) {
                mediaColumn.frame(maxWidth: .infinity, alignment: .leading)
                mapColumn.frame(maxWidth: .infinity, alignment: .leading)
            }

            if reference.hasMedia || reference.mapData != nil || reference.mapVideoData != nil {
                noteField
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
        .sheet(item: Binding(get: { previewImage.map { ImagePreview(image: $0, title: previewTitle) } },
                             set: { if $0 == nil { previewImage = nil } })) { preview in
            ImagePreviewSheet(preview: preview)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text(totalCount > 1 ? "REFERENCE \(index)" : "REFERENCE")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .kerning(0.5)

            matchChip

            if reference.isVideo {
                Text("VIDEO")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.15))
                    .foregroundStyle(Color.accentColor)
                    .clipShape(Capsule())
            }

            Spacer()

            // A shot always keeps at least one reference card, so the last one
            // can't be removed.
            if totalCount > 1 {
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Remove this reference")
            }
        }
    }

    /// Whether this reference's photo and its map came from the same capture.
    /// It describes this pair, so it belongs in this card rather than above them all.
    @ViewBuilder
    private var matchChip: some View {
        if let photoID = reference.captureID, let mapID = reference.mapCaptureID,
           reference.imageData != nil, reference.mapData != nil {
            let isMatch = photoID == mapID
            Label(isMatch ? "Matched" : "Not matched",
                  systemImage: isMatch ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.caption2)
                .fontWeight(.medium)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .foregroundStyle(isMatch ? Color.green : Color.orange)
                .background((isMatch ? Color.green : Color.orange).opacity(0.12))
                .clipShape(Capsule())
                .help(isMatch
                      ? "The photo and map were captured together"
                      : "The photo and map come from different captures")
        }
    }

    // MARK: - Note

    /// A short caption the user adds, shown under this reference's media in the
    /// PDF, the HTML export and the published web page.
    private var noteField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("NOTE")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .kerning(0.5)
            TextField("Add a caption — shown under this reference in exports",
                      text: Binding(get: { reference.note ?? "" },
                                    set: { reference.note = $0.isEmpty ? nil : $0 }),
                      axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
                .font(.subheadline)
        }
    }

    // MARK: - Media (photo or video)

    @ViewBuilder
    private var mediaColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let data = reference.videoData {
                ReferenceVideoView(
                    shotID: reference.uid,
                    videoData: data,
                    fileExtension: reference.videoExtension ?? "mov",
                    onDelete: {
                        reference.videoData = nil
                        reference.videoExtension = nil
                    }
                )
                .frame(maxWidth: .infinity)
            } else if let data = reference.imageData, let image = NSImage(data: data) {
                imageView(image, data: data, title: "Reference")
                if reference.imageMetadata.hasContent {
                    MetadataView(metadata: reference.imageMetadata)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                emptyMediaRow
            }
        }
    }

    /// Nothing added yet: one button offering either kind of media.
    private var emptyMediaRow: some View {
        Button {
            presentImporter($isImportingImage)
        } label: {
            addMediaLabel("Photo or Video", systemImage: "photo.badge.plus")
        }
        .buttonStyle(.plain)
        // Finder, not the Photos library: the Photos picker re-encodes the image
        // and drops the EXIF that carries the camera/lens metadata.
        .fileImporter(isPresented: $isImportingImage,
                      allowedContentTypes: [.image, .movie, .video, .quickTimeMovie, .mpeg4Movie],
                      allowsMultipleSelection: false) { result in
            handlePickedMedia(result)
        }
    }

    /// Shared dashed drop-zone label used by every "add media" button, so the
    /// photo, video and map placeholders read as one style.
    private func addMediaLabel(_ title: String, systemImage: String, tint: Color? = nil,
                               assetImage: String? = nil) -> some View {
        let fg = tint ?? .secondary
        return HStack(spacing: 8) {
            if let assetImage {
                Image(assetImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: systemImage)
                    .foregroundStyle(fg)
            }
            Text(title)
                .fontWeight(.medium)
                .foregroundStyle(fg)
            Spacer(minLength: 0)
            Text("Add")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .font(.subheadline)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke((tint ?? .secondary).opacity(tint == nil ? 0.3 : 0.55),
                        style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        }
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Map

    @ViewBuilder
    private var mapColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let data = reference.mapVideoData {
                ReferenceVideoView(
                    shotID: reference.uid + "-map",
                    videoData: data,
                    fileExtension: reference.mapVideoExtension ?? "mov",
                    onDelete: { clearMap() }
                )
                .frame(maxWidth: .infinity)
            } else if let data = reference.mapData, let image = NSImage(data: data) {
                imageView(image, data: data, title: "Top Down Map", isMap: true)
                if !reference.mapMetadata.mapDisplayItems.isEmpty {
                    TopDownMetadataView(metadata: reference.mapMetadata)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Button {
                    presentImporter($isImportingMap)
                } label: {
                    addMediaLabel("Map Image or Video", systemImage: "map")
                }
                .buttonStyle(.plain)
                .fileImporter(isPresented: $isImportingMap,
                              allowedContentTypes: [.image, .movie, .video, .quickTimeMovie, .mpeg4Movie],
                              allowsMultipleSelection: false) { result in
                    handlePickedMap(result)
                }
            }
        }
    }

    // MARK: - Shared image view

    private func imageView(_ image: NSImage, data: Data, title: String, isMap: Bool = false) -> some View {
        ZStack(alignment: .topTrailing) {
            // The picture is the button — clicking it opens the full size view,
            // so no separate enlarge control is needed. A fixed 4:3 box means the
            // reference and map boxes are identical regardless of the images'
            // own shapes; each image sits inside, scaled to fit.
            Button {
                previewTitle = title
                previewImage = image
            } label: {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.04))
                    .aspectRatio(4.0 / 3.0, contentMode: .fit)
                    .overlay {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .padding(3)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help("Click to view full size")

            Button {
                if isMap { clearMap() } else { clearImage() }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.white, .black)
                    .opacity(0.7)
                    .shadow(radius: 2)
            }
            .buttonStyle(.plain)
            .help(isMap ? "Remove map" : "Remove photo")
            .padding(8)
        }
    }

    // MARK: - Loading

    /// Opens a file importer, forcing a false→true transition. If a previous
    /// panel was dismissed without the flag being reset (a known SwiftUI
    /// fileImporter quirk), setting `true` again would be a no-op and the button
    /// would appear dead — clearing it first guarantees the change is seen.
    private func presentImporter(_ flag: Binding<Bool>) {
        flag.wrappedValue = false
        DispatchQueue.main.async { flag.wrappedValue = true }
    }

    /// Reads the file the user picked, honouring the security scope.
    private func readPickedFile(_ result: Result<[URL], Error>) -> Data? {
        guard case .success(let urls) = result, let url = urls.first else { return nil }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try? Data(contentsOf: url)
    }

    private func loadImage(data: Data) {
        ReferenceMediaLoader.loadImage(data, into: reference)
    }

    /// A picked map file may be an image or a video (e.g. a Shot Designer top-down
    /// animation), routed by its type.
    private func handlePickedMap(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }

        let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        if let type, type.conforms(to: .movie) || type.conforms(to: .video) {
            reference.mapData = nil            // the map is an image or a video, not both
            reference.mapVideoData = data
            reference.mapVideoExtension = url.pathExtension.isEmpty ? "mov" : url.pathExtension.lowercased()
        } else {
            reference.mapVideoData = nil
            reference.mapVideoExtension = nil
            loadMap(data: data)
        }
    }

    private func loadMap(data: Data) {
        reference.mapData = data
        guard let metadata = EXIFExtractor.extractMetadata(from: data) else { return }
        reference.mapCaptureID = metadata.captureID
        reference.mapCameraPhysicalWidth = metadata.cameraPhysicalWidth
        reference.mapCameraPhysicalLength = metadata.cameraPhysicalLength
        reference.mapLocationModel = metadata.locationModel
        reference.mapLocationWidth = metadata.locationWidth
        reference.mapLocationLength = metadata.locationLength
        reference.mapLocationHeight = metadata.locationHeight
    }

    /// Handles a picked file that may be a photo or a video, routing by its type.
    private func handlePickedMedia(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }

        let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        if let type, type.conforms(to: .movie) || type.conforms(to: .video) {
            reference.imageData = nil          // a reference holds one or the other
            reference.videoData = data
            reference.videoExtension = url.pathExtension.isEmpty ? "mov" : url.pathExtension.lowercased()
        } else {
            loadImage(data: data)              // sets imageData + extracts EXIF, clears video
        }
    }

    private func clearImage() {
        reference.imageData = nil
        reference.cameraFamily = nil
        reference.cameraFormat = nil
        reference.focalLength = nil
        reference.lensPreset = nil
        reference.horizon = nil
        reference.tilt = nil
        reference.height = nil
        reference.captureID = nil
        reference.captureType = nil
        reference.dateTimeOriginal = nil
        reference.keywords = nil
        reference.caption = nil
        reference.framelines = nil
        reference.software = nil
    }

    private func clearMap() {
        reference.mapData = nil
        reference.mapVideoData = nil
        reference.mapVideoExtension = nil
        reference.mapCaptureID = nil
        reference.mapCameraPhysicalWidth = nil
        reference.mapCameraPhysicalLength = nil
        reference.mapLocationModel = nil
        reference.mapLocationWidth = nil
        reference.mapLocationLength = nil
        reference.mapLocationHeight = nil
    }
}

// MARK: - Full size preview

struct ImagePreview: Identifiable {
    let image: NSImage
    let title: String
    var id: String { title + "\(image.size.width)x\(image.size.height)" }
}

struct ImagePreviewSheet: View {
    let preview: ImagePreview
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(preview.title)
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            Image(nsImage: preview.image)
                .resizable()
                .scaledToFit()
                .padding()
        }
        .frame(width: size.width, height: size.height)
    }

    /// Sizes to the image, capped to most of the screen, never smaller than the
    /// inline slot it was opened from.
    private var size: CGSize {
        let visible = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1600, height: 1000)
        let maxWidth = visible.width * 0.85
        let maxHeight = visible.height * 0.85
        let chrome: CGFloat = 96
        let floorWidth = min(900, maxWidth)
        let floorHeight = min(620, maxHeight)
        let s = preview.image.size
        guard s.width > 1, s.height > 1 else {
            return CGSize(width: floorWidth, height: floorHeight)
        }
        let scale = min(maxWidth / s.width, (maxHeight - chrome) / s.height)
        return CGSize(width: max(floorWidth, min(maxWidth, s.width * scale)),
                      height: max(floorHeight, min(maxHeight, s.height * scale + chrome)))
    }
}
