#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/un.h>

/* Private integration build: hold the writer after one measured short syscall. */
static int short_write_phase;

static int short_write_gate(struct state *s) {
    if (!getenv("LIBTMUX_SHORT_WRITE_SOCKET") || s->write_id == 0 || s->write_size != CHUNK_MAX)
        return 1;
    if (short_write_phase == 2) return 0;
    if (!short_write_phase) {
        int queued = -1;
        if (fcntl(s->child_in, F_SETPIPE_SZ, 4096) != 4096 ||
            fcntl(s->child_in, F_GETPIPE_SZ) != 4096 ||
            ioctl(s->child_in, FIONREAD, &queued) == -1 || queued != 0) {
            fail(s, 1, EIO); return 0;
        }
        short_write_phase = 1;
    }
    return 1;
}

static void short_write_after(struct state *s, ssize_t size) {
    if (short_write_phase != 1) return;
    short_write_phase = 2;
    int capacity = fcntl(s->child_in, F_GETPIPE_SZ), queued = -1;
    if (size <= 0 || (size_t)size >= s->write_size || s->write_sent != 0 ||
        capacity != 4096 || ioctl(s->child_in, FIONREAD, &queued) == -1 || queued < 0 || queued > size) {
        fail(s, 1, EIO); return;
    }
    const char *path = getenv("LIBTMUX_SHORT_WRITE_SOCKET");
    const char *nonce = getenv("LIBTMUX_SHORT_WRITE_NONCE");
    struct sockaddr_un address = {.sun_family = AF_UNIX};
    if (!path || strlen(path) >= sizeof address.sun_path || !nonce || strlen(nonce) != 32) {
        fail(s, 1, EINVAL); return;
    }
    memcpy(address.sun_path, path, strlen(path) + 1);
    int fd = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
    if (fd == -1) { fail(s, 1, errno); return; }
    unsigned char report[65] = {'P'};
    put32(report + 1, (uint32_t)getpid());
    put32(report + 5, (uint32_t)s->child);
    put32(report + 9, s->write_id);
    put32(report + 13, (uint32_t)size);
    put32(report + 17, (uint32_t)s->write_size);
    put32(report + 21, (uint32_t)capacity);
    put32(report + 25, (uint32_t)queued);
    put32(report + 29, 0);
    memcpy(report + 33, nonce, 32);
    ssize_t sent = sendto(fd, report, sizeof report, 0, (struct sockaddr *)&address, sizeof address);
    close(fd);
    if (sent != (ssize_t)sizeof report) fail(s, 1, EIO);
}
