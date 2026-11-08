#!/usr/bin/env bash
# Release a new version of the "Agents" Android app on GitHub.
#
# Usage: android/release.sh [--dry-run] VERSION CHANGES-FILE
#
#   VERSION       the new version name, such as 1.5
#   CHANGES-FILE  what changed since the last release, as Markdown; it
#                 becomes the "New since ..." paragraph of the notes
#   --dry-run     check, bump and build in a scratch copy, print the
#                 notes, and change nothing locally or on GitHub
#
# Run it on an up-to-date, clean main.  It
#   1. bumps android/version.env (VERSION_NAME, and VERSION_CODE by one),
#      commits the bump and pushes main;
#   2. builds the APK with android/build.sh and refuses to go on unless
#      it is signed with the key of the previous release, since a phone
#      will not install an update signed with another key;
#   3. publishes the release android-vVERSION with the APK, never marked
#      as the repository's latest release, which belongs to the package;
#   4. points the release android-latest, and its tag, at the new
#      version, so that
#      https://github.com/benthamite/agent/releases/download/android-latest/agent-remote.apk
#      always downloads the newest app and READMEs never need updating.
set -euo pipefail
# Backticks in the release notes are Markdown, not command substitution.
# shellcheck disable=SC2016

repo=benthamite/agent
latest_tag=android-latest
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
sdk=${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}
apksigner="$sdk/build-tools/37.0.0/apksigner"

die() { echo "release.sh: $*" >&2; exit 1; }

dry_run=false
if [[ ${1:-} == --dry-run ]]; then dry_run=true; shift; fi
[[ $# -eq 2 ]] || die "usage: android/release.sh [--dry-run] VERSION CHANGES-FILE"
version=$1
changes=$2
tag="android-v$version"

[[ $version =~ ^[0-9]+(\.[0-9]+)*$ ]] || die "VERSION must look like 1.5"
[[ -s $changes ]] || die "CHANGES-FILE $changes is missing or empty"
command -v gh >/dev/null || die "gh is not installed"
[[ -x $apksigner ]] || die "missing $apksigner"

cd "$root"
[[ $(git symbolic-ref --short HEAD) == main ]] || die "not on main"
[[ -z $(git status --porcelain) ]] || die "the working tree is not clean"
git fetch -q origin main --tags
if [[ $(git rev-parse HEAD) != $(git rev-parse origin/main) ]]; then
  if $dry_run; then
    echo "release.sh: warning: main and origin/main differ" >&2
  else
    die "main and origin/main differ; pull or push first"
  fi
fi
! git rev-parse -q --verify "refs/tags/$tag" >/dev/null \
  || die "tag $tag already exists"

# shellcheck source=android/version.env
source "$here/version.env"
previous_name=$VERSION_NAME
next_code=$((VERSION_CODE + 1))
[[ $version != "$previous_name" ]] || die "version $version is already released"
previous_tag="android-v$previous_name"

scratch=$(mktemp -d)
committed=false
# A failure before the bump is committed leaves version.env as it was.
cleanup() {
  rm -rf "$scratch"
  if ! $dry_run && ! $committed; then
    git -C "$root" checkout -q -- android/version.env
  fi
}
trap cleanup EXIT

# The previous release's signing certificate, which the new APK must share.
gh release download "$previous_tag" -R "$repo" -p agent-remote.apk \
  -D "$scratch/previous" >/dev/null \
  || die "cannot download the APK of $previous_tag"
cert() { "$apksigner" verify --print-certs "$1" 2>/dev/null \
           | sed -n 's/.*certificate SHA-256 digest: //p' | head -1; }
previous_cert=$(cert "$scratch/previous/agent-remote.apk")
[[ -n $previous_cert ]] || die "cannot read the signer of $previous_tag"

write_version() {
  cat >"$1" <<EOF
# The Android app's version.  android/release.sh bumps both; build.sh reads them.
# VERSION_CODE must grow with every release, or phones refuse the update.
VERSION_CODE=$next_code
VERSION_NAME=$version
EOF
}

# Build from a scratch copy on a dry run, so nothing in the checkout changes.
if $dry_run; then
  cp -R "$here" "$scratch/android"
  rm -rf "$scratch/android/build"
  build_dir="$scratch/android"
else
  build_dir="$here"
fi
write_version "$build_dir/version.env"
"$build_dir/build.sh" >"$scratch/build.log" 2>&1 \
  || { cat "$scratch/build.log" >&2; die "the build failed"; }
apk="$build_dir/build/agent-remote.apk"

new_cert=$(cert "$apk")
[[ $new_cert == "$previous_cert" ]] || die "the new APK is signed with
  $new_cert
but $previous_tag was signed with
  $previous_cert
Phones would refuse the update.  Build with the keystore that signed
$previous_tag (AGENT_REMOTE_KEYSTORE)."

sha=$(shasum -a 256 "$apk" | cut -d' ' -f1)
notes="$scratch/notes.md"
{
  printf '%s\n\n' '"Agents", the Android app for `agent-remote-mode`. Install `agent-remote.apk` on the phone (allow installs from unknown sources when asked), then enter the Tailscale address of the computer running `agent-remote-mode`, such as `100.101.102.103` (port 8787 is the default). The phone and the computer must be on the same tailnet.'
  printf 'New since %s: %s\n\n' "$previous_name" "$(cat "$changes")"
  printf 'SHA-256: `%s`\n' "$sha"
} >"$notes"

if $dry_run; then
  echo "Dry run: would release $tag (version code $next_code) as:"
  echo
  cat "$notes"
  exit 0
fi

git add android/version.env
git commit -q -m "Release the Android app $version"
committed=true
git push -q origin main
target=$(git rev-parse HEAD)

gh release create "$tag" -R "$repo" --target "$target" --latest=false \
  --title "Android app $version" --notes-file "$notes" "$apk"

# Move the stable download location to this version.
git tag -f "$latest_tag" "$target" >/dev/null
git push -q -f origin "refs/tags/$latest_tag"
latest_notes="$scratch/latest.md"
printf 'The newest Android app, currently %s: see [%s](https://github.com/%s/releases/tag/%s).\n\nThis release always holds the newest `agent-remote.apk`, at a link that never changes.\n' \
  "$version" "$tag" "$repo" "$tag" >"$latest_notes"
if gh release view "$latest_tag" -R "$repo" >/dev/null 2>&1; then
  gh release upload "$latest_tag" -R "$repo" --clobber "$apk"
  gh release edit "$latest_tag" -R "$repo" --latest=false \
    --title "Android app (newest)" --notes-file "$latest_notes"
else
  gh release create "$latest_tag" -R "$repo" --verify-tag --latest=false \
    --title "Android app (newest)" --notes-file "$latest_notes" "$apk"
fi

echo "Released $tag: https://github.com/$repo/releases/tag/$tag"
