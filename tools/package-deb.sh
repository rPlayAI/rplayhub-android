#!/usr/bin/env bash
# Build the Linux client as a Debian package: tools/package-deb.sh [version]
#
# Links against the distribution's SDL2 and FFmpeg (a self-built FFmpeg in /usr/local is
# typically GPL/nonfree and static, so it must not ship), stages bin/, share/ (agent, fonts,
# artwork), a desktop entry and icons, and runs dpkg-deb and lintian. Output:
# build/deb/rplayhub-android_<version>-1_<arch>.deb
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="${1:-$(sed -n 's/^project(rplayhub-android-linux VERSION \([0-9.]*\).*/\1/p' "$root/linux/CMakeLists.txt")}"
arch="$(dpkg --print-architecture)"
multiarch="$(dpkg-architecture -qDEB_HOST_MULTIARCH)"
build="$root/linux/build-deb"
stage="$root/build/deb/stage"
out="$root/build/deb"
die() { echo "package-deb: $*" >&2; exit 1; }
[ -f "$root/build/agent/screen-sharing-agent.jar" ] || die "no device agent in build/agent — run tools/build-agent.sh first"

# GCC ignores -I/-isystem for directories it already searches by default, so a self-built
# FFmpeg or SDL2 in /usr/local/include would shadow the distribution's headers. A directory of
# symlinks to the distribution's headers, given as a plain -I, wins the search.
shadow="$build/shadow-include"
rm -rf "$shadow"; mkdir -p "$shadow"
for d in libavcodec libavformat libavutil libswscale libswresample; do
    [ -d "/usr/include/$multiarch/$d" ] && ln -s "/usr/include/$multiarch/$d" "$shadow/$d"
done
[ -d /usr/include/SDL2 ] && ln -s /usr/include/SDL2 "$shadow/SDL2"

echo "package-deb: configuring against the distribution's SDL2 and FFmpeg"
PKG_CONFIG_LIBDIR="/usr/lib/$multiarch/pkgconfig:/usr/share/pkgconfig" \
cmake -S "$root/linux" -B "$build" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr \
      -DCMAKE_CXX_FLAGS="-I$shadow" -DCMAKE_C_FLAGS="-I$shadow" \
      -DCMAKE_EXE_LINKER_FLAGS="-L/usr/lib/$multiarch" >/dev/null
cmake --build "$build" -j"$(nproc)" --target rplayhub-android-linux
bin="$build/rplayhub-android-linux"
# ldd as on a user's machine: the distribution's library directories only (this host's ldconfig
# may prefer /usr/local/lib for the same sonames).
distro_ldd() { LD_LIBRARY_PATH="/lib/$multiarch:/usr/lib/$multiarch" ldd "$1"; }
distro_ldd "$bin" | grep -qE "not found|/usr/local/" && die "the binary needs a library outside the distribution:
$(distro_ldd "$bin" | grep -E 'not found|/usr/local/')"

rm -rf "$stage"; mkdir -p "$stage/DEBIAN" "$stage/usr/bin" "$stage/usr/share/rplayhub-android/agent" \
      "$stage/usr/share/rplayhub-android/fonts" "$stage/usr/share/applications" \
      "$stage/usr/share/icons/hicolor/256x256/apps" "$stage/usr/share/icons/hicolor/128x128/apps" \
      "$stage/usr/share/doc/rplayhub-android"
install -m 0755 "$bin" "$stage/usr/bin/rplayhub-android"
strip --strip-unneeded "$stage/usr/bin/rplayhub-android"
cp -r "$root/build/agent/." "$stage/usr/share/rplayhub-android/agent/"
cp "$root/linux/fonts/"*.ttf "$stage/usr/share/rplayhub-android/fonts/"
cp "$root/doc/pixel-backside-transparent.png" "$stage/usr/share/rplayhub-android/"
cp "$root/linux/packaging/rplayhub-android-256.png" "$stage/usr/share/icons/hicolor/256x256/apps/rplayhub-android.png"
cp "$root/linux/packaging/rplayhub-android-128.png" "$stage/usr/share/icons/hicolor/128x128/apps/rplayhub-android.png"
cp "$root/linux/packaging/rplayhub-android.desktop" "$stage/usr/share/applications/"
cp "$root/linux/packaging/copyright" "$stage/usr/share/doc/rplayhub-android/copyright"
{ echo "rplayhub-android ($version-1) stable; urgency=medium"; echo; echo "  * See https://github.com/rPlayAI/rplayhub-android/releases"; echo; echo " -- rPlayAI <noreply@rplay.ai>  $(date -R)"; } | gzip -9n > "$stage/usr/share/doc/rplayhub-android/changelog.Debian.gz"
# The agent's .so files are Android payload pushed to the phone, not host libraries.
mkdir -p "$stage/usr/share/lintian/overrides"
cat > "$stage/usr/share/lintian/overrides/rplayhub-android" <<'OVR'
# The device agent (Android, all ABIs) is pushed to the phone over adb; it never runs on the host.
rplayhub-android: arch-dependent-file-in-usr-share usr/share/rplayhub-android/agent/*
rplayhub-android: binary-from-other-architecture usr/share/rplayhub-android/agent/*
rplayhub-android: library-not-linked-against-libc usr/share/rplayhub-android/agent/*
rplayhub-android: no-manual-page usr/bin/rplayhub-android
OVR
find "$stage/usr" -type d -exec chmod 0755 {} + ; find "$stage/usr" -type f -exec chmod 0644 {} + ; chmod 0755 "$stage/usr/bin/rplayhub-android"

# Depends: the packages owning the libraries the binary itself needs (DT_NEEDED, not ldd's
# transitive closure), plus adb.
deps="adb"
for so in $(objdump -p "$stage/usr/bin/rplayhub-android" | awk '/NEEDED/{print $2}'); do
    # dpkg records libc's files under /lib and most others under /usr/lib (merged /usr).
    pkg="$(dpkg -S "/usr/lib/$multiarch/$so" "/lib/$multiarch/$so" 2>/dev/null | head -1 | cut -d: -f1)" || true
    [ -n "$pkg" ] && deps="$deps, $pkg" || die "no package owns $so"
done
deps="$(echo "$deps" | tr ',' '\n' | sed 's/^ *//' | sort -u | grep -v '^$' | paste -sd, | sed 's/,/, /g')"
size="$(du -sk "$stage/usr" | cut -f1)"
cat > "$stage/DEBIAN/control" <<CTL
Package: rplayhub-android
Version: $version-1
Section: utils
Priority: optional
Architecture: $arch
Installed-Size: $size
Depends: $deps
Maintainer: rPlayAI <noreply@rplay.ai>
Homepage: https://github.com/rPlayAI/rplayhub-android
Description: Android screen mirroring and control, in the style of the macOS client
 Mirrors an Android phone over adb (USB or network) with low-latency H.264/HEVC
 decoding, touch and keyboard control, a pop-out phone window, Desktop Mode and
 app windows on virtual displays, screenshots and recording, a 3D device twin
 that turns with the phone, and foldable support (Pixel Fold: posture, hinge
 angle, the fold drawn live). Ships the device agent it pushes to the phone.
CTL
( cd "$stage" && find usr -type f -exec md5sum {} + > DEBIAN/md5sums )
mkdir -p "$out"
deb="$out/rplayhub-android_${version}-1_${arch}.deb"
fakeroot dpkg-deb --build --root-owner-group "$stage" "$deb" >/dev/null
echo "package-deb: $deb"
echo "package-deb: Depends: $deps"
lintian --no-tag-display-limit "$deb" 2>&1 | grep -vE "^N:|^$" | head -20 || true
