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
    /// Called with the rendered PNG and an optional location label (the address).
    var onBackground: (Data, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var recenter: CLLocationCoordinate2D?
    @State private var visibleRect = MKMapRect.null
    @State private var meters: Double = 60
    @State private var geocoding = false
    @State private var rendering = false
    @State private var errorMessage: String?

    private var centerCoordinate: CLLocationCoordinate2D? {
        visibleRect.isNull ? nil : MKMapPoint(x: visibleRect.midX, y: visibleRect.midY).coordinate
    }
    private var visibleMeters: Double { visibleRect.isNull ? 0 : MapSnapshot.metersWide(visibleRect) }

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

            GeometryReader { geo in
                ZStack {
                    MapPreview(recenter: recenter, visibleRect: $visibleRect)
                    captureFrame(in: geo.size)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .padding(.horizontal, 16)

            HStack(spacing: 12) {
                Text("Capture size")
                Slider(value: $meters, in: 20...400, step: 5)
                Text("\(Int(meters)) m").monospacedDigit().frame(width: 52, alignment: .trailing)
            }
            .padding(.horizontal, 18).padding(.vertical, 10)

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
                    .padding(.horizontal, 18).padding(.bottom, 4)
            }

            Divider()
            HStack {
                Text("Drag the map to position; the white square is captured.")
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
        .frame(width: 640, height: 760)
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

    private func geocode() {
        let query = address.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        geocoding = true
        errorMessage = nil
        CLGeocoder().geocodeAddressString(query) { placemarks, error in
            geocoding = false
            guard let loc = placemarks?.first?.location else {
                errorMessage = error?.localizedDescription ?? "Address not found."
                return
            }
            recenter = loc.coordinate
        }
    }

    private func render() {
        guard let center = centerCoordinate else { return }
        rendering = true
        errorMessage = nil
        let captureMeters = meters
        Task {
            do {
                let image = try await MapSnapshot.satelliteImage(coordinate: center, meters: captureMeters)
                guard let data = image.pngDataForBackground() else {
                    throw NSError(domain: "MapSnapshot", code: -1,
                                  userInfo: [NSLocalizedDescriptionKey: "Couldn't encode the image."])
                }
                rendering = false
                let label = address.trimmingCharacters(in: .whitespaces)
                onBackground(data, label.isEmpty ? nil : label)
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
private struct MapPreview: NSViewRepresentable {
    var recenter: CLLocationCoordinate2D?
    @Binding var visibleRect: MKMapRect

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.mapType = .satellite
        map.delegate = context.coordinator
        map.showsZoomControls = true
        map.showsCompass = true
        map.setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 52.3702, longitude: 4.8952),
                                         latitudinalMeters: 300, longitudinalMeters: 300), animated: false)
        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        if let recenter,
           context.coordinator.lastRecenter?.latitude != recenter.latitude
            || context.coordinator.lastRecenter?.longitude != recenter.longitude {
            context.coordinator.lastRecenter = recenter
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
