#!/bin/bash
set -euo pipefail
package=${1:?Usage: install_linux_integration.sh package-root}
test -d "$package/opt/seafile-next"
mkdir -p "$package/usr/share/applications" "$package/DEBIAN"
cat > "$package/usr/share/applications/seafile-next-link.desktop" <<'EOF'
[Desktop Entry]
Name=Seafile Next local file link
Exec=seafile-next --open-local-file %u
Icon=seafile
Type=Application
NoDisplay=true
Terminal=false
MimeType=x-scheme-handler/seafile;
EOF
# dpkg activates/refreshes these associations at installation, not when the
# application starts. Do not force the default handler over another app.
for hook in postinst postrm; do
    cat > "$package/DEBIAN/$hook" <<'EOF'
#!/bin/sh
set -e
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database -q /usr/share/applications || true
fi
exit 0
EOF
    chmod 755 "$package/DEBIAN/$hook"
done
