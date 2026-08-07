//
//  MapBackgroundSheet.swift
//  CinePlanner
//
//  Collects a location (address lookup or coordinates) and a size in metres, then
//  renders a satellite still to use as the scene-map background.
//

import SwiftUI
import CoreLocation

struct MapBackgroundSheet: View {
    /// Called with the rendered PNG and an optional location label (the address).
    var onBackground: (Data, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var latText = ""
    @State private var lonText = ""
    @State private var meters: Double = 60
    @State private var geocoding = false
    @State private var rendering = false
    @State private var errorMessage: String?

    private var coordinate: CLLocationCoordinate2D? {
        guard let lat = Double(latText.trimmingCharacters(in: .whitespaces)),
              let lon = Double(lonText.trimmingCharacters(in: .whitespaces)),
              (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
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

            Form {
                Section("Location") {
                    HStack {
                        TextField("Address", text: $address).onSubmit { geocode() }
                        Button { geocode() } label: {
                            if geocoding { ProgressView().controlSize(.small) } else { Text("Look Up") }
                        }
                        .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || geocoding)
                    }
                    HStack {
                        TextField("Latitude", text: $latText)
                        TextField("Longitude", text: $lonText)
                    }
                }
                Section("Area") {
                    HStack {
                        Text("Size")
                        Slider(value: $meters, in: 20...400, step: 5)
                        Text("\(Int(meters)) m").monospacedDigit().frame(width: 52, alignment: .trailing)
                    }
                    Text("Width of the square area captured, to scale.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let errorMessage {
                    Section { Text(errorMessage).font(.caption).foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button {
                    render()
                } label: {
                    if rendering { ProgressView().controlSize(.small) } else { Text("Add Background") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(coordinate == nil || rendering)
            }
            .padding(16)
        }
        .frame(width: 400, height: 460)
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
            latText = String(format: "%.6f", loc.coordinate.latitude)
            lonText = String(format: "%.6f", loc.coordinate.longitude)
        }
    }

    private func render() {
        guard let coordinate else { return }
        rendering = true
        errorMessage = nil
        Task {
            do {
                let image = try await MapSnapshot.satelliteImage(coordinate: coordinate, meters: meters)
                guard let data = image.pngDataForBackground() else {
                    throw NSError(domain: "MapSnapshot", code: -1,
                                  userInfo: [NSLocalizedDescriptionKey: "Couldn't encode the image."])
                }
                await MainActor.run {
                    rendering = false
                    let label = address.trimmingCharacters(in: .whitespaces)
                    onBackground(data, label.isEmpty ? nil : label)
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    rendering = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}
