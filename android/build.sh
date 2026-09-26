#!/usr/bin/env bash
# Build (and optionally install) the "Agents" WebView app without Gradle.
#
# Usage: android/build.sh [install]
#
# Environment:
#   AGENT_REMOTE_URL   page to show (default http://100.69.180.87:8787/);
#                      cleartext HTTP is permitted for its host only.
#   ANDROID_HOME       SDK root (default: Homebrew android-commandlinetools)
#   AGENT_REMOTE_KEYSTORE  signing keystore (created if missing)
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
out="$here/build"

base_url=${AGENT_REMOTE_URL:-http://100.69.180.87:8787/}
sdk=${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}
platform=android-37.2
build_tools=37.0.0
min_sdk=33
target_sdk=37
keystore=${AGENT_REMOTE_KEYSTORE:-$HOME/.android/agent-remote.keystore}
storepass=android
alias_name=agentremote

bt="$sdk/build-tools/$build_tools"
android_jar="$sdk/platforms/$platform/android.jar"
for f in "$bt/aapt2" "$bt/d8" "$android_jar"; do
  [[ -e $f ]] || { echo "missing $f; run: sdkmanager 'platforms;$platform' 'build-tools;$build_tools'" >&2; exit 1; }
done

host=$(sed -E 's#^[a-z]+://([^/:]+).*#\1#' <<<"$base_url")
[[ -n $host && $host != "$base_url" ]] || { echo "cannot parse host from $base_url" >&2; exit 1; }

rm -rf "$out"
mkdir -p "$out/gen/net/stafforini/agentremote" "$out/res-gen/xml" \
  "$out/compiled" "$out/classes" "$out/dex"

# Build-time configuration: the page URL and the only cleartext host.
cat >"$out/gen/net/stafforini/agentremote/BuildConfig.java" <<EOF
package net.stafforini.agentremote;

final class BuildConfig {
  static final String BASE_URL = "$base_url";
}
EOF
cat >"$out/res-gen/xml/network_security_config.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<network-security-config>
  <base-config cleartextTrafficPermitted="false" />
  <domain-config cleartextTrafficPermitted="true">
    <domain includeSubdomains="false">$host</domain>
  </domain-config>
</network-security-config>
EOF

"$bt/aapt2" compile --dir "$here/res" -o "$out/compiled/res.zip"
"$bt/aapt2" compile --dir "$out/res-gen" -o "$out/compiled/res-gen.zip"
"$bt/aapt2" link -o "$out/unsigned.apk" \
  -I "$android_jar" \
  --manifest "$here/AndroidManifest.xml" \
  --min-sdk-version "$min_sdk" --target-sdk-version "$target_sdk" \
  --version-code 1 --version-name 1.0 \
  --java "$out/gen" \
  "$out/compiled/res.zip" "$out/compiled/res-gen.zip"

javac --release 17 -nowarn -classpath "$android_jar" -d "$out/classes" \
  $(find "$here/src" "$out/gen" -name '*.java')
"$bt/d8" --release --min-api "$min_sdk" --lib "$android_jar" \
  --output "$out/dex" $(find "$out/classes" -name '*.class')
(cd "$out/dex" && zip -qj "$out/unsigned.apk" classes.dex)

"$bt/zipalign" -f -p 4 "$out/unsigned.apk" "$out/aligned.apk"

if [[ ! -f $keystore ]]; then
  mkdir -p "$(dirname "$keystore")"
  keytool -genkeypair -keystore "$keystore" -storepass "$storepass" \
    -alias "$alias_name" -keyalg RSA -keysize 2048 -validity 10000 \
    -dname "CN=Agent Remote"
fi
"$bt/apksigner" sign --ks "$keystore" --ks-pass "pass:$storepass" \
  --ks-key-alias "$alias_name" --out "$out/agent-remote.apk" "$out/aligned.apk"

echo "built $out/agent-remote.apk ($base_url)"

if [[ ${1:-} == install ]]; then
  adb install -r "$out/agent-remote.apk"
fi
