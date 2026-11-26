import Testing
import Foundation
import PTYShim

/// M4-MAC-03 wedge discriminator (temporary, directive-authorized):
/// distinguishes an Xcode toolchain problem from Needletail's pty
/// cleanup. Both tests spawn a trivial child through the same shim the
/// PTY legs use; variant B retains the slave descriptor (the
/// exact-restoration oracle's anchor) until process exit, variant A
/// closes everything at stop. If B wedges the swift-testing runner at
/// exit while A completes, the retained slave descriptor is the cause.
final class WedgeDiscriminatorTests {
    private func spawnChild(retainSlave: Bool) {
        var pty = nt_pty_t()
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup("/usr/bin/true"), nil]
        let rc = nt_pty_spawn(&pty, &argv)
        argv.forEach { $0?.deallocate() }
        #expect(rc == 0)
        guard rc == 0 else { return }
        var status: Int32 = 0
        let deadline = Date().addingTimeInterval(10)
        var reaped = false
        while Date() < deadline {
            if waitpid(pty.childPid, &status, WNOHANG) == pty.childPid { reaped = true; break }
            usleep(50_000)
        }
        #expect(reaped, "child must exit")
        if !retainSlave {
            nt_pty_close(&pty)
        }
        // Variant B leaks master+slave+struct to process exit on purpose.
    }

    @Test("discriminator A: pty child, all descriptors closed at stop")
    func discriminatorAClosed() {
        spawnChild(retainSlave: false)
    }

    @Test("discriminator B: pty child, slave descriptor retained to exit")
    func discriminatorBRetained() {
        spawnChild(retainSlave: true)
    }
}
