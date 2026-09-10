//
//  CineStagerLibrary.swift
//  CinePlanner
//
//  Reads the shot library that CineStager (the AR viewfinder app) syncs to its
//  iCloud Drive container. CineStager stores plain files:
//    <ubiquity>/Documents/shots.json          — array of ShotItem
//    <ubiquity>/Documents/ShotLibrary/*.jpg    — stills, videos, top-down maps
//    <ubiquity>/Documents/ShotThumbnails/*.jpg — thumbnails
//
//  Because both apps are on the same Apple team, CinePlanner can declare
//  CineStager's container in its iCloud entitlement and read these files
//  directly — no changes to CineStager, no manual export.
//
//  Requires the iCloud capability with the container below. Until that's set up
//  (or if iCloud is signed out), the container URL is nil and `state` is
//  `.unavailable` — the UI explains how to enable it.
//

import Foundation
import Combine

/// One shot from CineStager's library — mirrors CineStager's `ShotItem` so the
/// same `shots.json` decodes directly.
struct CineStagerShot: Codable, Identifiable {
    let id: UUID
    let captureID: String
    let type: String            // "image" | "video"
    let mode: String            // "ar" | "game"
    let timestamp: Date
    let fileName: String
    let thumbnailFileName: String?
    let topDownMapFileName: String?
    /// Top-down map of the location model only — no camera/mannequin/actor
    /// markers. Used as the scene-map background in CinePlanner.
    let cleanMapFileName: String?
    let cameraFamily: String
    let cameraFormat: String
    let framelines: String?
    let focalLengthMM: Int?
    let lensPresetName: String?
    let pitchDeg: Double?
    let rollDeg: Double?
    let yawDeg: Double?
    let heightCM: Double?
    let locationModelName: String?
    let durationSeconds: Double?
    /// Active sensor size (mm) of the format the shot was framed on. Optional —
    /// older captures predate it.
    let sensorWidthMM: Double?
    let sensorHeightMM: Double?
    /// Camera→nearest-mannequin distance (m) at capture — lets CinePlanner judge
    /// framing without a top-down map / location model. Optional (newer captures).
    let subjectDistanceM: Double?

    var isVideo: Bool { type == "video" }
    var hasMap: Bool { topDownMapFileName != nil }
}

@MainActor
final class CineStagerLibrary: ObservableObject {
    /// CineStager's iCloud Drive container (its entitlement declares this id).
    static let containerID = "iCloud.YannickGiraud.CinemaAR"

    enum LoadState: Equatable { case loading, unavailable, loaded }

    @Published private(set) var state: LoadState = .loading
    @Published private(set) var shots: [CineStagerShot] = []

    private var documentsURL: URL?
    private var shotsDir: URL? { documentsURL?.appendingPathComponent("ShotLibrary") }
    private var thumbsDir: URL? { documentsURL?.appendingPathComponent("ShotThumbnails") }
    private var metadataURL: URL? { documentsURL?.appendingPathComponent("shots.json") }

    /// Resolves the shared container (off the main thread — it can block) and
    /// loads the shot metadata.
    func refresh() async {
        state = .loading
        let containerID = Self.containerID
        let url = await Task.detached { () -> URL? in
            FileManager.default.url(forUbiquityContainerIdentifier: containerID)?
                .appendingPathComponent("Documents")
        }.value

        guard let url else {
            documentsURL = nil
            shots = []
            state = .unavailable
            return
        }
        documentsURL = url
        // Wake iCloud so it learns about files CineStager added since we last looked.
        // Without this, `startDownloadingUbiquitousItem` trusts stale local metadata
        // that still says shots.json is current, and we read yesterday's list.
        await syncMetadata(in: url)
        await loadShots()
    }

    /// Runs a one-shot metadata query over the shared container so the iCloud daemon
    /// reports the current state of its files (and starts pulling newer versions)
    /// before we read them. Returns once the first gather finishes, or after a short
    /// timeout so a stalled query never blocks the refresh.
    private func syncMetadata(in documents: URL, timeout: TimeInterval = 8) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let query = NSMetadataQuery()
            query.searchScopes = [documents]
            query.predicate = NSPredicate(format: "%K LIKE %@", NSMetadataItemFSNameKey, "*")
            var finished = false
            var observer: NSObjectProtocol?
            func finish() {
                guard !finished else { return }
                finished = true
                if let observer { NotificationCenter.default.removeObserver(observer) }
                query.stop()
                continuation.resume()
            }
            observer = NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main
            ) { _ in finish() }
            query.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish() }
        }
    }

    private func loadShots() async {
        guard let metadataURL else { state = .unavailable; return }
        try? await ensureDownloaded(metadataURL)
        guard let data = await coordinatedRead(metadataURL) else {
            shots = []
            state = .loaded          // container reachable, just nothing captured yet
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601   // matches CineStager's encoder
        let decoded = (try? decoder.decode([CineStagerShot].self, from: data)) ?? []
        shots = decoded.sorted { $0.timestamp > $1.timestamp }
        state = .loaded
    }

    // MARK: - File access

    func imageURL(for shot: CineStagerShot) -> URL? {
        shotsDir?.appendingPathComponent(shot.fileName)
    }
    func mapURL(for shot: CineStagerShot) -> URL? {
        shot.topDownMapFileName.flatMap { shotsDir?.appendingPathComponent($0) }
    }
    func cleanMapURL(for shot: CineStagerShot) -> URL? {
        shot.cleanMapFileName.flatMap { shotsDir?.appendingPathComponent($0) }
    }
    func thumbnailURL(for shot: CineStagerShot) -> URL? {
        shot.thumbnailFileName.flatMap { thumbsDir?.appendingPathComponent($0) }
    }

    /// Downloads the item if it's still cloud-only, then returns its bytes.
    func data(at url: URL?) async -> Data? {
        guard let url else { return nil }
        try? await ensureDownloaded(url)
        return await coordinatedRead(url)
    }

    /// Reads a file through NSFileCoordinator (off the main thread) so a running
    /// process gets the current iCloud version rather than a stale cached one —
    /// important when CineStager replaces shots.json after a new capture.
    private func coordinatedRead(_ url: URL) async -> Data? {
        await Task.detached {
            var data: Data?
            var coordinationError: NSError?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
                data = try? Data(contentsOf: readURL)
            }
            return data
        }.value
    }

    /// Best thumbnail bytes for a shot — the small thumbnail, falling back to the
    /// full image.
    func thumbnailData(for shot: CineStagerShot) async -> Data? {
        if let t = await data(at: thumbnailURL(for: shot)) { return t }
        return await data(at: imageURL(for: shot))
    }

    // MARK: - iCloud download

    private func ensureDownloaded(_ url: URL, timeout: TimeInterval = 60) async throws {
        if isDownloaded(url) { return }
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isDownloaded(url) { return }
            try await Task.sleep(nanoseconds: 400_000_000)
        }
        throw NSError(domain: "CineStager", code: -1,
                      userInfo: [NSLocalizedDescriptionKey: "iCloud file download timed out."])
    }

    private func isDownloaded(_ url: URL) -> Bool {
        if let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            .ubiquitousItemDownloadingStatus {
            return status == .current
        }
        return FileManager.default.fileExists(atPath: url.path)
    }
}
