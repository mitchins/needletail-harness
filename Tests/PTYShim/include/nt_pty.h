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
    int haveSavedTermios;
} nt_pty_t;

/* Spawn `argv` under a fresh PTY. Returns 0 on success. */
int nt_pty_spawn(nt_pty_t *pty, char *const argv[]);

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

/* Close the master and reap if needed. */
void nt_pty_close(nt_pty_t *pty);

/* Install a SIGUSR1 handler that writes one byte to `writeFd`
 * (async-signal-safe self-pipe pattern). Kept in C because a Swift
 * @convention(c) handler cannot capture context. */
void nt_install_usr1_pipe(int writeFd);

#endif
