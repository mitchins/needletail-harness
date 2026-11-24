import Foundation
#if canImport(Glibc)
import Glibc
import PTYShim
#elseif canImport(Darwin)
import Darwin
#endif

/// NTPTYBootstrap — a DEBUG-ONLY fixture executable (M4-MAC launcher
/// qualification). Spawned by the test shim via posix_spawn with
/// POSIX_SPAWN_SETSID; it acquires the controlling terminal, verifies
/// session/foreground-group ownership, and then execs the actual
/// Needletail executable. Failure exits report the phase:
///   120 = controlling-terminal acquisition failed
///   121 = session/foreground ownership verification failed
///   127 = exec failed
/// Markers on stderr: BOOTSTRAP:ctty-ok, BOOTSTRAP:fg-ok, BOOTSTRAP:exec.

func fail(_ code: Int32, _ why: String) -> Never {
    FileHandle.standardError.write(Data("BOOTSTRAP-FAIL \(why) errno=\(errno)\n".utf8))
    exit(code)
}

let args = CommandLine.arguments
guard args.count >= 2 else { fail(120, "no-executable-argument") }

// fd 0 is the pty slave (dup2'd by the spawner) and this process is
// already a session leader (POSIX_SPAWN_SETSID). Acquire the
// controlling terminal:
//   Linux: explicit TIOCSCTTY.
//   macOS/BSD: a session leader acquires the ctty on the first open
//   of the terminal AFTER becoming the leader, so reopen the slave and
//   re-dup it (the pre-setsid dup2 does not count).
#if canImport(Darwin)
// macOS/BSD: a session leader acquires the ctty on the first open of
// the terminal after becoming the leader — reopen and re-dup.
if let name = ttyname(0) {
    let fd = open(name, O_RDWR)
    if fd >= 0 {
        _ = dup2(fd, 0)
        _ = dup2(fd, 1)
        _ = dup2(fd, 2)
        if fd > 2 { close(fd) }
    }
}
#else
// Linux: the explicit acquisition call (the shim, to avoid Swift's
// ioctl signature drift).
if nt_bootstrap_acquire_ctty() != 0 {
    fail(120, "ctty")
}
#endif
FileHandle.standardError.write(Data("BOOTSTRAP:ctty-ok\n".utf8))

// Foreground-group ownership: this process group must be the session's
// foreground group before the application runs.
let myPgrp = getpgrp()
if tcsetpgrp(0, myPgrp) == -1 { fail(121, "tcsetpgrp") }
if tcgetpgrp(0) != myPgrp { fail(121, "fg-verify") }
if getsid(0) != myPgrp && getsid(0) != getpid() {
    // SETSID made us the session leader; verify the session id matches
    // this process (or its group) so terminal signals route to us.
    fail(121, "session-verify")
}
FileHandle.standardError.write(Data("BOOTSTRAP:fg-ok\n".utf8))

// Exec the real executable with the remaining arguments.
var argvC: [UnsafeMutablePointer<CChar>?] = args.dropFirst().map { strdup($0) }
argvC.append(nil)
FileHandle.standardError.write(Data("BOOTSTRAP:exec\n".utf8))
execv(args[1], &argvC)
fail(127, "execv")
