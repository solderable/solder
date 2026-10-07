[CmdletBinding()]
param(
    [string]$Version,
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA "Solder"),
    [ValidateSet("Auto", "GitHub")]
    [string]$DownloadSource = "Auto",
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Repo = "solderable/solder"

function Fail {
    param([string]$Message)
    throw $Message
}

function Assert-WindowsX64 {
    # Do not use [System.Runtime.InteropServices.RuntimeInformation] here: under
    # Windows PowerShell 5.1 it binds to whichever facade assembly the session
    # already loaded, and older facades lack OSArchitecture, which is a
    # strict-mode PropertyNotFoundStrict error.
    if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
        Fail "install.ps1 supports Windows only."
    }

    # PROCESSOR_ARCHITEW6432 reports the OS architecture when running in a
    # 32-bit process on a 64-bit OS; PROCESSOR_ARCHITECTURE alone would say x86.
    $architecture = $env:PROCESSOR_ARCHITEW6432
    if ([string]::IsNullOrWhiteSpace($architecture)) {
        $architecture = $env:PROCESSOR_ARCHITECTURE
    }

    if ($architecture -ne "AMD64") {
        Fail "unsupported Windows architecture: $architecture"
    }
}

function Get-ReleaseProperty {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return ,$property.Value
}

function Resolve-ReleaseDownload {
    param([string]$RequestedVersion, [string]$Source)
    if (-not [string]::IsNullOrEmpty($RequestedVersion) -and $RequestedVersion -cnotmatch '\Av?[0-9]+\.[0-9]+(?:\.[0-9]+)?(?:-[0-9A-Za-z.-]+)?\z') {
        Fail "-Version must be a release version."
    }
    $releaseUrl = if ([string]::IsNullOrEmpty($RequestedVersion)) {
        "https://api.github.com/repos/$Repo/releases/latest"
    } else {
        "https://api.github.com/repos/$Repo/releases/tags/$RequestedVersion"
    }
    Write-Host "Reading GitHub release metadata..."
    try {
        $release = Invoke-RestMethod -Uri $releaseUrl -TimeoutSec 60 -Headers @{ "User-Agent" = "solder-installer"; "Accept" = "application/vnd.github+json" }
    }
    catch {
        Fail "failed to read GitHub release metadata: $($_.Exception.Message)"
    }
    $tag = Get-ReleaseProperty $release "tag_name"
    $draft = Get-ReleaseProperty $release "draft"
    $releaseAssets = Get-ReleaseProperty $release "assets"
    if ($release -isnot [pscustomobject] -or $tag -isnot [string] -or $tag -cnotmatch '\Av?[0-9]+\.[0-9]+(?:\.[0-9]+)?(?:-[0-9A-Za-z.-]+)?\z' -or $draft -isnot [bool] -or $draft -or $releaseAssets -isnot [Array]) {
        Fail "GitHub returned invalid release metadata."
    }
    if (-not [string]::IsNullOrEmpty($RequestedVersion) -and $tag -cne $RequestedVersion) {
        Fail "GitHub returned a different release version than requested."
    }
    $name = "solder-$tag-windows-x64.zip"
    $assets = @($releaseAssets | Where-Object { (Get-ReleaseProperty $_ "name") -ceq $name })
    if ($assets.Count -ne 1) { Fail "GitHub release must contain exactly one $name asset." }
    $asset = $assets[0]
    $size = Get-ReleaseProperty $asset "size"
    $digest = Get-ReleaseProperty $asset "digest"
    $url = "https://github.com/$Repo/releases/download/$tag/$name"
    if (($size -isnot [int] -and $size -isnot [long] -and $size -isnot [double]) -or $size -le 0 -or $size -gt 9007199254740991 -or [math]::Floor($size) -ne $size -or $digest -isnot [string] -or $digest -notmatch '\Asha256:[0-9a-f]{64}\z' -or (Get-ReleaseProperty $asset "browser_download_url") -cne $url) {
        Fail "GitHub release asset is missing a valid size, SHA-256 digest, or download URL."
    }
    $resolvedSource = "github"
    $body = Get-ReleaseProperty $release "body"
    if ($Source -ne "GitHub" -and $null -ne $body) {
        if ($body -isnot [string]) { Fail "GitHub release body is invalid." }
        $marker = "<!-- solder-release-platform-details"
        $start = $body.IndexOf($marker, [StringComparison]::Ordinal)
        if ($start -ge 0) {
            $prefix = "$marker "
            if (-not $body.Substring($start).StartsWith($prefix, [StringComparison]::Ordinal)) {
                Fail "Release download metadata is malformed. Use -DownloadSource GitHub to select GitHub explicitly."
            }
            $end = $body.IndexOf(" -->", $start + $prefix.Length, [StringComparison]::Ordinal)
            if ($end -lt 0 -or $body.IndexOf($marker, $start + $marker.Length, [StringComparison]::Ordinal) -ge 0) {
                Fail "Release download metadata is malformed. Use -DownloadSource GitHub to select GitHub explicitly."
            }
            try { $details = $body.Substring($start + $prefix.Length, $end - $start - $prefix.Length) | ConvertFrom-Json }
            catch { Fail "Release download metadata is invalid JSON. Use -DownloadSource GitHub to select GitHub explicitly." }
            if ($details -isnot [pscustomobject]) { Fail "Release download metadata must be an object." }
            $platformProperty = $details.PSObject.Properties["windows"]
            if ($null -ne $platformProperty) {
                $mirror = Get-ReleaseProperty $platformProperty.Value "asset"
                $mirrorDigest = Get-ReleaseProperty $mirror "digest"
                $mirrorSize = Get-ReleaseProperty $mirror "size"
                if ($mirror -isnot [pscustomobject] -or (Get-ReleaseProperty $mirror "name") -cne $name -or ($mirrorSize -isnot [int] -and $mirrorSize -isnot [long] -and $mirrorSize -isnot [double]) -or $mirrorSize -ne $size -or $mirrorDigest -isnot [string] -or $mirrorDigest -notmatch '\Asha256:[0-9a-f]{64}\z' -or $mirrorDigest -ine $digest) {
                    Fail "Release download metadata does not match the GitHub asset. Use -DownloadSource GitHub to select GitHub explicitly."
                }
                $downloadProperty = $mirror.PSObject.Properties["downloadUrl"]
                if ($null -ne $downloadProperty) {
                    $candidate = $downloadProperty.Value
                    if ($candidate -isnot [string] -or $candidate -cnotmatch '\Ahttps://(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.ufs\.sh|utfs\.io)/f/[A-Za-z0-9_-]+\z') {
                        Fail "Release download URL must be a public UploadThing URL without credentials or query parameters."
                    }
                    $url = $candidate
                    $resolvedSource = "uploadthing"
                }
            }
        }
    }
    return [pscustomobject]@{ Version = $tag; AssetName = $name; DownloadUrl = $url; Size = $size; Sha256 = $digest.Substring(7).ToLowerInvariant(); Source = $resolvedSource }
}

function Assert-ArchiveIntegrity {
    param([string]$ArchivePath, $Download)
    if ((Get-Item -LiteralPath $ArchivePath).Length -ne $Download.Size) {
        Fail "downloaded archive size does not match the GitHub release asset"
    }
    # Stream through .NET so this also works when PowerShell 5.1 is launched
    # from a host whose PSModulePath does not expose Get-FileHash.
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $stream = $null
    try {
        $stream = [System.IO.File]::OpenRead($ArchivePath)
        $actualHash = [BitConverter]::ToString($sha256.ComputeHash($stream)).Replace("-", "")
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
        $sha256.Dispose()
    }
    if ($actualHash -ine $Download.Sha256) {
        Fail "downloaded archive SHA-256 does not match the GitHub release asset"
    }
}

function Remove-ExistingPath {
    param([string]$Path)

    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
}

function Copy-DirectoryFresh {
    param(
        [string]$Source,
        [string]$Destination
    )

    Remove-ExistingPath -Path $Destination
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Get-ChildItem -LiteralPath $Source -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $Destination -Recurse -Force
    }
}

function Add-UserPathEntry {
    param([string]$PathToAdd)

    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $entries = @()
    if (-not [string]::IsNullOrWhiteSpace($userPath)) {
        $entries = @($userPath -split ";" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    $normalizedPathToAdd = $PathToAdd.TrimEnd("\")
    $alreadyPresent = $false
    foreach ($entry in $entries) {
        if ($entry.TrimEnd("\") -ieq $normalizedPathToAdd) {
            $alreadyPresent = $true
            break
        }
    }

    if (-not $alreadyPresent) {
        $newPath = if ($entries.Count -eq 0) {
            $PathToAdd
        }
        else {
            ($entries + $PathToAdd) -join ";"
        }

        [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
    }

    $processEntries = @($env:Path -split ";" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $processHasPath = $false
    foreach ($entry in $processEntries) {
        if ($entry.TrimEnd("\") -ieq $normalizedPathToAdd) {
            $processHasPath = $true
            break
        }
    }

    if (-not $processHasPath) {
        $env:Path = ($processEntries + $PathToAdd) -join ";"
    }
}

function Expand-ZipArchive {
    param(
        [string]$ArchivePath,
        [string]$DestinationPath
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
    [System.IO.Compression.ZipFile]::ExtractToDirectory($ArchivePath, $DestinationPath)
}

function Assert-SolderCadPythonRuntime {
    param([string]$SolderCadPath)

    $pythonExe = Join-Path $SolderCadPath "bin\python.exe"
    $encodingInit = Join-Path $SolderCadPath "bin\Lib\encodings\__init__.py"

    if (-not (Test-Path -LiteralPath $pythonExe -PathType Leaf)) {
        Fail "SolderCAD Python runtime is missing bin\python.exe"
    }
    if (-not (Test-Path -LiteralPath $encodingInit -PathType Leaf)) {
        Fail "SolderCAD Python runtime is missing bin\Lib\encodings\__init__.py"
    }
}

function Resolve-ShortTempRoot {
    if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        Fail "USERPROFILE is not set; cannot choose a short extraction path."
    }

    $shortId = [System.Guid]::NewGuid().ToString("N").Substring(0, 8)
    return Join-Path (Join-Path $env:USERPROFILE "sld") $shortId
}

Assert-WindowsX64

$download = Resolve-ReleaseDownload -RequestedVersion $Version -Source $DownloadSource
$Version = $download.Version
$assetName = $download.AssetName
$downloadUrl = $download.DownloadUrl
$binDir = Join-Path $InstallDir "bin"
$cliDestination = Join-Path $binDir "solder.exe"
$solderCadDestination = Join-Path $InstallDir "SolderCAD"
$oldSidecarSolderCadDestination = Join-Path $binDir "SolderCAD"
$kicadAppPath = $solderCadDestination
$kicadCliPath = Join-Path $solderCadDestination "bin\kicad-cli.exe"
$kicadDisableLibraryPreload = "1"

if ($DryRun) {
    @"
Solder Windows installer dry run

Repository:      $Repo
Version:         $Version
Architecture:    x64
Download URL:    $downloadUrl
Download source: $($download.Source)
Archive bytes:   $($download.Size)
SHA-256:         $($download.Sha256)
Install dir:     $InstallDir
CLI destination: $cliDestination
SolderCAD dir:   $solderCadDestination
Old sidecar dir: $oldSidecarSolderCadDestination
KICAD_APP_PATH:  $kicadAppPath
KICAD_CLI_PATH:  $kicadCliPath
KICAD_DISABLE_LIBRARY_PRELOAD: $kicadDisableLibraryPreload
KICAD_SOFTWARE_RENDERING: cleared
"@ | Write-Output
    exit 0
}

$tempRoot = Resolve-ShortTempRoot
$archivePath = Join-Path $tempRoot $assetName
$extractDir = Join-Path $tempRoot "extract"

try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

    Write-Host "Downloading $downloadUrl"
    try {
        Invoke-WebRequest -Uri $downloadUrl -OutFile $archivePath -Headers @{ "User-Agent" = "solder-installer" }
    }
    catch {
        Fail "$($download.Source) download failed; no other source was tried. To use GitHub explicitly, rerun with -DownloadSource GitHub."
    }

    Write-Host "Verifying archive size and SHA-256..."
    Assert-ArchiveIntegrity -ArchivePath $archivePath -Download $download

    Write-Host "Extracting $assetName"
    Expand-ZipArchive -ArchivePath $archivePath -DestinationPath $extractDir

    $payloadRoots = @(Get-ChildItem -LiteralPath $extractDir -Directory)
    if ($payloadRoots.Count -ne 1) {
        Fail "expected archive to contain exactly one top-level folder"
    }

    $payloadRoot = $payloadRoots[0].FullName
    $payloadCli = Join-Path $payloadRoot "solder.exe"
    $payloadInstallTxt = Join-Path $payloadRoot "INSTALL.txt"
    $payloadSolderCad = Join-Path $payloadRoot "SolderCAD"
    $payloadKicadExe = Join-Path $payloadSolderCad "bin\kicad.exe"
    $payloadKicadCli = Join-Path $payloadSolderCad "bin\kicad-cli.exe"
    $payloadKicadShare = Join-Path $payloadSolderCad "share\kicad"

    if (-not (Test-Path -LiteralPath $payloadCli -PathType Leaf)) {
        Fail "archive missing solder.exe"
    }
    if (-not (Test-Path -LiteralPath $payloadInstallTxt -PathType Leaf)) {
        Fail "archive missing INSTALL.txt"
    }
    if (-not (Test-Path -LiteralPath $payloadKicadExe -PathType Leaf)) {
        Fail "archive missing SolderCAD\bin\kicad.exe"
    }
    if (-not (Test-Path -LiteralPath $payloadKicadCli -PathType Leaf)) {
        Fail "archive missing SolderCAD\bin\kicad-cli.exe"
    }
    if (-not (Test-Path -LiteralPath $payloadKicadShare -PathType Container)) {
        Fail "archive missing SolderCAD\share\kicad"
    }
    Assert-SolderCadPythonRuntime -SolderCadPath $payloadSolderCad

    Write-Host "Installing solder.exe to $cliDestination"
    New-Item -ItemType Directory -Path $binDir -Force | Out-Null
    Copy-Item -LiteralPath $payloadCli -Destination $cliDestination -Force

    if (Test-Path -LiteralPath $oldSidecarSolderCadDestination) {
        Write-Host "Removing old sidecar SolderCAD from $oldSidecarSolderCadDestination"
        Remove-ExistingPath -Path $oldSidecarSolderCadDestination
    }

    Write-Host "Installing SolderCAD to $solderCadDestination"
    Copy-DirectoryFresh -Source $payloadSolderCad -Destination $solderCadDestination
    Assert-SolderCadPythonRuntime -SolderCadPath $solderCadDestination

    Add-UserPathEntry -PathToAdd $binDir
    [Environment]::SetEnvironmentVariable("KICAD_APP_PATH", $kicadAppPath, "User")
    [Environment]::SetEnvironmentVariable("KICAD_CLI_PATH", $kicadCliPath, "User")
    [Environment]::SetEnvironmentVariable("KICAD_DISABLE_LIBRARY_PRELOAD", $kicadDisableLibraryPreload, "User")
    [Environment]::SetEnvironmentVariable("KICAD_SOFTWARE_RENDERING", $null, "User")
    $env:KICAD_APP_PATH = $kicadAppPath
    $env:KICAD_CLI_PATH = $kicadCliPath
    $env:KICAD_DISABLE_LIBRARY_PRELOAD = $kicadDisableLibraryPreload
    Remove-Item Env:KICAD_SOFTWARE_RENDERING -ErrorAction SilentlyContinue

    Write-Host ""
    Write-Host "Solder $Version installed."
    Write-Host "CLI:            $cliDestination"
    Write-Host "SolderCAD:      $solderCadDestination"
    Write-Host "KICAD_APP_PATH: $kicadAppPath"
    Write-Host "KICAD_CLI_PATH: $kicadCliPath"
    Write-Host "KICAD_DISABLE_LIBRARY_PRELOAD: $kicadDisableLibraryPreload"
    Write-Host "KICAD_SOFTWARE_RENDERING: cleared"
    Write-Host ""
    Write-Host "Open a new terminal before running solder if this is your first install."
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
