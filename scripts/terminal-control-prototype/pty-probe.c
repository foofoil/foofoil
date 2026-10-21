#include <util.h>
#include <sys/wait.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <signal.h>
#include <poll.h>
#include <stdio.h>
#include <errno.h>
#include <string.h>
#include <time.h>

/* 仅运行常量脚本和脚本创建的夹具。子进程只用 async-signal-safe 调用。 */
int main(int argc, char **argv) {
    if (argc != 3 && argc != 4) return 2;
    int master = -1;
    struct winsize size = {.ws_row = 24, .ws_col = 80};
    pid_t child = forkpty(&master, NULL, NULL, &size);
    if (child < 0) { printf("forkpty errno=%d (%s)\n", errno, strerror(errno)); return 3; }
    if (child == 0) {
        if (tcsetpgrp(STDIN_FILENO, getpgrp()) == 0) {
            const char message[] = "PGRP_OK\n";
            write(STDOUT_FILENO, message, sizeof(message) - 1);
        } else {
            const char message[] = "PGRP_DENIED\n";
            write(STDOUT_FILENO, message, sizeof(message) - 1);
        }
        const char *script = argc == 4 ? "\"$1\" --version" :
            "if test -t 0 && test -t 1; then printf 'TTY_OK\\n'; fi; "
            "if test -r \"$1\"; then printf 'FILE_OK\\n'; else printf 'FILE_DENIED\\n'; fi; "
            "if cd -- \"${1%/*}\"; then printf 'CWD_OK\\n'; else printf 'CWD_DENIED\\n'; fi; "
            "if ( : > \"${1%/*}/shell-created\" ); then printf 'WRITE_OK\\n'; else printf 'WRITE_DENIED\\n'; fi; "
            "exit 0";
        int bash = strstr(argv[1], "bash") != NULL;
        char *const args[] = {argv[1], bash ? "--noprofile" : "-f", bash ? "--norc" : "-f",
                              "-i", "-c", (char *)script, "probe", argv[2], NULL};

        execv(argv[1], args);
        _exit(127);
    }
    time_t deadline = time(NULL) + 5;
    size_t total = 0;
    int status = 0;
    int exited = 0;
    while (time(NULL) < deadline && total < 16384) {
        struct pollfd item = {.fd = master, .events = POLLIN};
        if (poll(&item, 1, 100) > 0 && (item.revents & (POLLIN | POLLHUP))) {
            char buffer[1024];
            ssize_t count = read(master, buffer, sizeof(buffer));
            if (count <= 0) break;
            fwrite(buffer, 1, (size_t)count, stdout);
            total += (size_t)count;
        }
        if (!exited && waitpid(child, &status, WNOHANG) == child) exited = 1;
    }
    /* 仅终止本 helper 创建的会话组，并回收直接子进程。 */
    if (!exited && waitpid(child, &status, WNOHANG) == 0) {
        kill(-child, SIGKILL);
        kill(child, SIGKILL);
        while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
    }
    close(master);
    return WIFEXITED(status) ? WEXITSTATUS(status) : 4;
}
