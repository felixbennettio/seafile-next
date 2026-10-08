#!/bin/bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/.." && pwd)
prefix="$repo_root/usr"
brew_prefix=$(brew --prefix)
export PATH="$(brew --prefix gettext)/bin:$prefix/bin:$PATH"
export PKG_CONFIG_PATH="$prefix/lib/pkgconfig:$brew_prefix/lib/pkgconfig:$(brew --prefix openssl@3)/lib/pkgconfig:$(brew --prefix sqlite)/lib/pkgconfig"
export CPPFLAGS="-I$prefix/include -I$brew_prefix/include"
export LDFLAGS="-L$prefix/lib -L$brew_prefix/lib"
# The upstream autotools files still expect this aclocal search path.
sudo mkdir -p /opt/local/share
if [[ ! -e /opt/local/share/aclocal ]]; then sudo ln -s "$brew_prefix/share/aclocal" /opt/local/share/aclocal; fi
cd "$repo_root/libsearpc"
./autogen.sh
./configure --prefix="$prefix" --disable-compile-demo
make -j"$(sysctl -n hw.ncpu)"
make install
cd "$repo_root/sync"
./autogen.sh
./configure --prefix="$prefix" --disable-fuse
make -j"$(sysctl -n hw.ncpu)"
make install
engine="$repo_root/apple/Engine"
cp "$prefix/bin/seaf-daemon" "$engine/seaf-daemon"
dylibbundler -b -of -cd -x "$engine/seaf-daemon" -d "$engine/lib" -p '@executable_path/lib/'
while IFS= read -r -d '' binary; do
  if file -b "$binary" | grep -q 'Mach-O'; then
    if otool -L "$binary" | tail -n +2 | awk '{print $1}' | grep -Eq '^(/opt/homebrew/|/usr/local/|/Users/runner/)'; then
      echo "Unbundled engine dependency: $binary" >&2; exit 1
    fi
    codesign --force --sign - "$binary"
  fi
done < <(find "$engine" -type f -print0)
