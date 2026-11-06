// Loads the given libraries the way MomentoBooth does: libgphoto2 is linked in, its drivers are loaded at runtime.
// Fails when one of them cannot be loaded, e.g. because of a library it cannot find.

#include <dlfcn.h>
#include <gphoto2/gphoto2-version.h>
#include <stdio.h>

int main(int argc, char **argv) {
  int failed = 0;
  printf("libgphoto2 %s\n", gp_library_version(GP_VERSION_SHORT)[0]);
  for (int i = 1; i < argc; i++) {
    if (!dlopen(argv[i], RTLD_NOW)) {
      fprintf(stderr, "%s\n", dlerror());
      failed = 1;
    }
  }
  return failed;
}
