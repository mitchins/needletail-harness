/*
 * NTPTYBootstrap — a DEBUG-ONLY fixture executable (M4-MAC launcher
 * qualification). Spawned by the test shim via posix_spawn with
 * POSIX_SPAWN_SETSID; acquires the controlling terminal, verifies
 * session/foreground ownership, then execs the real Needletail
 * executable. Phase exits: 120 = ctty failed, 121 = ownership failed,
 * 127 = exec failed. Markers on stderr: BOOTSTRAP:ctty-ok,
 * BOOTSTRAP:fg-ok, BOOTSTRAP:exec.
 */
#define _XOPEN_SOURCE 600
#define _DEFAULT_SOURCE 1
#include <sys/ioctl.h>
#include <termios.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void fail(int code, const char *why) {
    fprintf(stderr, "BOOTSTRAP-FAIL %s errno=%d\n", why, errno);
    exit(code);
}

int main(int argc, char **argv) {
    if (argc < 2) fail(120, "no-executable-argument");

    /* fd 0 is the pty slave; this process is already a session leader
     * (POSIX_SPAWN_SETSID). Acquire the controlling terminal:
     *   Linux: explicit TIOCSCTTY.
     *   macOS/BSD: a session leader acquires the ctty on the first open
     *   of the terminal AFTER becoming the leader — reopen and re-dup. */
#if defined(__APPLE__)
    /* macOS/BSD: a session leader acquires the ctty on the first open
     * of the terminal AFTER becoming the leader. Every step is
     * verified; any failure is explicit (M4-MAC-06 defect B: success
     * markers were previously emitted on attempted, unverified paths). */
    const char *name = ttyname(0);
    if (name == NULL) fail(120, "terminal-identify");
    int fd = open(name, O_RDWR);
    if (fd < 0) fail(120, "terminal-open");
    if (dup2(fd, 0) < 0 || dup2(fd, 1) < 0 || dup2(fd, 2) < 0)
        fail(120, "descriptor-duplicate");
    if (fd > 2) close(fd);
    /* Acquisition verification: the fd's controlling session must now
     * be OUR session and its foreground group OUR group. */
    if (tcgetsid(0) == (pid_t)-1 || tcgetsid(0) != getsid(0))
        fail(120, "ctty-acquisition-verify");
    if (tcsetpgrp(0, getpgrp()) == -1) fail(120, "tcsetpgrp");
#else
    if (ioctl(0, TIOCSCTTY, 0) == -1) fail(120, "ctty");
#endif
    fprintf(stderr, "BOOTSTRAP:ctty-ok\n");
    fflush(stderr);

    /* Foreground-group ownership before the application runs. */
    pid_t myPgrp = getpgrp();
    if (tcsetpgrp(0, myPgrp) == -1) fail(121, "tcsetpgrp");
    if (tcgetpgrp(0) != myPgrp) fail(121, "fg-verify");
    fprintf(stderr, "BOOTSTRAP:fg-ok\n");
    fflush(stderr);

    fprintf(stderr, "BOOTSTRAP:exec\n");
    fflush(stderr);
    execv(argv[1], &argv[1]);
    fail(127, "execv");
    return 127;
}
