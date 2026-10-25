#!/usr/bin/env bash
# Cross-compiles quickjs-kt's JNI library (libquickjs.dll) for Windows on ARM64.
#
# Upstream quickjs-kt publishes JVM natives for windows_x64 only, so on an ARM64 JVM
# JS plugins fail with "Cannot find a suitable QuickJS binary". This builds the same
# sources for aarch64-windows-gnu with zig, matching the version in libs.versions.toml.
#
# Usage: scripts/windows/build-quickjs-windows-arm64.sh OUTPUT_DIR
# Requires: git, cmake >= 3.22, ninja, zig (or `pip install ziglang`), a JDK (for jni.h).
# Output:   OUTPUT_DIR/libquickjs.dll  (pass to Gradle as -Pnuvio.windows.quickjs.dll=...)
set -euo pipefail

output_dir=${1:?usage: $0 OUTPUT_DIR}
repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
version=$(sed -n 's/^quickjsKt = "\(.*\)"/\1/p' "$repo_root/gradle/libs.versions.toml")
if [[ -z "$version" ]]; then
    echo "could not read quickjsKt version from gradle/libs.versions.toml" >&2
    exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# zig on PATH, or fall back to the PyPI ziglang package.
if ! command -v zig >/dev/null 2>&1; then
    if python3 -c 'import ziglang' 2>/dev/null; then
        mkdir -p "$work/bin"
        printf '#!/bin/sh\nexec python3 -m ziglang "$@"\n' > "$work/bin/zig"
        chmod +x "$work/bin/zig"
        export PATH="$work/bin:$PATH"
    else
        echo "zig not found: install zig or run 'pip install ziglang'" >&2
        exit 1
    fi
fi

git -c advice.detachedHead=false clone --quiet --depth 1 --branch "v$version" https://github.com/dokar3/quickjs-kt.git "$work/quickjs-kt"
git -C "$work/quickjs-kt" submodule update --init --depth 1 --quiet
native="$work/quickjs-kt/quickjs/native"

# Windows JNI headers: jni.h is platform-neutral; jni_md.h for win32 is tiny and fixed.
host_java_home=${JAVA_HOME:-$(dirname "$(dirname "$(readlink -f "$(command -v javac || command -v java)")")")}
jdk="$work/jdk"
mkdir -p "$jdk/include/win32"
cp "$host_java_home/include/jni.h" "$jdk/include/jni.h"
cat > "$jdk/include/win32/jni_md.h" <<'JNIMD'
#ifndef _JAVASOFT_JNI_MD_H_
#define _JAVASOFT_JNI_MD_H_
#define JNIEXPORT __declspec(dllexport)
#define JNIIMPORT __declspec(dllimport)
#define JNICALL __stdcall
typedef int jint;
typedef long long jlong;
typedef signed char jbyte;
#endif
JNIMD

# Reuse upstream's windows_x64 configuration (winpthreads, CONFIG_WIN32, stack_chk,
# exports .def) and swap only the compiler target to aarch64.
toolchain="$native/cmake/zig-toolchain-windows_x64.cmake"
sed -i \
    -e 's/CMAKE_SYSTEM_PROCESSOR "x86_64"/CMAKE_SYSTEM_PROCESSOR "aarch64"/' \
    -e 's/x86_64-windows-gnu/aarch64-windows-gnu/g' \
    "$toolchain"
grep -q 'aarch64-windows-gnu' "$toolchain"

# -Wno-date-time: newer zig/clang turns __DATE__/__TIME__ in common/stack_chk.c into errors.
# -U__SEH__: winpthreads' per-thread SEH block references mingw's _gnu_exception_handler,
# which zig's aarch64 mingw CRT doesn't provide; without it exceptions simply propagate
# to the JVM's own handler (same as CONTINUE_SEARCH).
cmake -S "$native" -B "$work/build" -G Ninja \
    -DTARGET_PLATFORM=windows_x64 \
    -DLIBRARY_TYPE=shared \
    -DPLATFORM_JAVA_HOME="$jdk" \
    -DJNI_INCLUDE_DIRS="$jdk/include;$jdk/include/win32" \
    -DJAVA_INCLUDE_PATH="$jdk/include" \
    -DJAVA_INCLUDE_PATH2="$jdk/include/win32" \
    -DJAVA_AWT_INCLUDE_PATH="$jdk/include" \
    -DJAVA_AWT_LIBRARY=NotNeeded \
    -DJAVA_JVM_LIBRARY=NotNeeded \
    -DCMAKE_C_FLAGS="-Wno-date-time -U__SEH__" \
    -DCMAKE_BUILD_TYPE=Release
cmake --build "$work/build" --parallel

built=$(find "$work/build" -maxdepth 2 -iname '*quickjs*.dll' | head -n 1)
if [[ -z "$built" ]]; then
    echo "libquickjs.dll was not produced" >&2
    exit 1
fi

# Sanity check: PE machine must be ARM64 (0xAA64).
machine=$(python3 - "$built" <<'PY'
import struct, sys
data = open(sys.argv[1], 'rb').read(4096)
pe = struct.unpack_from('<I', data, 0x3C)[0]
print(hex(struct.unpack_from('<H', data, pe + 4)[0]))
PY
)
if [[ "$machine" != "0xaa64" ]]; then
    echo "expected an ARM64 DLL, got machine $machine" >&2
    exit 1
fi

mkdir -p "$output_dir"
cp "$built" "$output_dir/libquickjs.dll"
echo "built quickjs-kt v$version for windows_aarch64: $output_dir/libquickjs.dll"
