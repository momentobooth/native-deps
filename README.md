# MomentoBooth native dependencies

Prebuilt native libraries for [MomentoBooth](https://github.com/momentobooth/momentobooth), so that building the app does not require installing them through a package manager.

Currently this contains [libgphoto2](https://github.com/gphoto/libgphoto2) and its dependencies for Windows x64 and macOS arm64.

## Bundle contents

Each release contains a zip per platform with:

| Path | Contents |
| - | - |
| `bin/` (Windows), `lib/*.dylib` (macOS) | Runtime libraries: libgphoto2 and everything it depends on, except the libraries that are part of the operating system |
| `lib/libgphoto2/<version>/` | Camera drivers (camlibs) |
| `lib/libgphoto2_port/<version>/` | Port drivers (iolibs) |
| `lib/*.dll.a` (Windows), `lib/pkgconfig/`, `include/` | Import libraries, relocatable pkg-config files and headers, used to build against the libraries |
| `tools/` (Windows) | `pkgconf` (also as `pkg-config`), used by the Rust build scripts to find the libraries |
| `licenses/` | License files of all included components |
| `manifest.json` | Name, version, license and files of every included component |

A `SHA256SUMS` file with the checksums of all zips is attached to every release.

### macOS

- The bundle requires macOS 15 or later, see [Build configuration](#build-configuration).
- The libraries and drivers refer to each other as `@rpath/<name>`. An application that uses them must have the directory that it puts the `.dylib` files in as an rpath.
- The zip contains symbolic links (`libgphoto2.dylib` to `libgphoto2.6.dylib`), which the linker needs. Extract it with a tool that keeps them, like `unzip` or `ditto`.
- pkgconf is not included, install it with `brew install pkgconf`.

## Build configuration

libgphoto2 is built from a git ref (tag, branch or commit), so unreleased fixes can be used when needed. It is built without these optional dependencies, which keeps the bundle small (13 instead of 57 DLLs on Windows) and free of GPL licensed libraries:

- **libgd**: only used by the camlibs for digital picture frames (ax203, st2205, tp6801) and the docupen scanner. Without it, the picture frame camlibs are built with reduced functionality and docupen is not built.
- **libcurl**: only used by the lumix camlib, which controls Panasonic cameras over WiFi. Panasonic cameras connected over USB use the ptp2 camlib.
- **libtiff** and **NLS** (translated error messages).

On Windows, the dependencies of libgphoto2 are MSYS2 packages. On macOS they are [Homebrew bottles](https://docs.brew.sh/Bottles), for the oldest macOS version that Homebrew provides all of them for (`bottle_tag` in `macos/build.sh`). That version, currently macOS 15, is the minimum macOS version of the bundle. When Homebrew stops providing a bottle for it, the build fails and the version has to be raised, together with the minimum macOS version of MomentoBooth.

## Building a release

Run the *Build native dependencies* workflow from the Actions tab, with the libgphoto2 ref to build and the release tag to publish to (e.g. `libgphoto2-2.5.34-1`). Then update the release tag and checksums in the MomentoBooth repository.

### Building locally on Windows

1. Install [MSYS2](https://www.msys2.org) in a path without spaces.
2. In a CLANG64 shell, install the build dependencies:

   ```sh
   pacman -S --needed $(cat windows/msys2-packages.txt)
   ```

3. Build, using a work directory without spaces in its path (defaults to `build/windows-x64` in this repository):

   ```sh
   windows/build.sh v2.5.34 dist/libgphoto2-windows-x64.zip
   ```

The patches in `windows/patches/` are taken from the [MSYS2 libgphoto2 package](https://github.com/msys2/MINGW-packages/tree/master/mingw-w64-libgphoto2).

### Building locally on macOS

1. Install Xcode and [Homebrew](https://brew.sh) on an Apple Silicon Mac.
2. Install the build dependencies:

   ```sh
   brew install $(cat macos/brew-packages.txt)
   ```

3. Build, using a work directory without spaces in its path (defaults to `build/macos-arm64` in this repository):

   ```sh
   macos/build.sh v2.5.34 dist/libgphoto2-macos-arm64.zip
   ```

The build ends with a check that every library and driver in the bundle loads, has no references outside the bundle and runs on the minimum macOS version.
