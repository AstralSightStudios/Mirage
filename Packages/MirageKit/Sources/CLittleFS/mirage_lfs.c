/*
 * Mirage littlefs helpers (see include/mirage_lfs.h).
 *
 * The configuration mirrors littlefs-python (which emu/mknor.py and
 * emu/mksensornor.py use), so the images are byte-identical to theirs:
 * cache = block size, lookahead 8 bytes, no wear levelling.
 */
#include <stdlib.h>
#include <string.h>

#include "lfs.h"
#include "mirage_lfs.h"

typedef struct ram_disk {
    uint8_t *data;
    int readonly;
} ram_disk;

static int rd_read(const struct lfs_config *c, lfs_block_t block,
                   lfs_off_t off, void *buffer, lfs_size_t size)
{
    ram_disk *d = c->context;
    memcpy(buffer, d->data + (size_t)block * c->block_size + off, size);
    return 0;
}

static int rd_prog(const struct lfs_config *c, lfs_block_t block,
                   lfs_off_t off, const void *buffer, lfs_size_t size)
{
    ram_disk *d = c->context;
    if (d->readonly) {
        return LFS_ERR_IO;
    }
    memcpy(d->data + (size_t)block * c->block_size + off, buffer, size);
    return 0;
}

static int rd_erase(const struct lfs_config *c, lfs_block_t block)
{
    ram_disk *d = c->context;
    if (d->readonly) {
        return LFS_ERR_IO;
    }
    memset(d->data + (size_t)block * c->block_size, 0xff, c->block_size);
    return 0;
}

static int rd_sync(const struct lfs_config *c)
{
    (void)c;
    return 0;
}

static void config(struct lfs_config *cfg, ram_disk *disk,
                   const mlfs_geometry *geo)
{
    memset(cfg, 0, sizeof(*cfg));
    cfg->context = disk;
    cfg->read = rd_read;
    cfg->prog = rd_prog;
    cfg->erase = rd_erase;
    cfg->sync = rd_sync;
    cfg->read_size = geo->read_size;
    cfg->prog_size = geo->prog_size;
    cfg->block_size = geo->block_size;
    cfg->block_count = geo->block_count;
    cfg->block_cycles = -1;
    cfg->cache_size = geo->block_size;
    cfg->lookahead_size = 8;
    cfg->name_max = geo->name_max;
    cfg->disk_version = geo->disk_version;
}

static int write_file(lfs_t *lfs, const char *path, const void *data,
                      size_t size)
{
    lfs_file_t f;
    int err = lfs_file_open(lfs, &f, path,
                            LFS_O_WRONLY | LFS_O_CREAT | LFS_O_TRUNC);
    if (err) {
        return err;
    }
    lfs_ssize_t n = lfs_file_write(lfs, &f, data, (lfs_size_t)size);
    int cerr = lfs_file_close(lfs, &f);
    if (n < 0) {
        return (int)n;
    }
    return cerr;
}

int mlfs_build(void *image, const mlfs_geometry *geo,
               const mlfs_file *files, size_t nfiles)
{
    ram_disk disk = { image, 0 };
    struct lfs_config cfg;
    lfs_t lfs;
    int err;

    memset(image, 0xff, (size_t)geo->block_size * geo->block_count);
    config(&cfg, &disk, geo);
    err = lfs_format(&lfs, &cfg);
    if (err) {
        return err;
    }
    err = lfs_mount(&lfs, &cfg);
    if (err) {
        return err;
    }
    for (size_t i = 0; i < nfiles && !err; i++) {
        err = write_file(&lfs, files[i].path, files[i].data, files[i].size);
    }
    int uerr = lfs_unmount(&lfs);
    return err ? err : uerr;
}

long mlfs_read(const void *image, const mlfs_geometry *geo,
               const char *path, void *out, size_t cap)
{
    ram_disk disk = { (uint8_t *)image, 1 };
    struct lfs_config cfg;
    struct lfs_info info;
    lfs_file_t f;
    lfs_t lfs;
    long ret;
    int err;

    config(&cfg, &disk, geo);
    err = lfs_mount(&lfs, &cfg);
    if (err) {
        return err;
    }
    err = lfs_stat(&lfs, path, &info);
    if (err) {
        lfs_unmount(&lfs);
        return err;
    }
    err = lfs_file_open(&lfs, &f, path, LFS_O_RDONLY);
    if (err) {
        lfs_unmount(&lfs);
        return err;
    }
    lfs_ssize_t n = lfs_file_read(&lfs, &f, out,
                                  (lfs_size_t)(cap < info.size ? cap
                                                               : info.size));
    lfs_file_close(&lfs, &f);
    lfs_unmount(&lfs);
    ret = n < 0 ? (long)n : (long)info.size;
    return ret;
}

int mlfs_write(void *image, const mlfs_geometry *geo,
               const char *path, const void *data, size_t size)
{
    ram_disk disk = { image, 0 };
    struct lfs_config cfg;
    lfs_t lfs;
    int err;

    config(&cfg, &disk, geo);
    err = lfs_mount(&lfs, &cfg);
    if (err) {
        return err;
    }
    err = write_file(&lfs, path, data, size);
    int uerr = lfs_unmount(&lfs);
    return err ? err : uerr;
}

int mlfs_list_root(const void *image, const mlfs_geometry *geo,
                   char *out, size_t cap)
{
    ram_disk disk = { (uint8_t *)image, 1 };
    struct lfs_config cfg;
    struct lfs_info info;
    lfs_dir_t dir;
    lfs_t lfs;
    size_t used = 0;
    int count = 0;
    int err;

    if (cap) {
        out[0] = 0;
    }
    config(&cfg, &disk, geo);
    err = lfs_mount(&lfs, &cfg);
    if (err) {
        return err;
    }
    err = lfs_dir_open(&lfs, &dir, "/");
    if (err) {
        lfs_unmount(&lfs);
        return err;
    }
    while (lfs_dir_read(&lfs, &dir, &info) > 0) {
        if (!strcmp(info.name, ".") || !strcmp(info.name, "..")) {
            continue;
        }
        size_t len = strlen(info.name);
        if (used + len + 2 <= cap) {
            memcpy(out + used, info.name, len);
            used += len;
            out[used++] = '\n';
            out[used] = 0;
        }
        count++;
    }
    lfs_dir_close(&lfs, &dir);
    lfs_unmount(&lfs);
    return count;
}
