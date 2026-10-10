# Handover: prebuilt libgphoto2 for macOS

This document hands over the macOS part of moving MomentoBooth's native dependencies from package managers to prebuilt bundles. The Windows part is done and verified. The goal is to build and verify the same for macOS (arm64 and x86_64), on a Mac, possibly with the help of Claude Code.

## Repositories and branches

- **momentobooth/native-deps** (this repository), branch `main`: builds the bundles and publishes them as GitHub releases. Windows is in `windows/` and `.github/workflows/build.yml`.
- **momentobooth/momentobooth**, branch `<BRANCH — to be filled in by Casper>`: consumes the bundles. The Windows integration is the reference for macOS.

## Background: why

- Installing libgphoto2 through MSYS2 (Windows) or Homebrew (macOS) is slow in CI, annoying to set up on dev machines, and pulls in far more than needed.
- The packaged libgphoto2 builds depend on libgd for a few picture frame camlibs. libgd pulls in ~40 libraries, including x265, which is GPL licensed and therefore problematic to ship with MomentoBooth (MPL-2.0).
- On Windows, building libgphoto2 ourselves without libgd and libcurl reduced the bundled DLLs from 57 to 13. macOS currently has the same problem: `macos/ci_download_deps.sh` downloads the Homebrew bottle of libgphoto2 and all its dependencies recursively, including gd.

## What exists for Windows (use as reference)

### native-deps

- `windows/build.sh` (runs in MSYS2 CLANG64):
  1. Fetches libgphoto2 at a git ref (tag, branch or commit), applies `windows/patches/`, runs `autoreconf -fi`.
  2. Configures with `--with-libusb=no --with-gdlib=no --with-libcurl=no --with-libtiff-4=no --disable-nls --disable-internal-docs`. Without gd and curl, the `docupen` and `lumix` camlibs are not built and the picture frame camlibs (ax203, st2205, tp6801) lose image conversion. The standard camlib set is kept otherwise.
  3. Stages a bundle: runtime libraries in `bin/`, camlibs in `lib/libgphoto2/<version>/`, iolibs in `lib/libgphoto2_port/<version>/`, import libs, headers (gphoto2, libusb-1.0, libexif), pkg-config files made relocatable with `prefix=${pcfiledir}/../..`, `pkgconf` in `tools/`, license files in `licenses/`.
  4. Writes `manifest.json` (see below) and zips the bundle.
- `.github/workflows/build.yml`: manually dispatched with `libgphoto2_ref` and optionally `release_tag`. The `release` job publishes all zips plus `SHA256SUMS` to a GitHub release.
- Current release: `libgphoto2-2.5.34-1` (Windows only).

### manifest.json

The license overview in the app is generated from this file, so the macOS bundles must produce the same schema:

```json
{
  "platform": "windows-x64",
  "libgphoto2": { "version": "2.5.34", "gitRef": "v2.5.34", "gitCommit": "a4ec9cc8…" },
  "components": [
    {
      "name": "libusb",
      "version": "1.0.30-1",
      "description": "…",
      "url": "https://libusb.info",
      "license": "LGPL-2.1",
      "usage": "runtime",
      "files": ["libusb-1.0.dll"],
      "licenseFiles": ["licenses/libusb/COPYING"]
    }
  ]
}
```

`usage` is `runtime` for shipped libraries and `buildTime` for tools like pkgconf. Component `name`s should match across platforms (e.g. `libgphoto2`, `libusb`, `libexif`, `libltdl`), as the app's license generator deduplicates by name and lets them replace the hand-maintained entries in `licenses/manual_licenses.toml`.

### momentobooth repository

- `windows/get_native_deps.ps1` (also `just get-native-deps`): downloads the pinned release asset, verifies its SHA256, extracts it to `.native_deps/windows-x64/` and writes a gitignored `.cargo/config.toml` in the repository root with `PKG_CONFIG` and `PKG_CONFIG_PATH` in `[env]`. Cargo picks this up for both `cargo` in `rust/` and the Flutter build (cargokit runs cargo from `build/…`, and Cargo searches parent directories for config).
- `windows/CMakeLists.txt` installs `bin/*.dll` next to the executable, and the camlibs and iolibs into `libgphoto2_camlibs/` and `libgphoto2_iolibs/` next to it. This replaced `windows/bundle_libs.ps1`.
- `lib/hardware_control/gphoto2_camera.dart` defaults the driver directories to those names on Windows. See "libgphoto2 driver locations" in `documentation/src/dev_setup.md` for how `IOLIBS`/`CAMLIBS` work per platform.
- `tool/generate_licenses.dart` reads every `.native_deps/*/manifest.json` (deduplicated by component name).
- Windows CI workflows: the MSYS2 steps are replaced by `./windows/get_native_deps.ps1` plus LLVM (for libclang/bindgen and lld-link).

## Current macOS situation (momentobooth repository)

- Dev machines: Homebrew `pkgconf` and `libgphoto2`. Nothing needs configuring, libgphoto2 uses its compiled-in driver directories.
- CI (`.github/workflows/pr-ci-app-macos-arm64.yml` and `release-macos-arm64.yml`), on an arm64 runner:
  1. `macos/ci_download_deps.sh -a arm64_ventura,ventura libgphoto2` downloads the Homebrew bottles for macOS 13 (arm64 and x86_64) of libgphoto2 and all its dependencies. `macos/ci_adapt_pkgconf_dirs.sh` rewrites the `.pc` files.
  2. The app is built twice, with `FLUTTER_XCODE_ARCHS=arm64` and `x86_64` and the matching `PKG_CONFIG_PATH` (plus `PKG_CONFIG_SYSROOT_DIR` for x86_64), with `--dart-define IOLIBS=../Libs/Iolibs --dart-define CAMLIBS=../Libs/Camlibs`.
  3. `macos/ci_bundle_libraries.py` copies the dylibs into `MomentoBooth.app/Contents/Libs` and rewrites their references to `@executable_path/../Libs/…` with `install_name_tool`. Camlibs and iolibs go to `Contents/Libs/Camlibs` and `Contents/Libs/Iolibs`. Note: the script skips dependencies that already start with `@rpath/`.
  4. `macos/ci_resign_everything.py` re-signs everything, then `create-dmg` builds one dmg per architecture.
- Minimum macOS version of the app: **13.5** (`MACOSX_DEPLOYMENT_TARGET`, Podfile). This is why the CI explicitly uses the `*_ventura` bottles: libraries built on a newer macOS get a newer minimum version and won't load on 13.x.

## Task

### 1. native-deps: build macOS bundles

Add `macos/build.sh` and jobs for `macos-arm64` and `macos-x64` to `.github/workflows/build.yml`, and add them to the `needs` of the `release` job. Asset names: `libgphoto2-macos-arm64.zip` and `libgphoto2-macos-x64.zip`.

Points to decide or watch out for:

- **Minimum macOS version.** Everything in the bundle must have a minimum OS of at most 13.5. Set `MACOSX_DEPLOYMENT_TARGET=13.5` for our own builds, and make sure dependencies are not taken from a Homebrew installation built for the runner's newer macOS. Options: build the few dependencies from source as well (libusb, libexif, libltdl, libjpeg-turbo are small, autotools/CMake projects), or keep using the `*_ventura` bottles for them. Verify with `otool -l <lib> | grep -A3 LC_BUILD_VERSION` (`minos`).
- **Architectures.** Either a native runner per architecture (`macos-15` for arm64, `macos-15-intel` for x86_64), or cross-compiling x86_64 on arm64 with `-arch x86_64` (then dependencies must be x86_64 too). Native runners are simplest.
- **Use system libraries where macOS provides them**: libiconv, libxml2 and zlib are part of macOS (`/usr/lib`) and do not need to be bundled. libjpeg is not.
- **Configure options**: same as Windows (`--with-gdlib=no --with-libcurl=no --with-libtiff-4=no --disable-nls`). `--with-libusb=no` refers to the legacy libusb 0.1 iolib and is fine on macOS too. The MSYS2 patches in `windows/patches/` are Windows-specific and not needed.
- **Install names.** Decide how the app finds the bundled dylibs. Either give everything `@rpath/<name>.dylib` install names (and add an rpath to the app, note `ci_bundle_libraries.py` ignores `@rpath/` references), or keep absolute install names and keep relinking them with `ci_bundle_libraries.py`. Camlibs and iolibs (`.so`) reference `libgphoto2`/`libgphoto2_port` and other dylibs too.
- **pkg-config**: Homebrew `pkgconf` is already used in CI and on dev machines, so bundling pkgconf is optional on macOS. Relocatable `.pc` files (`prefix=${pcfiledir}/../..`) remove the need for `ci_adapt_pkgconf_dirs.sh`.
- **Manifest and licenses**: there is no `pacman -Qi` equivalent, so collect name, version, license, URL and license files per component yourself (e.g. from the source tarballs/repositories, or `brew info --json=v2` if bottles are used).

### 2. momentobooth: consume the macOS bundles

- Add a macOS counterpart of `windows/get_native_deps.ps1` (e.g. `macos/get_native_deps.sh`), hooked into `just get-native-deps` (the `[unix]` recipe currently only prints a message, it should keep doing that on Linux). Download both architectures to `.native_deps/macos-arm64/` and `.native_deps/macos-x64/`, as the release build builds both.
- **Cargo configuration per architecture**: the `pkg-config` crate supports target-specific variables, so `.cargo/config.toml` can set `PKG_CONFIG_PATH_aarch64_apple_darwin` and `PKG_CONFIG_PATH_x86_64_apple_darwin` to the matching bundle. Building x86_64 on an arm64 machine also needs `PKG_CONFIG_ALLOW_CROSS=1`.
- **Driver directories**: release builds keep `--dart-define IOLIBS=../Libs/Iolibs --dart-define CAMLIBS=../Libs/Camlibs`. Decide whether dev machines also use the bundle (no Homebrew libgphoto2 needed anymore, consistent with Windows) or keep Homebrew for development. If dev uses the bundle, debug builds must also find the dylibs and drivers (the compiled-in driver paths of a bundled libgphoto2 point to the CI build directory, which doesn't exist locally), so a macOS default in `gphoto2_camera.dart` like the Windows one, plus copying into the app bundle during the Xcode build, would be needed.
- Update the macOS CI workflows: replace `ci_download_deps.sh`/`ci_adapt_pkgconf_dirs.sh` with the new script, adapt the "Bundle libraries" step (copy camlibs/iolibs from `.native_deps/macos-*/lib/libgphoto2*/*/`), and remove scripts that are no longer used.
- Update `documentation/src/dev_setup.md` (macOS requirements, "libgphoto2 driver locations" table), `CLAUDE.md` (Development Setup) and `CHANGELOG.md` (Dev changes).

## Verification

- `otool -L` on every dylib, camlib and iolib in the final `MomentoBooth.app` shows no `/opt/homebrew`, `/usr/local` or CI build paths, only `@executable_path`/`@rpath`/`@loader_path` references and system libraries.
- `minos` of every bundled binary is at most 13.5.
- No GPL-licensed component in any `manifest.json`.
- The app starts from the dmg on both architectures (or at least on arm64 plus an x86_64 check under Rosetta), finds a camera over USB (ptp2) and can capture a photo.
- The macOS PR workflow in the momentobooth repository is green, and the About screen lists the libraries from the macOS manifest under "Native libraries".
- Code signing still succeeds (`ci_resign_everything.py`), and Gatekeeper accepts the app (`spctl -a -vv MomentoBooth.app`).

## Practical

- Pushing to native-deps is fine; publish a release only when the macOS bundles are verified, e.g. as `libgphoto2-2.5.34-2` (all platforms), then update the Windows SHA256 in `windows/get_native_deps.ps1` as well, since a new release contains a newly built Windows zip.
- Without `release_tag`, the workflow only uploads the zips as workflow artifacts, useful for testing (`gh run download <run id> -R momentobooth/native-deps`).
- `windows/get_native_deps.ps1 -ZipPath <zip>` lets Windows test a local or artifact zip without a release; a similar option is useful for the macOS script.
