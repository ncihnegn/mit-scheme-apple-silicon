#include "ptyspawn.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>

int mit_scheme_pty_spawn(
    const char *executable_path,
    char *const argv[],
    char *const envp[],
    const char *working_directory,
    int rows,
    int cols,
    int enable_echo,
    int *master_fd_out,
    pid_t *pid_out,
    int *errno_out
) {
    if (!executable_path || !argv || !envp || !master_fd_out || !pid_out) {
        if (errno_out) *errno_out = EINVAL;
        return -1;
    }

    struct winsize ws;
    ws.ws_row = (unsigned short)(rows > 0 ? rows : 24);
    ws.ws_col = (unsigned short)(cols > 0 ? cols : 80);
    ws.ws_xpixel = 0;
    ws.ws_ypixel = 0;

    int master_fd = -1;
    int slave_fd = -1;
    if (openpty(&master_fd, &slave_fd, NULL, NULL, &ws) != 0) {
        if (errno_out) *errno_out = errno;
        return -1;
    }

    struct termios tty;
    if (tcgetattr(slave_fd, &tty) == 0) {
        if (!enable_echo) {
            tty.c_lflag &= ~(tcflag_t)(ECHO | ECHOE | ECHOK | ECHONL);
            tty.c_oflag &= ~(tcflag_t)(ONLCR);
        }
        (void)tcsetattr(slave_fd, TCSANOW, &tty);
    }

    (void)fcntl(master_fd, F_SETFD, FD_CLOEXEC);
    int flags = fcntl(master_fd, F_GETFL, 0);
    if (flags >= 0) {
        (void)fcntl(master_fd, F_SETFL, flags | O_NONBLOCK);
    }

    pid_t pid = fork();
    if (pid < 0) {
        int saved = errno;
        close(master_fd);
        close(slave_fd);
        if (errno_out) *errno_out = saved;
        return -2;
    }

    if (pid == 0) {
        close(master_fd);
        (void)setsid();
        (void)ioctl(slave_fd, TIOCSCTTY, 0);
        (void)dup2(slave_fd, STDIN_FILENO);
        (void)dup2(slave_fd, STDOUT_FILENO);
        (void)dup2(slave_fd, STDERR_FILENO);
        if (slave_fd > STDERR_FILENO) {
            close(slave_fd);
        }

        int max_fd = getdtablesize();
        if (max_fd > 4096) max_fd = 4096;
        for (int fd = 3; fd < max_fd; fd++) {
            close(fd);
        }

        if (working_directory && working_directory[0] != '\0') {
            (void)chdir(working_directory);
        }
        (void)signal(SIGPIPE, SIG_DFL);
        execve(executable_path, argv, envp);
        _exit(127);
    }

    close(slave_fd);
    *master_fd_out = master_fd;
    *pid_out = pid;
    if (errno_out) *errno_out = 0;
    return 0;
}
