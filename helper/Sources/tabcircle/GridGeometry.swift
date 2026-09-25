/// Visual adjacency geometry for the global switcher grid layout.
///
/// Extracted as a pure function without dependencies for isolated verification (`helper/checks/`):
/// Cards wrap within each browser group independently; the last row of each group may be incomplete,
/// so naive `cursor ± cols` flat index calculations would jump unexpectedly across group boundaries.
enum GridGeometry {

    /// Position of the visually adjacent item directly above or below; returns nil at topmost/bottommost boundaries (no wrap-around).
    ///
    /// Cross-group transitions are intentional: arrow keys follow visual spatial layout regardless of browser ownership.
    /// Pressing ↓ on the last row of a group moves to the same column in the first row of the next group (clamped if narrower).
    ///
    /// - Parameters:
    ///   - cursor: Current index (flat index).
    ///   - groupStarts: Flat index of the first item in each group, sorted ascending, first item is 0.
    ///   - total: Total number of items.
    ///   - cols: Number of columns per row.
    ///   - up: true for upward navigation, false for downward.
    static func rowNeighbor(of cursor: Int,
                            groupStarts: [Int],
                            total: Int,
                            cols: Int,
                            up: Bool) -> Int? {
        guard cols > 0, cursor >= 0, cursor < total,
              let groupIndex = groupStarts.lastIndex(where: { $0 <= cursor }) else { return nil }

        let groupStart = groupStarts[groupIndex]
        let groupEnd = groupIndex + 1 < groupStarts.count ? groupStarts[groupIndex + 1] : total
        let local = cursor - groupStart
        let col = local % cols
        let rowStart = local - col

        if up {
            if rowStart >= cols {
                // Previous row within the same group; guaranteed full since it is not the last row
                return groupStart + rowStart - cols + col
            }
            // First row of current group -> last row of previous group
            guard groupIndex > 0 else { return nil }
            let prevStart = groupStarts[groupIndex - 1]
            let prevCount = groupStart - prevStart
            let prevLastRowStart = (prevCount - 1) / cols * cols
            let width = min(cols, prevCount - prevLastRowStart)
            return prevStart + prevLastRowStart + min(col, width - 1)
        }

        let count = groupEnd - groupStart
        let nextRowStart = rowStart + cols
        if nextRowStart < count {
            // Next row within same group, possibly incomplete — clamp to end of that row
            return groupStart + nextRowStart + min(col, min(cols, count - nextRowStart) - 1)
        }
        // Last row of current group -> first row of next group
        guard groupIndex + 1 < groupStarts.count else { return nil }
        let nextStart = groupStarts[groupIndex + 1]
        let nextEnd = groupIndex + 2 < groupStarts.count ? groupStarts[groupIndex + 2] : total
        return nextStart + min(col, min(cols, nextEnd - nextStart) - 1)
    }
}
