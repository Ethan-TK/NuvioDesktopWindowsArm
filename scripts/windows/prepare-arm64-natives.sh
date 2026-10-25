#!/usr/bin/env bash
# Collects the three native libraries a Windows ARM64 build needs that are not in the repo:
#
#   libmpv-2.dll     - mpv dev build for aarch64 (shinchiro/mpv-winbuild-cmake)
#   nuvio_engine.dll - torrent engine, built from NuvioMedia/nuvio-engine at the tag matching
#                      composeApp/libs/nuvio-engine-jvm-<version>.jar (Docker, linux/arm64)
#   libquickjs.dll   - quickjs-kt JNI library for windows_aarch64 (zig cross-compile)
#
# Runs on Linux. The engine step uses nuvio-engine's own Docker toolchain, which targets a
# linux/arm64 builder, so run this on an arm64 host (e.g. GitHub's ubuntu-24.04-arm).
#
# Usage: scripts/windows/prepare-arm64-natives.sh OUTPUT_DIR [--skip-engine]
# Env:   LIBMPV_ARM64_URL   optional explicit URL of an mpv-dev-aarch64-*.7z
#        LIBMPV_ARM64_SHA256 optional expected sha256 of that archive
#        GH_TOKEN           optional, avoids GitHub API rate limits
set -euo pipefail

output_dir=${1:?usage: $0 OUTPUT_DIR [--skip-engine]}
skip_engine=false
[[ "${2:-}" == "--skip-engine" ]] && skip_engine=true

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
mkdir -p "$output_dir"
output_dir=$(cd "$output_dir" && pwd -P)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

pe_machine() {
    python3 - "$1" <<'PY'
import struct, sys
data = open(sys.argv[1], 'rb').read(4096)
pe = struct.unpack_from('<I', data, 0x3C)[0]
print(hex(struct.unpack_from('<H', data, pe + 4)[0]))
PY
}

require_arm64() {
    local machine
    machine=$(pe_machine "$1")
    if [[ "$machine" != "0xaa64" ]]; then
        echo "$1 is not an ARM64 binary (machine $machine)" >&2
        exit 1
    fi
}

# ---- libmpv ---------------------------------------------------------------------------
libmpv_url=${LIBMPV_ARM64_URL:-}
if [[ -z "$libmpv_url" ]]; then
    auth=()
    [[ -n "${GH_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer $GH_TOKEN")
    libmpv_url=$(
        curl --fail --silent --show-error --retry 3 "${auth[@]}" \
            https://api.github.com/repos/shinchiro/mpv-winbuild-cmake/releases/latest \
            | python3 -c '
import json, re, sys
assets = json.load(sys.stdin)["assets"]
matches = [a["browser_download_url"] for a in assets if re.fullmatch(r"mpv-dev-aarch64-\d{8}-git-[0-9a-f]+\.7z", a["name"])]
print(matches[0] if matches else "")
'
    )
fi
if [[ -z "$libmpv_url" ]]; then
    echo "could not find an mpv-dev-aarch64 archive; set LIBMPV_ARM64_URL" >&2
    exit 1
fi
echo "libmpv: $libmpv_url"
curl --fail --location --silent --show-error --retry 3 --output "$work/mpv-dev.7z" "$libmpv_url"
libmpv_sha=$(sha256sum "$work/mpv-dev.7z" | awk '{print $1}')
if [[ -n "${LIBMPV_ARM64_SHA256:-}" && "$libmpv_sha" != "$LIBMPV_ARM64_SHA256" ]]; then
    echo "libmpv archive sha256 mismatch: got $libmpv_sha" >&2
    exit 1
fi
mkdir -p "$work/mpv-dev" "$output_dir/libmpv"
if command -v 7z >/dev/null 2>&1; then
    7z x -y -o"$work/mpv-dev" "$work/mpv-dev.7z" >/dev/null
else
    bsdtar -xf "$work/mpv-dev.7z" -C "$work/mpv-dev"
fi
libmpv_dll=$(find "$work/mpv-dev" -name 'libmpv-2.dll' | head -n 1)
[[ -n "$libmpv_dll" ]] || { echo "libmpv-2.dll not found in archive" >&2; exit 1; }
require_arm64 "$libmpv_dll"
cp "$libmpv_dll" "$output_dir/libmpv/libmpv-2.dll"

# ---- quickjs-kt JNI -------------------------------------------------------------------
"$repo_root/scripts/windows/build-quickjs-windows-arm64.sh" "$output_dir/quickjs"
require_arm64 "$output_dir/quickjs/libquickjs.dll"

# ---- nuvio-engine ---------------------------------------------------------------------
engine_version=""
if [[ "$skip_engine" == false ]]; then
    engine_jar=$(ls "$repo_root"/composeApp/libs/nuvio-engine-jvm-*.jar | head -n 1)
    engine_version=$(basename "$engine_jar" | sed -E 's/^nuvio-engine-jvm-(.*)\.jar$/\1/')
    git -c advice.detachedHead=false clone --quiet --depth 1 --branch "v$engine_version" \
        https://github.com/NuvioMedia/nuvio-engine.git "$work/nuvio-engine"
    docker buildx build \
        --platform linux/arm64 \
        --build-arg NUVIO_WINDOWS_ARCH=aarch64 \
        --file "$work/nuvio-engine/platform/windows/Dockerfile" \
        --target artifact \
        --output "type=local,dest=$work/engine-dist" \
        "$work/nuvio-engine"
    (cd "$work/engine-dist" && sha256sum --check --strict nuvio-engine-windows-aarch64.zip.sha256)
    python3 -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' \
        "$work/engine-dist/nuvio-engine-windows-aarch64.zip" "$work/engine-pkg"
    engine_dll=$(find "$work/engine-pkg" -path '*/bin/nuvio_engine.dll' | head -n 1)
    [[ -n "$engine_dll" ]] || { echo "nuvio_engine.dll not found in engine package" >&2; exit 1; }
    require_arm64 "$engine_dll"
    mkdir -p "$output_dir/engine"
    cp "$engine_dll" "$output_dir/engine/nuvio_engine.dll"
fi

engine_desc="skipped"
[[ -n "$engine_version" ]] && engine_desc="nuvio-engine v$engine_version (llvm-mingw aarch64)"
cat > "$output_dir/SOURCES.txt" <<EOF
libmpv-2.dll     $libmpv_url
                 sha256(archive)=$libmpv_sha
libquickjs.dll   quickjs-kt v$(sed -n 's/^quickjsKt = "\(.*\)"/\1/p' "$repo_root/gradle/libs.versions.toml") (zig aarch64-windows-gnu)
nuvio_engine.dll $engine_desc
EOF
cat "$output_dir/SOURCES.txt"
