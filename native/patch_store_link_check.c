#include <dlfcn.h>
#include <stdio.h>

/* No C reference to psio_*: just like Dart FFI, lookup happens by name. */
int main(int argc, char **argv) {
  if (argc > 2) return 2;
  void *library = dlopen(argc == 2 ? argv[1] : NULL, RTLD_NOW | RTLD_LOCAL);
  if (!library) { fprintf(stderr, "%s\n", dlerror()); return 1; }
  const char *symbols[] = {
    "psio_open_root", "psio_close", "psio_lock", "psio_unlock",
    "psio_read", "psio_replace", "psio_free"
  };
  for (unsigned i = 0; i < sizeof(symbols) / sizeof(symbols[0]); ++i) {
    if (!dlsym(library, symbols[i])) {
      fprintf(stderr, "missing bundled symbol: %s\n", symbols[i]);
      dlclose(library);
      return 1;
    }
  }
  dlclose(library);
  puts("PASS: all bundled patch-store FFI symbols survive final linkage");
  return 0;
}
