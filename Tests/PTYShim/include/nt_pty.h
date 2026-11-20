/*
 * PTYShim — test-only C shim for the native terminal tests (UX-DX §3.3,
 * TESTING §7). OS interfaces only: forkpty/openpty-family facilities,
 * termios, ioctl(TIOCSWINSZ), signals. Linked ONLY by
 * NeedletailTerminalTests, never by a product target. Platform-specific
 * linking is qualified on Linux now and macOS at M4.
 */
#ifndef NEEDLETAIL_PTY_SHIM_H
#define NEEDLETAIL_PTY_SHIM_H

#include <stddef.h>
#include <sys/types.h>
#include <termios.h>

typedef struct {
    int masterFd;
    pid_t childPid;
    struct termios savedSlaveTermios;
    int slaveFd; /* kept open in the parent: post-exit termios oracle */
    int haveSavedTermios;
} nt_pty_t;

/* Spawn `argv` under a fresh PTY. Returns 0 on success. */
int nt_pty_spawn(nt_pty_t *pty, char *const argv[]);

/* Spawn with child-only environment overrides applied after fork (the
 * parent environment is never touched): each entry is "KEY=VALUE" to
 * set, or bare "KEY" to unset. `env` may be NULL. Returns 0 on
 * success. */
int nt_pty_spawn_env(nt_pty_t *pty, char *const argv[], char *const env[]);

/* Bounded read from the master. Returns bytes read, 0 on EOF, -1 on error
 * or timeout (timeout in milliseconds). Never blocks past the deadline. */
int nt_pty_read(nt_pty_t *pty, unsigned char *buf, size_t capacity, int timeout_ms);

/* Write bytes to the master (i.e. to the child's input). */
int nt_pty_write(nt_pty_t *pty, const unsigned char *buf, size_t length);

/* Resize the slave window (rows x cols). */
int nt_pty_resize(nt_pty_t *pty, int rows, int cols);

/* Deliver a signal to the child. */
int nt_pty_signal(nt_pty_t *pty, int sig);

/* Wait for the child to exit within the deadline. Returns the wait status,
 * -1 on timeout. */
int nt_pty_wait(nt_pty_t *pty, int timeout_ms);

/* M4-MAC-02 exact-restore oracle: the parent keeps the slave open, so
 * after the child exits the termios is still readable. Returns 0 and
 * fills current with the slave's live termios; -1 if unavailable. */
int nt_pty_slave_termios(nt_pty_t *pty, struct termios *current);
/* 1 when the spawn-time initial termios was captured, else 0. */
int nt_pty_have_initial_termios(nt_pty_t *pty);
/* The retained slave descriptor (post-exit termios oracle anchor). */
int nt_pty_slave_fd(nt_pty_t *pty);
/* M4-MAC-03: meaningful-settings equality (flags, all NCCS control
 * chars, speeds) — no struct padding involvement. 1 = equal. */
int nt_pty_termios_equal(struct termios *a, struct termios *b);

/* A bare pty pair without a child process: for in-process editor
 * probes that need a real terminal on fd 0. */
typedef struct {
    int master;
    int slave;
    int retainedSlave;
    int haveInitial;
    struct termios initial;
} nt_pty_pair_t;
int nt_pty_open_pair(nt_pty_pair_t *pair);
void nt_pty_pair_close(nt_pty_pair_t *pair);
/* 1 when the live slave termios equals the spawn-time capture exactly
 * (full struct memcmp, c_cc included); 0 when it differs; -1 if
 * unavailable. */
int nt_pty_termios_restored_exactly(nt_pty_t *pty);

/* Close the master and reap if needed. */
void nt_pty_close(nt_pty_t *pty);

/* Install a SIGUSR1 handler that writes one byte to `writeFd`
 * (async-signal-safe self-pipe pattern). Kept in C because a Swift
 * @convention(c) handler cannot capture context. */
void nt_install_usr1_pipe(int writeFd);

#endif
