import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// NTPTYInputFixture — a DEBUG-ONLY harness-proof executable
/// (M4-MAC-06A). Modes:
///   (default) byte:  read ONE byte from stdin (a real pty), emit an
///     observable post-input marker, exit 0 — proves the launcher, the
///     pty byte delivery, the runner's capture, the bounded exit wait
///     and the reaping in isolation.
///   envdump <KEY>:   print "ENV:<KEY>=<value>" or "ENV:<KEY>=ABSENT"
///     and exit 0 — proves the child-environment merge (overrides
///     applied, removals honoured, the inherited environment intact).
let args = CommandLine.arguments
if args.count >= 3, args[1] == "envdump" {
    let key = args[2]
    let value = getenv(key).map { String(cString: $0) } ?? "ABSENT"
    FileHandle.standardError.write(Data("ENV:\(key)=\(value)\n".utf8))
    exit(0)
}
var buf: [UInt8] = [0]
let n = read(0, &buf, 1)
if n != 1 {
    FileHandle.standardError.write(Data("FIXTURE-FAIL no-input\n".utf8))
    exit(4)
}
FileHandle.standardError.write(Data("FIXTURE:post-input-marker byte=0x\(String(buf[0], radix: 16))\n".utf8))
exit(0)
