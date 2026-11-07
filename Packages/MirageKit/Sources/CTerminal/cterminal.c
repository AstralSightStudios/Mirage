#include "cterminal.h"

#ifdef _WIN32

#include <windows.h>

#ifndef ENABLE_VIRTUAL_TERMINAL_INPUT
#define ENABLE_VIRTUAL_TERMINAL_INPUT 0x0200
#endif
#ifndef ENABLE_VIRTUAL_TERMINAL_PROCESSING
#define ENABLE_VIRTUAL_TERMINAL_PROCESSING 0x0004
#endif
#ifndef DISABLE_NEWLINE_AUTO_RETURN
#define DISABLE_NEWLINE_AUTO_RETURN 0x0008
#endif

static int saved;
static DWORD saved_in, saved_out;
static UINT saved_cp, saved_output_cp;

int mirage_term_raw_enter(void) {
    HANDLE in = GetStdHandle(STD_INPUT_HANDLE), out = GetStdHandle(STD_OUTPUT_HANDLE);
    if (!GetConsoleMode(in, &saved_in) || !GetConsoleMode(out, &saved_out)) return -1;
    saved_cp = GetConsoleCP();
    saved_output_cp = GetConsoleOutputCP();
    // Without line input, echo, Ctrl-C processing and quick edit
    // (ENABLE_EXTENDED_FLAGS clears it); keys and mouse arrive as VT sequences.
    DWORD in_mode = ENABLE_VIRTUAL_TERMINAL_INPUT | ENABLE_EXTENDED_FLAGS;
    DWORD out_mode = saved_out | ENABLE_PROCESSED_OUTPUT | ENABLE_VIRTUAL_TERMINAL_PROCESSING |
                     DISABLE_NEWLINE_AUTO_RETURN;
    if (!SetConsoleMode(in, in_mode) || !SetConsoleMode(out, out_mode)) {
        SetConsoleMode(in, saved_in);
        SetConsoleMode(out, saved_out);
        return -1;
    }
    SetConsoleCP(CP_UTF8);
    SetConsoleOutputCP(CP_UTF8);
    saved = 1;
    return 0;
}

void mirage_term_raw_leave(void) {
    if (!saved) return;
    SetConsoleMode(GetStdHandle(STD_INPUT_HANDLE), saved_in);
    SetConsoleMode(GetStdHandle(STD_OUTPUT_HANDLE), saved_out);
    SetConsoleCP(saved_cp);
    SetConsoleOutputCP(saved_output_cp);
    saved = 0;
}

long mirage_term_read(void *buf, size_t len) {
    DWORD n = 0;
    if (!ReadFile(GetStdHandle(STD_INPUT_HANDLE), buf, (DWORD)len, &n, NULL)) return -1;
    return (long)n;
}

int mirage_term_write(const void *buf, size_t len) {
    HANDLE out = GetStdHandle(STD_OUTPUT_HANDLE);
    const char *p = buf;
    while (len > 0) {
        DWORD n = 0;
        if (!WriteFile(out, p, (DWORD)len, &n, NULL)) return -1;
        p += n;
        len -= n;
    }
    return 0;
}

int mirage_term_size(unsigned *columns, unsigned *rows, unsigned *width, unsigned *height) {
    CONSOLE_SCREEN_BUFFER_INFO info;
    if (!GetConsoleScreenBufferInfo(GetStdHandle(STD_OUTPUT_HANDLE), &info)) return -1;
    *columns = (unsigned)(info.srWindow.Right - info.srWindow.Left + 1);
    *rows = (unsigned)(info.srWindow.Bottom - info.srWindow.Top + 1);
    *width = 0;
    *height = 0;
    return 0;
}

int mirage_shm_write(const char *name, const void *data, size_t len) {
    (void)name;
    (void)data;
    (void)len;
    return -1;
}

void mirage_shm_unlink(const char *name) { (void)name; }

#else

#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <termios.h>
#include <unistd.h>

static int saved;
static struct termios saved_tio;

int mirage_term_raw_enter(void) {
    if (!isatty(0) || !isatty(1) || tcgetattr(0, &saved_tio) != 0) return -1;
    struct termios raw = saved_tio;
    cfmakeraw(&raw);
    if (tcsetattr(0, TCSANOW, &raw) != 0) return -1;
    saved = 1;
    return 0;
}

void mirage_term_raw_leave(void) {
    if (!saved) return;
    tcsetattr(0, TCSANOW, &saved_tio);
    saved = 0;
}

long mirage_term_read(void *buf, size_t len) {
    for (;;) {
        ssize_t n = read(0, buf, len);
        if (n >= 0 || errno != EINTR) return (long)n;
    }
}

int mirage_term_write(const void *buf, size_t len) {
    const char *p = buf;
    while (len > 0) {
        ssize_t n = write(1, p, len);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        p += n;
        len -= (size_t)n;
    }
    return 0;
}

int mirage_term_size(unsigned *columns, unsigned *rows, unsigned *width, unsigned *height) {
    struct winsize ws;
    if (ioctl(1, TIOCGWINSZ, &ws) != 0 && ioctl(0, TIOCGWINSZ, &ws) != 0) return -1;
    *columns = ws.ws_col;
    *rows = ws.ws_row;
    *width = ws.ws_xpixel;
    *height = ws.ws_ypixel;
    return 0;
}

int mirage_shm_write(const char *name, const void *data, size_t len) {
    int fd = shm_open(name, O_CREAT | O_EXCL | O_RDWR, 0600);
    if (fd < 0) return -1;
    int ok = ftruncate(fd, (off_t)len) == 0;
    if (ok) {
        void *p = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        if (p == MAP_FAILED) {
            ok = 0;
        } else {
            memcpy(p, data, len);
            munmap(p, len);
        }
    }
    close(fd);
    if (!ok) {
        shm_unlink(name);
        return -1;
    }
    return 0;
}

void mirage_shm_unlink(const char *name) { shm_unlink(name); }

#endif
