#!/usr/bin/env bash
# release-image.sh -- publish a built Kiln flashable image as a GitHub Release asset,
# so users can `dd` it and boot straight into a ready system (no curl|bash, no double
# reboot, no Wi-Fi deadlock).
#
# Run this ONLY AFTER you have:
#   1. built the image        -> buildroot/build-image.sh  (=> br-out/images/sdcard.img)
#   2. VALIDATED IT ON REAL HARDWARE (flashed a card, booted, `kiln-doctor` is green).
# Kiln does not publish unvalidated images -- this script asks you to confirm.
#
# Usage:
#   scripts/release-image.sh [--image br-out/images/sdcard.img] [--tag kiln-image-YYYYMMDD]
#                            [--board rock-4d] [--yes]
#
# Needs the GitHub CLI (`gh auth login` done) + `xz`.
set -euo pipefail

GH_REPO="${KILN_GH:-gahingwoo/kiln}"
IMG="br-out/images/sdcard.img"
TAG=""
BOARD="rock-4d"
YES=0

say(){ printf '\n\033[1;36m[release]\033[0m %s\n' "$*"; }
die(){ printf '\n\033[1;31m[release] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
	case "$1" in
		--image) IMG="$2"; shift 2 ;;
		--tag)   TAG="$2"; shift 2 ;;
		--board) BOARD="$2"; shift 2 ;;
		--yes|-y) YES=1; shift ;;
		-h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) die "unknown arg: $1" ;;
	esac
done

command -v gh >/dev/null 2>&1 || die "needs the GitHub CLI (gh). Install it and 'gh auth login'."
command -v xz >/dev/null 2>&1 || die "needs xz (sudo apt install xz-utils)."
[ -f "$IMG" ] || die "no image at '$IMG' -- build it first: buildroot/build-image.sh"
[ -n "$TAG" ] || TAG="kiln-image-$(date +%Y%m%d)"

sz=$(du -h "$IMG" | cut -f1)
say "image:  $IMG  ($sz)"
say "board:  $BOARD"
say "tag:    $TAG   (repo $GH_REPO)"

if [ "$YES" != 1 ]; then
	printf '\nHave you flashed THIS image to a card and confirmed it boots + kiln-doctor is green? [y/N] '
	read -r a; case "$a" in y|Y|yes) : ;; *) die "aborted -- validate on hardware first."; esac
fi

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
out="$work/kiln-${BOARD}-${TAG}.img.xz"
say "compressing (xz -9, all cores) -- this takes a while ..."
xz -T0 -9 -c "$IMG" > "$out"
( cd "$work" && sha256sum "$(basename "$out")" > "$(basename "$out").sha256" )
say "compressed: $(du -h "$out" | cut -f1)"

notes="$work/notes.md"
cat > "$notes" <<EOF
# Kiln flashable image ($BOARD)

A ready-to-run SD-card image: **flash it and boot** — no \`curl | bash\`, no double
reboot, no Wi-Fi deadlock. The NPU driver, runtimes, and \`kiln-*\` tools are already
installed. You still supply your own models (\`kiln-convert\` builds vision ones on the
board; drop a \`*.rkllm\` in \`/opt/models\` for chat).

## Flash

\`\`\`sh
# Linux (replace /dev/sdX with your card; this ERASES it):
xz -dc kiln-${BOARD}-${TAG}.img.xz | sudo dd of=/dev/sdX bs=8M status=progress conv=fsync
\`\`\`

Or use [Raspberry Pi Imager](https://www.raspberrypi.com/software/) / [balenaEtcher]
(https://etcher.balena.io/) and pick the \`.img.xz\` directly.

Verify the download first:
\`\`\`sh
sha256sum -c kiln-${BOARD}-${TAG}.img.xz.sha256
\`\`\`

## First boot

Boot the card, log in, and run \`kiln\` for a menu or \`kiln-doctor\` for a health check.

> **Tested hardware:** Radxa ROCK 4D (RK3576) only. See the repo README.
EOF

say "creating GitHub release $TAG ..."
if gh release view "$TAG" --repo "$GH_REPO" >/dev/null 2>&1; then
	gh release upload "$TAG" "$out" "$out.sha256" --repo "$GH_REPO" --clobber
	say "uploaded assets to existing release $TAG."
else
	gh release create "$TAG" "$out" "$out.sha256" --repo "$GH_REPO" \
		--title "Kiln image ($BOARD) $TAG" --notes-file "$notes"
	say "created release $TAG with the image + checksum."
fi
say "done: https://github.com/$GH_REPO/releases/tag/$TAG"
