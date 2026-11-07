import Testing
import Foundation
import NeedletailPresentation
import NeedletailCore

/// B3 RED: UX-NAV-01…06 pure session/model/context/epoch views.
/// (UX-NAV-07 diff views belong to B4.) Fails until GREEN implements them.
struct InspectionViewsTests {

    private func apply(_ state: inout UIState, _ action: UIAction) -> [UIEffect] {
        let r = reduce(state, action)
        state = r.0
        return r.1
    }

    private func row(_ id: String, phase: String = "idle", last: UInt64? = 1000,
                     live: Bool = false) -> UISessionRow {
        UISessionRow(sessionID: SessionID(id), phase: phase, lastActivityMillis: last,
            routeAlias: "local-coder", locality: "local", modelAlias: "m", isLive: live)
    }

    @Test("UX-NAV-01 sessions separate active, idle, stale and unknown")
    func UX_NAV_01_sessionLiveness() throws {
        var state = UIState()
        _ = apply(&state, .inspectResult(.sessions(rows: [
            row("live-busy", phase: "requesting", live: true),
            row("live-idle", live: true),
            row("recent", last: 999_900),
            row("old", last: 100),
            row("noheartbeat", last: nil),
        ], asOfMillis: 1_000_000)))
        guard case .sessions(let rows) = state.inspection else {
            Issue.record("sessions view must project"); return
        }
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.row.sessionID.raw, $0.liveness) })
        #expect(byID["live-busy"] == .active)
        #expect(byID["live-idle"] == .idle)
        #expect(byID["recent"] == .idle, "within 5 minutes is idle, not stale")
        #expect(byID["old"] == .stale, "old heartbeat is stale, never live proof")
        #expect(byID["noheartbeat"] == .unknown, "missing heartbeat is unknown, never zero-idle")
    }

    @Test("UX-NAV-02 consult appears as child activity, not a team")
    func UX_NAV_02_consultChildActivity() throws {
        var state = UIState()
        _ = apply(&state, .inspectResult(.agents(rows: [
            UIAgentRow(alias: "local-coder", phase: "consulting", childActivity: "bounded consult: search"),
            UIAgentRow(alias: "other", phase: "idle", childActivity: nil),
        ])))
        guard case .agents(let rows) = state.inspection else {
            Issue.record("agents view must project"); return
        }
        #expect(rows[0].childActivity == "bounded consult: search")
        #expect(rows[1].childActivity == nil)
        let frame = render(state, width: 80, capabilities: TerminalCapabilities())
        #expect(frame.lines.contains(where: { $0.id == "agent-0-child" }),
            "child activity renders as its own line")
    }

    @Test("UX-NAV-03 models, sessions and agents stay separate with no fetch")
    func UX_NAV_03_separateMeanings() throws {
        var state = UIState()
        let fxModels = apply(&state, .inspect(.models))
        #expect(fxModels == [.inspect(.models)], "exactly one local inspect effect")
        _ = apply(&state, .inspectResult(.models(routes: [
            UIModelRoute(alias: "local-coder", locality: "local", kind: .local, models: ["m1"]),
            UIModelRoute(alias: "cloud", locality: "remote", kind: .cloud, models: ["m2"]),
        ])))
        guard case .models(let routes) = state.inspection else {
            Issue.record("models view must project"); return
        }
        #expect(routes.count == 2 && routes[0].kind == .local && routes[1].kind == .cloud,
            "local vs configured routes distinguished, no network used")
    }

    @Test("UX-NAV-04 unknown cache is labeled unknown, never zero")
    func UX_NAV_04_cacheUnknown() throws {
        var state = UIState()
        _ = apply(&state, .inspectResult(.context(usage: UIContextUsage(
            inputTokens: nil, estimated: true,
            cacheHits: nil, cacheUnknown: true,
            receipts: 7, unverifiedClaims: 2))))
        guard case .context(let usage) = state.inspection else {
            Issue.record("context view must project"); return
        }
        #expect(usage.estimated && usage.cacheUnknown, "estimates flagged")
        let frame = render(state, width: 80, capabilities: TerminalCapabilities())
        let text = frame.lines.map { $0.runs.map(\.text).joined() }.joined(separator: "\n")
        #expect(text.contains("unknown"), "UNKNOWN rendered, got: \(text)")
        #expect(!text.contains("0 hits"), "unknown never renders as zero")
    }

    @Test("UX-NAV-05 compact dry-run inspects only")
    func UX_NAV_05_compactDryRun() throws {
        var state = UIState()
        let fx = apply(&state, .inspect(.compactDryRun))
        #expect(fx == [.inspect(.compactDryRun)], "dry run is a local inspect")
        _ = apply(&state, .inspectResult(.compact(preview: UICompactPreview(
            estimatedTokens: 1200, wouldReplaceEpoch: true,
            providerCalls: 0, note: "offline estimate"))))
        guard case .compact(let preview) = state.inspection else {
            Issue.record("compact view must project"); return
        }
        #expect(preview.providerCalls == 0, "dry run performs no provider call")
        #expect(preview.wouldReplaceEpoch, "cost vs rollover visible")
    }

    @Test("UX-NAV-06 epochs show lineage, failure and prefill")
    func UX_NAV_06_epochLineage() throws {
        var state = UIState()
        _ = apply(&state, .inspectResult(.epochs(rows: [
            UIEpochRow(epochID: "e-2", parentID: "e-1",
                checkpoint: .success(costMillis: 40), prefill: "summary"),
            UIEpochRow(epochID: "e-3", parentID: "e-2",
                checkpoint: .failed(reason: "budget"), prefill: nil),
        ])))
        guard case .epochs(let rows) = state.inspection else {
            Issue.record("epochs view must project"); return
        }
        #expect(rows[0].parentID == "e-1" && rows[1].parentID == "e-2", "parent lineage")
        let frame = render(state, width: 80, capabilities: TerminalCapabilities())
        let text = frame.lines.map { $0.runs.map(\.text).joined() }.joined(separator: "\n")
        #expect(text.contains("failed: budget"), "failure visible, got: \(text)")
    }

    @Test("UX run budget-boundary completion is distinct from clean completion")
    func UX_RUN_budgetBoundaryDistinct() throws {
        var state = UIState()
        _ = apply(&state, .session(.runFinished(outcome: "completed-budget-boundary", detail: "turns exhausted")))
        if case .completedBudgetBoundary = state.status { } else {
            Issue.record("budget boundary must not collapse to idle, got \(state.status)")
        }
        _ = apply(&state, .session(.runFinished(outcome: "completed", detail: "done")))
        if case .idle = state.status { } else {
            Issue.record("clean completion stays idle, got \(state.status)")
        }
    }
}
