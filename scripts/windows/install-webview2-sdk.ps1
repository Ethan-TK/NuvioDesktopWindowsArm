# Downloads the Microsoft.Web.WebView2 NuGet package without needing nuget.exe
# (not guaranteed on Windows on ARM runners) and exports WEBVIEW2_ROOT for Gradle
# (-Pnuvio.webview2.dir). Verifies the loader import library exists for -Arch.
#
# Usage: scripts/windows/install-webview2-sdk.ps1 -Version 1.0.4078.44 -Arch arm64
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [ValidateSet("x64", "arm64", "x86")][string]$Arch = "x64",
    [string]$Destination = $(if ($env:RUNNER_TEMP) { Join-Path $env:RUNNER_TEMP "nuget" } else { Join-Path $HOME ".nuget\packages\microsoft.web.webview2" })
)
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$root = Join-Path $Destination "Microsoft.Web.WebView2.$Version"
if (-not (Test-Path (Join-Path $root "build\native\include\WebView2.h"))) {
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $package = Join-Path $Destination "Microsoft.Web.WebView2.$Version.zip"
    # Manual retry loop: -MaximumRetryCount needs PowerShell 7; this also runs on Windows PowerShell 5.1.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    for ($attempt = 1; ; $attempt++) {
        try {
            Invoke-WebRequest -UseBasicParsing `
                -Uri "https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2/$Version" `
                -OutFile $package
            break
        } catch {
            if ($attempt -ge 4) { throw }
            Start-Sleep -Seconds 5
        }
    }
    Expand-Archive -Path $package -DestinationPath $root -Force
    Remove-Item $package
}

$loaderLibrary = Join-Path $root "build\native\$Arch\WebView2Loader.dll.lib"
if (-not (Test-Path $loaderLibrary)) {
    throw "WebView2Loader.dll.lib was not found at $loaderLibrary"
}
if ($env:GITHUB_ENV) {
    "WEBVIEW2_ROOT=$root" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
}
Write-Output "WebView2 SDK $Version ($Arch): $root"
