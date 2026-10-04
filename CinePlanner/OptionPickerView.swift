//
//  OptionPickerView.swift
//  CinePlanner
//
//  A picker for a shot field's options (built-in and the user's own), with free text.
//

import SwiftUI
import SwiftData
import PhotosUI
import AVKit
import UniformTypeIdentifiers
import os

/// A reusable field (size, type, grip): a button that opens a popover of options
/// laid out in two balanced columns, grouped like with like. The user can add
/// their own options, which are remembered app-wide and can be removed here.
struct OptionPickerView: View {
    typealias Option = (label: String, value: String)
    typealias Section = (title: String, options: [Option])

    let noun: String                    // "size" / "type" / "grip"
    let placeholder: String
    let sections: [Section]             // built-in options
    let grouped: Bool                   // false = one flat list, no section headers
    @Binding var value: String          // the stored value
    var onSelect: ((String) -> Void)? = nil   // called after any value change

    // Custom options are stored as one newline-joined string because @AppStorage
    // can't hold an array directly. The key is per-field, passed in at init.
    @AppStorage private var customRaw: String
    @State private var showAdd = false
    @State private var newName = ""

    init(noun: String, placeholder: String, sections: [Section], grouped: Bool = true,
         value: Binding<String>, customKey: String, onSelect: ((String) -> Void)? = nil) {
        self.noun = noun
        self.placeholder = placeholder
        self.sections = sections
        self.grouped = grouped
        self._value = value
        self.onSelect = onSelect
        self._customRaw = AppStorage(wrappedValue: "", customKey)
    }

    private var customOptions: [String] {
        customRaw.split(separator: "\n").map(String.init)
    }

    private var hasValue: Bool { !value.isEmpty && value != "none" }

    /// The menu label for the current value — a built-in's display name, or the
    /// custom text itself.
    private var currentLabel: String {
        for section in sections {
            if let match = section.options.first(where: { $0.value == value }) { return match.label }
        }
        return hasValue ? value : placeholder
    }

    /// Built-in groups plus the user's custom list. Custom options carry
    /// label == value.
    private var allSections: [Section] {
        var result = sections
        if !customOptions.isEmpty {
            result.append((title: "Custom", options: customOptions.map { (label: $0, value: $0) }))
        }
        return result
    }

    /// The dropdown's pill label, shared by the button/menu on every platform.
    private var pickerLabel: some View {
        HStack {
            Text(currentLabel)
                .foregroundStyle(hasValue ? .primary : .secondary)
                // One line, sized to its text — the card is given enough width
                // (camera card is capped narrower) so labels never wrap or clip.
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 60)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }

    /// A native menu on every platform: it opens instantly and lets you go straight
    /// from one dropdown to another. On macOS the menu is rendered as a plain button
    /// so the trigger is exactly the pill label — identical to iOS/iPadOS.
    private var control: some View {
        Menu { menuContent } label: { pickerLabel }
            .menuIndicator(.hidden)
            #if os(macOS)
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
            #endif
    }

    /// The iPad menu's contents: every option (grouped), then add / clear / remove.
    @ViewBuilder private var menuContent: some View {
        ForEach(allSections, id: \.title) { section in
            SwiftUI.Section(section.title) {
                ForEach(section.options, id: \.value) { option in
                    Button {
                        select(option.value)
                    } label: {
                        menuSelectionLabel(option.label, isSelected: value == option.value)
                    }
                }
            }
        }
        Divider()
        Button {
            newName = ""
            showAdd = true
        } label: {
            Label("Add Custom \(noun.capitalized)…", systemImage: "plus")
        }
        if hasValue {
            Button("Clear", role: .destructive) { select("") }
        }
        if !customOptions.isEmpty {
            Menu("Remove Custom") {
                ForEach(customOptions, id: \.self) { name in
                    Button(role: .destructive) { removeCustom(name) } label: { Text(name) }
                }
            }
        }
    }

    var body: some View {
        control
        .alert("Add Custom \(noun.capitalized)", isPresented: $showAdd) {
            TextField("\(noun.capitalized) name", text: $newName)
            Button("Add") { addCustom(newName) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Enter a \(noun) name. It'll be saved for use in all your projects.")
        }
    }

    /// The option columns/sections, without the Add/Clear footer.
    private func select(_ newValue: String) {
        value = newValue
        onSelect?(newValue)
    }

    /// Adds a custom option app-wide (unless it duplicates a built-in label,
    /// a built-in value, or an existing custom — all case-insensitively) and
    /// selects it.
    private func addCustom(_ raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let builtIn = sections.flatMap { $0.options }.flatMap { [$0.label.lowercased(), $0.value.lowercased()] }
        let taken = Set(customOptions.map { $0.lowercased() } + builtIn)
        if !taken.contains(name.lowercased()) {
            customRaw = (customOptions + [name]).joined(separator: "\n")
        }
        select(name)
    }

    private func removeCustom(_ name: String) {
        customRaw = customOptions
            .filter { $0.caseInsensitiveCompare(name) != .orderedSame }
            .joined(separator: "\n")
    }
}
