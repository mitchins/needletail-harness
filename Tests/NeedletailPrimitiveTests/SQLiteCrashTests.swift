import Testing
import GRDB
import Foundation
import NeedletailCore
#if canImport(Glibc)
import Glibc
#endif

/// STORE-02 bounded crash primitive — SIGKILL mid-transaction over a
/// separate `sqlite3` process, then native reopen.
///
/// Given a committed row, when a SEPARATE process opens an immediate
/// transaction, writes a second row and is killed with SIGKILL before
/// commit, then reopening must show the committed row, no trace of the
/// uncommitted row, and a writable database. Bounded: one child, one
/// kill, temp dir removed on exit; the child is synchronised on a
/// `SELECT 'ready'` echo (no blind sleeps on the kill path).
struct SQLiteCrashTests {

    @Test("STORE-02 SIGKILL mid-transaction rolls back and the database reopens writable")
    func STORE_02_sigkillMidTransactionRollsBack() throws {
        // The kill primitive shells a real sqlite3 CLI: fail closed with a
        // reason when the tool is absent, instead of a bare throw.
        let sqlitePath = "/usr/bin/sqlite3"
        try #require(FileManager.default.isExecutableFile(atPath: sqlitePath),
                     "STORE-02 needs the sqlite3 CLI at \(sqlitePath)")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("needletail-crash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("crash.sqlite").path

        let database = try DatabaseQueue(path: path)
        try database.write { db in
            try db.execute(sql: "CREATE TABLE probe (id INTEGER PRIMARY KEY, note TEXT)")
            try db.execute(sql: "INSERT INTO probe (note) VALUES (?)", arguments: ["committed"])
        }
        try database.close()

        // Child holds an open immediate transaction on stdin; the echo
        // proves the uncommitted write executed before the kill.
        let child = Process()
        child.executableURL = URL(fileURLWithPath: sqlitePath)
        child.arguments = [path]
        let stdin = Pipe()
        let stdout = Pipe()
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        try child.run()
        // The child is ALWAYS reaped: a failed sync kills (never leaves a
        // stdin-blocked orphan behind).
        defer {
            if child.isRunning {
                #if canImport(Glibc)
                Glibc.kill(child.processIdentifier, SIGKILL)
                #else
                child.terminate()
                #endif
                child.waitUntilExit()
            }
        }
        func writeLine(_ line: String) throws {
            // A dead child means the sync already failed: say so instead of
            // risking SIGPIPE on a broken pipe.
            try #require(child.isRunning, "sqlite3 child died before the transaction was staged")
            stdin.fileHandleForWriting.write(Data(line.utf8))
        }
        try writeLine("BEGIN IMMEDIATE;\n")
        try writeLine("INSERT INTO probe (note) VALUES ('doomed');\n")
        // `changes()` ties the echo to the write itself: a failed INSERT
        // would echo ready:0 and fail closed instead of proving nothing.
        try writeLine("SELECT 'ready:'||changes();\n")
        var echo = Data()
        let readyMarker = Data("ready:1".utf8)
        #if canImport(Glibc)
        // Deadline-driven poll: the fd is waited on with a timeout, so a
        // silent child fails closed instead of blocking the runner forever.
        let stop = Date().addingTimeInterval(10)
        while !echo.contains(readyMarker) {
            let remaining = max(0, stop.timeIntervalSinceNow)
            var fds = pollfd(fd: stdout.fileHandleForReading.fileDescriptor,
                             events: Int16(POLLIN), revents: 0)
            let waited = Glibc.poll(&fds, 1, Int32(remaining * 1000))
            guard waited > 0 else { break }
            if fds.revents & Int16(POLLIN) != 0 {
                echo.append(stdout.fileHandleForReading.availableData)
            } else {
                break
            }
        }
        #else
        let stop = Date().addingTimeInterval(10)
        while !echo.contains(readyMarker) {
            echo.append(stdout.fileHandleForReading.availableData)
            if Date() > stop { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        #endif
        #expect(echo.contains(readyMarker), "child must confirm the uncommitted write ran (got \(String(data: echo, encoding: .utf8) ?? "?"))")
        #expect(child.isRunning, "child must still hold the transaction when killed")
        #if canImport(Glibc)
        Glibc.kill(child.processIdentifier, SIGKILL)
        #else
        child.terminate()
        #endif
        child.waitUntilExit()
        #expect(!child.isRunning, "killed child must be reaped")

        let reopened = try DatabaseQueue(path: path)
        let notes = try reopened.read { db in
            try String.fetchAll(db, sql: "SELECT note FROM probe ORDER BY id")
        }
        #expect(notes == ["committed"], "uncommitted row must roll back, got \(notes)")
        try reopened.write { db in
            try db.execute(sql: "INSERT INTO probe (note) VALUES (?)", arguments: ["after-reopen"])
        }
        let count = try reopened.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM probe") ?? -1
        }
        #expect(count == 2, "database must be writable after kill, got \(count) rows")
    }
}
