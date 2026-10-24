#define _POSIX_C_SOURCE 200809L
#include <sys/socket.h>
#include <sys/un.h>
#include <arpa/inet.h>
#include <errno.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static unsigned char data[131072];
static size_t used;

static void append(const char *value) {
    size_t size = value ? strlen(value) : 0;
    if (used + size + 1 > sizeof data) _exit(90);
    if (size) memcpy(data + used, value, size);
    used += size;
    data[used++] = 0;
}

static void send_all(int fd, const void *bytes, size_t size) {
    const unsigned char *p = bytes;
    while (size) {
        ssize_t n = write(fd, p, size);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) _exit(91);
        p += n;
        size -= (size_t)n;
    }
}

int main(int argc, char **argv) {
    const char *path = getenv("LIBTMUX_ARGV_SOCKET");
    struct sockaddr_un address = { .sun_family = AF_UNIX };
    if (!path || strlen(path) >= sizeof address.sun_path) return 92;
    strcpy(address.sun_path, path);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0 || connect(fd, (struct sockaddr *)&address, sizeof address)) return 93;
    uint32_t header[] = {htonl((uint32_t)argc), htonl((uint32_t)getpid()),
                         htonl((uint32_t)getppid()), htonl((uint32_t)getpgrp())};
    memcpy(data, header, sizeof header);
    used = sizeof header;
    for (int i = 0; i < argc; i++) append(argv[i]);
    char cwd[4096];
    if (!getcwd(cwd, sizeof cwd)) return 94;
    append(cwd);
    append(getenv("LIBTMUX_ARGV_VALUE"));
    append(getenv("PATH"));
    append(getenv("SHELL"));
    uint32_t length = htonl((uint32_t)used);
    send_all(fd, &length, sizeof length);
    send_all(fd, data, used);
    unsigned char status;
    ssize_t n;
    do { n = read(fd, &status, 1); } while (n < 0 && errno == EINTR);
    close(fd);
    return n == 1 ? status : 95;
}
