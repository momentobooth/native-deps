#!/usr/bin/env bash
# Builds libgphoto2 for Windows x64 and packages it together with everything needed to build and run MomentoBooth against it.
#
# Must run in an MSYS2 CLANG64 shell with the packages from windows/msys2-packages.txt installed.
# Usage: windows/build.sh <libgphoto2 git ref> <output zip>

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <libgphoto2 git ref> <output zip>" >&2
  exit 1
fi
if [[ "${MSYSTEM:-}" != "CLANG64" ]]; then
  echo "This script must run in an MSYS2 CLANG64 shell" >&2
  exit 1
fi

ref=$1
output=$(realpath -m "$2")
root=$(cd "$(dirname "$0")/.." && pwd)
work=${WORK_DIR:-$root/build/windows-x64}

# The compiler reports its own location as a Windows path, which libtool cannot handle when it contains spaces.
if [[ "$(cygpath -w "$MINGW_PREFIX")" == *" "* || "$work" == *" "* ]]; then
  echo "Neither the MSYS2 installation nor the work directory may contain spaces in their path" >&2
  exit 1
fi
src=$work/libgphoto2
prefix=$work/install
stage=$work/stage

rm -rf "$work"
mkdir -p "$work"

# //////////////////// #
# Build libgphoto2     #
# //////////////////// #

# Fetching a single ref works for tags, branches and commit hashes alike.
git init -q "$src"
git -C "$src" fetch -q --depth 1 https://github.com/gphoto/libgphoto2 "$ref"
git -C "$src" checkout -q FETCH_HEAD
commit=$(git -C "$src" rev-parse HEAD)

cd "$src"
for patch in "$root"/windows/patches/*.patch; do
  patch -Np1 -i "$patch"
done
autoreconf -fi

# Optional libraries are disabled explicitly, so the result does not depend on what happens to be installed:
# - libgd is only used by digital picture frame camlibs (ax203, st2205, tp6801) and docupen, and pulls in ~40 DLLs.
# - libcurl is only used by the lumix camlib, which controls Panasonic cameras over WiFi.
# - NLS only translates error messages, which MomentoBooth does not show as-is.
# --with-libusb=no refers to the legacy libusb 0.1 iolib, the libusb 1.0 iolib is still built.
./configure \
  --prefix="$prefix" \
  --build="$MINGW_CHOST" \
  --host="$MINGW_CHOST" \
  --with-libusb=no \
  --with-gdlib=no \
  --with-libcurl=no \
  --with-libtiff-4=no \
  --disable-nls \
  --disable-internal-docs

# Clang cannot handle '-Wl,-rpath' (taken from the MSYS2 package build).
find . -depth -name config.status -exec sed -e 's|${wl}-rpath ${wl}|-L|g' -i {} ';'

make -j"$(nproc)"
make install

version=$(pkgconf --modversion "$prefix/lib/pkgconfig/libgphoto2.pc")

# //////////////////// #
# Stage the bundle     #
# //////////////////// #

mkdir -p "$stage"/{bin,lib/pkgconfig,include,tools,licenses}

# Camlibs and iolibs, keeping the standard directory layout.
for dir in libgphoto2 libgphoto2_port; do
  for driverdir in "$prefix/lib/$dir"/*/; do
    mkdir -p "$stage/lib/$dir/$(basename "$driverdir")"
    cp "$driverdir"*.dll "$stage/lib/$dir/$(basename "$driverdir")/"
  done
done

# Prints the DLLs (recursively) imported by the given binaries that are not part of Windows itself, i.e. found in the given search directories.
dll_closure() {
  local search_dirs=$1
  shift
  local queue=("$@") seen=" " file dll dir
  while [[ ${#queue[@]} -gt 0 ]]; do
    file=${queue[0]}
    queue=("${queue[@]:1}")
    for dll in $(llvm-objdump -p "$file" | awk '/DLL Name:/ {print $3}'); do
      for dir in $search_dirs; do
        if [[ -f "$dir/$dll" && "$seen" != *" $dll "* ]]; then
          seen+="$dll "
          echo "$dir/$dll"
          queue+=("$dir/$dll")
          break
        fi
      done
    done
  done
}

runtime_roots=("$prefix"/bin/libgphoto2*.dll "$stage"/lib/libgphoto2*/*/*.dll)
mapfile -t runtime_dlls < <(dll_closure "$prefix/bin $MINGW_PREFIX/bin" "${runtime_roots[@]}" | sort -u)
cp "${runtime_dlls[@]}" "$stage/bin/"

# Build-time files: headers, import libraries and pkg-config files of the libraries the Rust crates link against.
cp -r "$prefix/include/gphoto2" "$stage/include/"
cp -r "$MINGW_PREFIX/include/libusb-1.0" "$MINGW_PREFIX/include/libexif" "$stage/include/"
cp "$prefix"/lib/libgphoto2*.dll.a "$MINGW_PREFIX/lib/libusb-1.0.dll.a" "$stage/lib/"
cp "$prefix"/lib/pkgconfig/libgphoto2*.pc "$MINGW_PREFIX"/lib/pkgconfig/{libusb-1.0,libexif}.pc "$stage/lib/pkgconfig/"
# Make the pkg-config files relocatable.
sed -i 's|^prefix=.*|prefix=${pcfiledir}/../..|' "$stage"/lib/pkgconfig/*.pc

# pkgconf, so that no MSYS2 installation is needed to build MomentoBooth.
mapfile -t pkgconf_dlls < <(dll_closure "$MINGW_PREFIX/bin" "$MINGW_PREFIX/bin/pkgconf.exe")
cp "$MINGW_PREFIX/bin/pkgconf.exe" "${pkgconf_dlls[@]}" "$stage/tools/"
cp "$stage/tools/pkgconf.exe" "$stage/tools/pkg-config.exe"

# ////////////////////////////// #
# Licenses and manifest          #
# ////////////////////////////// #

# Prints a JSON object describing the MSYS2 package that owns the given file, and copies its license files.
package_json() {
  local file=$1 usage=$2 package name info
  package=$(pacman -Qqo "$file")
  name=${package#"$MINGW_PACKAGE_PREFIX-"}
  info=$(pacman -Qi "$package")
  local license_dir="$MINGW_PREFIX/share/licenses/$name" license_files=()
  if [[ -d "$license_dir" ]]; then
    mkdir -p "$stage/licenses/$name"
    cp -r "$license_dir"/. "$stage/licenses/$name/"
    mapfile -t license_files < <(cd "$stage" && find "licenses/$name" -type f | sort)
  fi
  jq -n \
    --arg name "$name" \
    --arg version "$(awk -F' : ' '/^Version/ {print $2}' <<<"$info")" \
    --arg description "$(awk -F' : ' '/^Description/ {print $2}' <<<"$info")" \
    --arg url "$(awk -F' : ' '/^URL/ {print $2}' <<<"$info")" \
    --arg license "$(awk -F' : ' '/^Licenses/ {print $2}' <<<"$info" | sed -E 's/(spdx|custom)://g; s/ +documentation:[^ ]+//g')" \
    --arg usage "$usage" \
    --arg file "$(basename "$file")" \
    --args '{name: $name, version: $version, description: $description, url: $url, license: $license, usage: $usage, files: [$file], licenseFiles: $ARGS.positional}' \
    "${license_files[@]}"
}

mkdir -p "$stage/licenses/libgphoto2"
cp "$src/COPYING" "$stage/licenses/libgphoto2/COPYING"

{
  jq -n \
    --arg version "$version" \
    --arg ref "$ref" \
    --arg commit "$commit" \
    '{name: "libgphoto2", version: $version, gitRef: $ref, gitCommit: $commit,
      description: "The libgphoto2 camera access and control library", url: "http://www.gphoto.org/proj/libgphoto2/",
      license: "LGPL-2.1-or-later", usage: "runtime", files: ["libgphoto2-6.dll", "libgphoto2_port-12.dll"], licenseFiles: ["licenses/libgphoto2/COPYING"]}'
  for dll in "${runtime_dlls[@]}"; do
    [[ "$dll" == "$prefix"/* ]] || package_json "$dll" runtime
  done
  package_json "$MINGW_PREFIX/bin/pkgconf.exe" buildTime
  for dll in "${pkgconf_dlls[@]}"; do
    package_json "$dll" buildTime
  done
} | jq -s '
  # Merge entries of the same package, e.g. multiple DLLs from one MSYS2 package.
  group_by(.name) | map(.[0] + {files: (map(.files) | add | unique)})
  | {platform: "windows-x64", libgphoto2: (map(select(.name == "libgphoto2"))[0] | {version, gitRef, gitCommit}),
     components: map(del(.gitRef, .gitCommit))}' > "$stage/manifest.json"

rm -f "$output"
mkdir -p "$(dirname "$output")"
(cd "$stage" && zip -qr9 "$output" .)

echo "Built libgphoto2 $version ($commit) into $output"
