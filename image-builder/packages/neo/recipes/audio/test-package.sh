#!/bin/bash
# SPDX-License-Identifier: MIT
# Exercise the real split package functions against tiny inert source trees.
set -euo pipefail
recipe=$(cd "$(dirname "$0")" && pwd -P)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
srcdir="$work/src"
mkdir -p "$srcdir/ucm/ucm2" "$srcdir/audio"
printf 'fixture UCM profile\n' > "$srcdir/ucm/ucm2/fixture.conf"
printf 'fixture UCM license\n' > "$srcdir/ucm/LICENSE.asahi"
printf 'fixture DSP profile\n' > "$srcdir/audio/fixture.conf"
printf 'fixture DSP license\n' > "$srcdir/audio/LICENSE"
cat > "$srcdir/audio/Makefile" <<'MAKE'
install:
	install -Dm644 fixture.conf "$(DESTDIR)$(PREFIX)/share/asahi-audio/fixture.conf"
MAKE
cp "$recipe/10-pipewire-user.conf" "$srcdir/"
cd "$srcdir"
source "$recipe/PKGBUILD"
[[ $pkgrel == 2 ]]
[[ ${source[0]} == 'ucm::git+https://github.com/aurora-silicon/alsa-ucm-conf-asahi.git#commit=e55107ad9ba220a2772dbe4d55438cd1ec669288' ]]
[[ ${source[1]} == 'audio::git+https://github.com/aurora-silicon/asahi-audio.git#commit=b2da7512e9bfcd5837355d2393f3c43219acf6b9' ]]
[[ ${source[2]} == 10-pipewire-user.conf ]]
[[ $(sha256sum 10-pipewire-user.conf | cut -d ' ' -f1) == "${sha256sums[2]}" ]]
printf 'ok - source pins and drop-in checksum\n'
pkgname=alsa-ucm-conf-asahi
pkgdir="$work/ucm-package"
package_alsa-ucm-conf-asahi
[[ ${license[*]} == BSD-3-Clause ]]
cmp ucm/ucm2/fixture.conf "$pkgdir/usr/share/alsa/ucm2/fixture.conf"
cmp ucm/LICENSE.asahi "$pkgdir/usr/share/licenses/$pkgname/LICENSE.asahi"
[[ ! -e $pkgdir/usr/lib/systemd ]]
printf 'ok - UCM split payload and license preserved\n'
pkgname=asahi-audio
pkgdir="$work/audio-package"
package_asahi-audio
[[ ${license[*]} == MIT ]]
[[ ${depends[*]} == 'alsa-ucm-conf-asahi>=10.aurora1 pipewire-audio>=1.0 wireplumber>=0.5.2 bankstown>=1.1.0 lsp-plugins-lv2>=1.2.15 speakersafetyd speakerguardd triforce-lv2>=0.2.0' ]]
dropin="$pkgdir/usr/lib/systemd/user/wireplumber.service.d/10-pipewire-user.conf"
cmp "$srcdir/10-pipewire-user.conf" "$dropin"
[[ $(stat -c '%a' "$dropin") == 644 ]]
[[ $(cat "$dropin") == $'[Unit]\nConditionUser=!root' ]]
cmp audio/fixture.conf "$pkgdir/usr/share/asahi-audio/fixture.conf"
cmp audio/LICENSE "$pkgdir/usr/share/licenses/$pkgname/LICENSE"
[[ $(find "$pkgdir" -type f | wc -l) == 3 ]]
[[ -z $(find "$pkgdir" -type l) ]]
printf 'ok - only the DSP split ships the ordinary user drop-in\n'
cp "$srcdir/audio/Makefile" "$srcdir/audio/Makefile.good"
printf 'install:\n\tfalse\n' > "$srcdir/audio/Makefile"
if (
  pkgdir="$work/failed-dsp-package"
  package_asahi-audio
); then
  printf 'failed DSP installation was accepted\n' >&2
  exit 1
fi
[[ ! -e $work/failed-dsp-package/usr/lib/systemd ]]
printf 'ok - failed DSP installation refuses packaging before drop-in\n'
mv "$srcdir/audio/Makefile.good" "$srcdir/audio/Makefile"
rm "$srcdir/10-pipewire-user.conf"
if (
  set -e
  pkgdir="$work/missing-input-package"
  package_asahi-audio
); then
  printf 'missing required drop-in was accepted\n' >&2
  exit 1
fi
printf 'ok - missing required drop-in refuses packaging\n'
