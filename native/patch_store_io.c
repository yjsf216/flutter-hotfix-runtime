#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE 1
#endif
#define _POSIX_C_SOURCE 200809L
#define _DARWIN_C_SOURCE 1
#define _DEFAULT_SOURCE 1
#include "patch_store_io.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

#define PSIO_MAX_PATH 4096
#define PSIO_MAX_BYTES (64u * 1024u * 1024u)

#if defined(__APPLE__)
// Immutable after trusted app startup; the descriptor lives for the process.
static int app_base_fd = -1;
static char app_base_path[PSIO_MAX_PATH + 1];
int psio_set_app_base(const char *path) {
  if (app_base_fd >= 0) return -EALREADY;
  if (!path || path[0] != '/' || strlen(path) > PSIO_MAX_PATH) return -EINVAL;
  char resolved[PATH_MAX];
  if (!realpath(path, resolved)) return -errno;
  if (strcmp(path, resolved)) return -EINVAL;
  int fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (fd < 0) return -errno;
  struct stat info;
  int error = fstat(fd, &info) < 0 ? -errno : 0;
  if (!error && (info.st_uid != geteuid() || (info.st_mode & 0022))) error = -EPERM;
  if (error) { close(fd); return error; }
  strcpy(app_base_path, path);
  app_base_fd = fd;
  return 0;
}
#endif

static int sync_fd(int fd) {
  int result;
  do {
    result = fsync(fd);
  } while (result < 0 && errno == EINTR);
  return result < 0 ? -errno : 0;
}

static int component(const char *start, size_t size) {
  return size && size <= NAME_MAX &&
         !(size == 1 && start[0] == '.') &&
         !(size == 2 && start[0] == '.' && start[1] == '.') &&
         !memchr(start, '\\', size);
}

static int open_search_directory(int parent, const char *name) {
#if defined(__linux__)
  int fd = openat(parent, name,
                  O_PATH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  return fd < 0 ? -errno : fd;
#else
  (void)parent;
  (void)name;
  return -EACCES;
#endif
}

static int sync_directory_fd(int fd) {
  int error = sync_fd(fd);
#if defined(__linux__)
  if (error == -EBADF) {
    int readable = openat(fd, ".",
                          O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (readable < 0) return -errno;
    error = sync_fd(readable);
    if (close(readable) < 0 && !error) error = -errno;
  }
#endif
  return error;
}

static int open_directory(int parent, const char *name, int create) {
  int fd = openat(parent, name,
                  O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (fd >= 0) return fd;
  if (errno == EACCES) return open_search_directory(parent, name);
  if (!create || errno != ENOENT) return -errno;
  if (mkdirat(parent, name, 0700) < 0 && errno != EEXIST) return -errno;
  fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (fd < 0) return -errno;
  int error = sync_directory_fd(fd);
  if (!error) error = sync_directory_fd(parent);
  if (error) {
    close(fd);
    return error;
  }
  return fd;
}

static int readable_directory_fd(int fd) {
#if defined(__linux__)
  int readable = openat(fd, ".",
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (readable < 0) {
    int error = -errno;
    close(fd);
    return error;
  }
  close(fd);
  return readable;
#else
  return fd;
#endif
}

/* Owns a duplicate descriptor; each new directory is opened relative to the
 * already pinned parent inode, including when a path component is renamed. */
static int walk_directories(int root, const char *path, size_t length,
                            int create) {
  int fd = fcntl(root, F_DUPFD_CLOEXEC, 0);
  if (fd < 0) return -errno;
  size_t offset = 0;
  while (offset < length) {
    size_t end = offset;
    while (end < length && path[end] != '/') ++end;
    size_t size = end - offset;
    if (!component(path + offset, size)) {
      close(fd);
      return -EINVAL;
    }
    char name[NAME_MAX + 1];
    memcpy(name, path + offset, size);
    name[size] = '\0';
    int next = open_directory(fd, name, create);
    close(fd);
    if (next < 0) return next;
    fd = next;
    offset = end + 1;
  }
  return readable_directory_fd(fd);
}

static int path_length(const char *path, size_t *length) {
  if (!path) return -EINVAL;
  *length = strnlen(path, PSIO_MAX_PATH + 1);
  if (!*length || *length > PSIO_MAX_PATH || path[*length - 1] == '/')
    return -EINVAL;
  /* Validate the whole path before creating any directory. */
  const char *start = path;
  for (const char *cursor = path; ; ++cursor) {
    if (*cursor == '/' || !*cursor) {
      if (!component(start, (size_t)(cursor - start))) return -EINVAL;
      if (!*cursor) break;
      start = cursor + 1;
    }
  }
  return 0;
}

static int parent_directory(int root, const char *path, int create,
                            const char **name) {
  size_t length;
  int error = path_length(path, &length);
  if (error) return error;
  const char *slash = strrchr(path, '/');
  *name = slash ? slash + 1 : path;
  return walk_directories(root, path, slash ? (size_t)(slash - path) : 0,
                          create);
}

int psio_open_root(const char *path, int create) {
  if (!path || path[0] != '/' || (create != 0 && create != 1)) return -EINVAL;
  size_t length;
  int error = path_length(path + 1, &length);
  if (error) return error;
  const char *relative = path + 1;
  int base;
#if defined(__APPLE__)
  if (app_base_fd >= 0) {
    size_t base_length = strlen(app_base_path);
    if (strncmp(path, app_base_path, base_length) || path[base_length] != '/')
      return -EPERM;
    relative = path + base_length + 1;
    length = strlen(relative);
    base = fcntl(app_base_fd, F_DUPFD_CLOEXEC, 0);
    if (base < 0) return -errno;
  } else
#endif
  {
    base = open_directory(AT_FDCWD, "/", 0);
  }
  if (base < 0) return base;
  int root = walk_directories(base, relative, length, create);
  close(base);
  if (root < 0) return root;
  struct stat info;
  if (fstat(root, &info) < 0) error = -errno;
  else if (info.st_uid != geteuid() || (info.st_mode & 0022)) error = -EPERM;
  if (error) {
    close(root);
    return error;
  }
  return root;
}

int psio_close(int root_fd) {
  /* Do not retry close after EINTR: the fd may already have been reused. */
  return close(root_fd) < 0 ? -errno : 0;
}

static int lock_operation(int root_fd, int operation) {
  int result;
  do {
    result = flock(root_fd, operation);
  } while (result < 0 && errno == EINTR);
  return result < 0 ? -errno : 0;
}

int psio_lock(int root_fd) { return lock_operation(root_fd, LOCK_EX); }
int psio_unlock(int root_fd) { return lock_operation(root_fd, LOCK_UN); }

static int regular_file(const struct stat *info) {
  return S_ISREG(info->st_mode) && info->st_nlink == 1 &&
         info->st_uid == geteuid();
}

static int same_file(const struct stat *left, const struct stat *right) {
#if defined(__APPLE__)
#define PSIO_MTIME st_mtimespec
#define PSIO_CTIME st_ctimespec
#else
#define PSIO_MTIME st_mtim
#define PSIO_CTIME st_ctim
#endif
  return regular_file(right) && left->st_dev == right->st_dev &&
         left->st_ino == right->st_ino && left->st_size == right->st_size &&
         left->PSIO_MTIME.tv_sec == right->PSIO_MTIME.tv_sec &&
         left->PSIO_MTIME.tv_nsec == right->PSIO_MTIME.tv_nsec &&
         left->PSIO_CTIME.tv_sec == right->PSIO_CTIME.tv_sec &&
         left->PSIO_CTIME.tv_nsec == right->PSIO_CTIME.tv_nsec;
}

int psio_read(int root_fd, const char *path, size_t limit,
              uint8_t **bytes, size_t *length) {
  if (!bytes || !length) return -EINVAL;
  *bytes = NULL;
  *length = 0;
  if (limit > PSIO_MAX_BYTES) return -EFBIG;
  const char *name;
  int parent = parent_directory(root_fd, path, 0, &name);
  if (parent < 0) return parent;
  /* O_NONBLOCK prevents an attacker-controlled FIFO from blocking before
   * fstat can reject it; regular files are unaffected. */
  int fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
  int error = fd < 0 ? -errno : 0;
  close(parent);
  if (error) return error;
  struct stat before, after;
  uint8_t *buffer = NULL;
  if (fstat(fd, &before) < 0) { error = -errno; goto done; }
  if (!regular_file(&before)) {
    /* rename may retire the pinned inode between openat and fstat. */
    error = S_ISREG(before.st_mode) && before.st_nlink == 0 ? -ESTALE : -EINVAL;
    goto done;
  }
  if (before.st_size < 0 || (uintmax_t)before.st_size > limit) {
    error = -EFBIG;
    goto done;
  }
  size_t size = (size_t)before.st_size;
  buffer = malloc(size ? size : 1);
  if (!buffer) { error = -ENOMEM; goto done; }
  size_t offset = 0;
  while (offset < size) {
    ssize_t count = read(fd, buffer + offset, size - offset);
    if (count < 0 && errno == EINTR) continue;
    if (count <= 0) { error = count < 0 ? -errno : -ESTALE; goto done; }
    offset += (size_t)count;
  }
  uint8_t extra;
  ssize_t count;
  do { count = read(fd, &extra, 1); } while (count < 0 && errno == EINTR);
  if (count != 0) { error = count < 0 ? -errno : -ESTALE; goto done; }
  if (fstat(fd, &after) < 0) { error = -errno; goto done; }
  if (!same_file(&before, &after)) { error = -ESTALE; goto done; }
  *bytes = buffer;
  *length = size;
  buffer = NULL;
done:
  free(buffer);
  if (close(fd) < 0 && !error) {
    error = -errno;
    free(*bytes);
    *bytes = NULL;
    *length = 0;
  }
  return error;
}

int psio_replace(int root_fd, const char *path,
                 const uint8_t *bytes, size_t length) {
  if (!bytes && length) return -EINVAL;
  if (length > PSIO_MAX_BYTES) return -EFBIG;
  const char *name;
  int parent = parent_directory(root_fd, path, 1, &name);
  if (parent < 0) return parent;
  int error = 0, fd = -1;
  struct stat target;
  if (fstatat(parent, name, &target, AT_SYMLINK_NOFOLLOW) == 0) {
    if (!regular_file(&target)) { error = -EINVAL; goto done; }
  } else if (errno != ENOENT) { error = -errno; goto done; }
  static _Atomic unsigned long sequence;
  char temporary[80] = {0};
  /* O_EXCL is the security boundary, not unpredictability of this name.
   * ponytail: bounded collision retries fail closed under local file flooding. */
  for (int attempt = 0; attempt < 128; ++attempt) {
    unsigned long id = atomic_fetch_add_explicit(&sequence, 1, memory_order_relaxed);
    snprintf(temporary, sizeof(temporary), ".patch-store-%ld-%lu",
             (long)getpid(), id);
    fd = openat(parent, temporary,
                 O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd >= 0) break;
    if (errno != EEXIST) { error = -errno; goto done; }
  }
  if (fd < 0) { error = -EEXIST; goto done; }
  size_t offset = 0;
  while (offset < length) {
    ssize_t count = write(fd, bytes + offset, length - offset);
    if (count < 0 && errno == EINTR) continue;
    if (count <= 0) { error = count < 0 ? -errno : -EIO; break; }
    offset += (size_t)count;
  }
  if (!error) error = sync_fd(fd);
  if (close(fd) < 0 && !error) error = -errno;
  fd = -1;
  if (!error && renameat(parent, temporary, parent, name) < 0) error = -errno;
  if (!error) error = sync_fd(parent);
  if (error) unlinkat(parent, temporary, 0);
done:
  if (fd >= 0) close(fd);
  close(parent);
  return error;
}

void psio_free(void *bytes) { free(bytes); }
