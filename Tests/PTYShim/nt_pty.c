/*
 * PTYShim implementation — Linux (macOS: same openpty-family API via
 * util.h; M4-A build-portability only, no PTY behavior change).
 * Uses forkpty-family facilities through
 * openpty + login_tty (forkpty itself glibc-internal), termios save/restore,
 * ioctl(TIOCSWINSZ), waitpid with deadlines, and bounded select() reads.
 * Teardown kills only the child it spawned (never a generic name).
 */
#define _XOPEN_SOURCE 600
#define _DEFAULT_SOURCE 1
#define _GNU_SOURCE 1
#include <spawn.h>
#include <unistd.h>
extern char **environ;
#define _DARWIN_C_SOURCE 1
#include "nt_pty.h"

#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>

#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <util.h>
#else
#include <pty.h>
#endif
#include <pthread.h>

int nt_pty_spawn(nt_pty_t *pty, char *const argv[]) {
    return nt_pty_spawn_env(pty, argv, NULL);
}

int nt_pty_spawn_env(nt_pty_t *pty, char *const argv[], char *const env[]) {
    if (pty == NULL || argv == NULL) {
        return -1;
    }
    memset(pty, 0, sizeof(*pty));

    int master = -1;
    int slave = -1;
    if (openpty(&master, &slave, NULL, NULL, NULL) != 0) {
        return -1;
    }

    /* Save the slave's starting termios so the driver can verify the mode
     * state returns to canonical echo after the child exits. */
    if (tcgetattr(slave, &pty->savedSlaveTermios) == 0) {
        pty->haveSavedTermios = 1;
    }

    pid_t pid = fork();
    if (pid < 0) {
        close(master);
        close(slave);
        return -1;
    }
    if (pid == 0) {
        /* Child: fresh session, controlling terminal, stdio on the slave. */
        close(master);
        setsid();
        if (ioctl(slave, TIOCSCTTY, 0) == -1) {
            _exit(126);
        }
        dup2(slave, STDIN_FILENO);
        dup2(slave, STDOUT_FILENO);
        dup2(slave, STDERR_FILENO);
        if (slave > STDERR_FILENO) {
            close(slave);
        }
        /* Apply caller-supplied environment overrides in the child
         * (the parent's environment is never mutated, so concurrent
         * suites cannot cross-contaminate spawned children): each
         * entry is "KEY=VALUE" to set, or bare "KEY" to unset. */
        if (env != NULL) {
            for (char *const *entry = env; *entry != NULL; entry++) {
                char *equals = strchr(*entry, '=');
                if (equals != NULL) {
                    *equals = '\0';
                    setenv(*entry, equals + 1, 1);
                    *equals = '=';
                } else {
                    unsetenv(*entry);
                }
            }
        }
        execvp(argv[0], argv);
        _exit(127);
    }

    /* Parent. The slave fd stays open (stored, never used for I/O):
     * it anchors the post-exit termios oracle — a pty whose only slave
     * handle closed tears down, and the restore state would be
     * unobservable (the M4-MAC-02 oracle defect). */
    pty->slaveFd = slave;
    pty->masterFd = master;
    pty->childPid = pid;
    return 0;
}

/* needletail 0000-A/B: posix_spawn launcher variant. The fork-based
 * launcher's children are session leaders with a controlling pty; on
 * macOS 26.7.1 under the Swift Testing runner such children have been
 * observed entering an unsampleable kernel-held exit state (?NEs) at
 * nondeterministic lifecycle points. This variant spawns WITHOUT
 * setsid/TIOCSCTTY: the child keeps the caller's process group
 * (posix_spawn SETPGROUP(0) gives it its own pgroup), has no
 * controlling terminal, and therefore has no session-leader tty
 * teardown to hang in. Semantics preserved for the raw-mode path:
 * tcsetattr/tcgetattr are fd-based (no ctty needed); ISIG is off in
 * raw mode so Ctrl+C arrives as a byte; there is no ctty so no
 * SIGTTOU can be raised by termio calls; SIGWINCH is NOT delivered
 * (no foreground process group) — resize-driven legs must use the
 * fork launcher. Both launchers are kept as an A/B control pair. */
int nt_pty_spawn_posix(nt_pty_t *pty, char *const argv[], char *const env[]) {
    if (pty == NULL || argv == NULL) {
        return -1;
    }
    memset(pty, 0, sizeof(*pty));

    int master = -1;
    int slave = -1;
    if (openpty(&master, &slave, NULL, NULL, NULL) != 0) {
        return -1;
    }
    if (tcgetattr(slave, &pty->savedSlaveTermios) == 0) {
        pty->haveSavedTermios = 1;
    }

    posix_spawn_file_actions_t actions;
    if (posix_spawn_file_actions_init(&actions) != 0) {
        close(master);
        close(slave);
        return -1;
    }
    posix_spawn_file_actions_adddup2(&actions, slave, STDIN_FILENO);
    posix_spawn_file_actions_adddup2(&actions, slave, STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, slave, STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, master);
    if (slave > STDERR_FILENO) {
        posix_spawn_file_actions_addclose(&actions, slave);
    }
    posix_spawnattr_t attr;
    if (posix_spawnattr_init(&attr) != 0) {
        posix_spawn_file_actions_destroy(&actions);
        close(master);
        close(slave);
        return -1;
    }
    sigset_t allSignals;
    sigset_t noSignals;
    sigfillset(&allSignals);
    sigemptyset(&noSignals);
    (void)(posix_spawnattr_setsigdefault(&attr, &allSignals) == 0);
    (void)(posix_spawnattr_setsigmask(&attr, &noSignals) == 0);
    (void)(posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETPGROUP) == 0);
    (void)(posix_spawnattr_setpgroup(&attr, 0) == 0);

    pid_t pid = -1;
    int rc;
    if (env != NULL) {
        rc = posix_spawnp(&pid, argv[0], &actions, &attr, argv, env);
    } else {
        rc = posix_spawnp(&pid, argv[0], &actions, &attr, argv, environ);
    }
    posix_spawnattr_destroy(&attr);
    posix_spawn_file_actions_destroy(&actions);
    if (rc != 0) {
        close(master);
        close(slave);
        errno = rc;
        return -1;
    }
    pty->slaveFd = slave;
    pty->masterFd = master;
    pty->childPid = pid;
    return 0;
}

int nt_pty_read(nt_pty_t *pty, unsigned char *buf, size_t capacity, int timeout_ms) {
    if (pty == NULL || pty->masterFd < 0 || buf == NULL || capacity == 0) {
        return -1;
    }
    fd_set readSet;
    FD_ZERO(&readSet);
    FD_SET(pty->masterFd, &readSet);
    struct timeval timeout;
    struct timeval *timeoutPtr = NULL;
    if (timeout_ms >= 0) {
        timeout.tv_sec = timeout_ms / 1000;
        timeout.tv_usec = (timeout_ms % 1000) * 1000;
        timeoutPtr = &timeout;
    }
    int ready = select(pty->masterFd + 1, &readSet, NULL, NULL, timeoutPtr);
    if (ready < 0) {
        return -1;
    }
    if (ready == 0) {
        return -1; /* deadline: the caller retries or fails */
    }
    ssize_t count = read(pty->masterFd, buf, capacity);
    if (count < 0) {
        return -1;
    }
    return (int)count;
}

int nt_pty_write(nt_pty_t *pty, const unsigned char *buf, size_t length) {
    if (pty == NULL || pty->masterFd < 0 || buf == NULL) {
        return -1;
    }
    size_t written = 0;
    while (written < length) {
        ssize_t count = write(pty->masterFd, buf + written, length - written);
        if (count < 0) {
            if (errno == EINTR) {
                continue;
            }
            return -1;
        }
        written += (size_t)count;
    }
    return 0;
}

int nt_pty_resize(nt_pty_t *pty, int rows, int cols) {
    if (pty == NULL || pty->masterFd < 0) {
        return -1;
    }
    struct winsize size;
    memset(&size, 0, sizeof(size));
    size.ws_row = (unsigned short)rows;
    size.ws_col = (unsigned short)cols;
    return ioctl(pty->masterFd, TIOCSWINSZ, &size);
}

int nt_pty_slave_termios(nt_pty_t *pty, struct termios *current) {
    if (pty == NULL || current == NULL || pty->slaveFd < 0) {
        return -1;
    }
    return tcgetattr(pty->slaveFd, current);
}

int nt_pty_have_initial_termios(nt_pty_t *pty) {
    return (pty != NULL && pty->haveSavedTermios) ? 1 : 0;
}

int nt_pty_slave_fd(nt_pty_t *pty) {
    return (pty != NULL) ? pty->slaveFd : -1;
}

/* M4-MAC-03 finding C: compare MEANINGFUL terminal settings only —
 * all four flag fields, every control character, and both speeds.
 * No memcmp: struct padding is unspecified and could make the verdict
 * depend on bytes that are not terminal state at all. */
static int termios_equal_meaningful(const struct termios *a, const struct termios *b) {
    if (a->c_iflag != b->c_iflag) return 0;
    if (a->c_oflag != b->c_oflag) return 0;
    if (a->c_cflag != b->c_cflag) return 0;
    if (a->c_lflag != b->c_lflag) return 0;
    for (int i = 0; i < NCCS; i++) {
        if (a->c_cc[i] != b->c_cc[i]) return 0;
    }
    if (cfgetispeed(a) != cfgetispeed(b)) return 0;
    if (cfgetospeed(a) != cfgetospeed(b)) return 0;
    return 1;
}

/* 1 = equal, 0 = differ (M4-MAC-03 regression-provable: flips of
 * VMIN/VTIME (c_cc) or IEXTEN (c_lflag) change the verdict). */
int nt_pty_termios_equal(struct termios *a, struct termios *b) {
    return termios_equal_meaningful(a, b);
}

/* M4-MAC-02: exact restoration verdict — full meaningful comparison. */
int nt_pty_termios_restored_exactly(nt_pty_t *pty) {
    if (pty == NULL || !pty->haveSavedTermios || pty->slaveFd < 0) {
        return -1;
    }
    struct termios current;
    if (tcgetattr(pty->slaveFd, &current) != 0) {
        return -1;
    }
    int verdict = termios_equal_meaningful(&current, &pty->savedSlaveTermios);
    if (verdict != 1) {
        int fd = open("/tmp/nb-td.log", O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd >= 0) {
            char buf[256];
            int n = snprintf(buf, sizeof(buf), "saved: l=%lx i=%lx o=%lx c=%lx cc[VT]=%x cc[VM]=%x\n",
                (unsigned long)pty->savedSlaveTermios.c_lflag,
                (unsigned long)pty->savedSlaveTermios.c_iflag, (unsigned long)pty->savedSlaveTermios.c_oflag,
                (unsigned long)pty->savedSlaveTermios.c_cflag,
                (unsigned)pty->savedSlaveTermios.c_cc[VTIME], (unsigned)pty->savedSlaveTermios.c_cc[VMIN]);
            ssize_t w1 = write(fd, buf, (size_t)n);
            (void)w1;
            n = snprintf(buf, sizeof(buf), "curr : l=%lx i=%lx o=%lx c=%lx cc[VT]=%x cc[VM]=%x\n",
                (unsigned long)current.c_lflag,
                (unsigned long)current.c_iflag, (unsigned long)current.c_oflag,
                (unsigned long)current.c_cflag,
                (unsigned)current.c_cc[VTIME], (unsigned)current.c_cc[VMIN]);
            ssize_t w2 = write(fd, buf, (size_t)n);
            (void)w2;
            close(fd);
        }
    }
    return verdict;
}

int nt_pty_signal(nt_pty_t *pty, int sig) {
    if (pty == NULL || pty->childPid <= 0) {
        return -1;
    }
    return kill(pty->childPid, sig);
}

int nt_pty_wait(nt_pty_t *pty, int timeout_ms) {
    if (pty == NULL || pty->childPid <= 0) {
        return -1;
    }
    int waited_ms = 0;
    for (;;) {
        int status = 0;
        pid_t result = waitpid(pty->childPid, &status, WNOHANG);
        if (result < 0) {
            return -1;
        }
        if (result == pty->childPid) {
            return status;
        }
        if (timeout_ms >= 0 && waited_ms >= timeout_ms) {
            return -1;
        }
        usleep(10 * 1000);
        waited_ms += 10;
    }
}

void nt_pty_close(nt_pty_t *pty) {
    if (pty == NULL) {
        return;
    }
    if (pty->childPid > 0) {
        int status = 0;
        /* Reap only our own child; bounded, then signal, then reap. */
        if (waitpid(pty->childPid, &status, WNOHANG) == 0) {
            kill(pty->childPid, SIGTERM);
            for (int waited = 0; waited < 500; waited += 10) {
                if (waitpid(pty->childPid, &status, WNOHANG) == pty->childPid) {
                    break;
                }
                usleep(10 * 1000);
            }
            if (waitpid(pty->childPid, &status, WNOHANG) == 0) {
                kill(pty->childPid, SIGKILL);
                waitpid(pty->childPid, &status, 0);
            }
        }
        pty->childPid = -1;
    }
    if (pty->masterFd >= 0) {
        close(pty->masterFd);
	if (pty->slaveFd >= 0) { close(pty->slaveFd); pty->slaveFd = -1; }
        pty->masterFd = -1;
    }
}

static int g_usr1WriteFd = -1;

static void nt_usr1_handler(int sig) {
    (void)sig;
    if (g_usr1WriteFd >= 0) {
        char byte = 1;
        ssize_t ignored = write(g_usr1WriteFd, &byte, 1);
        (void)ignored;
    }
}

void nt_install_usr1_pipe(int writeFd) {
    g_usr1WriteFd = writeFd;
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = nt_usr1_handler;
    sigemptyset(&action.sa_mask);
    action.sa_flags = 0; /* no SA_RESTART: let read() observe the pipe */
    sigaction(SIGUSR1, &action, NULL);
    /* fork() inherits the parent's signal mask, and the Swift Testing
     * runner blocks SIGUSR1: a child that does not unblock it would never
     * receive the signal. Unblock it explicitly. */
    sigset_t set;
    sigemptyset(&set);
    sigaddset(&set, SIGUSR1);
    pthread_sigmask(SIG_UNBLOCK, &set, NULL);
}

int nt_pty_open_pair(nt_pty_pair_t *pair) {
    memset(pair, 0, sizeof(*pair));
    int master = posix_openpt(O_RDWR | O_NOCTTY);
    if (master < 0) return -1;
    if (grantpt(master) != 0 || unlockpt(master) != 0) {
        close(master);
        return -1;
    }
    const char *slaveName = ptsname(master);
    if (slaveName == NULL) {
        close(master);
        return -1;
    }
    char slavePath[128];
    snprintf(slavePath, sizeof(slavePath), "%s", slaveName);
    int slave = open(slavePath, O_RDWR | O_NOCTTY);
    if (slave < 0) {
        close(master);
        return -1;
    }
    pair->master = master;
    pair->slave = slave;
    pair->retainedSlave = -1;
    struct termios t;
    if (tcgetattr(slave, &t) == 0) {
        pair->haveInitial = 1;
        pair->initial = t;
    }
    return 0;
}

void nt_pty_pair_close(nt_pty_pair_t *pair) {
    if (pair->master >= 0) close(pair->master);
    if (pair->slave >= 0) close(pair->slave);
    if (pair->retainedSlave >= 0) close(pair->retainedSlave);
    memset(pair, 0, sizeof(*pair));
}

#pragma weak replxx_notify_drops
unsigned long nt_replxx_notify_drops(void) {
    extern unsigned long replxx_notify_drops(void);
    if ((void *)replxx_notify_drops != NULL) {
        return replxx_notify_drops();
    }
    return 0;
}

static void nt_shim_trace(const char *msg) {
    if (getenv("NB_INPUT_TRACE") != NULL) {
        fprintf(stderr, "[it]%s\n", msg);
        fflush(stderr);
    }
}

int nt_bootstrap_acquire_ctty(void) {
    return ioctl(0, TIOCSCTTY, 0);
}

/* needletail 0000-A/B: build the FULL inherited environment with
 * child-only overrides/unsets applied in the parent (matching the fork
 * launcher's semantics — the child inherits everything except the
 * explicit overrides). Returns a malloc'd NULL-terminated array the
 * caller owns. */
static char **nt_build_full_env(char *const env[]) {
    size_t baseCount = 0;
    while (environ[baseCount] != NULL) baseCount++;
    size_t overrideCount = 0;
    if (env != NULL) while (env[overrideCount] != NULL) overrideCount++;
    size_t capacity = baseCount + overrideCount + 2;
    char **merged = calloc(capacity, sizeof(char *));
    if (merged == NULL) return NULL;
    size_t used = 0;
    for (size_t i = 0; i < baseCount; i++) {
        const char *entry = environ[i];
        const char *equals = strchr(entry, '=');
        size_t keyLen = equals != NULL ? (size_t)(equals - entry) : strlen(entry);
        int overridden = 0;
        for (size_t j = 0; j < overrideCount; j++) {
            const char *o = env[j];
            if (strncmp(o, entry, keyLen) == 0 &&
                (o[keyLen] == '=' || o[keyLen] == '\0')) {
                overridden = 1;
                break;
            }
        }
        if (!overridden) {
            merged[used] = strdup(entry);
            if (merged[used] != NULL) used++;
        }
    }
    for (size_t j = 0; j < overrideCount; j++) {
        if (strchr(env[j], '=') != NULL) {
            merged[used] = strdup(env[j]);
            if (merged[used] != NULL) used++;
        }
    }
    return merged;
}

/* needletail 0000-A/B: the CONTROLLED posix launcher. Spawns
 * argv[0] (the bootstrap fixture) with POSIX_SPAWN_SETSID (a new
 * session, NOT SETPGROUP); the bootstrap acquires the controlling
 * terminal, verifies session/foreground ownership and execs the real
 * executable (the caller prebuilds argv: [bootstrap, executable,
 * args..., NULL]). env entries are "KEY=VALUE" overrides or bare
 * "KEY" unsets merged over the full inherited environment in the
 * parent. */
int nt_pty_spawn_posix_ctty(nt_pty_t *pty, char *const argv[], char *const env[]) {
    nt_shim_trace("spct:enter");
    if (pty == NULL || argv == NULL || argv[0] == NULL) {
        return -1;
    }
    memset(pty, 0, sizeof(*pty));

    int master = -1;
    int slave = -1;
    if (openpty(&master, &slave, NULL, NULL, NULL) != 0) {
        return -1;
    }
    if (tcgetattr(slave, &pty->savedSlaveTermios) == 0) {
        pty->haveSavedTermios = 1;
    }

    posix_spawn_file_actions_t actions;
    if (posix_spawn_file_actions_init(&actions) != 0) {
        close(master);
        close(slave);
        return -1;
    }
    posix_spawn_file_actions_adddup2(&actions, slave, STDIN_FILENO);
    posix_spawn_file_actions_adddup2(&actions, slave, STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, slave, STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, master);
    if (slave > STDERR_FILENO) {
        posix_spawn_file_actions_addclose(&actions, slave);
    }
    posix_spawnattr_t attr;
    if (posix_spawnattr_init(&attr) != 0) {
        posix_spawn_file_actions_destroy(&actions);
        close(master);
        close(slave);
        return -1;
    }
    sigset_t allSignals;
    sigset_t noSignals;
    sigfillset(&allSignals);
    sigemptyset(&noSignals);
    (void)(posix_spawnattr_setsigdefault(&attr, &allSignals) == 0);
    (void)(posix_spawnattr_setsigmask(&attr, &noSignals) == 0);
    /* SETSID only: a new session (and its own process group) without
     * SETPGROUP, so the bootstrap can acquire the controlling terminal
     * as the session leader. */
    int spawnFlags = POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK;
    if (getenv("NB_NO_SETSID") == NULL) spawnFlags |= POSIX_SPAWN_SETSID;
    (void)(posix_spawnattr_setflags(&attr, spawnFlags) == 0);
    (void)(getenv("NB_NO_SETSID") == NULL); /* bisection knob retained */
    nt_shim_trace("spct:spawning");
    pid_t pid = -1;
    int rc = posix_spawnp(&pid, argv[0], &actions, &attr, argv, env);
    {
        char m[64];
        snprintf(m, sizeof(m), "spct:spawned rc=%d pid=%d", rc, (int)pid);
        nt_shim_trace(m);
    }
    posix_spawnattr_destroy(&attr);
    posix_spawn_file_actions_destroy(&actions);
    if (rc != 0) {
        close(master);
        close(slave);
        errno = rc;
        return -1;
    }
    pty->slaveFd = slave;
    pty->masterFd = master;
    pty->childPid = pid;
    return 0;
}
