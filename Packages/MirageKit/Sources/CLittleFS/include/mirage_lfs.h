/*
 * Mirage littlefs helpers: build and read littlefs images held in memory.
 *
 * littlefs is compiled with LFS_MULTIVERSION so the on-disk version can be
 * pinned to what a firmware's own driver writes (2.0 / 2.1). Swift never
 * sees struct lfs_config; it only talks to these functions.
 */
#ifndef MIRAGE_LFS_H
#define MIRAGE_LFS_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct mlfs_geometry {
    uint32_t block_size;
    uint32_t block_count;
    uint32_t read_size;
    uint32_t prog_size;
    uint32_t name_max;
    /* 0x00020000 = 2.0, 0x00020001 = 2.1; 0 = newest */
    uint32_t disk_version;
} mlfs_geometry;

typedef struct mlfs_file {
    const char *path;
    const void *data;
    size_t size;
} mlfs_file;

/*
 * Format `image` (block_size * block_count bytes; erased bytes are 0xFF)
 * and write `files` into it. Returns 0 or a negative littlefs error.
 */
int mlfs_build(void *image, const mlfs_geometry *geo,
               const mlfs_file *files, size_t nfiles);

/*
 * Read file `path` from a littlefs image. On success returns the file size
 * and copies at most `cap` bytes into `out`; returns a negative littlefs
 * error otherwise (LFS_ERR_CORRUPT when the image holds no filesystem).
 */
long mlfs_read(const void *image, const mlfs_geometry *geo,
               const char *path, void *out, size_t cap);

/*
 * Replace (or create) file `path` in an existing littlefs image, keeping
 * every other file. Returns 0 or a negative littlefs error.
 */
int mlfs_write(void *image, const mlfs_geometry *geo,
               const char *path, const void *data, size_t size);

/*
 * Names in the root directory, '\n'-separated, written into `out` (NUL
 * terminated). Returns the number of entries or a negative error.
 */
int mlfs_list_root(const void *image, const mlfs_geometry *geo,
                   char *out, size_t cap);

#ifdef __cplusplus
}
#endif

#endif
