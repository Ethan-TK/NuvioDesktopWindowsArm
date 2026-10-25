# Verifies a packaged Nuvio MSI: extracts it, checks the bundled JVM and native libraries,
# confirms every native DLL matches the target architecture, and writes a contents manifest.
#
# Usage: scripts/windows/verify-msi.ps1 -Arch x64|arm64 -Version <release version>
param(
    [Parameter(Mandatory = $true)][ValidateSet("x64", "arm64")][string]$Arch,
    [Parameter(Mandatory = $true)][string]$Version
)
$ErrorActionPreference = "Stop"

# [IO.Path]::GetRelativePath needs .NET Core (PowerShell 7); keep Windows PowerShell 5.1 working.
function Get-RelativePath([string]$Base, [string]$Path) {
    $baseFull = [IO.Path]::GetFullPath($Base).TrimEnd('\') + '\'
    $full = [IO.Path]::GetFullPath($Path)
    if ($full.StartsWith($baseFull, [StringComparison]::OrdinalIgnoreCase)) { return $full.Substring($baseFull.Length) }
    return $full
}

function Get-PeMachine([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    try {
        $reader = [IO.BinaryReader]::new($stream)
        if ($stream.Length -lt 0x40) { return $null }
        $stream.Seek(0x3C, "Begin") | Out-Null
        $peOffset = $reader.ReadInt32()
        if ($peOffset -le 0 -or ($peOffset + 6) -gt $stream.Length) { return $null }
        $stream.Seek($peOffset, "Begin") | Out-Null
        if ($reader.ReadUInt32() -ne 0x00004550) { return $null }
        return $reader.ReadUInt16()
    } finally {
        $stream.Dispose()
    }
}

$expectedMachine = if ($Arch -eq "arm64") { 0xAA64 } else { 0x8664 }
$msiName = "Nuvio-Windows-$Arch-$Version.msi"
$msiRelativePath = "composeApp\build\compose\release-msis\$msiName"
if (-not (Test-Path $msiRelativePath)) {
    throw "Expected MSI was not produced: $msiRelativePath"
}
$msiPath = (Resolve-Path $msiRelativePath).Path
$tempRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
$extractDir = Join-Path $tempRoot "nuvio-msi-$Arch-$([Guid]::NewGuid().ToString('N'))"
$extractLog = Join-Path $tempRoot "nuvio-msi-$Arch-extract.log"
New-Item -ItemType Directory -Path $extractDir | Out-Null

$extractProcess = Start-Process `
    -FilePath msiexec.exe `
    -ArgumentList @("/a", "`"$msiPath`"", "/qn", "TARGETDIR=`"$extractDir`"", "/l*v", "`"$extractLog`"") `
    -Wait `
    -PassThru
if ($extractProcess.ExitCode -ne 0) {
    Get-Content $extractLog -Tail 200
    throw "MSI administrative extraction failed with exit code $($extractProcess.ExitCode)."
}

$appJar = Get-ChildItem $extractDir -Recurse -Filter "composeApp-desktop-*.jar" | Select-Object -First 1
if ($null -eq $appJar) {
    throw "The extracted MSI does not contain the desktop application JAR."
}

$jarEntries = & jar tf $appJar.FullName
if ($LASTEXITCODE -ne 0) {
    throw "Could not inspect the extracted desktop application JAR."
}
$requiredEntries = @(
    "native/windows/player_bridge.dll",
    "native/windows/libmpv-2.dll",
    "native/windows/WebView2Loader.dll",
    "native/windows/vcruntime140.dll",
    "native/windows/msvcp140.dll",
    "native/windows/runtime-files.txt",
    "native/windows/nuvio_engine.dll"
)
if ($Arch -eq "arm64") {
    # quickjs-kt only ships windows_x64 natives upstream; ARM64 builds bundle their own.
    $requiredEntries += "jni/windows_aarch64/libquickjs.dll"
}
foreach ($entry in $requiredEntries) {
    if ($jarEntries -notcontains $entry) {
        throw "The extracted MSI application is missing $entry"
    }
}

# Every bundled DLL must match the target architecture; a mismatch only fails at runtime.
$quickJsResourceDir = if ($Arch -eq "arm64") { "jni/windows_aarch64/" } else { "jni/windows_x64/" }
$nativeDllEntries = @($jarEntries | Where-Object {
    ($_ -like "native/windows/*.dll") -or ($_ -like "$quickJsResourceDir*.dll")
})
$jarExtractDir = Join-Path $extractDir "__jar"
New-Item -ItemType Directory -Path $jarExtractDir | Out-Null
Push-Location $jarExtractDir
try {
    & jar xf $appJar.FullName @nativeDllEntries
    if ($LASTEXITCODE -ne 0) { throw "Could not extract native libraries from the application JAR." }
} finally {
    Pop-Location
}
foreach ($entry in $nativeDllEntries) {
    $dll = Join-Path $jarExtractDir $entry
    $machine = Get-PeMachine $dll
    if ($machine -ne $expectedMachine) {
        throw ("{0} has PE machine 0x{1:X4}, expected 0x{2:X4} ({3})." -f $entry, $machine, $expectedMachine, $Arch)
    }
}

$javaRuntimeJvm = Get-ChildItem $extractDir -Recurse -Filter "jvm.dll" `
    | Where-Object { $_.FullName -match "[\\/]runtime[\\/]bin[\\/]server[\\/]jvm\.dll$" } `
    | Select-Object -First 1
if ($null -eq $javaRuntimeJvm) {
    throw "The extracted MSI does not contain the bundled Java runtime."
}
if ((Get-PeMachine $javaRuntimeJvm.FullName) -ne $expectedMachine) {
    throw "The bundled Java runtime is not a native $Arch JVM. Build with a $Arch JDK."
}
Remove-Item -Recurse -Force $jarExtractDir

$manifestPath = "composeApp\build\compose\release-msis\Nuvio-Windows-$Arch-$Version-contents.txt"
$extractedFiles = Get-ChildItem $extractDir -Recurse -File | Sort-Object FullName
$nativeEntries = $jarEntries | Where-Object { $_ -like "native/windows/*" -or $_ -like "jni/windows_*" } | Sort-Object
$manifest = [Collections.Generic.List[string]]::new()
$manifest.Add("MSI=$msiName")
$manifest.Add("MSI_SHA256=$((Get-FileHash $msiPath -Algorithm SHA256).Hash.ToLowerInvariant())")
$manifest.Add("MSI_SIGNATURE_STATUS=$((Get-AuthenticodeSignature $msiPath).Status)")
$manifest.Add("ARCH=$Arch")
$manifest.Add("EXTRACTED_FILE_COUNT=$($extractedFiles.Count)")
$manifest.Add("APP_JAR=$((Get-RelativePath $extractDir $appJar.FullName).Replace('\', '/'))")
$manifest.Add("JAVA_RUNTIME_JVM=$((Get-RelativePath $extractDir $javaRuntimeJvm.FullName).Replace('\', '/'))")
$manifest.Add("")
$manifest.Add("NATIVE_JAR_ENTRIES")
foreach ($entry in $nativeEntries) {
    $manifest.Add($entry)
}
$manifest.Add("")
$manifest.Add("EXTRACTED_FILES")
foreach ($file in $extractedFiles) {
    $relativePath = (Get-RelativePath $extractDir $file.FullName).Replace('\', '/')
    $manifest.Add("$relativePath`t$($file.Length)")
}
$manifest | Set-Content $manifestPath -Encoding utf8

Get-Item $msiPath | Format-List Name, Length, LastWriteTime
$manifest | Select-Object -First (10 + $nativeEntries.Count)
