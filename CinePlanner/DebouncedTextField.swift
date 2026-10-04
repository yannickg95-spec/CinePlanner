//
//  DebouncedTextField.swift
//  CinePlanner
//
//  A text field that writes its binding only after the user pauses typing.
//

import SwiftUI
import SwiftData
import PhotosUI
import AVKit
import UniformTypeIdentifiers
import os

/// A `TextField` that types into fast local state and writes the bound value only
/// after the user pauses (or when the field goes away). Binding a `TextField`
/// straight to a SwiftData `@Model` property makes every keystroke trigger a store
/// write (autosave + CloudKit) and re-render the whole detail view, which makes
/// typing lag badly. This decouples keystrokes from those writes.
///
/// Safe against shot-switching only when its host view has a stable identity per
/// shot (see the `.id(shot.uid)` on `ShotDetailView`): the field then reseeds on
/// appear and flushes any pending write on disappear, so no edit is lost.
struct DebouncedTextField: View {
    private let placeholder: LocalizedStringKey
    @Binding private var text: String
    private let axis: Axis

    @State private var draft = ""
    @State private var debounce: Task<Void, Never>?

    init(_ placeholder: LocalizedStringKey, text: Binding<String>, axis: Axis = .horizontal) {
        self.placeholder = placeholder
        self._text = text
        self.axis = axis
    }

    var body: some View {
        TextField(placeholder, text: $draft, axis: axis)
            .onAppear { draft = text }
            .onChange(of: text) { _, newValue in
                // Adopt external changes (undo/redo, sync) and drop any pending
                // write so a stale draft can't clobber them.
                if newValue != draft { debounce?.cancel(); draft = newValue }
            }
            .onChange(of: draft) { _, newValue in
                guard newValue != text else { return }
                debounce?.cancel()
                debounce = Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    if !Task.isCancelled { text = newValue }
                }
            }
            .onDisappear {
                debounce?.cancel()
                if draft != text { text = draft }   // flush before leaving
            }
    }
}
