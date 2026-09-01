//
//  SunSettingsSheet.swift
//  CinePlanner
//
//  Settings for a scene map's sun-direction overlay: the location (address lookup
//  or manual coordinates), the shoot date, and which way North points on the map.
//

import SwiftUI
import CoreLocation

struct SunSettingsSheet: View {
    @Binding var settings: SunSettings
    var onChange: () -> Void
    /// Apple Maps (satellite) backgrounds are already north-up, so the North dial is
    /// hidden and the offset pinned to 0 for them.
    var isNorthLocked: Bool = false

    @Environment(\.dismiss) private var dismiss
    @State private var geocoding = false
    @State private var geocodeError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Location Details").font(.title3.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()

            Form {
                Section("Location") {
                    if isNorthLocked {
                        // Satellite maps take their location from the map itself, so the
                        // coordinates are read-only and there's no address lookup.
                        LabeledContent("Latitude", value: coordDisplay(\.latitude))
                        LabeledContent("Longitude", value: coordDisplay(\.longitude))
                        if let tz = settings.timeZoneID {
                            Text("Timezone: \(tz)").font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        HStack {
                            TextField("Address", text: $settings.address)
                                .onSubmit { geocode() }
                            Button { geocode() } label: {
                                if geocoding { ProgressView().controlSize(.small) }
                                else { Text("Look Up") }
                            }
                            .disabled(settings.address.trimmingCharacters(in: .whitespaces).isEmpty || geocoding)
                        }
                        HStack {
                            TextField("Latitude", text: coordText(\.latitude))
                            TextField("Longitude", text: coordText(\.longitude))
                        }
                        if let error = geocodeError {
                            Text(error).font(.caption).foregroundStyle(.red)
                        } else if let tz = settings.timeZoneID {
                            Text("Timezone: \(tz)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Date") {
                    DatePicker("Shoot date", selection: dateBinding, displayedComponents: .date)
                }

                if !isNorthLocked {
                    Section("North") {
                        HStack(spacing: 20) {
                            NorthDial(degrees: northBinding)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Rotate so N points the way North is on your map.")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text("\(Int(settings.northOffsetDeg.rounded()))° from up")
                                    .font(.callout.monospacedDigit())
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .onAppear {
            // Satellite maps are north-up; keep the overlay's North aligned.
            if isNorthLocked, settings.northOffsetDeg != 0 {
                settings.northOffsetDeg = 0
                onChange()
            }
        }
        .adaptiveSheetFrame(width: 400, height: isNorthLocked ? 360 : 600)
    }

    // MARK: - Bindings

    private var dateBinding: Binding<Date> {
        Binding(get: { settings.date },
                set: { settings.dateEpoch = $0.timeIntervalSince1970; onChange() })
    }
    private var northBinding: Binding<Double> {
        Binding(get: { settings.northOffsetDeg },
                set: { settings.northOffsetDeg = $0; onChange() })
    }
    private func coordDisplay(_ key: KeyPath<SunSettings, Double?>) -> String {
        settings[keyPath: key].map { String(format: "%.5f", $0) } ?? "—"
    }
    private func coordText(_ key: WritableKeyPath<SunSettings, Double?>) -> Binding<String> {
        Binding(
            get: { settings[keyPath: key].map { String(format: "%.5f", $0) } ?? "" },
            set: {
                settings[keyPath: key] = Double($0.trimmingCharacters(in: .whitespaces))
                onChange()
            })
    }

    // MARK: - Geocoding

    private func geocode() {
        let query = settings.address.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        geocoding = true
        geocodeError = nil
        CLGeocoder().geocodeAddressString(query) { placemarks, error in
            geocoding = false
            guard let placemark = placemarks?.first, let loc = placemark.location else {
                geocodeError = Self.geocodeMessage(for: error, query: query)
                return
            }
            settings.latitude = loc.coordinate.latitude
            settings.longitude = loc.coordinate.longitude
            settings.timeZoneID = placemark.timeZone?.identifier
            onChange()
        }
    }

    /// Turns a `CLGeocoder` failure into plain language. The common one is
    /// `kCLErrorGeocodeFoundNoResult` (CLError code 8), which Apple otherwise
    /// surfaces as "The operation couldn't be completed. (kCLErrorDomain error 8.)".
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
}

/// A draggable compass dial: drag to point the "N" marker the way North lies on
/// the map. Angle is degrees clockwise from straight up.
private struct NorthDial: View {
    @Binding var degrees: Double
    private let size: CGFloat = 92

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.4), lineWidth: 1)
            Circle().fill(Color.secondary.opacity(0.06))
            // Fixed "up" tick (map up).
            Rectangle().fill(Color.secondary.opacity(0.4))
                .frame(width: 1, height: 8).offset(y: -size/2 + 5)
            // North needle.
            VStack(spacing: 0) {
                Image(systemName: "location.north.fill")
                    .foregroundStyle(.red)
                Text("N").font(.caption2.bold())
            }
            .offset(y: -size/4)
            .rotationEffect(.degrees(degrees))
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .gesture(
            DragGesture()
                .onChanged { value in
                    let dx = value.location.x - size/2
                    let dy = value.location.y - size/2
                    var a = atan2(dx, -dy) * 180 / .pi   // 0 = up, clockwise
                    if a < 0 { a += 360 }
                    degrees = a
                }
        )
    }
}
