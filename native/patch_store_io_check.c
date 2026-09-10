#define _POSIX_C_SOURCE 200809L
#include "patch_store_io.h"

#include <assert.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

static void write_value(int root, const char *name, const char *value) {
  assert(psio_replace(root, name, (const uint8_t *)value, strlen(value)) == 0);
}

static void expect_value(int root, const char *name, const char *value) {
  uint8_t *bytes = NULL;
  size_t length = 0;
  assert(psio_read(root, name, 1024, &bytes, &length) == 0);
  assert(length == strlen(value) && memcmp(bytes, value, length) == 0);
  psio_free(bytes);
}

static void wait_success(pid_t child) {
  int status;
  assert(waitpid(child, &status, 0) == child);
  assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
}

#if defined(__linux__)
static void check_search_only_ancestor(const char *root_path) {
  if (geteuid() == 0) {
    puts("SKIP: search-only ancestor regression requires a non-root UID");
    return;
  }
  char parent_path[4096];
  size_t length = strnlen(root_path, sizeof(parent_path));
  assert(length > 0 && length < sizeof(parent_path));
  memcpy(parent_path, root_path, length + 1);
  char *slash = strrchr(parent_path, '/');
  assert(slash && slash != parent_path);
  *slash = '\0';
  assert(chmod(parent_path, 0100) == 0);
  int denied = open(parent_path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  assert(denied < 0 && errno == EACCES);
  int opened = psio_open_root(root_path, 0);
  assert(chmod(parent_path, 0700) == 0);
  assert(opened >= 0);
  assert(psio_lock(opened) == 0 && psio_unlock(opened) == 0);
  write_value(opened, "ancestor-check", "ok");
  expect_value(opened, "ancestor-check", "ok");
  assert(psio_close(opened) == 0);
  puts("PASS: Linux search-only ancestor traversal uses an O_PATH pin");
}
#endif

static void check_paths(int root, const char *root_path) {
  const char *invalid[] = {"", "/etc/passwd", ".", "..", "x/../state",
                            "x/./state", "x//state", "x/", "x\\state"};
  for (size_t i = 0; i < sizeof(invalid) / sizeof(invalid[0]); ++i) {
    uint8_t *bytes = (void *)1;
    size_t length = 99;
    assert(psio_read(root, invalid[i], 64, &bytes, &length) == -EINVAL);
    assert(bytes == NULL && length == 0);
    assert(psio_replace(root, invalid[i], (const uint8_t *)"x", 1) == -EINVAL);
  }
  assert(psio_open_root("relative", 0) == -EINVAL);
  assert(psio_open_root("/", 0) == -EINVAL);
  assert(psio_open_root(root_path, 2) == -EINVAL);
  uint8_t *bytes;
  size_t length;
  assert(psio_read(root, "missing", 4, &bytes, &length) == -ENOENT);
  assert(psio_read(root, "missing", 64u * 1024u * 1024u + 1, &bytes, &length) == -EFBIG);
  assert(psio_replace(root, "invalid", NULL, 1) == -EINVAL);
  assert(psio_read(-1, "missing", 4, &bytes, &length) == -EBADF);
  assert(psio_lock(-1) == -EBADF);
  write_value(root, "versions/a.ir", "original");
  assert(symlinkat("versions/a.ir", root, "file-link") == 0);
  assert(psio_read(root, "file-link", 64, &bytes, &length) < 0);
  assert(psio_replace(root, "file-link", (const uint8_t *)"evil", 4) < 0);
  assert(symlinkat("versions", root, "dir-link") == 0);
  assert(psio_read(root, "dir-link/a.ir", 64, &bytes, &length) < 0);
  assert(psio_replace(root, "dir-link/a.ir", (const uint8_t *)"evil", 4) < 0);
  char linked_root[4096];
  assert(snprintf(linked_root, sizeof(linked_root), "%s/dir-link", root_path) > 0);
  assert(psio_open_root(linked_root, 0) < 0);
  assert(linkat(root, "versions/a.ir", root, "hard-link", 0) == 0);
  assert(psio_read(root, "hard-link", 64, &bytes, &length) < 0);
  assert(psio_replace(root, "hard-link", (const uint8_t *)"evil", 4) < 0);
  assert(unlinkat(root, "hard-link", 0) == 0);
  expect_value(root, "versions/a.ir", "original");
  assert(mkfifoat(root, "fifo", 0600) == 0);
  assert(psio_read(root, "fifo", 64, &bytes, &length) < 0);
  assert(psio_replace(root, "fifo", (const uint8_t *)"evil", 4) < 0);
  assert(psio_read(root, "versions", 64, &bytes, &length) < 0);
  assert(psio_read(root, "versions/a.ir", 2, &bytes, &length) == -EFBIG);
  int sparse = openat(root, "oversized", O_WRONLY | O_CREAT | O_EXCL, 0600);
  assert(sparse >= 0 && ftruncate(sparse, 65u * 1024u * 1024u) == 0);
  assert(close(sparse) == 0);
  assert(psio_read(root, "oversized", 64u * 1024u * 1024u, &bytes, &length) == -EFBIG);
  write_value(root, "empty", "");
  assert(psio_read(root, "empty", 0, &bytes, &length) == 0 && length == 0);
  psio_free(bytes);
  assert(psio_read(root, "versions/a.ir", 64, &bytes, &length) == 0);
  write_value(root, "versions/a.ir", "replacement");
  assert(length == 8 && memcmp(bytes, "original", 8) == 0);
  psio_free(bytes);
  expect_value(root, "versions/a.ir", "replacement");
  puts("PASS: invalid paths, symlink levels, hardlinks, FIFO, bounds and owned buffer");
}

static void check_transactions(int root, const char *root_path) {
  write_value(root, "counter", "0");
  pid_t children[4];
  for (int worker = 0; worker < 4; ++worker) {
    children[worker] = fork();
    assert(children[worker] >= 0);
    if (!children[worker]) {
      assert(psio_close(root) == 0);
      int own = psio_open_root(root_path, 0);
      assert(own >= 0);
      for (int iteration = 0; iteration < 30; ++iteration) {
        assert(psio_lock(own) == 0);
        uint8_t *bytes;
        size_t length;
        assert(psio_read(own, "counter", 16, &bytes, &length) == 0);
        char number[17] = {0};
        memcpy(number, bytes, length);
        psio_free(bytes);
        int count = atoi(number);
        snprintf(number, sizeof(number), "%d", count + 1);
        write_value(own, "counter", number);
        assert(psio_unlock(own) == 0);
      }
      assert(psio_close(own) == 0);
      _exit(0);
    }
  }
  for (int worker = 0; worker < 4; ++worker) wait_success(children[worker]);
  expect_value(root, "counter", "120");

  int channel[2];
  assert(pipe(channel) == 0);
  pid_t owner = fork();
  assert(owner >= 0);
  if (!owner) {
    close(channel[0]);
    psio_close(root);
    int own = psio_open_root(root_path, 0);
    assert(own >= 0 && psio_lock(own) == 0);
    assert(write(channel[1], "!", 1) == 1);
    for (;;) pause();
  }
  close(channel[1]);
  char ready;
  assert(read(channel[0], &ready, 1) == 1);
  close(channel[0]);
  assert(kill(owner, SIGKILL) == 0);
  int status;
  assert(waitpid(owner, &status, 0) == owner && WIFSIGNALED(status));
  assert(psio_lock(root) == 0 && psio_unlock(root) == 0);
  puts("PASS: concurrent read/modify/write transactions and crashed-owner unlock");
}

static void check_atomic_reads(int root, const char *root_path) {
  enum { size = 65536 };
  uint8_t value[size];
  memset(value, 'a', size);
  assert(psio_replace(root, "atomic", value, size) == 0);
  pid_t writer = fork();
  assert(writer >= 0);
  if (!writer) {
    psio_close(root);
    int own = psio_open_root(root_path, 0);
    assert(own >= 0);
    for (int i = 0; i < 80; ++i) {
      memset(value, i % 2 ? 'a' : 'b', size);
      assert(psio_lock(own) == 0);
      assert(psio_replace(own, "atomic", value, size) == 0);
      assert(psio_unlock(own) == 0);
    }
    psio_close(own);
    _exit(0);
  }
  for (int i = 0; i < 300; ++i) {
    uint8_t *bytes;
    size_t length;
    /* Deliberately read without locking: rename may unlink the pinned old
     * inode during the read, which is safely reported as ESTALE. */
    int result = psio_read(root, "atomic", size, &bytes, &length);
    if (result == -ESTALE) continue;
    assert(result == 0 && length == size);
    assert(bytes[0] == 'a' || bytes[0] == 'b');
    for (size_t n = 1; n < length; ++n) assert(bytes[n] == bytes[0]);
    psio_free(bytes);
  }
  wait_success(writer);
  puts("PASS: concurrent replacement never exposes truncated or mixed contents");
}

static void check_failed_write(int root) {
  write_value(root, "preserved", "last-known-good");
  pid_t writer = fork();
  assert(writer >= 0);
  if (!writer) {
    struct rlimit limit = {1, 1};
    assert(signal(SIGXFSZ, SIG_IGN) != SIG_ERR);
    assert(setrlimit(RLIMIT_FSIZE, &limit) == 0);
    assert(psio_replace(root, "preserved", (const uint8_t *)"new-value", 9) == -EFBIG);
    _exit(0);
  }
  wait_success(writer);
  expect_value(root, "preserved", "last-known-good");
  int copy = fcntl(root, F_DUPFD_CLOEXEC, 0);
  assert(copy >= 0);
  DIR *directory = fdopendir(copy);
  assert(directory);
  struct dirent *entry;
  while ((entry = readdir(directory)))
    assert(strncmp(entry->d_name, ".patch-store-", 13) != 0);
  assert(closedir(directory) == 0);
  puts("PASS: partial write failure preserves last-known-good and cleans staging inode");
}

int main(int argc, char **argv) {
  assert(argc == 2);
  alarm(30);
  int root = psio_open_root(argv[1], 1);
  assert(root >= 0);
#if defined(__linux__)
  check_search_only_ancestor(argv[1]);
#endif
  check_paths(root, argv[1]);
  check_transactions(root, argv[1]);
  check_atomic_reads(root, argv[1]);
  check_failed_write(root);
  assert(psio_close(root) == 0);
  return 0;
}
