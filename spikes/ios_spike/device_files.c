// Test-only USB file transfer, restricted to this authorized phone and app.
#include <libimobiledevice/libimobiledevice.h>
#include <libimobiledevice/house_arrest.h>
#include <libimobiledevice/afc.h>
#include <plist/plist.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>

static void check(int code, const char *operation) {
  if (code) { fprintf(stderr, "%s failed: %d\n", operation, code); exit(1); }
}
static int allowed(const char *path) {
  return !strstr(path, "..") && !strchr(path, '\\') &&
      (!strncmp(path, "Documents/hotfix-device/", sizeof("Documents/hotfix-device/") - 1) ||
       !strcmp(path, "Documents/hotfix-device") ||
       !strcmp(path, "Documents/hotfix/result.txt"));
}
int main(int argc, char **argv) {
  if (argc == 2 && !strcmp(argv[1], "--self-check")) {
    assert(allowed("Documents/hotfix-device/valid/inbox/patch.bytecode"));
    assert(!allowed("Documents/hotfix-device-elsewhere/file"));
    assert(!allowed("Documents/hotfix-device/../other"));
    assert(!allowed("/Documents/hotfix-device/valid"));
    puts("PASS: test-file scope validation (no device accessed)");
    return 0;
  }
  if (argc < 3 || !allowed(argv[2]) ||
      (strcmp(argv[1], "get") && strcmp(argv[1], "put") &&
       strcmp(argv[1], "mkdir") && strcmp(argv[1], "rename"))) return 2;
  if (!strcmp(argv[1], "rename") && (argc != 4 || !allowed(argv[3]))) return 2;
  idevice_t device = NULL;
  house_arrest_client_t house = NULL;
  afc_client_t afc = NULL;
  plist_t result = NULL;
  check(idevice_new_with_options(&device,
      "IOS_DEVICE_UDID", IDEVICE_LOOKUP_USBMUX), "device");
  check(house_arrest_client_start_service(device, &house, "HotfixRuntimeCheck"), "house arrest");
  check(house_arrest_send_command(house, "VendContainer", "dev.hotfixruntime.ios-spike"), "container");
  check(house_arrest_get_result(house, &result), "container response");
  if (plist_dict_get_item(result, "Error")) {
    fprintf(stderr, "App container access denied\n"); return 1;
  }
  plist_free(result);
  check(afc_client_new_from_house_arrest_client(house, &afc), "AFC");
  if (!strcmp(argv[1], "mkdir")) {
    int code = afc_make_directory(afc, argv[2]);
    if (code != AFC_E_OBJECT_EXISTS) check(code, "mkdir");
  } else if (!strcmp(argv[1], "rename")) {
    check(afc_rename_path(afc, argv[2], argv[3]), "rename");
  } else {
    int writing = !strcmp(argv[1], "put");
    uint64_t handle = 0;
    check(afc_file_open(afc, argv[2], writing ? AFC_FOPEN_WRONLY : AFC_FOPEN_RDONLY, &handle), "open");
    char buffer[65536];
    size_t total = 0;
    for (;;) {
      uint32_t count = 0;
      if (writing) {
        size_t size = fread(buffer, 1, sizeof(buffer), stdin);
        if (!size) { if (ferror(stdin)) return 1; break; }
        for (size_t offset = 0; offset < size; offset += count) {
          check(afc_file_write(afc, handle, buffer + offset, (uint32_t)(size - offset), &count), "write");
          if (!count) return 1;
        }
        total += size;
      } else {
        check(afc_file_read(afc, handle, buffer, sizeof(buffer), &count), "read");
        if (!count) break;
        if (fwrite(buffer, 1, count, stdout) != count) return 1;
        total += count;
      }
      if (total > 64u * 1024u * 1024u) return 1;
    }
    check(afc_file_close(afc, handle), "close");
  }
  afc_client_free(afc);
  house_arrest_client_free(house);
  idevice_free(device);
  return 0;
}
