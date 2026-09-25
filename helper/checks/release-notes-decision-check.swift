// Launch decision validation for whether the "What's New" release notes window should pop up.
//
// Running (under helper/):
//   swiftc -parse-as-library Sources/tabcircle/ReleaseNotes.swift \
//          Sources/tabcircle/ReleaseNotesParser.swift \
//          Sources/tabcircle/L10n.swift Sources/tabcircle/Log.swift \
//          checks/release-notes-decision-check.swift -o ./notesdecide && ./notesdecide
//
// Rationale: These branches fail silently without runtime errors — the symptom is either
// "fails to show when it should" or "shows stale release notes for an outdated version",
// which can only be noticed during actual updates. In v0.12.1, network timeout during
// fetching consumed the flag prematurely, permanently suppressing that version's notes.
// After splitting into lastRun and pending flags, the state space expanded, requiring
// exhaustive testing.
//
// Assertions verify three aspects: target values of both flags + whether to fetch.
// If pending isn't retained when needed, the next launch won't resume; if not cleared when stale,
// outdated release notes will be displayed.

import Foundation

@MainActor
func checkDecisions() {
    var cases = 0
    var failures = 0

    func expect(_ name: String,
                lastRun: String?, pending: String?, everChecked: Bool, current: String,
                wantPending: String?, wantFetch: Bool, wantUpgraded: Bool) {
        cases += 1
        let got = ReleaseNotes.decide(lastRun: lastRun, pending: pending,
                                      everChecked: everChecked, current: current)
        var problems: [String] = []
        if got.lastRun != current {
            problems.append("lastRun expected \(current), got \(got.lastRun)")
        }
        if got.pending != wantPending {
            problems.append("pending expected \(wantPending ?? "nil"), got \(got.pending ?? "nil")")
        }
        if got.shouldFetch != wantFetch {
            problems.append("shouldFetch expected \(wantFetch), got \(got.shouldFetch)")
        }
        if got.justUpgraded != wantUpgraded {
            problems.append("justUpgraded expected \(wantUpgraded), got \(got.justUpgraded)")
        }
        if problems.isEmpty {
            print("  ✓ \(name)")
        } else {
            failures += 1
            print("  ✗ \(name): \(problems.joined(separator: "; "))")
        }
    }

    print("Clean install: has not checked for updates at the moment of first launch, should not show")
    expect("Clean machine", lastRun: nil, pending: nil, everChecked: false, current: "0.13.0",
           wantPending: nil, wantFetch: false, wantUpgraded: false)

    print("Upgrading from legacy version without this feature: no lastRun, but checked for updates")
    expect("Legacy user upgrade", lastRun: nil, pending: nil, everChecked: true, current: "0.13.0",
           wantPending: "0.13.0", wantFetch: true, wantUpgraded: true)

    print("Routine upgrade")
    expect("0.12.1 → 0.13.0", lastRun: "0.12.1", pending: nil, everChecked: true,
           current: "0.13.0", wantPending: "0.13.0", wantFetch: true, wantUpgraded: true)

    print("Restarting same version: should not repeatedly show")
    expect("Normal restart", lastRun: "0.13.0", pending: nil, everChecked: true, current: "0.13.0",
           wantPending: nil, wantFetch: false, wantUpgraded: false)

    print("Failed to fetch notes last time (network jitter): keep pending, retry on next launch")
    expect("Pending notes retry on restart", lastRun: "0.13.0", pending: "0.13.0", everChecked: true,
           current: "0.13.0", wantPending: "0.13.0", wantFetch: true, wantUpgraded: false)

    print("Pending notes not yet shown before another upgrade arrives: discard stale version notes")
    expect("Pending superseded by newer version", lastRun: "0.13.0", pending: "0.13.0", everChecked: true,
           current: "0.14.0", wantPending: "0.14.0", wantFetch: true, wantUpgraded: true)

    print("Pending version mismatch (manually modified / reinstalled different package): discard stale")
    expect("Pending outdated", lastRun: "0.14.0", pending: "0.13.0", everChecked: true,
           current: "0.14.0", wantPending: nil, wantFetch: false, wantUpgraded: false)

    print("Downgrades count as version change: show notes for downgraded version, not leftover")
    expect("0.14.0 → 0.13.0", lastRun: "0.14.0", pending: "0.14.0", everChecked: true,
           current: "0.13.0", wantPending: "0.13.0", wantFetch: true, wantUpgraded: true)

    print("Clean install with leftover pending (installed before, cleared lastRun): do not show without upgrade")
    expect("Only pending left and mismatched", lastRun: nil, pending: "0.12.0", everChecked: false,
           current: "0.13.0", wantPending: nil, wantFetch: false, wantUpgraded: false)

    print("Decision must be pure: identical inputs produce identical outputs (no hidden external state)")
    cases += 1
    let a = ReleaseNotes.decide(lastRun: "0.13.0", pending: "0.13.0",
                                everChecked: true, current: "0.13.0")
    let b = ReleaseNotes.decide(lastRun: "0.13.0", pending: "0.13.0",
                                everChecked: true, current: "0.13.0")
    if a == b {
        print("  ✓ Same inputs yield same results")
    } else {
        failures += 1
        print("  ✗ Same inputs yielded different results: \(a) / \(b)")
    }

    print(failures == 0
          ? "\nAll passed (\(cases) cases)"
          : "\n\(failures) failed (out of \(cases) cases)")
    if failures > 0 { fatalError("Release notes launch decision check failed") }
}

@main
enum ReleaseNotesDecisionCheck {
    static func main() {
        // On failure, fatalError -> abort() without flushing stdio; unbuffer stdout so output is not lost in pipes.
        setvbuf(stdout, nil, _IONBF, 0)
        MainActor.assumeIsolated { checkDecisions() }
    }
}
