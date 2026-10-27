/*
 * Grab evdev nodes when libinput opens them in sway.
 *
 * Apollo creates its passthrough input devices in the host kernel, so the
 * host compositor can read them too. An exclusive EVIOCGRAB on the fd that
 * libinput uses stops delivery to every other client without requiring any
 * host udev rule. The library is preloaded only for sway and checks the
 * process name so child processes are unaffected.
 */

#define _GNU_SOURCE

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/syscall.h>
#include <unistd.h>

#ifndef EVIOCGRAB
#define EVIOCGRAB _IOW('E', 0x90, int)
#endif

static int (*next_open)(const char *, int, ...);
static int (*next_open64)(const char *, int, ...);
static int (*next_openat)(int, const char *, int, ...);
static int (*next_openat64)(int, const char *, int, ...);

static bool grab_enabled(void)
{
    const char *name = program_invocation_short_name;
    return name != NULL && strcmp(name, "sway") == 0;
}

static bool is_event_node(const char *path)
{
    return path != NULL && strncmp(path, "/dev/input/event", 16) == 0;
}

static void grab_device(int fd, const char *path)
{
    if (fd < 0 || !grab_enabled() || !is_event_node(path)) {
        return;
    }

    if (ioctl(fd, EVIOCGRAB, 1) == 0) {
        return;
    }

    /* EBUSY means another process already holds the node. It is reported so
     * the missing input can be traced from the sway log. */
    if (errno == EBUSY) {
        dprintf(STDERR_FILENO, "[vulcan] %s is already grabbed\n", path);
    }
}

static void resolve(void)
{
    if (next_open == NULL) {
        next_open = dlsym(RTLD_NEXT, "open");
    }
    if (next_open64 == NULL) {
        next_open64 = dlsym(RTLD_NEXT, "open64");
    }
    if (next_openat == NULL) {
        next_openat = dlsym(RTLD_NEXT, "openat");
    }
    if (next_openat64 == NULL) {
        next_openat64 = dlsym(RTLD_NEXT, "openat64");
    }
}

int open(const char *path, int flags, ...)
{
    mode_t mode = 0;
    if (flags & (O_CREAT | O_TMPFILE)) {
        va_list args;
        va_start(args, flags);
        mode = va_arg(args, mode_t);
        va_end(args);
    }

    resolve();
    int fd = next_open != NULL
        ? next_open(path, flags, mode)
        : (int)syscall(SYS_openat, AT_FDCWD, path, flags, mode);
    grab_device(fd, path);
    return fd;
}

int open64(const char *path, int flags, ...)
{
    mode_t mode = 0;
    if (flags & (O_CREAT | O_TMPFILE)) {
        va_list args;
        va_start(args, flags);
        mode = va_arg(args, mode_t);
        va_end(args);
    }

    resolve();
    int fd = next_open64 != NULL
        ? next_open64(path, flags, mode)
        : (int)syscall(SYS_openat, AT_FDCWD, path, flags, mode);
    grab_device(fd, path);
    return fd;
}

int openat(int dirfd, const char *path, int flags, ...)
{
    mode_t mode = 0;
    if (flags & (O_CREAT | O_TMPFILE)) {
        va_list args;
        va_start(args, flags);
        mode = va_arg(args, mode_t);
        va_end(args);
    }

    resolve();
    int fd = next_openat != NULL
        ? next_openat(dirfd, path, flags, mode)
        : (int)syscall(SYS_openat, dirfd, path, flags, mode);
    grab_device(fd, path);
    return fd;
}

int openat64(int dirfd, const char *path, int flags, ...)
{
    mode_t mode = 0;
    if (flags & (O_CREAT | O_TMPFILE)) {
        va_list args;
        va_start(args, flags);
        mode = va_arg(args, mode_t);
        va_end(args);
    }

    resolve();
    int fd = next_openat64 != NULL
        ? next_openat64(dirfd, path, flags, mode)
        : (int)syscall(SYS_openat, dirfd, path, flags, mode);
    grab_device(fd, path);
    return fd;
}
