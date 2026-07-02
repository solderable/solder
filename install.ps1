[CmdletBinding()]
param(
    [string]$Version,
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA "Solder"),
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
    $runningOnWindows = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
        [System.Runtime.InteropServices.OSPlatform]::Windows
    )
    if (-not $runningOnWindows) {
        Fail "install.ps1 supports Windows only."
    }

    $architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
    if ($architecture -ne [System.Runtime.InteropServices.Architecture]::X64) {
        Fail "unsupported Windows architecture: $architecture"
    }
}

function Resolve-LatestVersion {
    $latestUrl = "https://api.github.com/repos/$Repo/releases/latest"
    try {
        $release = Invoke-RestMethod -Uri $latestUrl -Headers @{ "User-Agent" = "solder-installer" }
    }
    catch {
        Fail "failed to resolve latest release from ${latestUrl}: $($_.Exception.Message)"
    }

    $tagNameProperty = $release.PSObject.Properties["tag_name"]
    if ($null -eq $tagNameProperty -or [string]::IsNullOrWhiteSpace([string]$tagNameProperty.Value)) {
        Fail "latest release response did not include tag_name"
    }

    return [string]$tagNameProperty.Value
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

if ([string]::IsNullOrWhiteSpace($Version)) {
    $Version = Resolve-LatestVersion
}

$assetName = "solder-$Version-windows-x64.zip"
$downloadUrl = "https://github.com/$Repo/releases/download/$Version/$assetName"
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
    Invoke-WebRequest -Uri $downloadUrl -OutFile $archivePath -Headers @{ "User-Agent" = "solder-installer" }

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
