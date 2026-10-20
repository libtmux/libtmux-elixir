#define _GNU_SOURCE
#include <sys/prctl.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define INPUT_MAX 32768
#define CHUNK_MAX 8192
#define OUT_SLOTS 8
#define OUT_MAX (CHUNK_MAX + 4)
#define ARGC_MAX 256

struct packet { unsigned char bytes[OUT_MAX]; size_t size, sent; };
struct state {
    unsigned char input[INPUT_MAX + 2], write[CHUNK_MAX];
    size_t input_have, input_need, write_size, write_sent;
    uint32_t write_id;
    int write_pending, write_failed, close_pending;
    struct packet output[OUT_SLOTS];
    unsigned head, count;
    int child_in, streams[2], exec_fd, signals[2];
    unsigned credits[2];
    int eof[2], configured, ready, parent_gone, stopping, reason;
    int retired, terminal, fatal, fatal_errno, wait_status, leader_reaped;
    int cleanup_warned;
    pid_t child;
    int64_t deadline, cleanup_deadline, delivery_deadline;
};

static int signal_write = -1;
static volatile sig_atomic_t terminate_requested;

static int64_t now_ms(void) {
    struct timespec t;
    if (clock_gettime(CLOCK_MONOTONIC, &t) == -1) _exit(120);
    return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

static void signal_event(int number) {
    int saved = errno;
    unsigned char byte = (unsigned char)number;
    if (number != SIGCHLD) terminate_requested = 1;
    if (signal_write != -1) { ssize_t result = write(signal_write, &byte, 1); (void)result; }
    errno = saved;
}

static uint16_t get16(const unsigned char *p) { return (uint16_t)((p[0] << 8) | p[1]); }
static uint32_t get32(const unsigned char *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}
static void put32(unsigned char *p, uint32_t value) {
    p[0] = value >> 24; p[1] = value >> 16; p[2] = value >> 8; p[3] = value;
}
static void close_fd(int *fd) { if (*fd != -1) { close(*fd); *fd = -1; } }

static int enqueue(struct state *s, const unsigned char *body, size_t size) {
    if (s->terminal || s->count == OUT_SLOTS || size > OUT_MAX - 2) return 0;
    struct packet *p = &s->output[(s->head + s->count) % OUT_SLOTS];
    p->bytes[0] = size >> 8; p->bytes[1] = size;
    memcpy(p->bytes + 2, body, size);
    p->size = size + 2; p->sent = 0; s->count++;
    return 1;
}

static void stop_child(struct state *s, int reason) {
    if (s->terminal) return;
    if (!s->stopping) {
        s->stopping = 1; s->reason = reason; s->cleanup_deadline = now_ms() + 750;
        if (reason == 0 && !s->deadline) s->deadline = now_ms() + 750;
        /* Keep the leader unreaped until the group signal; its PID cannot be reused. */
        if (s->child > 0) (void)kill(-s->child, SIGKILL);
    } else if (reason != 0 && s->reason == 0) s->reason = reason;
    close_fd(&s->child_in);
    if (s->write_pending && s->write_sent != s->write_size) s->write_failed = 1;
    if (reason != 0 || s->parent_gone) {
        if (!s->delivery_deadline) s->delivery_deadline = now_ms() + 750;
        close_fd(&s->exec_fd);
        for (int i = 0; i < 2; i++) {
            close_fd(&s->streams[i]); s->eof[i] = 1; s->credits[i] = 0;
        }
    }
}

static void fail(struct state *s, int reason, int error) {
    if (!s->fatal) { s->fatal = reason; s->fatal_errno = error; }
    stop_child(s, 3);
}

static int nonblock(int fd) {
    int flags = fcntl(fd, F_GETFL);
    return flags == -1 ? -1 : fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

static int child_fds(int keep) {
    DIR *directory = opendir("/proc/self/fd");
    if (!directory) return -1;
    int own = dirfd(directory);
    struct dirent *entry;
    while ((entry = readdir(directory)) != NULL) {
        char *end;
        long fd = strtol(entry->d_name, &end, 10);
        if (*end == '\0' && fd > 2 && fd != keep && fd != own) close((int)fd);
    }
    closedir(directory);
    return 0;
}

static char *take_string(const unsigned char **at, size_t *left) {
    if (*left < 2) return NULL;
    size_t size = get16(*at); *at += 2; *left -= 2;
    if (size > *left || memchr(*at, 0, size)) return NULL;
    char *value = malloc(size + 1);
    if (!value) return NULL;
    memcpy(value, *at, size); value[size] = '\0'; *at += size; *left -= size;
    return value;
}

static void launch(struct state *s, const unsigned char *body, size_t size) {
    char *cwd = NULL, *args[ARGC_MAX + 1] = {0}, *environment[ARGC_MAX + 1] = {0};
    int pipes[4][2] = {{-1,-1},{-1,-1},{-1,-1},{-1,-1}};
    int error = EINVAL;
    if (size < 11 || body[0] != 'O' || body[1] != 2 || body[2] > 1) goto bad;
    int input_open = body[2];
    uint32_t timeout = get32(body + 3);
    if (timeout > 600000) goto bad;
    s->deadline = timeout ? now_ms() + timeout : 0;
    const unsigned char *at = body + 7;
    size_t left = size - 7;
    cwd = take_string(&at, &left);
    if (!cwd || !*cwd || left < 2) goto bad;
    unsigned count = get16(at); at += 2; left -= 2;
    if (!count || count > ARGC_MAX) goto bad;
    for (unsigned i = 0; i < count; i++) {
        args[i] = take_string(&at, &left);
        if (!args[i]) goto bad;
    }
    if (left < 2 || args[0][0] != '/') goto bad;
    unsigned env_count = get16(at); at += 2; left -= 2;
    if (env_count > ARGC_MAX) goto bad;
    for (unsigned i = 0; i < env_count; i++) {
        environment[i] = take_string(&at, &left);
        if (!environment[i]) goto bad;
        char *equals = strchr(environment[i], '=');
        if (!equals || equals == environment[i]) goto bad;
    }
    if (left) goto bad;
    for (int i = 0; i < 4; i++) {
        if (pipe2(pipes[i], O_CLOEXEC) == -1) { error = errno; goto bad; }
        if (fcntl(pipes[i][0], F_SETPIPE_SZ, 8192) == -1) { error = errno; goto bad; }
    }
    s->child = fork();
    if (s->child == -1) { s->child = 0; error = errno; goto bad; }
    if (s->child == 0) {
        int error_fd = pipes[3][1];
        if (setsid() == -1 || chdir(cwd) == -1 ||
            dup2(pipes[0][0], STDIN_FILENO) == -1 ||
            dup2(pipes[1][1], STDOUT_FILENO) == -1 ||
            dup2(pipes[2][1], STDERR_FILENO) == -1) goto exec_error;
        if (child_fds(error_fd) == -1) goto exec_error;
        signal(SIGCHLD, SIG_DFL); signal(SIGTERM, SIG_DFL);
        signal(SIGHUP, SIG_DFL); signal(SIGINT, SIG_DFL); signal(SIGPIPE, SIG_DFL);
        execve(args[0], args, environment);
exec_error:
        error = errno;
        ssize_t result = write(error_fd, &error, sizeof error);
        (void)result;
        _exit(127);
    }
    close(pipes[0][0]); pipes[0][0] = -1;
    close(pipes[1][1]); pipes[1][1] = -1;
    close(pipes[2][1]); pipes[2][1] = -1;
    close(pipes[3][1]); pipes[3][1] = -1;
    s->child_in = pipes[0][1]; pipes[0][1] = -1;
    s->streams[0] = pipes[1][0]; pipes[1][0] = -1;
    s->streams[1] = pipes[2][0]; pipes[2][0] = -1;
    s->exec_fd = pipes[3][0]; pipes[3][0] = -1;
    if (!input_open) close_fd(&s->child_in);
    for (int i = 0; i < 2; i++) if (nonblock(s->streams[i]) == -1) goto launch_error;
    if (nonblock(s->exec_fd) == -1 ||
        (s->child_in != -1 && nonblock(s->child_in) == -1)) goto launch_error;
    s->configured = 1;
    goto out;
launch_error:
    error = errno;
bad:
    fail(s, 1, error);
out:
    free(cwd);
    for (unsigned i = 0; i < ARGC_MAX; i++) { free(args[i]); free(environment[i]); }
    for (int i = 0; i < 4; i++) for (int j = 0; j < 2; j++) close_fd(&pipes[i][j]);
}

static void input_packet(struct state *s, const unsigned char *body, size_t size) {
    /* A closing lane may still contain earlier credits or write fragments. */
    if (s->terminal || (s->stopping && s->reason != 0)) return;
    if (!s->configured && !s->stopping) { launch(s, body, size); return; }
    if (size == 1 && body[0] == 'Q') { stop_child(s, 1); return; }
    if (s->fatal || !s->ready) { fail(s, 1, EPROTO); return; }
    if (size == 4 && body[0] == 'R') {
        unsigned stream = body[1], credit = get16(body + 2);
        if (stream < 1 || stream > 2 || !credit || credit > CHUNK_MAX ||
            s->credits[stream - 1] || s->eof[stream - 1]) { fail(s, 1, EPROTO); return; }
        s->credits[stream - 1] = credit;
    } else if (size > 5 && size <= CHUNK_MAX + 5 && body[0] == 'W') {
        if (s->write_pending || (!s->stopping && s->child_in == -1)) { fail(s, 1, EPROTO); return; }
        s->write_id = get32(body + 1); s->write_size = size - 5; s->write_sent = 0;
        memcpy(s->write, body + 5, s->write_size); s->write_pending = 1; s->write_failed = s->stopping;
    } else if (size == 1 && body[0] == 'C') {
        if ((!s->stopping && s->child_in == -1) || s->write_pending || s->close_pending) { fail(s, 1, EPROTO); return; }
        close_fd(&s->child_in);
        s->close_pending = 1;
    } else fail(s, 1, EPROTO);
}

static void read_parent(struct state *s) {
    ssize_t count = read(STDIN_FILENO, s->input + s->input_have, s->input_need - s->input_have);
    if (count == 0) { s->parent_gone = 1; stop_child(s, 1); return; }
    if (count < 0) {
        if (errno != EINTR && errno != EAGAIN) { s->parent_gone = 1; stop_child(s, 1); }
        return;
    }
    s->input_have += (size_t)count;
    if (s->input_have != s->input_need) return;
    if (s->input_need == 2) {
        size_t size = get16(s->input);
        if (!size || size > INPUT_MAX) { fail(s, 1, EMSGSIZE); return; }
        s->input_need += size;
    } else {
        input_packet(s, s->input + 2, s->input_need - 2);
        s->input_have = 0; s->input_need = 2;
    }
}

static void write_parent(struct state *s) {
    if (!s->count) return;
    struct packet *p = &s->output[s->head];
    ssize_t size = write(STDOUT_FILENO, p->bytes + p->sent, p->size - p->sent);
    if (size > 0) {
        p->sent += (size_t)size;
        if (p->sent == p->size) { s->head = (s->head + 1) % OUT_SLOTS; s->count--; }
    } else if (size < 0 && errno != EINTR && errno != EAGAIN) {
        s->parent_gone = 1; stop_child(s, 1);
    }
}

static void read_stream(struct state *s, int index) {
    unsigned char body[CHUNK_MAX + 2];
    ssize_t size = read(s->streams[index], body + 2, s->credits[index]);
    if (size < 0) {
        if (errno != EINTR && errno != EAGAIN) fail(s, 3, errno);
        return;
    }
    body[1] = index + 1;
    if (size == 0) {
        body[0] = 'Z'; s->eof[index] = 1; close_fd(&s->streams[index]);
        (void)enqueue(s, body, 2);
    } else {
        body[0] = 'D'; (void)enqueue(s, body, (size_t)size + 2);
    }
    s->credits[index] = 0;
}

static void write_child(struct state *s) {
    ssize_t size = write(s->child_in, s->write + s->write_sent, s->write_size - s->write_sent);
    if (size > 0) s->write_sent += (size_t)size;
    else if (size < 0 && errno != EINTR && errno != EAGAIN) {
        s->write_failed = 1; close_fd(&s->child_in);
    }
}

static void kill_adopted(void) {
    char path[80];
    snprintf(path, sizeof path, "/proc/self/task/%ld/children", (long)getpid());
    FILE *file = fopen(path, "re");
    if (!file) return;
    long child;
    /* Only unreaped direct children occur here; this process is their sole reaper. */
    for (unsigned count = 0; count < 4096 && fscanf(file, "%ld", &child) == 1; count++) {
        if (child > 0) (void)kill((pid_t)child, SIGKILL);
    }
    fclose(file);
}

static void lifecycle(struct state *s) {
    if (s->terminal) return;
    if (terminate_requested) stop_child(s, 1);
    if (s->deadline && now_ms() >= s->deadline) stop_child(s, 2);
    if (s->child > 0 && !s->stopping) {
        siginfo_t info = {0};
        if (waitid(P_PID, (id_t)s->child, &info, WEXITED | WNOHANG | WNOWAIT) == 0 && info.si_pid)
            stop_child(s, 0);
    }
    if (s->stopping) {
        kill_adopted();
        for (;;) {
            int status;
            pid_t child = waitpid(-1, &status, WNOHANG);
            if (child > 0) {
                if (child == s->child) {
                    s->leader_reaped = 1;
                    s->wait_status = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
                }
                continue;
            }
            if (child == -1 && errno == ECHILD) s->retired = 1;
            break;
        }
    }
    if (s->write_pending && (s->write_sent == s->write_size || s->write_failed) && s->count < OUT_SLOTS) {
        unsigned char ack[8] = {'A'};
        put32(ack + 1, s->write_id);
        ack[5] = s->write_sent >> 8; ack[6] = s->write_sent; ack[7] = s->write_failed;
        (void)enqueue(s, ack, sizeof ack); s->write_pending = 0;
    }
    if (s->close_pending && s->count < OUT_SLOTS) {
        (void)enqueue(s, (const unsigned char *)"C", 1); s->close_pending = 0;
    }
    if (s->stopping && !s->retired && !s->cleanup_warned && now_ms() >= s->cleanup_deadline) {
        if (s->count < OUT_SLOTS) {
            unsigned char warning[] = {'F', 4, 0, 0, 0, 0};
            (void)enqueue(s, warning, sizeof warning); s->cleanup_warned = 1;
        }
    }
    if (s->retired && s->exec_fd == -1 && s->count < OUT_SLOTS &&
        (s->fatal || (s->eof[0] && s->eof[1] && !s->write_pending && !s->close_pending))) {
        unsigned char terminal[6];
        terminal[0] = s->fatal ? 'F' : 'E';
        terminal[1] = s->fatal ? s->fatal : s->reason;
        put32(terminal + 2, s->fatal ? (uint32_t)s->fatal_errno : (uint32_t)s->wait_status);
        if (!s->delivery_deadline) s->delivery_deadline = now_ms() + 750;
        (void)enqueue(s, terminal, sizeof terminal); s->terminal = 1;
    }
}

static void exec_result(struct state *s) {
    if (s->terminal || (s->stopping && s->reason != 0)) { close_fd(&s->exec_fd); return; }
    int error;
    ssize_t size = read(s->exec_fd, &error, sizeof error);
    if (size == 0) {
        unsigned char body[5] = {'S'};
        put32(body + 1, (uint32_t)s->child);
        if (!enqueue(s, body, sizeof body)) { fail(s, 1, ENOBUFS); return; }
        s->ready = 1; close_fd(&s->exec_fd);
    } else if (size > 0) { close_fd(&s->exec_fd); fail(s, 2, size == sizeof error ? error : EIO); }
    else if (errno != EINTR && errno != EAGAIN) { close_fd(&s->exec_fd); fail(s, 2, errno); }
}

int main(void) {
    struct state s = {0};
    s.child_in = s.exec_fd = s.streams[0] = s.streams[1] = -1;
    s.input_need = 2; s.deadline = now_ms() + 750;
    if (prctl(PR_SET_CHILD_SUBREAPER, 1) == -1 || pipe2(s.signals, O_CLOEXEC | O_NONBLOCK) == -1)
        return 122;
    if (fcntl(s.signals[0], F_SETPIPE_SZ, 4096) == -1) return 122;
    signal_write = s.signals[1];
    struct sigaction action = {0};
    action.sa_handler = signal_event; sigemptyset(&action.sa_mask);
    sigaction(SIGCHLD, &action, NULL); sigaction(SIGTERM, &action, NULL);
    sigaction(SIGHUP, &action, NULL); sigaction(SIGINT, &action, NULL);
    signal(SIGPIPE, SIG_IGN);
    if (nonblock(STDIN_FILENO) == -1 || nonblock(STDOUT_FILENO) == -1) return 123;

    for (;;) {
        lifecycle(&s);
        if (s.parent_gone && s.retired) break;
        if (s.terminal && s.count == 0) break;
        if (s.retired && s.delivery_deadline && now_ms() >= s.delivery_deadline) return 124;
        struct pollfd fds[7] = {
            {STDIN_FILENO, POLLIN, 0}, {STDOUT_FILENO, s.count ? POLLOUT : 0, 0},
            {s.signals[0], POLLIN, 0}, {s.terminal ? -1 : s.exec_fd, POLLIN, 0},
            {-1, POLLIN, 0}, {-1, POLLIN, 0}, {-1, POLLOUT, 0}
        };
        if (s.parent_gone) { fds[0].fd = fds[1].fd = -1; s.count = 0; }
        for (int i = 0; i < 2; i++)
            if (s.credits[i] && s.count < OUT_SLOTS) fds[4+i].fd = s.streams[i];
        if (s.write_pending && !s.write_failed && s.write_sent < s.write_size) fds[6].fd = s.child_in;
        int timeout = -1;
        int64_t deadline = s.terminal ? 0 : s.deadline;
        if (s.retired && s.delivery_deadline && (!deadline || s.delivery_deadline < deadline))
            deadline = s.delivery_deadline;
        if (s.stopping && !s.retired && !s.cleanup_warned &&
            (!deadline || s.cleanup_deadline < deadline)) deadline = s.cleanup_deadline;
        if (deadline) {
            int64_t remaining = deadline - now_ms();
            timeout = remaining <= 0 ? 0 : (int)remaining;
        }
        if (s.stopping && s.reason != 0) s.deadline = 0;
        int result = poll(fds, 7, timeout);
        if (result < 0) { if (errno != EINTR) fail(&s, 3, errno); continue; }
        if (fds[2].revents) {
            unsigned char bytes[128];
            while (read(s.signals[0], bytes, sizeof bytes) > 0) {}
        }
        if (fds[0].revents) read_parent(&s);
        if (fds[1].revents & (POLLERR | POLLHUP | POLLNVAL)) {
            s.parent_gone = 1; stop_child(&s, 1);
        } else if (fds[1].revents) write_parent(&s);
        if (fds[3].revents && s.exec_fd != -1) exec_result(&s);
        for (int i = 0; i < 2; i++)
            if (fds[4+i].revents && s.streams[i] != -1 && s.count < OUT_SLOTS) read_stream(&s, i);
        if (fds[6].revents && s.child_in != -1) write_child(&s);
    }
    return 0;
}
