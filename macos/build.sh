#!/usr/bin/env bash
# Builds libgphoto2 for macOS arm64 and packages it together with everything needed to build and run MomentoBooth against it.
#
# Must run on an Apple Silicon Mac with Xcode and the Homebrew packages from macos/brew-packages.txt installed.
# Usage: macos/build.sh <libgphoto2 git ref> <output zip>

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <libgphoto2 git ref> <output zip>" >&2
  exit 1
fi
if [[ "$(uname -sm)" != "Darwin arm64" ]]; then
  echo "This script must run on an Apple Silicon Mac" >&2
  exit 1
fi

# The dependencies of libgphoto2 are Homebrew bottles (prebuilt packages) for the oldest macOS version that Homebrew provides all
# of them for. That version is the minimum macOS version of the bundle, and with that of MomentoBooth.
bottle_tag=arm64_sequoia
export MACOSX_DEPLOYMENT_TARGET=15.0
# gettext provides libintl, which the libexif bottle is linked against.
bottle_formulae=(libusb libexif libtool jpeg-turbo gettext)

ref=$1
mkdir -p "$(dirname "$2")"
output=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
root=$(cd "$(dirname "$0")/.." && pwd)
work=${WORK_DIR:-$root/build/macos-arm64}

if [[ "$work" == *" "* ]]; then
  echo "The work directory may not contain spaces in its path, libtool cannot handle those" >&2
  exit 1
fi
src=$work/libgphoto2
bottles=$work/bottles
prefix=$work/install
stage=$work/stage

rm -rf "$src" "$bottles" "$prefix" "$stage"
mkdir -p "$bottles"

for formula in "${bottle_formulae[@]}"; do
  bottle=$(curl -fsSL "https://formulae.brew.sh/api/formula/$formula.json" | jq --arg tag "$bottle_tag" '.bottle.stable.files[$tag]')
  if [[ "$bottle" == null ]]; then
    echo "Homebrew has no $bottle_tag bottle of $formula, see the comment at bottle_tag in $0" >&2
    exit 1
  fi
  # GitHub Packages requires a token for public downloads too, but accepts any value.
  curl -fsSL -H "Authorization: Bearer QQ==" -o "$bottles/$formula.tar.gz" "$(jq -r .url <<<"$bottle")"
  echo "$(jq -r .sha256 <<<"$bottle")  $bottles/$formula.tar.gz" | shasum -a 256 -c - >/dev/null
  # Extracts to <formula>/<version>, like in a Homebrew Cellar.
  tar -xzf "$bottles/$formula.tar.gz" -C "$bottles"
done
# Bottles refer to their own location through a placeholder, which `brew install` would replace by the installation directory.
sed -i '' -E 's#@@HOMEBREW_[A-Z]+@@/[^/]+/[^/]+#${pcfiledir}/../..#' "$bottles"/*/*/lib/pkgconfig/*.pc
# Without PKG_CONFIG_PATH and with only these directories, pkg-config cannot find the libraries installed through Homebrew on this
# machine, which do not run on the minimum macOS version.
export PKG_CONFIG_PATH=
export PKG_CONFIG_LIBDIR=$prefix/lib/pkgconfig:$(echo "$bottles"/*/*/lib/pkgconfig | tr ' ' ':')

# Fetching a single ref works for tags, branches and commit hashes alike.
git init -q "$src"
git -C "$src" fetch -q --depth 1 https://github.com/gphoto/libgphoto2 "$ref"
git -C "$src" checkout -q FETCH_HEAD
commit=$(git -C "$src" rev-parse HEAD)

cd "$src"
autoreconf -fi

# Optional libraries are disabled explicitly, so the result does not depend on what happens to be installed. See "Build
# configuration" in the README for what they are used for. --with-libusb=no refers to the legacy libusb 0.1 iolib.
# libltdl has no pkg-config file and would be taken from Homebrew when not given. libxml2 is part of macOS, which has none either.
./configure \
  --prefix="$prefix" \
  --with-libusb=no \
  --with-gdlib=no \
  --with-libcurl=no \
  --with-libtiff-4=no \
  --disable-nls \
  --disable-internal-docs \
  LTDLINCL="-I$(echo "$bottles"/libtool/*/include)" \
  LIBLTDL="-L$(echo "$bottles"/libtool/*/lib) -lltdl" \
  LIBXML2_CFLAGS="$(/usr/bin/xml2-config --cflags)" \
  LIBXML2_LIBS=-lxml2

make -j"$(sysctl -n hw.ncpu)"
make install

version=$(pkgconf --modversion libgphoto2)

mkdir -p "$stage"/{lib/pkgconfig,include,licenses}

# Camlibs and iolibs, keeping the standard directory layout.
for dir in libgphoto2 libgphoto2_port; do
  for driverdir in "$prefix/lib/$dir"/*/; do
    mkdir -p "$stage/lib/$dir/$(basename "$driverdir")"
    cp "$driverdir"*.so "$stage/lib/$dir/$(basename "$driverdir")/"
  done
done

# Prints the libraries (recursively) loaded by the given binaries that are not part of macOS itself, i.e. found in the given search directories.
dylib_closure() {
  local search_dirs=$1
  shift
  local queue=("$@") seen=" " file dependency name dir
  while [[ ${#queue[@]} -gt 0 ]]; do
    file=${queue[0]}
    queue=("${queue[@]:1}")
    for dependency in $(otool -L "$file" | awk 'NR > 1 && $1 !~ /^\/(usr\/lib|System)\// {print $1}'); do
      name=$(basename "$dependency")
      for dir in $search_dirs; do
        if [[ -f "$dir/$name" && "$seen" != *" $name "* ]]; then
          seen+="$name "
          echo "$dir/$name"
          queue+=("$dir/$name")
          break
        fi
      done
    done
  done
}

runtime_roots=("$prefix"/lib/libgphoto2*.dylib "$stage"/lib/libgphoto2*/*/*.so)
runtime_dylibs=$(dylib_closure "$prefix/lib $(echo "$bottles"/*/*/lib)" "${runtime_roots[@]}" | sort -u)
for dylib in $runtime_dylibs; do
  cp "$dylib" "$stage/lib/"
done
# The libraries in bottles are read-only.
chmod u+w "$stage"/lib/*.dylib

# Every reference to a library in the bundle becomes @rpath/<name>, so the bundle works from any location. The application has to
# have the directory it puts the libraries in as an rpath.
for binary in "$stage"/lib/*.dylib "$stage"/lib/libgphoto2*/*/*.so; do
  if [[ "$binary" == *.dylib ]]; then
    install_name_tool -id "@rpath/$(basename "$binary")" "$binary"
  fi
  for dependency in $(otool -L "$binary" | awk 'NR > 1 {print $1}'); do
    if [[ "$dependency" != @rpath/* && -f "$stage/lib/$(basename "$dependency")" ]]; then
      install_name_tool -change "$dependency" "@rpath/$(basename "$dependency")" "$binary"
    fi
  done
  # Bottles built with CMake have an rpath to their Homebrew location, which is a placeholder that nothing in the bundle uses.
  for rpath in $(otool -l "$binary" | awk '$1 == "cmd" {in_rpath = $2 == "LC_RPATH"} in_rpath && $1 == "path" {print $2}'); do
    install_name_tool -delete_rpath "$rpath" "$binary"
  done
  # Changing a binary invalidates its signature, without which macOS refuses to load it on arm64.
  codesign --force --sign - "$binary"
done

# Build-time files: headers, pkg-config files and the unversioned library names that the linker looks for.
cp -R "$prefix/include/gphoto2" "$bottles"/libusb/*/include/libusb-1.0 "$bottles"/libexif/*/include/libexif "$stage/include/"
cp "$prefix"/lib/pkgconfig/libgphoto2*.pc "$bottles"/libusb/*/lib/pkgconfig/libusb-1.0.pc "$bottles"/libexif/*/lib/pkgconfig/libexif.pc "$stage/lib/pkgconfig/"
# Make the pkg-config files relocatable.
sed -i '' 's|^prefix=.*|prefix=${pcfiledir}/../..|' "$stage"/lib/pkgconfig/*.pc
cp -a "$prefix"/lib/libgphoto2.dylib "$prefix"/lib/libgphoto2_port.dylib "$bottles"/libusb/*/lib/libusb-1.0.dylib "$bottles"/libexif/*/lib/libexif.dylib "$stage/lib/"

# Prints a JSON object describing the component that the given library of the bundle belongs to, and copies its license files.
component_json() {
  local dylib=$1 name component_version description url license license_files=() file
  if [[ "$dylib" == "$prefix"/* ]]; then
    name=libgphoto2 component_version=$version license="LGPL-2.1-or-later"
    description="The libgphoto2 camera access and control library" url="http://www.gphoto.org/proj/libgphoto2/"
    license_files=("$src/COPYING")
  else
    local bottle=${dylib%/lib/*}
    component_version=$(basename "$bottle")
    # The names are those of the Windows bundle. The licenses are those of the library, which for libltdl and libintl differs from
    # the license that Homebrew lists, as that includes the GPL licensed tools of the formula.
    case "$(basename "$(dirname "$bottle")")" in
      libusb)
        name=libusb license="LGPL-2.1-or-later"
        description="Library that provides generic access to USB devices" url="https://libusb.info/"
        license_files=("$bottle/COPYING") ;;
      libexif)
        name=libexif license="LGPL-2.1-or-later"
        description="A library to parse an EXIF file and read the data from those tags" url="https://libexif.github.io/"
        license_files=("$bottle/COPYING") ;;
      libtool)
        name=libltdl license="LGPL-2.0-or-later WITH Libtool-exception"
        description="A system independent dlopen wrapper for GNU libtool" url="https://www.gnu.org/software/libtool/"
        license_files=("$bottle/share/libtool/COPYING.LIB") ;;
      jpeg-turbo)
        name=libjpeg-turbo license="IJG AND BSD-3-Clause AND Zlib"
        description="JPEG image codec with accelerated baseline compression and decompression" url="https://libjpeg-turbo.org/"
        license_files=("$bottle/LICENSE.md" "$bottle/share/doc/libjpeg-turbo/README.ijg") ;;
      gettext)
        name=gettext-runtime license="LGPL-2.1-or-later"
        description="GNU internationalization runtime library" url="https://www.gnu.org/software/gettext/"
        # The bottle only contains the GPL of the gettext tools. The license text of libintl is the same as that of libltdl.
        license_files=("$bottles"/libtool/*/share/libtool/COPYING.LIB) ;;
      *)
        echo "No license information for $dylib, add it to component_json in $0" >&2
        exit 1 ;;
    esac
  fi
  mkdir -p "$stage/licenses/$name"
  cp "${license_files[@]}" "$stage/licenses/$name/"
  jq -n \
    --arg name "$name" \
    --arg version "$component_version" \
    --arg description "$description" \
    --arg url "$url" \
    --arg license "$license" \
    --arg file "$(basename "$dylib")" \
    --args '{name: $name, version: $version, description: $description, url: $url, license: $license, usage: "runtime", files: [$file], licenseFiles: $ARGS.positional}' \
    $(for file in "${license_files[@]}"; do echo "licenses/$name/$(basename "$file")"; done)
}

for dylib in $runtime_dylibs; do
  component_json "$dylib"
done | jq -s \
  --arg version "$version" \
  --arg ref "$ref" \
  --arg commit "$commit" '
  # Merge entries of the same component, e.g. the two libraries of libgphoto2.
  {platform: "macos-arm64", libgphoto2: {version: $version, gitRef: $ref, gitCommit: $commit},
   components: (group_by(.name) | map(.[0] + {files: (map(.files) | add | unique)}))}' > "$stage/manifest.json"

# What is published has to load on the minimum macOS version, from any location.
binaries=$(find "$stage/lib" -type f \( -name '*.dylib' -o -name '*.so' \))
for binary in $binaries; do
  minos=$(otool -l "$binary" | awk '$1 == "minos" {print $2; exit}')
  if [[ "$(printf '%s\n' "$minos" "$MACOSX_DEPLOYMENT_TARGET" | sort -V | tail -1)" != "$MACOSX_DEPLOYMENT_TARGET" ]]; then
    echo "$binary requires macOS $minos, which is newer than $MACOSX_DEPLOYMENT_TARGET" >&2
    exit 1
  fi
  if otool -L "$binary" | awk 'NR > 1 {print $1}' | grep -vE '^(@rpath|/usr/lib|/System)/'; then
    echo "$binary depends on the libraries above, which are not in the bundle" >&2
    exit 1
  fi
done
cc -o "$work/load_test" "$root/macos/load_test.c" -Wl,-rpath,"$stage/lib" \
  $(PKG_CONFIG_LIBDIR="$stage/lib/pkgconfig" pkgconf --cflags --libs libgphoto2)
"$work/load_test" $binaries

rm -f "$output"
(cd "$stage" && zip -qry9 "$output" .)

echo "Built libgphoto2 $version ($commit) into $output"
