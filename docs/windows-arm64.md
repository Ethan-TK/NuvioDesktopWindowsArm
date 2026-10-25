# Windows on ARM (arm64)

Nuvio Desktop can run as a native arm64 app on Windows on ARM devices, such as Snapdragon X
laptops. You don't need x64 emulation (Prism). The Compose UI, the JVM, the player bridge,
libmpv, the torrent engine and the QuickJS plugin runtime all run as native arm64 code.

## What differs from x64

| Component | x64 | arm64 |
|---|---|---|
| JDK | any x64 JDK 17+ | an **arm64** JDK (Microsoft Build of OpenJDK 21 recommended) |
| `player_bridge.dll` | MSVC x64 tools | MSVC **ARM64** tools (`VC.Tools.ARM64` component), built automatically |
| `libmpv-2.dll` | checked in (Git LFS) | `mpv-dev-aarch64-*.7z` from [shinchiro/mpv-winbuild-cmake](https://github.com/shinchiro/mpv-winbuild-cmake/releases) |
| `nuvio_engine.dll` | checked in | built from [nuvio-engine](https://github.com/NuvioMedia/nuvio-engine) (`aarch64` target) |
| `libquickjs.dll` | shipped by quickjs-kt | built by `scripts/windows/build-quickjs-windows-arm64.sh` |
| WebView2 | `build/native/x64` | `build/native/arm64` (same NuGet package) |

The build checks the PE machine type of every native DLL. If an x64 DLL ends up in an
arm64 build, the build fails with a clear message, not a `LoadLibrary` error at runtime.
If you leave out the engine or QuickJS DLL, the build only warns: the app still runs, but
P2P streaming or JS plugins won't be available.

## Build in CI (recommended)

Run **Actions → Windows ARM64 Test Build** (`.github/workflows/windows-arm64-build.yml`).
It uses GitHub's free `ubuntu-24.04-arm` and `windows-11-arm` runners:

1. `natives` downloads libmpv and cross-builds `nuvio_engine.dll` and `libquickjs.dll`
   (`scripts/windows/prepare-arm64-natives.sh`).
2. `msi` builds and verifies `Nuvio-Windows-arm64-<version>.msi` with an arm64 JDK.

The release workflow (`desktop-release.yml`) builds the same MSI in the `windows_arm64` job
and publishes it alongside the x64 MSI. The in-app updater already prefers `arm64` assets
on arm64 JVMs.

## Build locally on a Windows on ARM PC

1. Install **Visual Studio 2022** (or Build Tools) with *Desktop development with C++*, and
   tick **MSVC ARM64/ARM64EC build tools**.
2. Install an **arm64 JDK**, for example `winget install Microsoft.OpenJDK.21`, and make sure
   it is first on `PATH`. `java -XshowSettings:properties -version` must report
   `os.arch = aarch64`.
3. Get the native libraries. Either download the `windows-arm64-native-libraries` artifact
   from a CI run, or produce it yourself:
   - libmpv: download `mpv-dev-aarch64-<date>-git-<hash>.7z` and extract `libmpv-2.dll`
     into, for example, `C:\nuvio-arm64\libmpv\`.
   - engine and QuickJS: run `scripts/windows/prepare-arm64-natives.sh` on an arm64 Linux
     machine or WSL (it needs Docker for the engine).
4. Install the WebView2 SDK:
   `./scripts/windows/install-webview2-sdk.ps1 -Version 1.0.4078.44 -Arch arm64`
5. Build and run:

   ```powershell
   .\gradlew.bat :composeApp:run `
     "-Pnuvio.webview2.dir=$env:USERPROFILE\.nuget\packages\microsoft.web.webview2\Microsoft.Web.WebView2.1.0.4078.44" `
     "-Pnuvio.windows.libmpv.runtimeDir=C:\nuvio-arm64\libmpv" `
     "-Pnuvio.windows.engine.dll=C:\nuvio-arm64\engine\nuvio_engine.dll" `
     "-Pnuvio.windows.quickjs.dll=C:\nuvio-arm64\quickjs\libquickjs.dll"
   ```

   To build an installer, use `:composeApp:packageReleaseMsi` with the same properties.
   You can also put these properties in `%USERPROFILE%\.gradle\gradle.properties` so you
   don't have to pass them every time.

## Playback tuning on arm64

The player bridge compiles with `_M_ARM64` and changes these settings on arm64:

- **D3D11 pinned.** It uses `gpu-api=d3d11` and `hwdec=d3d11va,auto-safe` instead of `auto`,
  so mpv never falls back to Adreno's less mature Vulkan/OpenGL drivers. Decoded frames stay
  on the GPU (zero-copy), which saves the most power on battery.
- **No NVIDIA RTX Video Super Resolution.** ARM64 Windows has no NVIDIA adapters, so this
  setting is ignored.
- **Software fallback uses all cores.** It sets `vd-lavc-threads=0`, so FFmpeg sizes its own
  thread pool. Snapdragon X has 8 to 12 fast cores, and the x64 default caps it at 4.
- **Fast profile.** Adreno reports a unified-memory architecture, so the existing
  `profile=fast` path is used, the same as on other integrated GPUs.

The bridge is now compiled with `/O2` on all architectures. Before this change it was
compiled without optimizations.
