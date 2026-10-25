#!/usr/bin/env bash
# Build (and optionally install) the "Agents" WebView app without Gradle.
#
# Usage: android/build.sh [install]
#
# Environment:
#   AGENT_REMOTE_URL   server address to pre-fill on first launch
#                      (default: none).  The app asks for the address
#                      itself, so one build serves any computer.
#   ANDROID_HOME       SDK root (default: Homebrew android-commandlinetools)
#   AGENT_REMOTE_KEYSTORE  signing keystore (created if missing)
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
out="$here/build"

base_url=${AGENT_REMOTE_URL:-}
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

rm -rf "$out"
mkdir -p "$out/gen/net/stafforini/agentremote" "$out/res-gen/xml" \
  "$out/compiled" "$out/classes" "$out/dex"

# Build-time configuration: the address to pre-fill.  Cleartext is
# permitted to every host because the address is only known at run
# time; the app accepts plain http only to a Tailscale address.
cat >"$out/gen/net/stafforini/agentremote/BuildConfig.java" <<EOF
package net.stafforini.agentremote;

final class BuildConfig {
  static final String BASE_URL = "$base_url";
}
EOF
cat >"$out/res-gen/xml/network_security_config.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<network-security-config>
  <base-config cleartextTrafficPermitted="true" />
</network-security-config>
EOF

"$bt/aapt2" compile --dir "$here/res" -o "$out/compiled/res.zip"
"$bt/aapt2" compile --dir "$out/res-gen" -o "$out/compiled/res-gen.zip"
"$bt/aapt2" link -o "$out/unsigned.apk" \
  -I "$android_jar" \
  --manifest "$here/AndroidManifest.xml" \
  --min-sdk-version "$min_sdk" --target-sdk-version "$target_sdk" \
  --version-code 2 --version-name 1.1 \
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

echo "built $out/agent-remote.apk${base_url:+ (pre-filled: $base_url)}"

if [[ ${1:-} == install ]]; then
  adb install -r "$out/agent-remote.apk"
fi
