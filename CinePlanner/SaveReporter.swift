//
//  SaveReporter.swift
//  CinePlanner
//
//  Saving used to be `try? context.save()` everywhere, so a failed save vanished
//  without a trace: nothing in the log, nothing on screen, and the user only found
//  out when an edit was missing on another device. Every save now goes through
//  `saveReporting()`, which logs a failure and shows a brief, non-blocking banner.
//  The unsaved changes stay in the context, and the periodic flush retries them.
//

import SwiftUI
import SwiftData
import Observation
import os

extension ModelContext {
    /// Saves, making a failure visible instead of swallowing it.
    func saveReporting(file: StaticString = #fileID, line: UInt = #line) {
        // Read-only after the trial: keep nothing (see ReadOnlyGate).
        if ReadOnlyGate.isActive {
            if hasChanges { rollback() }
            return
        }
        do {
            try save()
        } catch {
            Log.app.error("Save failed (\(String(describing: file), privacy: .public):\(line)): \(error.localizedDescription, privacy: .public)")
            SaveReporter.shared.report(error)
        }
    }
}

/// The latest save failure, shown as a banner for a few seconds.
@MainActor @Observable
final class SaveReporter {
    static let shared = SaveReporter()
    private(set) var message: String?
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    private init() {}

    func report(_ error: Error) {
        message = error.localizedDescription
        // Keep it up while failures keep coming (the flush retries every few
        // seconds), and let it go once they stop.
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }

    func dismiss() {
        hideTask?.cancel()
        message = nil
    }
}

/// A slim banner at the top of the window while saving fails.
struct SaveFailureBanner: View {
    private var reporter = SaveReporter.shared

    var body: some View {
        if let message = reporter.message {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Changes couldn't be saved").font(.footnote.weight(.semibold))
                    Text("CinePlanner keeps them and tries again. \(message)")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
                Button { reporter.dismiss() } label: {
                    Image(systemName: "xmark").font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: 460)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.orange.opacity(0.35)))
            .padding(.top, 8).padding(.horizontal, 16)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
