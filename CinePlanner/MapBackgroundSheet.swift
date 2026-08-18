//
//  MapBackgroundSheet.swift
//  CinePlanner
//
//  A live satellite map the user pans to position a location, with a resizable
//  capture frame (set by the metres slider) drawn on it. The framed square is
//  captured as the scene-map background. The capture size is independent of the
//  map's zoom, so it can go tighter than MapKit's max satellite zoom (rendered
//  then cropped to scale).
//

import SwiftUI
import MapKit
import CoreLocation

struct MapBackgroundSheet: View {
    /// Called with the rendered PNG, the captured centre coordinate + size, and an
    /// optional location label (the address).
    var onBackground: (Data, CLLocationCoordinate2D, Double, String?) -> Void
    /// When true, the map is pinned to `initialCoordinate` and can't be panned —
    /// used for "Rescale", where only the capture size changes and the location
    /// stays put (so markers only re-scale, never translate).
    var lockToCenter: Bool = false

    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var recenter: CLLocationCoordinate2D?
    @State private var visibleRect = MKMapRect.null
    @State private var meters: Double
    /// Mirrors `meters` but updates only when the slider drag *ends* — so showing
    /// or hiding the preview panel (and resizing the sheet) can't move the slider
    /// out from under the cursor mid-drag.
    @State private var layoutMeters: Double

    /// `initialCoordinate`/`initialMeters` reopen the picker where it was last set.
    init(initialCoordinate: CLLocationCoordinate2D? = nil,
         initialMeters: Double? = nil,
         lockToCenter: Bool = false,
         onBackground: @escaping (Data, CLLocationCoordinate2D, Double, String?) -> Void) {
        self.onBackground = onBackground
        self.lockToCenter = lockToCenter
        _recenter = State(initialValue: initialCoordinate)
        _meters = State(initialValue: initialMeters ?? 60)
        _layoutMeters = State(initialValue: initialMeters ?? 60)
    }
    @State private var geocoding = false
    @State private var rendering = false
    @State private var errorMessage: String?
    @State private var previewImage: PlatformImage?
    @State private var previewLoading = false
    @State private var previewTask: Task<Void, Never>?

    private let panelSide: CGFloat = 400
    /// The capture preview is always shown, beside the map.
    private var showsPreview: Bool { true }
    /// Width for the map panel plus the always-present preview panel.
    private var sheetWidth: CGFloat { panelSide * 2 + 44 }

    private var centerCoordinate: CLLocationCoordinate2D? {
        visibleRect.isNull ? nil : MKMapPoint(x: visibleRect.midX, y: visibleRect.midY).coordinate
    }
    private var visibleMeters: Double { visibleRect.isNull ? 0 : MapSnapshot.metersWide(visibleRect) }

    /// Capture-size range (metres).
    private static let captureMin = 10.0
    private static let captureMax = 400.0
    /// Maps `meters` geometrically onto the slider's 0…1, so small sizes take up
    /// more of the track (finer control) and large sizes grow faster.
    private var captureSizeBinding: Binding<Double> {
        Binding(
            get: {
                let t = log(meters / Self.captureMin) / log(Self.captureMax / Self.captureMin)
                return min(max(t, 0), 1)
            },
            set: { t in
                let raw = Self.captureMin * pow(Self.captureMax / Self.captureMin, t)
                // Snap to a tidy step that scales with magnitude.
                let step: Double = raw < 30 ? 1 : (raw < 100 ? 5 : 10)
                meters = min(max((raw / step).rounded() * step, Self.captureMin), Self.captureMax)
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Satellite Background").font(.title3.bold())
                Spacer()
                Button("Cancel") { dismiss() }
            }
            .padding(16)
            Divider()

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search an address or place", text: $address).textFieldStyle(.plain)
                    .onSubmit { geocode() }
                if geocoding { ProgressView().controlSize(.small) }
                Button("Go") { geocode() }
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || geocoding)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)

            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    MapPreview(recenter: recenter, visibleRect: $visibleRect,
                               spanMeters: max(meters * 2.5, 80), scrollEnabled: !lockToCenter)
                    captureFrame(in: CGSize(width: panelSide, height: panelSide))
                }
                .frame(width: panelSide, height: panelSide)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onChange(of: previewKey) { schedulePreview() }

                if showsPreview { previewPanel }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)

            HStack(spacing: 12) {
                Text("Capture size")
                // Exponential (geometric) slider: fine control at small distances,
                // faster growth toward the wide end.
                Slider(value: captureSizeBinding, in: 0...1) { editing in
                    if !editing { layoutMeters = meters }
                }
                Text("\(Int(meters)) m").monospacedDigit().frame(width: 52, alignment: .trailing)
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            .onChange(of: layoutMeters) { schedulePreview() }

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
                    .padding(.horizontal, 18).padding(.bottom, 4)
            }

            Divider()
            HStack {
                Text(lockToCenter
                     ? "Adjust the capture size; the location stays fixed so markers keep their place."
                     : "Drag the map to position; the white square is captured.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { render() } label: {
                    if rendering { ProgressView().controlSize(.small) } else { Text("Add Background") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(centerCoordinate == nil || rendering)
            }
            .padding(16)
        }
        #if os(macOS)
        .adaptiveSheetFrame(width: sheetWidth, height: 640)
        #endif
    }

    /// The capture-frame overlay: everything outside the framed square is dimmed
    /// (a crop-tool mask) so the small captured area stands out clearly.
    @ViewBuilder
    private func captureFrame(in size: CGSize) -> some View {
        let raw = visibleMeters > 0 ? min(size.width, size.height) * CGFloat(meters / visibleMeters)
                                    : min(size.width, size.height)
        let side = min(max(raw, 0), min(size.width, size.height))
        let rect = CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side)
        ZStack {
            // Dim outside the square (even-odd fill leaves the square clear).
            Path { p in
                p.addRect(CGRect(origin: .zero, size: size))
                p.addRoundedRect(in: rect, cornerSize: CGSize(width: 6, height: 6))
            }
            .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.white, lineWidth: 2)
                .frame(width: side, height: side)
        }
        .allowsHitTesting(false)
    }

    /// Magnified preview of exactly what will be captured, beside the map (shown
    /// only for small captures), upscaled so a small square is legible.
    private var previewPanel: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.15))
                if let previewImage {
                    Image(platformImage: previewImage).resizable().scaledToFill()
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                if previewLoading { ProgressView().controlSize(.small) }
            }
            .frame(width: panelSide, height: panelSide)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.35), lineWidth: 1))
            Text("Capture preview").font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Coarse key so the preview re-renders only when the framed area meaningfully
    /// changes (not on every sub-pixel pan).
    private var previewKey: String {
        visibleRect.isNull ? "" : "\(Int(visibleRect.midX))-\(Int(visibleRect.midY))-\(Int(meters))"
    }

    /// Debounced: renders the capture ~0.35s after the last change.
    private func schedulePreview() {
        previewTask?.cancel()
        guard showsPreview, let center = centerCoordinate else { previewImage = nil; return }
        let captureMeters = meters
        previewTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            if Task.isCancelled { return }
            previewLoading = true
            let image = try? await MapSnapshot.satelliteImage(coordinate: center, meters: captureMeters, pixels: 500)
            if Task.isCancelled { return }
            previewImage = image
            previewLoading = false
        }
    }

    private func geocode() {
        let query = address.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        geocoding = true
        errorMessage = nil
        CLGeocoder().geocodeAddressString(query) { placemarks, error in
            geocoding = false
            if let loc = placemarks?.first?.location {
                recenter = loc.coordinate
                return
            }
            errorMessage = Self.geocodeMessage(for: error, query: query)
        }
    }

    /// Turns a `CLGeocoder` failure into plain language. The common one is
    /// `kCLErrorGeocodeFoundNoResult` (CLError code 8) — Apple surfaces it as the
    /// opaque "The operation couldn't be completed. (kCLErrorDomain error 8.)",
    /// which reads like a crash to the user. Returns `nil` when there's nothing
    /// worth showing (a search superseded by a newer one).
    private static func geocodeMessage(for error: Error?, query: String) -> String? {
        if let clError = error as? CLError {
            switch clError.code {
            case .geocodeFoundNoResult, .geocodeFoundPartialResult:
                return "No place found for “\(query)”. Try a more specific address, a city, or coordinates."
            case .network:
                return "Couldn't reach the map service. Check your connection and try again."
            case .geocodeCanceled:
                return nil
            default:
                break
            }
        }
        return error?.localizedDescription ?? "No place found for “\(query)”."
    }

    private func render() {
        guard let center = centerCoordinate else { return }
        rendering = true
        errorMessage = nil
        let captureMeters = meters
        Task {
            do {
                let image = try await MapSnapshot.satelliteImage(coordinate: center, meters: captureMeters)
                guard let data = image.pngRepresentation() else {
                    throw NSError(domain: "MapSnapshot", code: -1,
                                  userInfo: [NSLocalizedDescriptionKey: "Couldn't encode the image."])
                }
                rendering = false
                let label = address.trimmingCharacters(in: .whitespaces)
                onBackground(data, center, captureMeters, label.isEmpty ? nil : label)
                dismiss()
            } catch {
                rendering = false
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// A live satellite MKMapView. Reports its visible rect as the user pans/zooms,
/// and recenters when `recenter` changes (keeping the current zoom).
private struct MapPreview {
    var recenter: CLLocationCoordinate2D?
    @Binding var visibleRect: MKMapRect
    /// Metres across to frame the map on open — roughly the capture size plus
    /// context, so the white capture square is prominent and panning the map moves
    /// the capture proportionally (not amplified as it was at a fixed wide zoom).
    var spanMeters: Double = 300
    /// When false the map can't be panned (Rescale keeps the location fixed).
    var scrollEnabled: Bool = true

    /// Shared setup for both the AppKit and UIKit representable conformances.
    func makeMap(_ coordinator: Coordinator) -> MKMapView {
        let map = MKMapView()
        map.mapType = .satellite
        map.delegate = coordinator
        map.isScrollEnabled = scrollEnabled
        #if os(macOS)
        map.showsZoomControls = true
        #endif
        map.showsCompass = true
        let start = recenter ?? CLLocationCoordinate2D(latitude: 52.3702, longitude: 4.8952)
        map.setRegion(MKCoordinateRegion(center: start, latitudinalMeters: spanMeters, longitudinalMeters: spanMeters), animated: false)
        // Treat the starting centre as already applied so it isn't re-animated.
        coordinator.lastRecenter = recenter
        return map
    }

    func applyRecenter(_ map: MKMapView, _ coordinator: Coordinator) {
        if let recenter,
           coordinator.lastRecenter?.latitude != recenter.latitude
            || coordinator.lastRecenter?.longitude != recenter.longitude {
            coordinator.lastRecenter = recenter
            var region = map.region
            region.center = recenter
            map.setRegion(region, animated: true)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, MKMapViewDelegate {
        let parent: MapPreview
        var lastRecenter: CLLocationCoordinate2D?
        init(_ parent: MapPreview) { self.parent = parent }
        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            parent.visibleRect = mapView.visibleMapRect
        }
    }
}

#if canImport(UIKit)
extension MapPreview: UIViewRepresentable {
    func makeUIView(context: Context) -> MKMapView { makeMap(context.coordinator) }
    func updateUIView(_ map: MKMapView, context: Context) { applyRecenter(map, context.coordinator) }
}
#else
extension MapPreview: NSViewRepresentable {
    func makeNSView(context: Context) -> MKMapView { makeMap(context.coordinator) }
    func updateNSView(_ map: MKMapView, context: Context) { applyRecenter(map, context.coordinator) }
}
#endif
