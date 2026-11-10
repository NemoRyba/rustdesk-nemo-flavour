#!/usr/bin/env bash
# Publish a TBFDesk release on GitHub (NemoRyba/rustdesk-nemo-flavour): the tag, the release
# notes and every built file with its .sha256. Needs a logged-in GitHub CLI (`gh auth login`).
#   publish-release.sh <tag> <artifact dir> <notes.md>
#   e.g. publish-release.sh release-2026-11-10 /projects/rustdesk/vm/artifacts/release-1.4.20 dist/RELEASE-NOTES-1.4.20.md
set -euo pipefail
TAG="${1:?tag}"; DIR="$(readlink -f "${2:?artifact dir}")"; NOTES="$(readlink -f "${3:?notes}")"
REPO=NemoRyba/rustdesk-nemo-flavour
C=/projects/rustdesk/rustdesk-nemo-flavour/rustdesk-client-nemo
gh auth status >/dev/null 2>&1 || { echo "GitHub CLI not logged in: run  gh auth login" >&2; exit 1; }
cd "$DIR"
# every artifact must match its checksum before anything is uploaded
files=()
for f in *.exe *.run *.deb *.pkg.tar.zst *.tar.gz; do
  [ -f "$f" ] || continue
  sha256sum -c --quiet "$f.sha256" || { echo "checksum mismatch: $f" >&2; exit 1; }
  files+=("$DIR/$f" "$DIR/$f.sha256")
done
# the uninstallers ship with every release
U="$(mktemp -d)"; trap 'rm -rf "$U"' EXIT
cp "$C"/res/uninstall/tbfdesk-uninstall.sh "$C"/res/uninstall/tbfdesk-uninstall.ps1 "$U"/
files+=("$U/tbfdesk-uninstall.sh" "$U/tbfdesk-uninstall.ps1")
echo "${#files[@]} files, $(du -ch "${files[@]}" | tail -1 | cut -f1)"
cd /projects/rustdesk/rustdesk-nemo-flavour
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || git tag -a "$TAG" -m "$TAG"
git push origin "$TAG"
if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
  gh release upload "$TAG" -R "$REPO" --clobber "${files[@]}"
else
  gh release create "$TAG" -R "$REPO" --verify-tag --title "$(head -1 "$NOTES" | sed 's/^# *//')" \
    --notes-file "$NOTES" "${files[@]}"
fi
gh release view "$TAG" -R "$REPO" --json url,assets --jq '.url, (.assets | length | tostring) + " assets"'
