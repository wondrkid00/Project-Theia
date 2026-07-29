struct GraphDocumentHistory {
    private var undoStack: [GraphDocument] = []
    private var redoStack: [GraphDocument] = []
    private let limit: Int
    /// Identifies the edit that produced the snapshot on top of `undoStack`.
    /// While consecutive edits share a key they belong to one gesture and reuse
    /// that snapshot, so dragging a slider costs one undo step rather than one
    /// per tick — which previously flushed the whole history in a single drag.
    private var openCoalescingKey: String?

    init(limit: Int = 100) {
        self.limit = max(1, limit)
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Number of recorded undo steps. Exposed so the coalescing behaviour can be
    /// asserted directly rather than inferred from repeated undo calls.
    var undoDepthForTesting: Int { undoStack.count }

    mutating func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
        openCoalescingKey = nil
    }

    /// - Parameter coalescingKey: identifies a continuous edit. Consecutive
    ///   records sharing a non-nil key collapse into the first one's snapshot,
    ///   which is the pre-gesture state. `nil` always records and ends any open
    ///   gesture.
    mutating func record(_ document: GraphDocument, coalescingKey: String? = nil) {
        // A new edit always invalidates redo, whether or not it coalesces.
        redoStack.removeAll()

        if let coalescingKey, coalescingKey == openCoalescingKey, !undoStack.isEmpty {
            return
        }
        undoStack.append(document)
        if undoStack.count > limit {
            undoStack.removeFirst(undoStack.count - limit)
        }
        openCoalescingKey = coalescingKey
    }

    /// Closes the current gesture so the next edit starts a new undo step, even
    /// if it targets the same parameter.
    mutating func endCoalescing() {
        openCoalescingKey = nil
    }

    mutating func undo(current: GraphDocument) -> GraphDocument? {
        openCoalescingKey = nil
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        return previous
    }

    mutating func redo(current: GraphDocument) -> GraphDocument? {
        openCoalescingKey = nil
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        return next
    }
}
