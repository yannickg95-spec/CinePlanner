//
//  MapBackgroundSheet.swift
//  CinePlanner
//
//  Picks *where in the world* a scene's map is: a live satellite map the user pans
//  to a location, with a capture frame drawn on it. The framed square is rendered
//  as the scene-map background.
//
//  The capture size is deliberately independent of MapKit's zoom, so it can go
//  tighter than the max satellite zoom (rendered wide, then cropped to scale by
//  `MapSnapshot`). The map's region follows the size slider, so the frame on screen
//  always shows the true capture area rather than clamping to the panel edge.
//
//  Adjusting the framing of a map that's *already* set doesn't happen here — that's
//  done on the canvas itself, by panning and zooming the scene map.
//

import SwiftUI
import MapKit
import CoreLocation

struct MapBackgroundSheet: View {
    /// Called with the rendered PNG, the captured centre coordinate + size, and an
    /// optional location label (the place name at that centre).
    var onBackground: (Data, CLLocationCoordinate2D, Double, String?) -> Void
    /// The capture this map already has, when it has one. Used to tell the user
    /// which of two things is about to happen to what they've placed on it.
    var existingCapture: SatelliteFraming?
    /// How many markers are on the map, so the warning can be concrete.
    var markerCount = 0

    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var recenter: CLLocationCoordinate2D?
    @State private var visibleRect = MKMapRect.null
    @State private var meters: Double

    /// `initialCoordinate`/`initialMeters` reopen the picker where it was last set.
    init(initialCoordinate: CLLocationCoordinate2D? = nil,
         initialMeters: Double? = nil,
         existingCapture: SatelliteFraming? = nil,
         markerCount: Int = 0,
         onBackground: @escaping (Data, CLLocationCoordinate2D, Double, String?) -> Void) {
        self.onBackground = onBackground
        self.existingCapture = existingCapture
        self.markerCount = markerCount
        _recenter = State(initialValue: initialCoordinate)
        _meters = State(initialValue: initialMeters ?? 60)
    }

    @State private var geocoding = false
    @State private var rendering = false
    @State private var errorMessage: String?
    /// Place name looked up for whatever the map is centred on now — the honest
    /// label for the capture, rather than whatever was last typed in the search box.
    @State private var placeName: String?
    @State private var placeTask: Task<Void, Never>?

    private let panelSide: CGFloat = 420
    private var sheetWidth: CGFloat { panelSide + 32 }

    private var centerCoordinate: CLLocationCoordinate2D? {
        visibleRect.isNull ? nil : MKMapPoint(x: visibleRect.midX, y: visibleRect.midY).coordinate
    }
    private var visibleMeters: Double { visibleRect.isNull ? 0 : MapSnapshot.metersWide(visibleRect) }

    /// Capture-size range (metres).
    private static let captureMin = 10.0
    private static let captureMax = 400.0
    /// How much map to show around the capture. The frame is exactly
    /// 1/`contextFactor` of the panel, so this single number decides how large the
    /// capture reads against its surroundings: 1.6 gives the frame most of the panel
    /// while keeping a band of context to position by. Lower it for a bigger frame,
    /// raise it for more surroundings.
    private static let contextFactor = 1.6

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

            mapPanel
                .padding(.horizontal, 16)
                .padding(.top, 12)

            HStack(spacing: 12) {
                Text("Capture size")
                // Exponential (geometric) slider: fine control at small distances,
                // faster growth toward the wide end.
                Slider(value: captureSizeBinding, in: 0...1)
                Text("\(Int(meters)) m").monospacedDigit().frame(width: 52, alignment: .trailing)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
                    .padding(.horizontal, 18).padding(.bottom, 8)
            } else if let notice = markerNotice {
                Label(notice.text, systemImage: notice.isWarning
                      ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(notice.isWarning ? Color.orange : Color.secondary)
                    .padding(.horizontal, 18).padding(.bottom, 8)
            }

            Divider()
            HStack {
                Label(placeName ?? "Drag the map to position", systemImage: "mappin.and.ellipse")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button { render() } label: {
                    if rendering { ProgressView().controlSize(.small) } else { Text("Add Background") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(centerCoordinate == nil || rendering)
            }
            .padding(16)
        }
        .adaptiveSheetFrame(width: sheetWidth, height: 700)
    }

    /// The map, its capture frame, the search field and (when the frame is small)
    /// a close-up of what will actually be captured.
    private var mapPanel: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                MapPreview(recenter: recenter, spanMeters: requestedSpan,
                           visibleRect: $visibleRect)
                captureFrame(in: CGSize(width: side, height: side))
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .top) { searchField.padding(10).frame(width: side) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: mapKey) { schedulePlaceName() }
        }
        .frame(height: DeviceLayout.isPhone ? nil : panelSide)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search an address or place", text: $address)
                .textFieldStyle(.plain)
                .onSubmit { geocode() }
            if geocoding { ProgressView().controlSize(.small) }
            Button("Go") { geocode() }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || geocoding)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.secondary.opacity(0.25), lineWidth: 1))
    }

    /// What replacing the background will do to what's already on the map.
    ///
    /// Two different things can happen, and which one depends on where the user
    /// lands — so this reads the framing rather than warning in the abstract.
    /// Overlapping the old capture means the markers belong to ground the new one
    /// still covers, so they stay on it; somewhere else entirely means that ground
    /// is gone, and they come along keeping their layout instead of being flung off
    /// the map.
    private var markerNotice: (text: String, isWarning: Bool)? {
        guard markerCount > 0, let existing = existingCapture,
              let center = centerCoordinate else { return nil }
        let target = SatelliteFraming(center: center, meters: meters)
        let things = markerCount == 1 ? "marker" : "markers"
        if existing.overlaps(target) {
            return ("Your \(markerCount) \(things) keep their place on the ground.", false)
        }
        return ("A different location: your \(markerCount) \(things) come along, keeping their layout.", true)
    }

    /// The span the panel is meant to show: the capture plus context.
    private var requestedSpan: Double { meters * Self.contextFactor }

    /// The on-screen size of the capture frame, as a fraction of the map panel.
    ///
    /// A constant, and it has to be: measuring it as `meters / visibleMeters` divides
    /// two values that arrive at different moments. Dragging the slider moves
    /// `meters` a step ahead of the span the map has answered with, and the frame
    /// swelled by half on every drag — the size the map is *asked* for and the size
    /// it has *confirmed* are never in step mid-gesture.
    ///
    /// The panel is defined as `contextFactor` times the capture, and the slider is
    /// the only thing that sets that scale (map zoom is off, so nothing else can
    /// move it), which makes this fraction exactly true rather than merely stable.
    private var frameFraction: CGFloat { CGFloat(1 / Self.contextFactor) }

    /// The capture-frame overlay: everything outside the framed square is dimmed
    /// (a crop-tool mask) so the captured area stands out clearly.
    @ViewBuilder
    private func captureFrame(in size: CGSize) -> some View {
        let side = min(size.width, size.height) * frameFraction
        let rect = CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2,
                          width: side, height: side)
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

    /// Coarse key so the place lookup fires only when the framed area meaningfully
    /// changes (not on every sub-pixel of a pan).
    private var mapKey: String {
        visibleRect.isNull ? "" : "\(Int(visibleRect.midX))-\(Int(visibleRect.midY))-\(Int(meters))"
    }

    /// Debounced reverse geocode of the map's centre, so the saved label describes
    /// where the capture actually is — not whatever was last typed in the search box.
    private func schedulePlaceName() {
        placeTask?.cancel()
        guard let center = centerCoordinate else { placeName = nil; return }
        placeTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            if Task.isCancelled { return }
            let location = CLLocation(latitude: center.latitude, longitude: center.longitude)
            let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first
            if Task.isCancelled { return }
            placeName = placemark.map(Self.describe)
        }
    }

    /// A short, human place name: street and city where available, else whatever the
    /// placemark does carry.
    private static func describe(_ placemark: CLPlacemark) -> String {
        let street = [placemark.thoroughfare, placemark.subThoroughfare]
            .compactMap { $0 }.joined(separator: " ")
        let parts = [street.isEmpty ? placemark.name : street, placemark.locality]
            .compactMap { $0 }
        var seen = Set<String>()
        let unique = parts.filter { seen.insert($0).inserted }
        return unique.isEmpty ? (placemark.country ?? "") : unique.joined(separator: ", ")
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
        let label = placeName ?? {
            let typed = address.trimmingCharacters(in: .whitespaces)
            return typed.isEmpty ? nil : typed
        }()
        Task {
            do {
                let image = try await MapSnapshot.satelliteImage(coordinate: center, meters: captureMeters)
                guard let data = image.pngRepresentation() else {
                    throw NSError(domain: "MapSnapshot", code: -1,
                                  userInfo: [NSLocalizedDescriptionKey: "Couldn't encode the image."])
                }
                rendering = false
                onBackground(data, center, captureMeters, label)
                dismiss()
            } catch {
                rendering = false
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// A live satellite MKMapView. Reports its visible rect as the user pans/zooms,
/// recenters when `recenter` changes, and re-frames when `spanMeters` changes — so
/// the capture-size slider always leaves the frame visible on screen.
private struct MapPreview {
    var recenter: CLLocationCoordinate2D?
    /// Metres across to frame the map on: the capture size plus context, so the
    /// capture square is prominent and panning moves it proportionally.
    var spanMeters: Double
    @Binding var visibleRect: MKMapRect

    /// Shared setup for both the AppKit and UIKit representable conformances.
    func makeMap(_ coordinator: Coordinator) -> MKMapView {
        let map = MKMapView()
        map.mapType = .satellite
        map.delegate = coordinator
        // By default a map view refuses to be *set* closer than about 76 m across a
        // 420-point panel — not because it can't draw it (it happily does when the
        // region is set before layout), but because `setRegion` honours
        // `cameraZoomRange`. Left alone, the panel would stop following the capture
        // slider the moment it was touched. Widening the range lets it follow all
        // the way down.
        if let range = MKMapView.CameraZoomRange(minCenterCoordinateDistance: 1) {
            map.cameraZoomRange = range
        }
        // The capture slider owns the scale: it sets the capture size and the panel
        // is always `contextFactor` times that, which is what lets the frame be a
        // fixed viewfinder. A second way to zoom would break that promise — and
        // zooming the map wouldn't change the capture anyway. Panning stays: that's
        // how the location is chosen.
        map.isZoomEnabled = false
        #if os(macOS)
        map.showsZoomControls = true
        #endif
        map.showsCompass = true
        let start = recenter ?? CLLocationCoordinate2D(latitude: 52.3702, longitude: 4.8952)
        map.setRegion(MKCoordinateRegion(center: start, latitudinalMeters: spanMeters,
                                         longitudinalMeters: spanMeters), animated: false)
        // Treat the starting framing as already applied so it isn't re-animated.
        coordinator.lastRecenter = recenter
        coordinator.lastSpan = spanMeters
        return map
    }

    func applyUpdates(_ map: MKMapView, _ coordinator: Coordinator) {
        var center = map.region.center
        var changed = false
        if let recenter,
           coordinator.lastRecenter?.latitude != recenter.latitude
            || coordinator.lastRecenter?.longitude != recenter.longitude {
            coordinator.lastRecenter = recenter
            center = recenter
            changed = true
        }
        // A capture-size change re-frames the map, so the frame on screen keeps
        // showing the true capture area instead of running past the panel edge.
        if abs(coordinator.lastSpan - spanMeters) > 0.5 {
            coordinator.lastSpan = spanMeters
            changed = true
        }
        guard changed else { return }
        map.setRegion(MKCoordinateRegion(center: center, latitudinalMeters: spanMeters,
                                         longitudinalMeters: spanMeters), animated: false)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, MKMapViewDelegate {
        let parent: MapPreview
        var lastRecenter: CLLocationCoordinate2D?
        var lastSpan: Double = 0
        init(_ parent: MapPreview) { self.parent = parent }
        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            // Hop off the current cycle before writing. `applyUpdates` calls
            // `setRegion` from inside SwiftUI's view update, and MapKit answers by
            // calling this synchronously — so a direct write here is a state change
            // during a view update, which SwiftUI drops. The sheet was then left
            // measuring the *previous* span until something else forced a redraw,
            // which is why the frame resized the moment the map was dragged.
            let rect = mapView.visibleMapRect
            let parent = self.parent
            DispatchQueue.main.async { parent.visibleRect = rect }
        }
    }
}

#if canImport(UIKit)
extension MapPreview: UIViewRepresentable {
    func makeUIView(context: Context) -> MKMapView { makeMap(context.coordinator) }
    func updateUIView(_ map: MKMapView, context: Context) { applyUpdates(map, context.coordinator) }
}
#else
extension MapPreview: NSViewRepresentable {
    func makeNSView(context: Context) -> MKMapView { makeMap(context.coordinator) }
    func updateNSView(_ map: MKMapView, context: Context) { applyUpdates(map, context.coordinator) }
}
#endif
