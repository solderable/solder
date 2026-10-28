[CmdletBinding()]
param(
    [string]$Version,
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA "Solder"),
    [ValidateSet("Auto", "GitHub")]
    [string]$DownloadSource = "Auto",
    [switch]$DryRun,
    [switch]$NoUserIntegration
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

    # Windows 11 on ARM supports x64 programs through emulation. Do not pretend
    # older ARM editions have the same capability.
    if ($architecture -eq "ARM64") {
        $build = [int](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name CurrentBuildNumber).CurrentBuildNumber
        if ($build -lt 22000) { Fail "Windows 11 or newer is required to run the x64 release on ARM64." }
    }
    elseif ($architecture -ne "AMD64") {
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
    $cliVersion = $tag -replace '^v', ''
    if ($body -is [string]) {
        $versionMarker = '<!-- solder-release-binary-versions'
        $versionStart = $body.IndexOf($versionMarker, [StringComparison]::Ordinal)
        if ($versionStart -ge 0) {
            $prefix = "$versionMarker "
            $versionEnd = $body.IndexOf(' -->', $versionStart + $prefix.Length, [StringComparison]::Ordinal)
            if (-not $body.Substring($versionStart).StartsWith($prefix, [StringComparison]::Ordinal) -or
                $versionEnd -lt 0 -or $body.IndexOf($versionMarker, $versionStart + $versionMarker.Length, [StringComparison]::Ordinal) -ge 0) {
                Fail "Release binary version metadata is malformed."
            }
            try { $versions = $body.Substring($versionStart + $prefix.Length, $versionEnd - $versionStart - $prefix.Length) | ConvertFrom-Json }
            catch { Fail "Release binary version metadata is invalid." }
            $cliVersion = Get-ReleaseProperty $versions 'windows'
            if ($cliVersion -isnot [string] -or $cliVersion -cnotmatch '\A[0-9]+\.[0-9]+(?:\.[0-9]+)?(?:-[0-9A-Za-z.-]+)?\z') {
                Fail "Release binary version metadata does not identify the Windows CLI."
            }
        }
    }
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
    return [pscustomobject]@{ Version = $tag; CliVersion = $cliVersion; AssetName = $name; DownloadUrl = $url; Size = $size; Sha256 = $digest.Substring(7).ToLowerInvariant(); Source = $resolvedSource }
}

function Get-FileSha256 {
    param([string]$Path)
    # Stream through .NET so this also works when PowerShell 5.1 is launched
    # from a host whose PSModulePath does not expose Get-FileHash.
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $stream = $null
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        $actualHash = [BitConverter]::ToString($sha256.ComputeHash($stream)).Replace("-", "")
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
        $sha256.Dispose()
    }
    return $actualHash
}

function Assert-ArchiveIntegrity {
    param([string]$ArchivePath, $Download)
    if ((Get-Item -LiteralPath $ArchivePath).Length -ne $Download.Size) {
        Fail "downloaded archive size does not match the GitHub release asset"
    }
    if ((Get-FileSha256 $ArchivePath) -ine $Download.Sha256) {
        Fail "downloaded archive SHA-256 does not match the GitHub release asset"
    }
}

function Resolve-PhysicalPath {
    param([string]$Path)

    # Match realpathSync.native used by Solder's process lease. Opening an
    # existing directory without OPEN_REPARSE_POINT follows junctions and also
    # expands DOS short names; textual GetFullPath alone would not coordinate.
    if (-not ("SolderInstaller.NativePath" -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
namespace SolderInstaller {
  public static class NativePath {
    [StructLayout(LayoutKind.Sequential)]
    private struct FileInformation {
      public uint Attributes, CreationLow, CreationHigh, AccessLow, AccessHigh, WriteLow, WriteHigh;
      public uint VolumeSerialNumber, SizeHigh, SizeLow, NumberOfLinks, FileIndexHigh, FileIndexLow;
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetFinalPathNameByHandle(SafeFileHandle handle, StringBuilder path, uint length, uint flags);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out FileInformation info);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CommandLineToArgvW(string commandLine, out int count);
    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr memory);
    public static string Resolve(string path) {
      using (var handle = CreateFile(path, 0, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero)) {
        if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
        var buffer = new StringBuilder(32768);
        uint length = GetFinalPathNameByHandle(handle, buffer, (uint)buffer.Capacity, 0);
        if (length == 0 || length >= buffer.Capacity) throw new Win32Exception(Marshal.GetLastWin32Error());
        string result = buffer.ToString();
        if (result.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase)) return @"\\" + result.Substring(8);
        if (result.StartsWith(@"\\?\", StringComparison.OrdinalIgnoreCase)) return result.Substring(4);
        return result;
      }
    }
    public static string Identity(string path) {
      using (var handle = CreateFile(path, 0, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero)) {
        if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
        FileInformation info;
        if (!GetFileInformationByHandle(handle, out info)) throw new Win32Exception(Marshal.GetLastWin32Error());
        return String.Format("{0:X8}:{1:X8}:{2:X8}", info.VolumeSerialNumber, info.FileIndexHigh, info.FileIndexLow);
      }
    }
    public static string[] SplitCommandLine(string commandLine) {
      int count;
      IntPtr argv = CommandLineToArgvW(commandLine, out count);
      if (argv == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
      try {
        var result = new string[count];
        for (int i = 0; i < count; i++) result[i] = Marshal.PtrToStringUni(Marshal.ReadIntPtr(argv, i * IntPtr.Size));
        return result;
      } finally { LocalFree(argv); }
    }
  }
}
'@
    }
    return [SolderInstaller.NativePath]::Resolve([IO.Path]::GetFullPath($Path)).TrimEnd('\')
}

function Enter-SolderInstallLease {
    param([string]$InstallRoot)

    $physical = Join-Path (Resolve-PhysicalPath $InstallRoot) '.SolderCAD.update-lock'
    # v2 matches Solder's application-update lease. Only ASCII is folded:
    # JavaScript and .NET do not agree on Unicode lowercase mappings. The
    # physical parent is already canonicalized by Windows.
    $builder = New-Object Text.StringBuilder
    foreach ($character in $physical.ToCharArray()) {
        $code = [int]$character
        if ($code -ge 65 -and $code -le 90) { $code += 32 }
        [void]$builder.Append([char]$code)
    }
    $identities = @(
        @{ Version = 'v2'; Value = $builder.ToString() },
        # Also coordinate with the older public updater when its Unicode
        # lowercase mapping agrees with .NET (including ordinary ASCII paths).
        @{ Version = 'v1'; Value = $physical.ToLowerInvariant() }
    )
    $listeners = New-Object 'System.Collections.Generic.List[System.Net.Sockets.TcpListener]'
    $ports = New-Object 'System.Collections.Generic.HashSet[int]'
    try {
        foreach ($identity in $identities) {
            $bytes = [Text.Encoding]::UTF8.GetBytes("solder-process-lease-$($identity.Version)$([char]0)$($identity.Value)")
            $sha = [Security.Cryptography.SHA256]::Create()
            try { $hash = $sha.ComputeHash($bytes) } finally { $sha.Dispose() }
            $value = ([long]$hash[0] * 16777216) + ([long]$hash[1] * 65536) + ([long]$hash[2] * 256) + [long]$hash[3]
            $port = [int](16384 + ($value % 32768))
            if (-not $ports.Add($port)) { continue }
            $listener = New-Object Net.Sockets.TcpListener ([Net.IPAddress]::Loopback), $port
            $listener.ExclusiveAddressUse = $true
            $listener.Start()
            $listeners.Add($listener)
        }
    } catch {
        $cause = $_.Exception
        foreach ($listener in $listeners) { $listener.Stop() }
        if ($cause.InnerException -is [Net.Sockets.SocketException] -and
            $cause.InnerException.SocketErrorCode -eq [Net.Sockets.SocketError]::AddressAlreadyInUse) {
            throw "Another Solder installation or update is using this installation. Wait for it to finish and retry."
        }
        throw
    }
    $lease = [pscustomobject]@{ Listeners = $listeners }
    $lease | Add-Member -MemberType ScriptMethod -Name Stop -Value {
        foreach ($listener in $this.Listeners) { $listener.Stop() }
    }
    return $lease
}

function Assert-OrdinaryTarget {
    param([string]$Path, [bool]$Directory)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $item.PSIsContainer -ne $Directory) {
        Fail "Cannot safely replace '$Path': it is a link or has an unexpected type."
    }
}

function Assert-NoReparseTree {
    param([string]$Directory)
    Assert-OrdinaryTarget -Path $Directory -Directory $true
    foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($Directory)) {
        $attributes = [IO.File]::GetAttributes($entry)
        if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Fail "Cannot safely clean recovery directory containing a link: '$entry'. Recovery files were preserved."
        }
        if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) {
            Assert-NoReparseTree -Directory $entry
        }
    }
}

function ConvertTo-ExtendedPath {
    param([string]$Path)
    $path = [IO.Path]::GetFullPath($Path)
    if ($path.StartsWith('\\?\')) { return $path }
    if ($path.StartsWith('\\')) { return '\\?\UNC\' + $path.Substring(2) }
    return '\\?\' + $path
}

function Assert-SolderProcessesClosed {
    param([string]$InstallRoot)

    $app = (Join-Path $InstallRoot 'SolderCAD').TrimEnd('\') + '\'
    $sidecar = (Join-Path $InstallRoot 'bin\SolderCAD').TrimEnd('\') + '\'
    $cli = Join-Path $InstallRoot 'bin\solder.exe'
    $nativeNames = @('solder.exe', 'kicad.exe', 'kicad-cli.exe', 'eeschema.exe', 'pcbnew.exe',
                     'gerbview.exe', 'pcb_calculator.exe', 'pl_editor.exe', 'bitmap2component.exe',
                     'python.exe', 'pythonw.exe', 'crashpad_handler.exe')
    foreach ($process in @(Get-CimInstance Win32_Process -ErrorAction Stop)) {
        $path = $process.ExecutablePath
        if ([string]::IsNullOrWhiteSpace($path)) {
            if ($process.Name -in $nativeNames) {
                Fail "Cannot inspect a running Solder or KiCad process. Close it before installing."
            }
            continue
        }
        # Canonicalize potential aliases for known executables. If a running
        # executable cannot be inspected, fail closed instead of risking edits.
        if ($process.Name -in $nativeNames) {
            try { $path = Resolve-PhysicalPath $path }
            catch { Fail "Cannot inspect a running Solder or KiCad process. Close it before installing." }
        }
        if ($path.Equals($cli, [StringComparison]::OrdinalIgnoreCase) -or
            $path.StartsWith($app, [StringComparison]::OrdinalIgnoreCase) -or
            $path.StartsWith($sidecar, [StringComparison]::OrdinalIgnoreCase)) {
            Fail "Save your work and close SolderCAD, its editors, and Solder terminals for this installation, then retry. Open projects were not closed."
        }
        # A different installed CLI can explicitly target this app using
        # KICAD_APP_PATH. Its environment is not inspectable, so conservatively
        # wait for any other Solder update, while allowing unrelated sessions.
        if ($process.Name -ieq 'solder.exe') {
            if ([string]::IsNullOrWhiteSpace($process.CommandLine)) {
                Fail "Cannot inspect a running Solder process. Close it before installing."
            }
            try { $arguments = [SolderInstaller.NativePath]::SplitCommandLine($process.CommandLine) }
            catch { Fail "Cannot inspect a running Solder process. Close it before installing." }
            if ($arguments.Length -gt 1 -and $arguments[1] -ceq 'update') {
                Fail "Another Solder update is running. Wait for it to finish before installing."
            }
        }
    }
}

function Get-TargetIdentity {
    param([string]$Path, [bool]$Directory)
    Assert-OrdinaryTarget -Path $Path -Directory $Directory
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    # Native file IDs survive the same-volume renames used by publication and
    # distinguish the original, our staged payload, and an unrelated new file.
    return [SolderInstaller.NativePath]::Identity($Path)
}

function Get-InstalledVersions {
    param([string]$InstallRoot)
    $app = Join-Path $InstallRoot 'SolderCAD'
    $cli = Join-Path $InstallRoot 'bin\solder.exe'
    $appVersion = $null
    $cliVersion = $null
    $hasApp = Test-Path -LiteralPath $app -PathType Container
    $hasCli = Test-Path -LiteralPath $cli -PathType Leaf
    if ($hasApp) {
        $metadata = Join-Path $app 'share\kicad\resources\solder_chat\solder-release.json'
        try {
            $data = Get-Content -LiteralPath $metadata -Raw -ErrorAction Stop | ConvertFrom-Json
            if ($data.schemaVersion -eq 1 -and $data.component -ceq 'soldercad' -and
                $data.version -is [string] -and $data.version -match '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$') {
                $appVersion = $data.version
            }
        } catch { }
        if (-not $appVersion) { Write-Warning "The existing SolderCAD version is unknown. It will be replaced by the selected release." }
    } elseif ($hasCli) {
        Write-Warning "SolderCAD is missing. It will be installed from the selected release."
    }
    if ($hasCli) {
        $probe = Join-Path ([IO.Path]::GetTempPath()) ('solder-version-probe-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $probe | Out-Null
        try {
            $stdout = Join-Path $probe 'stdout'
            $stderr = Join-Path $probe 'stderr'
            $process = Start-Process -FilePath $cli -ArgumentList '--version' -NoNewWindow -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
            # Retain the process handle before it exits; otherwise Windows
            # PowerShell 5.1 can report a null ExitCode for a fast child.
            [void]$process.Handle
            if (-not $process.WaitForExit(15000)) {
                Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                $process.WaitForExit()
            } else {
                $process.Refresh()
                if ($process.ExitCode -ne 0) { throw 'The existing CLI version check failed.' }
                $output = (Get-Content -LiteralPath $stdout -Raw).Trim()
                if ($output -cmatch '^solder v(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)$') { $cliVersion = $Matches[1] }
            }
        } catch { }
        finally { Remove-Item -LiteralPath $probe -Recurse -Force -ErrorAction SilentlyContinue }
        if (-not $cliVersion) { Write-Warning "The existing Solder CLI version is unknown. It will be replaced by the selected release." }
    } elseif ($hasApp) {
        Write-Warning "The Solder CLI is missing. It will be installed from the selected release."
    }
    return [pscustomobject]@{ App = $appVersion; Cli = $cliVersion }
}

function Assert-NoImplicitDowngrade {
    param([object]$Installed, [string]$Selected)
    $target = [version](($Selected -replace '^v', '').Split('-')[0])
    foreach ($component in @($Installed.App, $Installed.Cli)) {
        if ($component -and [version]($component.Split('-')[0]) -gt $target) {
            Fail "An installed component is newer than release $Selected. Nothing was changed. Specify -Version explicitly to install a different release."
        }
    }
}

function Write-TransactionRecord {
    param([string]$Path, [string]$Content)
    $temp = "$Path.tmp"
    $stream = [IO.File]::Open($temp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Content)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    } finally { $stream.Dispose() }
    [IO.File]::Move($temp, $Path)
}

function Restore-TransactionItem {
    param([string]$Target, [string]$Backup, [string]$Quarantine, $OriginalIdentity, $NewIdentity, [bool]$Directory)
    $targetId = Get-TargetIdentity -Path $Target -Directory $Directory
    $backupId = Get-TargetIdentity -Path $Backup -Directory $Directory
    if ($null -ne $backupId -and $backupId -cne $OriginalIdentity) {
        Fail "Unexpected backup at '$Backup'. Recovery files were preserved."
    }
    if ($null -ne $targetId -and $targetId -cne $OriginalIdentity) {
        if ($null -eq $NewIdentity -or $targetId -cne $NewIdentity -or (Test-Path -LiteralPath $Quarantine)) {
            Fail "Unexpected installation path '$Target'. Recovery files were preserved."
        }
        # Preserve even our partially published payload: a person could have
        # added files to it after a crash. Never recursively delete it here.
        if ($Directory) { [IO.Directory]::Move($Target, $Quarantine) } else { [IO.File]::Move($Target, $Quarantine) }
        $targetId = $null
    }
    if ($null -ne $OriginalIdentity) {
        if ($null -ne $backupId) {
            if ($null -ne $targetId) { Fail "Both the original target and backup exist. Recovery files were preserved." }
            if ($Directory) { [IO.Directory]::Move($Backup, $Target) } else { [IO.File]::Move($Backup, $Target) }
        } elseif ($targetId -cne $OriginalIdentity) {
            Fail "The previous installation is missing from both '$Target' and '$Backup'. Recovery files were preserved."
        }
    } elseif ($null -ne $backupId -or $null -ne $targetId) {
        Fail "Unexpected recovery state for '$Target'. Recovery files were preserved."
    }
}

function Get-TransactionPaths {
    param([string]$InstallRoot, [string]$Token)
    if ($Token -cnotmatch '\A[0-9a-f]{32}\z') { Fail "Invalid transaction identifier. Recovery files were preserved." }
    $prefix = Join-Path $InstallRoot ('.solder-installer-' + $Token)
    return [pscustomobject]@{
        backupApp = $prefix + '-previous-app'
        backupCli = $prefix + '-previous-cli.exe'
        backupSidecar = $prefix + '-previous-sidecar'
        failedApp = $prefix + '-unpublished-app'
        failedCli = $prefix + '-unpublished-cli.exe'
        failedSidecar = $prefix + '-unpublished-sidecar'
    }
}

function Remove-TransactionBackup {
    param([string]$Path, $ExpectedIdentity, [bool]$Directory)
    try {
        $actual = Get-TargetIdentity -Path $Path -Directory $Directory
        if ($null -eq $actual) { return }
        if ($null -eq $ExpectedIdentity -or $actual -cne $ExpectedIdentity) {
            Fail "The previous component changed; it will not be removed."
        }
        $extended = ConvertTo-ExtendedPath $Path
        if ($Directory) {
            Assert-NoReparseTree -Directory $extended
            [IO.Directory]::Delete($extended, $true)
        } else { [IO.File]::Delete($extended) }
    } catch {
        Write-Warning "Cleanup of the previous component was incomplete. Remaining files are at '$Path': $($_.Exception.Message)"
    }
}

function Recover-SolderTransaction {
    param([string]$InstallRoot)
    $tx = Join-Path $InstallRoot '.solder-installer-transaction'
    if (-not (Test-Path -LiteralPath $tx)) { return }
    Assert-OrdinaryTarget -Path $tx -Directory $true
    $owner = Join-Path $tx 'owner'
    Assert-OrdinaryTarget -Path $owner -Directory $false
    if (-not (Test-Path -LiteralPath $owner -PathType Leaf) -or
        (Get-Content -LiteralPath $owner -Raw) -cne 'solder-installer-transaction-v1') {
        Fail "Unrecognized recovery directory '$tx'. Nothing was changed."
    }
    $journal = Join-Path $tx 'journal.json'
    $committed = Join-Path $tx 'committed'
    Assert-OrdinaryTarget -Path $journal -Directory $false
    Assert-OrdinaryTarget -Path $committed -Directory $false
    $record = $null
    $paths = $null
    $isCommitted = $false
    if (Test-Path -LiteralPath $journal) {
        try { $record = Get-Content -LiteralPath $journal -Raw | ConvertFrom-Json }
        catch { Fail "The recovery record at '$journal' is invalid. Recovery files were preserved." }
        if ($record.schemaVersion -ne 3 -or $record.token -isnot [string] -or
            $record.newApp -isnot [string] -or $record.newCli -isnot [string] -or
            ($null -ne $record.oldApp -and $record.oldApp -isnot [string]) -or
            ($null -ne $record.oldCli -and $record.oldCli -isnot [string]) -or
            ($null -ne $record.oldSidecar -and $record.oldSidecar -isnot [string])) {
            Fail "The recovery record at '$journal' is invalid. Recovery files were preserved."
        }
        $paths = Get-TransactionPaths -InstallRoot $InstallRoot -Token $record.token
        if (Test-Path -LiteralPath $committed) {
            if ((Get-Content -LiteralPath $committed -Raw) -cne 'committed-v1') {
                Fail "The commit record at '$committed' is invalid. Recovery files were preserved."
            }
            $currentApp = Get-TargetIdentity -Path (Join-Path $InstallRoot 'SolderCAD') -Directory $true
            $currentCli = Get-TargetIdentity -Path (Join-Path $InstallRoot 'bin\solder.exe') -Directory $false
            $currentSidecar = Get-TargetIdentity -Path (Join-Path $InstallRoot 'bin\SolderCAD') -Directory $true
            if ($currentApp -cne $record.newApp -or $currentCli -cne $record.newCli -or $null -ne $currentSidecar) {
                Fail "The committed Solder installation changed before cleanup. Recovery files were preserved."
            }
            $isCommitted = $true
        } else {
            Write-Host "Restoring an interrupted Solder installation..."
            Restore-TransactionItem -Target (Join-Path $InstallRoot 'SolderCAD') -Backup $paths.backupApp -Quarantine $paths.failedApp -OriginalIdentity $record.oldApp -NewIdentity $record.newApp -Directory $true
            Restore-TransactionItem -Target (Join-Path $InstallRoot 'bin\solder.exe') -Backup $paths.backupCli -Quarantine $paths.failedCli -OriginalIdentity $record.oldCli -NewIdentity $record.newCli -Directory $false
            Restore-TransactionItem -Target (Join-Path $InstallRoot 'bin\SolderCAD') -Backup $paths.backupSidecar -Quarantine $paths.failedSidecar -OriginalIdentity $record.oldSidecar -NewIdentity $null -Directory $true
            if ((Test-Path -LiteralPath $paths.failedApp) -or (Test-Path -LiteralPath $paths.failedCli)) {
                $recovered = Join-Path $InstallRoot ('.solder-installer-recovered-' + $record.token)
                [IO.Directory]::Move($tx, $recovered)
                Write-Warning "The previous installation was restored. Partially published files were preserved with identifier $($record.token) under '$InstallRoot'."
                return
            }
        }
    } elseif (Test-Path -LiteralPath $committed) {
        Fail "The recovery record is missing at '$journal'. Recovery files were preserved."
    }
    # Executed images can prevent their *parent* directory from being renamed.
    # Backups and quarantine files are siblings, never inside the active marker.
    $cleanup = Join-Path $InstallRoot ('.solder-installer-cleanup-' + [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::Move($tx, $cleanup)
    if ($isCommitted) {
        Remove-TransactionBackup -Path $paths.backupApp -ExpectedIdentity $record.oldApp -Directory $true
        Remove-TransactionBackup -Path $paths.backupCli -ExpectedIdentity $record.oldCli -Directory $false
        Remove-TransactionBackup -Path $paths.backupSidecar -ExpectedIdentity $record.oldSidecar -Directory $true
    }
    try {
        $extendedCleanup = ConvertTo-ExtendedPath $cleanup
        Assert-NoReparseTree -Directory $extendedCleanup
        [IO.Directory]::Delete($extendedCleanup, $true)
    } catch {
        Write-Warning "Installation cleanup was incomplete. Remaining files are at '$cleanup': $($_.Exception.Message)"
    }
}

function Publish-SolderTransaction {
    param([string]$InstallRoot, [string]$PayloadRoot, [object[]]$Original, [string]$NewCliPath)
    if (-not $NewCliPath) { $NewCliPath = Join-Path $PayloadRoot 'solder.exe' }
    $tx = Join-Path $InstallRoot '.solder-installer-transaction'
    $app = Join-Path $InstallRoot 'SolderCAD'
    $cli = Join-Path $InstallRoot 'bin\solder.exe'
    $sidecar = Join-Path $InstallRoot 'bin\SolderCAD'
    $current = @((Get-TargetIdentity $app $true), (Get-TargetIdentity $cli $false), (Get-TargetIdentity $sidecar $true))
    for ($i = 0; $i -lt 3; $i++) {
        if ($current[$i] -cne $Original[$i]) { Fail "Solder changed while preparing the installation. Retry." }
    }
    Assert-SolderProcessesClosed -InstallRoot $InstallRoot
    Assert-OrdinaryTarget -Path $PayloadRoot -Directory $true
    $newApp = Get-TargetIdentity (Join-Path $PayloadRoot 'SolderCAD') $true
    $newCli = Get-TargetIdentity $NewCliPath $false
    if ($null -eq $newApp -or $null -eq $newCli) { Fail "The staged Solder installation is incomplete." }
    $token = [Guid]::NewGuid().ToString('N')
    $paths = Get-TransactionPaths -InstallRoot $InstallRoot -Token $token
    foreach ($path in @($paths.backupApp, $paths.backupCli, $paths.backupSidecar, $paths.failedApp, $paths.failedCli, $paths.failedSidecar)) {
        if (Test-Path -LiteralPath $path) { Fail "The recovery path '$path' already exists. Nothing was changed." }
    }
    $record = [ordered]@{schemaVersion=3;token=$token;oldApp=$Original[0];oldCli=$Original[1];oldSidecar=$Original[2];newApp=$newApp;newCli=$newCli} | ConvertTo-Json -Compress
    Write-TransactionRecord -Path (Join-Path $tx 'journal.json') -Content $record
    if ($null -ne $Original[0]) { [IO.Directory]::Move($app, $paths.backupApp) }
    if ($null -ne $Original[1]) { [IO.File]::Move($cli, $paths.backupCli) }
    if ($null -ne $Original[2]) { [IO.Directory]::Move($sidecar, $paths.backupSidecar) }
    [IO.Directory]::Move((Join-Path $PayloadRoot 'SolderCAD'), $app)
    [IO.File]::Move($NewCliPath, $cli)
    Write-TransactionRecord -Path (Join-Path $tx 'committed') -Content 'committed-v1'
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

function Set-SolderCadDesktopShortcut {
    param([string]$ShortcutPath, [string]$TargetPath)

    if (-not (Test-Path -LiteralPath $TargetPath -PathType Leaf)) {
        Fail "cannot create SolderCAD desktop shortcut: executable not found at $TargetPath"
    }
    $TargetPath = (Get-Item -LiteralPath $TargetPath).FullName

    New-Item -ItemType Directory -Path (Split-Path -Parent $ShortcutPath) -Force | Out-Null
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($ShortcutPath)
    $shortcut.TargetPath = $TargetPath
    $shortcut.WorkingDirectory = Split-Path -Parent $TargetPath
    $shortcut.IconLocation = "$TargetPath,0"
    $shortcut.Description = "SolderCAD"
    $shortcut.Arguments = ""
    $shortcut.WindowStyle = 1
    $shortcut.Save()
}

function Expand-ZipArchive {
    param(
        [string]$ArchivePath,
        [string]$DestinationPath
    )

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (-not ("SolderInstaller.SafeZip" -as [type])) {
        # ZipFile.ExtractToDirectory cannot handle an extended-length prefix on
        # Windows PowerShell 5.1. Read and extract each entry through the same
        # .NET ZIP decoder so the checked name is exactly the extracted name.
        Add-Type -ReferencedAssemblies @([IO.Compression.ZipArchive].Assembly.Location, [IO.Compression.ZipFile].Assembly.Location) -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Text.RegularExpressions;
namespace SolderInstaller {
  public static class SafeZip {
    private static string Extended(string path) {
      path = Path.GetFullPath(path);
      if (path.StartsWith(@"\\?\", StringComparison.Ordinal)) return path;
      if (path.StartsWith(@"\\", StringComparison.Ordinal)) return @"\\?\UNC\" + path.Substring(2);
      return @"\\?\" + path;
    }
    public static void Extract(string archivePath, string destination) {
      using (var archive = ZipFile.OpenRead(archivePath)) {
        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var entry in archive.Entries) {
          string name = entry.FullName.TrimEnd('/');
          if (name.Length == 0 || name.IndexOfAny(new char[] { '\\', ':', '*', '?', '"', '<', '>', '|' }) >= 0 || !names.Add(name))
            throw new InvalidDataException("The release archive contains an unsafe or duplicate path.");
          foreach (char ch in name) {
            if (ch < 32 || ch == 127) throw new InvalidDataException("The release archive contains an unsafe or duplicate path.");
          }
          foreach (string part in name.Split('/')) {
            if (part.Length == 0 || part == "." || part == ".." || part.EndsWith(" ", StringComparison.Ordinal) ||
                part.EndsWith(".", StringComparison.Ordinal) ||
                Regex.IsMatch(part, @"^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant))
              throw new InvalidDataException("The release archive contains an unsafe or duplicate path.");
          }
          int kind = (entry.ExternalAttributes >> 16) & 0xf000;
          if (kind != 0 && kind != 0x4000 && kind != 0x8000)
            throw new InvalidDataException("The release archive contains an unsupported link or file type.");
        }

        string root = Extended(destination);
        Directory.CreateDirectory(root);
        foreach (var entry in archive.Entries) {
          string path = Path.Combine(root, entry.FullName.Replace('/', '\\'));
          if (entry.FullName.EndsWith("/", StringComparison.Ordinal)) {
            Directory.CreateDirectory(path);
          } else {
            Directory.CreateDirectory(Path.GetDirectoryName(path));
            ZipFileExtensions.ExtractToFile(entry, path, false);
          }
        }
      }
    }
  }
}
'@
    }
    [SolderInstaller.SafeZip]::Extract($ArchivePath, $DestinationPath)
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

$explicitVersion = -not [string]::IsNullOrWhiteSpace($Version)
$InstallDir = [IO.Path]::GetFullPath($InstallDir)
$binDir = Join-Path $InstallDir "bin"
$cliDestination = Join-Path $binDir "solder.exe"
$solderCadDestination = Join-Path $InstallDir "SolderCAD"
$oldSidecarSolderCadDestination = Join-Path $binDir "SolderCAD"
$kicadAppPath = $solderCadDestination
$kicadGuiPath = Join-Path $solderCadDestination "bin\kicad.exe"
$kicadCliPath = Join-Path $solderCadDestination "bin\kicad-cli.exe"
$kicadDisableLibraryPreload = "1"
$desktopShortcutPath = $null
if (-not $NoUserIntegration) {
    # Ask Windows for the configured desktop, including redirected folders.
    $desktopDir = [Environment]::GetFolderPath("DesktopDirectory", "DoNotVerify")
    if ([string]::IsNullOrWhiteSpace($desktopDir)) {
        Fail "cannot resolve the current user's desktop folder for the SolderCAD shortcut"
    }
    $desktopShortcutPath = Join-Path $desktopDir "SolderCAD.lnk"
}

if ($DryRun) {
    $download = Resolve-ReleaseDownload -RequestedVersion $Version -Source $DownloadSource
    $desktopDescription = if ($NoUserIntegration) { "skipped" } else { $desktopShortcutPath }
    $integrationDescription = if ($NoUserIntegration) { "skipped" } else { "enabled" }
    $appPathDescription = if ($NoUserIntegration) { "unchanged" } else { $kicadAppPath }
    $cliPathDescription = if ($NoUserIntegration) { "unchanged" } else { $kicadCliPath }
    $preloadDescription = if ($NoUserIntegration) { "unchanged" } else { $kicadDisableLibraryPreload }
    $renderingDescription = if ($NoUserIntegration) { "unchanged" } else { "cleared" }
    @"
Solder Windows installer dry run

Repository:      $Repo
Version:         $($download.Version)
Architecture:    x64
Download URL:    $($download.DownloadUrl)
Download source: $($download.Source)
Archive bytes:   $($download.Size)
SHA-256:         $($download.Sha256)
Install dir:     $InstallDir
CLI destination: $cliDestination
SolderCAD dir:   $solderCadDestination
Desktop shortcut: $desktopDescription
User integration: $integrationDescription
Old sidecar dir: $oldSidecarSolderCadDestination
KICAD_APP_PATH:  $appPathDescription
KICAD_CLI_PATH:  $cliPathDescription
KICAD_DISABLE_LIBRARY_PRELOAD: $preloadDescription
KICAD_SOFTWARE_RENDERING: $renderingDescription
"@ | Write-Output
    exit 0
}

# Every transaction directory, staged payload and backup is on the destination
# volume. The lease is shared with Solder's paired updater.
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
$InstallDir = Resolve-PhysicalPath $InstallDir
$binDir = Join-Path $InstallDir "bin"
$cliDestination = Join-Path $binDir "solder.exe"
$solderCadDestination = Join-Path $InstallDir "SolderCAD"
$oldSidecarSolderCadDestination = Join-Path $binDir "SolderCAD"
$kicadAppPath = $solderCadDestination
$kicadGuiPath = Join-Path $solderCadDestination "bin\kicad.exe"
$kicadCliPath = Join-Path $solderCadDestination "bin\kicad-cli.exe"
$tx = Join-Path $InstallDir '.solder-installer-transaction'
$lease = Enter-SolderInstallLease -InstallRoot $InstallDir

try {
    Assert-OrdinaryTarget -Path $binDir -Directory $true
    New-Item -ItemType Directory -Force -Path $binDir | Out-Null
    Assert-SolderProcessesClosed -InstallRoot $InstallDir
    Recover-SolderTransaction -InstallRoot $InstallDir
    foreach ($previousUpdate in @(Get-ChildItem -LiteralPath $InstallDir -Directory -Force -Filter '.SolderCAD.update-*')) {
        $previousApp = Join-Path $previousUpdate.FullName 'previous'
        if (Test-Path -LiteralPath $previousApp -PathType Container) {
            Write-Warning "An earlier Solder update retained the previous application at '$previousApp'. It will be preserved."
        }
    }
    foreach ($oldBackup in @(Get-ChildItem -LiteralPath $InstallDir -Force -Filter '.solder-installer-*-previous-*')) {
        Write-Warning "An earlier installer retained a previous component at '$($oldBackup.FullName)'. It will be preserved."
    }
    foreach ($oldVerifier in @(Get-ChildItem -LiteralPath $InstallDir -File -Force -Filter '.solder-installer-verified-*.exe')) {
        Write-Warning "An earlier installer retained an unpublished verifier at '$($oldVerifier.FullName)'. It will be preserved."
    }
    $original = @((Get-TargetIdentity $solderCadDestination $true), (Get-TargetIdentity $cliDestination $false), (Get-TargetIdentity $oldSidecarSolderCadDestination $true))

    $download = Resolve-ReleaseDownload -RequestedVersion $Version -Source $DownloadSource
    $Version = $download.Version
    if (-not $explicitVersion) {
        Assert-NoImplicitDowngrade -Installed (Get-InstalledVersions $InstallDir) -Selected $Version
    }
    $archivePath = Join-Path $tx $download.AssetName
    $extractDir = Join-Path $tx "extract"
    # Create the ownership marker before publishing the fixed recovery path.
    # A crash during this preparation cannot strand an unrecognized marker.
    $preparing = Join-Path $InstallDir ('.solder-installer-preparing-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $preparing | Out-Null
    try {
        Write-TransactionRecord -Path (Join-Path $preparing 'owner') -Content 'solder-installer-transaction-v1'
        [IO.Directory]::Move($preparing, $tx)
    } catch {
        if (Test-Path -LiteralPath $preparing) { Remove-Item -LiteralPath $preparing -Recurse -Force }
        throw
    }

    $verifiedCli = $null
    try {
        Write-Host "Downloading $($download.DownloadUrl)"
        $previousProgress = $ProgressPreference
        try {
            # Windows PowerShell 5.1's per-buffer progress rendering makes
            # large downloads dramatically slower, especially under emulation.
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri $download.DownloadUrl -OutFile $archivePath -TimeoutSec 1800 -Headers @{ "User-Agent" = "solder-installer" }
        }
        catch {
            Fail "$($download.Source) download failed; no other source was tried. To use GitHub explicitly, rerun with -DownloadSource GitHub."
        }
        finally { $ProgressPreference = $previousProgress }

        Write-Host "Verifying archive size and SHA-256..."
        Assert-ArchiveIntegrity -ArchivePath $archivePath -Download $download

        Write-Host "Extracting $($download.AssetName)"
        Expand-ZipArchive -ArchivePath $archivePath -DestinationPath $extractDir
        $payloadRoots = @(Get-ChildItem -LiteralPath $extractDir -Directory)
        if ($payloadRoots.Count -ne 1) { Fail "expected archive to contain exactly one top-level folder" }

        $payloadRoot = $payloadRoots[0].FullName
        $payloadCli = Join-Path $payloadRoot "solder.exe"
        $payloadInstallTxt = Join-Path $payloadRoot "INSTALL.txt"
        $payloadSolderCad = Join-Path $payloadRoot "SolderCAD"
        $payloadKicadExe = Join-Path $payloadSolderCad "bin\kicad.exe"
        $payloadKicadCli = Join-Path $payloadSolderCad "bin\kicad-cli.exe"
        $payloadKicadShare = Join-Path $payloadSolderCad "share\kicad"

        foreach ($requiredFile in @($payloadCli, $payloadInstallTxt, $payloadKicadExe, $payloadKicadCli)) {
            if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) { Fail "archive missing required file '$requiredFile'" }
        }
        if (-not (Test-Path -LiteralPath $payloadKicadShare -PathType Container)) {
            Fail "archive missing SolderCAD\share\kicad"
        }
        Assert-SolderCadPythonRuntime -SolderCadPath $payloadSolderCad
        # Verify and publish a byte-identical sibling outside the active
        # transaction. A hard stop while the image is running cannot hold the
        # recovery directory open, and publication uses a file rename.
        $verifiedCli = Join-Path $InstallDir ('.solder-installer-verified-' + [Guid]::NewGuid().ToString('N') + '.exe')
        [IO.File]::Copy($payloadCli, $verifiedCli)
        if ((Get-FileSha256 $payloadCli) -cne (Get-FileSha256 $verifiedCli)) {
            Fail "The staged Solder executable could not be verified."
        }
        $cliVersion = (& $verifiedCli --version | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or $cliVersion -cne "solder v$($download.CliVersion)") {
            Fail "The downloaded Solder executable did not identify itself as v$($download.CliVersion)."
        }
        $metadataPath = Join-Path $payloadKicadShare 'resources\solder_chat\solder-release.json'
        $normalizedVersion = ($Version -replace '^v', '').Split('-')[0]
        $requiresMetadata = [version]$normalizedVersion -ge [version]'1.32.3'
        if ($requiresMetadata -and -not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
            Fail "The downloaded SolderCAD is missing its release identity."
        }
        if (Test-Path -LiteralPath $metadataPath) {
            $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
            if ($metadata.schemaVersion -ne 1 -or $metadata.component -cne 'soldercad' -or $metadata.version -cne ($Version -replace '^v', '')) {
                Fail "The downloaded SolderCAD does not identify itself as release $Version."
            }
        }

        Write-Host "Installing Solder and SolderCAD together..."
        Publish-SolderTransaction -InstallRoot $InstallDir -PayloadRoot $payloadRoot -Original $original -NewCliPath $verifiedCli
    }
    catch {
        $installError = $_
        try {
            if ($verifiedCli -and (Test-Path -LiteralPath $verifiedCli -PathType Leaf)) {
                Write-Warning "The uninstalled verifier was preserved at '$verifiedCli'."
            }
            Assert-SolderProcessesClosed -InstallRoot $InstallDir
            Recover-SolderTransaction -InstallRoot $InstallDir
        } catch {
            throw "Installation failed: $($installError.Exception.Message) Automatic recovery could not finish: $($_.Exception.Message) Close SolderCAD and retry; recovery files remain at $tx."
        }
        throw $installError
    }

    try { Recover-SolderTransaction -InstallRoot $InstallDir }
    catch { throw "Solder publication could not be verified. Recovery files remain at '$tx': $($_.Exception.Message)" }

    if (-not $NoUserIntegration) {
        try {
            Add-UserPathEntry -PathToAdd $binDir
            [Environment]::SetEnvironmentVariable("KICAD_APP_PATH", $kicadAppPath, "User")
            [Environment]::SetEnvironmentVariable("KICAD_CLI_PATH", $kicadCliPath, "User")
            [Environment]::SetEnvironmentVariable("KICAD_DISABLE_LIBRARY_PRELOAD", $kicadDisableLibraryPreload, "User")
            [Environment]::SetEnvironmentVariable("KICAD_SOFTWARE_RENDERING", $null, "User")
            $env:KICAD_APP_PATH = $kicadAppPath
            $env:KICAD_CLI_PATH = $kicadCliPath
            $env:KICAD_DISABLE_LIBRARY_PRELOAD = $kicadDisableLibraryPreload
            Remove-Item Env:KICAD_SOFTWARE_RENDERING -ErrorAction SilentlyContinue
            Write-Host "Creating SolderCAD desktop shortcut at $desktopShortcutPath"
            Set-SolderCadDesktopShortcut -ShortcutPath $desktopShortcutPath -TargetPath $kicadGuiPath
        } catch {
            throw "Solder $Version was installed, but user integration could not be configured: $($_.Exception.Message) Run the installer again to repair it."
        }
    }

    Write-Host ""
    Write-Host "Solder $Version installed."
    Write-Host "CLI:            $cliDestination"
    Write-Host "SolderCAD:      $solderCadDestination"
    if ($NoUserIntegration) {
        Write-Host "Existing user environment and desktop shortcut were not changed."
    } else {
        Write-Host "Desktop shortcut: $desktopShortcutPath"
        Write-Host "KICAD_APP_PATH: $kicadAppPath"
        Write-Host "KICAD_CLI_PATH: $kicadCliPath"
        Write-Host "KICAD_DISABLE_LIBRARY_PRELOAD: $kicadDisableLibraryPreload"
        Write-Host "KICAD_SOFTWARE_RENDERING: cleared"
        Write-Host "Open a new terminal before running solder if this is your first install."
    }
}
finally {
    $lease.Stop()
}
