# Handover: prebuilt libgphoto2 for macOS

This document covers the macOS part of moving MomentoBooth's native dependencies from package managers to prebuilt bundles. The Windows part was done first and is the reference. The macOS part is implemented and verified locally, but not released yet: see [Left to do](#left-to-do). The original task description is in the history of this file.

## Repositories and branches

- **momentobooth/native-deps** (this repository), branch `macos-handover`: builds the bundles and publishes them as GitHub releases. Windows is in `windows/`, macOS in `macos/`, both are built by `.github/workflows/build.yml`.
- **momentobooth/momentobooth**, branch `feature/prebuilt-native-deps-macos`, based on `feature/prebuilt-native-deps` (the Windows integration): consumes the bundles.

## Background: why

- Installing libgphoto2 through MSYS2 (Windows) or Homebrew (macOS) is slow in CI, annoying to set up on dev machines, and pulls in far more than needed.
- The packaged libgphoto2 builds depend on libgd for a few picture frame camlibs. libgd pulls in ~40 libraries, including x265, which is GPL licensed and therefore problematic to ship with MomentoBooth (MPL-2.0).
- On Windows, building libgphoto2 ourselves without libgd and libcurl reduced the bundled DLLs from 57 to 13. On macOS, `macos/ci_download_deps.sh` downloaded the Homebrew bottle of libgphoto2 and all its dependencies recursively, including gd. That script no longer worked: it asked for macOS 13 bottles, which Homebrew no longer has, and current Homebrew versions only list the bottle of the machine they run on.

## Decisions for macOS

These differ from the original plan, which was arm64 and x86_64 with a minimum of macOS 13.5.

| Decision | Why |
| - | - |
| **Apple Silicon only**, no x86_64 bundle and no Intel build of MomentoBooth | Xcode is dropping Intel, Homebrew has stopped building Intel bottles, and there is no Intel Mac to test releases on. A test under Rosetta 2 was not considered enough to release on. |
| **Dependencies from Homebrew bottles**, libgphoto2 itself from source | Keeps the build script short. libgphoto2 has to be built from source anyway, to leave out libgd and libcurl. |
| **Minimum macOS 15.0** (bottle tag `arm64_sequoia`) | The minimum is that of the oldest macOS that Homebrew has bottles of all dependencies for. The libexif bottle needs libintl from gettext, and the current gettext bottle starts at macOS 15. Accepted consequence: when Homebrew drops a bottle, the build fails and the minimum has to be raised. |
| **`@rpath/<name>` install names** | The bundle works from any location and contains no build paths. MomentoBooth has `@executable_path/../Libs` as rpath. |
| **Development uses the bundle too**, pkgconf comes from Homebrew | Debug builds run on the same libgphoto2 as releases. pkgconf is not in the bundle, as it is one `brew install` and can be added later without breaking anything. |

## manifest.json

The license overview in the app is generated from this file, so all bundles have the same schema:

```json
{
  "platform": "macos-arm64",
  "libgphoto2": { "version": "2.5.34", "gitRef": "v2.5.34", "gitCommit": "a4ec9cc8…" },
  "components": [
    {
      "name": "libusb",
      "version": "1.0.30",
      "description": "…",
      "url": "https://libusb.info/",
      "license": "LGPL-2.1-or-later",
      "usage": "runtime",
      "files": ["libusb-1.0.0.dylib"],
      "licenseFiles": ["licenses/libusb/COPYING"]
    }
  ]
}
```

`usage` is `runtime` for shipped libraries and `buildTime` for tools like pkgconf. Component `name`s match across platforms (`libgphoto2`, `libusb`, `libexif`, `libltdl`, `libjpeg-turbo`, `gettext-runtime`), as the app's license generator deduplicates by name and lets them replace the hand-maintained entries in `licenses/manual_licenses.toml`.

On macOS the name, description, URL and license of every component are written out in `component_json` in `macos/build.sh`. Homebrew's own metadata is not used, as it gives the license of the whole formula: GPL for libtool and gettext, of which only the LGPL libraries libltdl and libintl are shipped.

## What exists for Windows (the reference)

### native-deps

- `windows/build.sh` (runs in MSYS2 CLANG64):
  1. Fetches libgphoto2 at a git ref (tag, branch or commit), applies `windows/patches/`, runs `autoreconf -fi`.
  2. Configures with `--with-libusb=no --with-gdlib=no --with-libcurl=no --with-libtiff-4=no --disable-nls --disable-internal-docs`. Without gd and curl, the `docupen` and `lumix` camlibs are not built and the picture frame camlibs (ax203, st2205, tp6801) lose image conversion. The standard camlib set is kept otherwise.
  3. Stages a bundle: runtime libraries in `bin/`, camlibs in `lib/libgphoto2/<version>/`, iolibs in `lib/libgphoto2_port/<version>/`, import libs, headers (gphoto2, libusb-1.0, libexif), pkg-config files made relocatable with `prefix=${pcfiledir}/../..`, `pkgconf` in `tools/`, license files in `licenses/`.
  4. Writes `manifest.json` (see above) and zips the bundle.
- `.github/workflows/build.yml`: manually dispatched with `libgphoto2_ref` and optionally `release_tag`. The `release` job publishes all zips plus `SHA256SUMS` to a GitHub release.
- Current release: `libgphoto2-2.5.34-1` (Windows only).

### momentobooth repository

- `windows/get_native_deps.ps1` (also `just get-native-deps`): downloads the pinned release asset, verifies its SHA256, extracts it to `.native_deps/windows-x64/` and writes a gitignored `.cargo/config.toml` in the repository root with `PKG_CONFIG` and `PKG_CONFIG_PATH` in `[env]`. Cargo picks this up for both `cargo` in `rust/` and the Flutter build (cargokit runs cargo from `build/…`, and Cargo searches parent directories for config).
- `windows/CMakeLists.txt` installs `bin/*.dll` next to the executable, and the camlibs and iolibs into `libgphoto2_camlibs/` and `libgphoto2_iolibs/` next to it. This replaced `windows/bundle_libs.ps1`.
- `lib/hardware_control/gphoto2_camera.dart` defaults the driver directories to those names on Windows. See "libgphoto2 driver locations" in `documentation/src/dev_setup.md` for how `IOLIBS`/`CAMLIBS` work per platform.
- `tool/generate_licenses.dart` reads every `.native_deps/*/manifest.json` (deduplicated by component name).
- Windows CI workflows: the MSYS2 steps are replaced by `./windows/get_native_deps.ps1` plus LLVM (for libclang/bindgen and lld-link).

## What was built for macOS

### In native-deps

- `macos/build.sh <libgphoto2 git ref> <output zip>`, runs on an Apple Silicon Mac:
  1. Downloads the bottles through the public Homebrew API and verifies their checksums.
  2. Builds libgphoto2 at the git ref with the same options as on Windows, against the bottles only. Every library location is given explicitly, as configure otherwise picks up the Homebrew installation of the build machine.
  3. Stages the bundle: libraries in `lib/`, camlibs in `lib/libgphoto2/<version>/`, iolibs in `lib/libgphoto2_port/<version>/`, headers, relocatable pkg-config files, license files and `manifest.json`.
  4. Rewrites all install names to `@rpath/<name>`, removes rpaths and signs ad hoc.
  5. Fails unless every binary has a minimum macOS of at most 15.0, refers only to the bundle and to macOS itself, and loads (`macos/load_test.c`).
- `.github/workflows/build.yml`: job `macos-arm64`, added to the `needs` of `release`. Asset name: `libgphoto2-macos-arm64.zip`.
- The bundle contains 7 libraries, the same 19 camlibs as Windows, and 4 iolibs (Windows has no serial iolib).

### In momentobooth

- `macos/get_native_deps.sh [zip]` (also `just get-native-deps`): downloads the pinned release asset, verifies its SHA256, extracts it to `.native_deps/macos-arm64/` and writes `.cargo/config.toml` with `PKG_CONFIG_PATH`. With a zip as argument it uses that instead, to test a local or artifact build.
- `macos/embed_native_deps.sh`, a build phase of the Runner target: copies the libraries to `MomentoBooth.app/Contents/Libs` and the drivers to `Contents/Libs/Camlibs` and `Contents/Libs/Iolibs`, and signs them with the identity of the build. This replaced `ci_bundle_libraries.py`, and runs for debug builds too.
- `rust_builder/macos/rust_lib_momento_booth.podspec` links against `.native_deps/macos-arm64/lib` instead of `/opt/homebrew/lib`.
- `lib/hardware_control/gphoto2_camera.dart` defaults the driver directories on macOS, like on Windows. The `IOLIBS` and `CAMLIBS` Dart defines are no longer needed.
- Minimum macOS 15.0 in the Xcode project, the Podfile and the podspec.
- CI workflows: `ci_download_deps.sh`, `ci_adapt_pkgconf_dirs.sh` and `ci_bundle_libraries.py` are replaced by `./macos/get_native_deps.sh` and removed. The x86_64 build and the Intel dmg are gone.

## Verified locally

- Every binary in the bundle and in `MomentoBooth.app` is arm64, has a minimum macOS of at most 15.0 and refers only to `@rpath`, `@executable_path`, `@loader_path` and macOS itself.
- From a bundle extracted to another location, and from the libraries embedded in a release and a debug build of the app, libgphoto2 loads all drivers: 4 ports and 2795 camera models, without errors.
- The Rust library loads through the rpath of the app, and fails to load without it, so nothing falls back to Homebrew.
- No GPL-licensed component in the macOS manifest. The About screen lists the macOS components.
- `flutter analyze` and `flutter test` pass.

## Left to do

1. Run the workflow in this repository without `release_tag` and check the macOS artifact. The workflows have not run yet.
2. Publish a release, e.g. `libgphoto2-2.5.34-2`. It contains a newly built Windows zip as well.
3. In momentobooth, set `sha256` in `macos/get_native_deps.sh`, and the release and checksum in `windows/get_native_deps.ps1`.
4. Test with a real camera over USB (ptp2): detect, live view and capture. No camera was connected during the local verification.
5. The Windows manifest lists `gettext-runtime` as `GPL-3.0-or-later AND LGPL-2.1-or-later`, taken from the MSYS2 package. Only the LGPL `libintl-8.dll` is shipped.
