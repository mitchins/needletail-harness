import Testing
import Foundation
import NeedletailRuntime

/// M3-C durable pre-send live-request budget: the 12-request allowance
/// is enforced before any provider byte is sent, survives process death
/// (re-runs never reset it), and fails closed on corruption.
struct LiveRequestBudgetTests {

    private static func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("m3c-budget-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func budget(in dir: URL, limit: Int = 12) -> LiveRequestBudget {
        LiveRequestBudget(fileURL: dir.appendingPathComponent("m3c-live-budget.json"), limit: limit)
    }

    @Test("fresh counter starts at zero and first consume returns one")
    func freshStartsAtZero() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let gate = Self.budget(in: dir)
        #expect(gate.inspect() == nil, "missing file inspects as nil (never as zero-sendable)")
        #expect(try gate.consume() == 1)
        #expect(gate.inspect() == 1)
    }

    @Test("twelve consumes succeed; the thirteenth is refused pre-send")
    func twelveThenExhausted() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let gate = Self.budget(in: dir, limit: 12)
        for expected in 1...12 {
            #expect(try gate.consume() == expected, "consume \(expected) of 12")
        }
        do {
            _ = try gate.consume()
            Issue.record("13th consume must throw")
        } catch let error as LiveRequestBudget.BudgetError {
            #expect(error == .exhausted(used: 12, limit: 12), "exhaustion carries counts, got \(error)")
        }
        #expect(gate.inspect() == 12, "a refused consume never advances the counter")
    }

    @Test("the counter is durable: a new instance sees prior consumption")
    func durableAcrossInstances() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = Self.budget(in: dir, limit: 3)
        #expect(try first.consume() == 1)
        #expect(try first.consume() == 2)
        // A re-run (new process-equivalent instance) cannot reset it.
        let second = Self.budget(in: dir, limit: 3)
        #expect(second.inspect() == 2)
        #expect(try second.consume() == 3)
        do {
            _ = try second.consume()
            Issue.record("4th consume must throw")
        } catch let error as LiveRequestBudget.BudgetError {
            #expect(error == .exhausted(used: 3, limit: 3))
        }
    }

    @Test("concurrent consumers never share a unit; the cap holds")
    func concurrentCapHolds() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let limit = 40
        let gate = Self.budget(in: dir, limit: limit)
        let results = await withTaskGroup(of: Int?.self, returning: [Int].self) { group in
            for _ in 0..<limit {
                group.addTask {
                    do { return try gate.consume() } catch { return nil }
                }
            }
            var won: [Int] = []
            for await value in group {
                if let value { won.append(value) }
            }
            return won
        }
        #expect(results.sorted() == Array(1...limit), "exactly one unit per consumer, got \(results.sorted())")
        #expect(gate.inspect() == limit)
        do {
            _ = try gate.consume()
            Issue.record("consume past the cap must throw")
        } catch let error as LiveRequestBudget.BudgetError {
            #expect(error == .exhausted(used: limit, limit: limit))
        }
    }

    @Test("limit selection: checkpoint floor 12, raised by env; plain runs env-gated")
    func limitSelection() throws {
        #expect(LiveRequestBudget.limit(checkpoint: true, environment: [:]) == 12)
        #expect(LiveRequestBudget.limit(checkpoint: true, environment: ["NEEDLETAIL_REQUEST_BUDGET": "3"]) == 12, "checkpoint allowance never shrinks")
        #expect(LiveRequestBudget.limit(checkpoint: true, environment: ["NEEDLETAIL_REQUEST_BUDGET": "45"]) == 45, "explicit raise honored")
        #expect(LiveRequestBudget.limit(checkpoint: true, environment: ["NEEDLETAIL_REQUEST_BUDGET": "many"]) == 12)
        #expect(LiveRequestBudget.limit(checkpoint: false, environment: [:]) == nil)
        #expect(LiveRequestBudget.limit(checkpoint: false, environment: ["NEEDLETAIL_REQUEST_BUDGET": "15"]) == 15)
        #expect(LiveRequestBudget.limit(checkpoint: false, environment: ["NEEDLETAIL_REQUEST_BUDGET": "0"]) == nil)
        #expect(LiveRequestBudget.limit(checkpoint: false, environment: ["NEEDLETAIL_REQUEST_BUDGET": "-2"]) == nil)
        #expect(LiveRequestBudget.limit(checkpoint: false, environment: ["NEEDLETAIL_REQUEST_BUDGET": "many"]) == nil)
    }

    @Test("a corrupt counter fails closed and is never reset")
    func corruptFailsClosed() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("m3c-live-budget.json")
        try Data("not-json{{".utf8).write(to: url)
        let gate = Self.budget(in: dir)
        do {
            _ = try gate.consume()
            Issue.record("corrupt counter must throw")
        } catch let error as LiveRequestBudget.BudgetError {
            #expect(error == .counterUnreadable("live-request budget counter is corrupt; refusing to send"))
        }
        let raw = try Data(contentsOf: url)
        #expect(String(decoding: raw, as: UTF8.self) == "not-json{{", "a refused consume never rewrites the file")
    }

    @Test("a negative counter fails closed")
    func negativeFailsClosed() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("m3c-live-budget.json")
        try JSONSerialization.data(withJSONObject: ["used": -1]).write(to: url)
        do {
            _ = try Self.budget(in: dir).consume()
            Issue.record("negative counter must throw")
        } catch let error as LiveRequestBudget.BudgetError {
            #expect(error == .counterUnreadable("live-request budget counter is corrupt; refusing to send"))
        }
    }
}
