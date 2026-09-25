// Exhaustive validation of GridGeometry.
//
// Running (under helper/):
//   swiftc -parse-as-library Sources/tabcircle/GridGeometry.swift \
//          checks/grid-geometry-check.swift -o ./gridcheck && ./gridcheck
//
// Approach: Lay out the actual grid (one array per row), then find the answer
// based on "same column, previous/next row, clamped to end of line if row is not wide enough"
// — this represents the visual adjacency definition itself. Then compare it against
// the modular arithmetic logic in GridGeometry. The two implementations are sufficiently
// distinct to catch any off-by-one boundary bugs.

/// Lay out items in 2D by wrapping within each group; elements are flat indices.
func layout(groupSizes: [Int], cols: Int) -> [[Int]] {
    var rows: [[Int]] = []
    var base = 0
    for n in groupSizes {
        var i = 0
        while i < n {
            let width = min(cols, n - i)
            rows.append((0..<width).map { base + i + $0 })
            i += width
        }
        base += n
    }
    return rows
}

/// Visual adjacency definition: same column, adjacent row; falls to end of row if target row is narrower.
func expected(cursor: Int, rows: [[Int]], up: Bool) -> Int? {
    guard let row = rows.firstIndex(where: { $0.contains(cursor) }),
          let col = rows[row].firstIndex(of: cursor) else { return nil }
    let target = up ? row - 1 : row + 1
    guard rows.indices.contains(target) else { return nil }
    return rows[target][min(col, rows[target].count - 1)]
}

func starts(of groupSizes: [Int]) -> [Int] {
    var result: [Int] = []
    var base = 0
    for n in groupSizes {
        result.append(base)
        base += n
    }
    return result
}

@main
struct Check {
    static func main() {
        var cases = 0
        var failures = 0

        // Group counts 1...3, items per group 1...9, column counts 1...5: covers full rows, gaps, single items, and all edge cases.
        var sizeSets: [[Int]] = []
        for a in 1...9 {
            sizeSets.append([a])
            for b in 1...9 {
                sizeSets.append([a, b])
                for c in 1...9 { sizeSets.append([a, b, c]) }
            }
        }

        for sizes in sizeSets {
            for cols in 1...5 {
                let rows = layout(groupSizes: sizes, cols: cols)
                let total = sizes.reduce(0, +)
                let groupStarts = starts(of: sizes)

                for cursor in 0..<total {
                    for up in [true, false] {
                        cases += 1
                        let want = expected(cursor: cursor, rows: rows, up: up)
                        let got = GridGeometry.rowNeighbor(of: cursor,
                                                           groupStarts: groupStarts,
                                                           total: total,
                                                           cols: cols,
                                                           up: up)
                        if want != got {
                            failures += 1
                            if failures <= 10 {
                                print("✗ sizes=\(sizes) cols=\(cols) cursor=\(cursor) "
                                      + "\(up ? "↑" : "↓") Expected \(want.map(String.init) ?? "nil") "
                                      + "Actual \(got.map(String.init) ?? "nil")")
                            }
                        }
                    }
                }
            }
        }

        // Out-of-bounds / empty lists must not crash, nor return valid positions.
        let guards: [(Int, [Int], Int, Int)] = [
            (-1, [0], 3, 2), (5, [0], 3, 2), (0, [0], 3, 0), (0, [], 0, 2),
        ]
        for (cursor, gs, total, cols) in guards {
            cases += 1
            for up in [true, false] where GridGeometry.rowNeighbor(
                of: cursor, groupStarts: gs, total: total, cols: cols, up: up) != nil {
                failures += 1
                print("✗ Invalid inputs should return nil: cursor=\(cursor) starts=\(gs) total=\(total) cols=\(cols)")
            }
        }

        print(failures == 0
              ? "All passed (\(cases) cases)"
              : "\(failures) failed (out of \(cases) cases)")
        if failures > 0 { fatalError("GridGeometry validation failed") }
    }
}
