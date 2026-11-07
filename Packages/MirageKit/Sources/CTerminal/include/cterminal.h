#ifndef CTERMINAL_H
#define CTERMINAL_H

#include <stddef.h>

/// Raw input (no echo, line editing or signals) and, on Windows, VT
/// sequences both ways with UTF-8 code pages. Returns 0, or -1 when stdin
/// or stdout is not a terminal.
int mirage_term_raw_enter(void);
void mirage_term_raw_leave(void);

/// Blocking read from stdin. Returns the byte count, 0 at end of input,
/// -1 on error.
long mirage_term_read(void *buf, size_t len);

/// Writes all of `buf` to stdout. Returns 0, or -1 on error.
int mirage_term_write(const void *buf, size_t len);

/// Window size in cells, and in pixels when the terminal reports it (else 0).
int mirage_term_size(unsigned *columns, unsigned *rows, unsigned *width, unsigned *height);

/// Writes `data` to a new POSIX shared memory object, for the kitty
/// graphics protocol's `t=s` transport. Returns 0, or -1 (always on Windows).
int mirage_shm_write(const char *name, const void *data, size_t len);
void mirage_shm_unlink(const char *name);

#endif
