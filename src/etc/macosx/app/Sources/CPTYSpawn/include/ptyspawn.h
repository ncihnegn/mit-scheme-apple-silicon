#ifndef MIT_SCHEME_PTY_SPAWN_H
#define MIT_SCHEME_PTY_SPAWN_H

#include <sys/types.h>

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
);

#endif
