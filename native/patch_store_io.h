#ifndef PATCH_STORE_IO_H
#define PATCH_STORE_IO_H

#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32)
#error "Patch store IO supports Android, iOS and OHOS POSIX platforms only"
#endif

#if defined(__GNUC__)
#define PSIO_API __attribute__((visibility("default")))
#else
#define PSIO_API
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* Returns a directory fd, or negative errno. The trusted app-private root must
 * be absolute, with no symlink, empty, dot or dot-dot path components. Missing
 * directories are created with mode 0700 only when create is 1. */
PSIO_API int psio_open_root(const char *absolute_path, int create);
#if defined(__APPLE__)
/* Trusted host initialization only, before starting runtime threads. Pins the
 * canonical app-owned container base once. Subsequent roots must be beneath it.
 * Never pass a path obtained from a patch, manifest or remote input. */
PSIO_API int psio_set_app_base(const char *canonical_path);
#endif
PSIO_API int psio_close(int root_fd);

/* Hold this directory-inode lock for the entire read/modify/write transaction.
 * Each independent owner must open its OWN root fd, and must not share an fd
 * concurrently or nest transactions. Never replace the root directory itself.
 * Locks on different descriptors to the same directory serialize with flock. */
PSIO_API int psio_lock(int root_fd);
PSIO_API int psio_unlock(int root_fd);

/* Returns 0 or negative errno; ENOENT is the only missing-file result. Relative
 * paths are traversed component by component without following symlinks. Reads
 * require a regular, single-link, current-user-owned inode. Successful output
 * is one bounded malloc buffer read from one fd; authenticate and consume that
 * same buffer, then psio_free it. No crypto is performed by this library.
 * Both reads and writes have an absolute 64 MiB ceiling. */
PSIO_API int psio_read(int root_fd, const char *relative_path, size_t limit,
                       uint8_t **bytes, size_t *length);

/* Creates missing parent directories; writes a mode-0600 exclusive temporary
 * inode in the destination directory, fsyncs it, renameats, then fsyncs the
 * directory. A negative result after rename means visibility may have changed
 * but durability was not established; callers must fail open to bundled AOT.
 * Readers observe either complete version, never a truncated destination. */
PSIO_API int psio_replace(int root_fd, const char *relative_path,
                          const uint8_t *bytes, size_t length);
PSIO_API void psio_free(void *bytes);

#ifdef __cplusplus
}
#endif
#endif
