//
//  EditHistory.swift
//  CinePlanner
//
//  A plain undo/redo stack of snapshots, used by the scene map editor: before each
//  committed edit the previous state is recorded; undo steps back (keeping the
//  current state for redo); a new edit clears redo. Kept free of any view so the
//  rules can be tested.
//

struct EditHistory<State> {
    private(set) var undoStack: [State] = []
    private(set) var redoStack: [State] = []
    /// Oldest steps fall off beyond this.
    var limit = 100

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// An edit was committed; `previous` is the state it replaced.
    mutating func record(_ previous: State) {
        undoStack.append(previous)
        if undoStack.count > limit { undoStack.removeFirst(undoStack.count - limit) }
        redoStack.removeAll()
    }

    /// The state to go back to, keeping `current` for redo — nil when there's none.
    mutating func undo(from current: State) -> State? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        return previous
    }

    /// The state to go forward to, keeping `current` for undo — nil when there's none.
    mutating func redo(from current: State) -> State? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        return next
    }

    mutating func reset() {
        undoStack.removeAll()
        redoStack.removeAll()
    }
}
