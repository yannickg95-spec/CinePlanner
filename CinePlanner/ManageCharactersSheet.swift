//
//  ManageCharactersSheet.swift
//  CinePlanner
//
//  Manage the project's characters (used for scene-map mannequin markers): rename,
//  recolor, add, and delete. Edits are committed back to the project.
//

import SwiftUI
import SwiftData

struct ManageCharactersSheet: View {
    let project: Project
    @Environment(\.dismiss) private var dismiss
    @State private var characters: [ScriptCharacter] = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .adaptiveSheetFrame(width: 400, height: 460)
        .onAppear { characters = project.scriptCharacters }
        .onDisappear { commit() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Characters").font(.title3.bold())
                Text("Used for the scene map's mannequin markers")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { commit(); dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        if characters.isEmpty {
            ContentUnavailableView(
                "No Characters",
                systemImage: "person.2",
                description: Text("Add a character below, or import a script to detect them.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach($characters) { $character in
                    HStack(spacing: 10) {
                        colorMenu($character)
                        TextField("Name", text: $character.name)
                            .textFieldStyle(.plain)
                        Button(role: .destructive) { delete(character) } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Delete character")
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button { add() } label: { Label("Add Character", systemImage: "plus") }
            Spacer()
        }
        .padding(12)
    }

    private func colorMenu(_ character: Binding<ScriptCharacter>) -> some View {
        Menu {
            ForEach(sceneMapPalette, id: \.hex) { item in
                Button {
                    character.wrappedValue.colorHex = item.hex
                } label: {
                    if character.wrappedValue.colorHex.caseInsensitiveCompare(item.hex) == .orderedSame {
                        Label(item.name, systemImage: "checkmark")
                    } else {
                        Text(item.name)
                    }
                }
            }
        } label: {
            Circle()
                .fill(Color(hex: character.wrappedValue.colorHex))
                .frame(width: 16, height: 16)
                .overlay(Circle().stroke(Color.secondary.opacity(0.35), lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func add() {
        let color = Project.characterPalette[characters.count % Project.characterPalette.count]
        characters.append(ScriptCharacter(name: "", colorHex: color))
        commit()
    }

    private func delete(_ character: ScriptCharacter) {
        characters.removeAll { $0.id == character.id }
        commit()
    }

    /// Writes the edited roster back to the project (dropping unnamed rows).
    private func commit() {
        project.scriptCharacters = characters
            .map { ScriptCharacter(id: $0.id, name: $0.name.trimmingCharacters(in: .whitespaces), colorHex: $0.colorHex) }
            .filter { !$0.name.isEmpty }
        try? project.modelContext?.save()
    }
}
