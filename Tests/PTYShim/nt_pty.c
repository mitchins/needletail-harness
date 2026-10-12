/*
 * PTYShim implementation — Linux. Uses forkpty-family facilities through
 * openpty + login_tty (forkpty itself glibc-internal), termios save/restore,
 * ioctl(TIOCSWINSZ), waitpid with deadlines, and bounded select() reads.
 * Teardown kills only the child it spawned (never a generic name).
 */
#include "nt_pty.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#include <pty.h>
#include <pthread.h>

int nt_pty_spawn(nt_pty_t *pty, char *const argv[]) {
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
        execvp(argv[0], argv);
        _exit(127);
    }

    /* Parent. */
    close(slave);
    pty->masterFd = master;
    pty->childPid = pid;
    return 0;
}

int nt_pty_read(nt_pty_t *pty, char *buf, size_t capacity, int timeout_ms) {
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

int nt_pty_write(nt_pty_t *pty, const char *buf, size_t length) {
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
