#!/bin/bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo_root"
package="$repo_root/dist/linux-package"
app="$package/opt/seafile-next"
mkdir -p "$app/bin" "$app/lib" "$package/usr/bin" "$package/usr/share/applications" "$package/usr/share/icons/hicolor" "$package/DEBIAN" "$repo_root/debian"
cp build-linux/seafile-applet "$app/bin/"
cp usr/bin/seaf-daemon "$app/bin/"
cp -a usr/lib/libsearpc.so* usr/lib/libseafile.so* "$app/lib/"
for binary in "$app/bin/"*; do patchelf --set-rpath '$ORIGIN/../lib' "$binary"; done
cat > "$app/seafile-next" <<'EOF'
#!/bin/sh
app_root=$(CDPATH= cd -- "$(dirname -- "$(readlink -f "$0")")" && pwd)
export PATH="$app_root/bin:$PATH"
exec "$app_root/bin/seafile-applet" "$@"
EOF
chmod +x "$app/seafile-next"
ln -s /opt/seafile-next/seafile-next "$package/usr/bin/seafile-next"
cp -a desktop/data/icons/. "$package/usr/share/icons/hicolor/"
sed -e 's/^Name=.*/Name=seafile-next/' -e 's/^TryExec=.*/TryExec=seafile-next/' -e 's/^Exec=.*/Exec=seafile-next/' desktop/data/com.seafile.seafile-applet.desktop > "$package/usr/share/applications/seafile-next.desktop"
cat > debian/control <<'EOF'
Source: seafile-next
Section: net
Priority: optional
Maintainer: Seafile Next <noreply@github.com>
Package: seafile-next
Architecture: amd64
Description: Seafile Next desktop sync client
EOF
export LD_LIBRARY_PATH="$app/lib:${LD_LIBRARY_PATH:-}"
dependencies=$(dpkg-shlibdeps --ignore-missing-info -O -e"$app/bin/seafile-applet" -e"$app/bin/seaf-daemon" -l"$app/lib" | sed -n 's/^shlibs:Depends=//p')
test -n "$dependencies"
cat > "$package/DEBIAN/control" <<EOF
Package: seafile-next
Version: 9.0.20-next.4
Section: net
Priority: optional
Architecture: amd64
Maintainer: Seafile Next <noreply@github.com>
Depends: $dependencies
Description: Seafile Next desktop sync client
 Native desktop library synchronization and file browsing.
EOF
dpkg-deb --build --root-owner-group "$package" dist/seafile-next-linux-amd64.deb
