[CmdletBinding()]
param(
    [string]$Version,
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA "Solder"),
    [ValidateSet("Auto", "GitHub")]
    [string]$DownloadSource = "Auto",
    [switch]$DryRun,
    [switch]$NoUserIntegration,
    [switch]$ManageLauncher,
    [switch]$RequireReopenRecords,
    [switch]$Launch,
    [switch]$Repair,
    [switch]$InteractiveUpdate,
    [string]$InstallerScriptPath,
    [string]$RelaunchExecutable,
    [string]$RelaunchProject,
    [int]$CallerProcessId,
    [long]$CallerWindowHandle,
    [switch]$InternalCoordinator,
    [switch]$InternalReopen,
    [object]$CoordinatorState
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Repo = "solderable/solder"
$InstallerSource = $MyInvocation.MyCommand.ScriptBlock.ToString()

function Fail {
    param([string]$Message)
    throw $Message
}

function Set-CoordinatorProgress {
    param([object]$State, [string]$Stage, [string]$Message)
    if ($null -eq $State) { return }
    $State.Stage = $Stage
    $State.Message = $Message
}

function Assert-CoordinatorNotCancelled {
    param([object]$State)
    if ($null -ne $State -and $State.CancelRequested) {
        throw [OperationCanceledException]::new('The update was cancelled.')
    }
}

function Save-SolderDownload {
    param([string]$Uri, [string]$Destination, [long]$Size, [object]$State)
    if ($null -eq $State) {
        $previousProgress = $ProgressPreference
        try {
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri $Uri -OutFile $Destination -TimeoutSec 1800 -Headers @{ "User-Agent" = "solder-installer" }
        } finally { $ProgressPreference = $previousProgress }
        return
    }
    Add-Type -AssemblyName System.Net.Http
    $client = New-Object Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromMinutes(30)
    $client.DefaultRequestHeaders.UserAgent.ParseAdd('solder-installer')
    $cancel = New-Object Threading.CancellationTokenSource
    $response = $null
    $inputStream = $null
    $outputStream = $null
    try {
        $request = $client.GetAsync($Uri, [Net.Http.HttpCompletionOption]::ResponseHeadersRead, $cancel.Token)
        while (-not $request.IsCompleted) {
            if ($State.CancelRequested) { $cancel.Cancel(); Assert-CoordinatorNotCancelled $State }
            Start-Sleep -Milliseconds 100
        }
        $response = $request.GetAwaiter().GetResult()
        [void]$response.EnsureSuccessStatusCode()
        $inputStream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $outputStream = [IO.File]::Open($Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $buffer = New-Object byte[] 65536
        $received = [long]0
        $totalTime = [Diagnostics.Stopwatch]::StartNew()
        while ($true) {
            Assert-CoordinatorNotCancelled $State
            $read = $inputStream.ReadAsync($buffer, 0, $buffer.Length, $cancel.Token)
            $idleTime = [Diagnostics.Stopwatch]::StartNew()
            while (-not $read.IsCompleted) {
                if ($State.CancelRequested) { $cancel.Cancel(); Assert-CoordinatorNotCancelled $State }
                if ($idleTime.ElapsedMilliseconds -ge 30000 -or $totalTime.ElapsedMilliseconds -ge 1800000) {
                    $cancel.Cancel()
                    throw [TimeoutException]::new('The update download timed out.')
                }
                Start-Sleep -Milliseconds 100
            }
            $count = $read.GetAwaiter().GetResult()
            if ($count -eq 0) { break }
            $received += $count
            if ($received -gt $Size) { Fail "The release download exceeds its advertised size." }
            $outputStream.Write($buffer, 0, $count)
            $percent = if ($Size -gt 0) { [Math]::Min(100, [int](100 * $received / $Size)) } else { 0 }
            Set-CoordinatorProgress $State 'downloading' "Downloading the update... $percent%"
        }
    } finally {
        if ($null -ne $outputStream) { $outputStream.Dispose() }
        if ($null -ne $inputStream) { $inputStream.Dispose() }
        if ($null -ne $response) { $response.Dispose() }
        $cancel.Dispose()
        $client.Dispose()
    }
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
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetHandleInformation(IntPtr handle, uint mask, uint flags);
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
    public static void PreventInheritance(IntPtr handle) {
      if (!SetHandleInformation(handle, 1, 0)) throw new Win32Exception(Marshal.GetLastWin32Error());
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
            $listeners.Add($listener)
            $listener.ExclusiveAddressUse = $true
            $listener.Start()
            # PowerShell 5.1 creates inheritable sockets. A reopened GUI child
            # must not keep this process lease alive after the worker exits.
            [SolderInstaller.NativePath]::PreventInheritance($listener.Server.Handle)
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

function Test-SolderProcessAlive {
    param([int]$ProcessId)
    try { $process = [Diagnostics.Process]::GetProcessById($ProcessId) }
    catch {
        if ($_.Exception -is [ArgumentException] -or $_.Exception.InnerException -is [ArgumentException]) { return $false }
        throw
    }
    try { return -not $process.HasExited } finally { $process.Dispose() }
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
                # CIM can return a partially cleared record for a process that
                # exits during enumeration. Distinguish that from a live,
                # uninspectable process before failing closed.
                $again = @(Get-CimInstance Win32_Process -Filter ("ProcessId = " + [int]$process.ProcessId) -ErrorAction Stop)
                if ($again.Count -eq 0) { continue }
                $process = $again[0]
                $path = $process.ExecutablePath
                if ([string]::IsNullOrWhiteSpace($path)) {
                    if (-not (Test-SolderProcessAlive ([int]$process.ProcessId))) { continue }
                    Fail "Cannot inspect a running Solder or KiCad process. Close it before installing."
                }
            } else {
                continue
            }
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
                $check = $false
                $json = $false
                $unknown = $false
                for ($i = 2; $i -lt $arguments.Length; $i++) {
                    if ($arguments[$i] -ceq '--check' -and -not $check) { $check = $true }
                    elseif ($arguments[$i] -ceq '--json' -and -not $json) { $json = $true }
                    else { $unknown = $true }
                }
                # Only the documented read-only check is known not to mutate.
                if (-not $check -or $unknown) {
                    Fail "Another Solder update is running. Wait for it to finish before installing."
                }
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
                $data.version -is [string] -and $data.version -match '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$') {
                $appVersion = $data.version
            }
        } catch { }
        if (-not $appVersion) { Write-Warning "The existing SolderCAD version is unknown. If installation proceeds, it will be replaced by the selected release." }
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
                if ($output -cmatch '^solder v(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?)$') { $cliVersion = $Matches[1] }
            }
        } catch { }
        finally { Remove-Item -LiteralPath $probe -Recurse -Force -ErrorAction SilentlyContinue }
        if (-not $cliVersion) { Write-Warning "The existing Solder CLI version is unknown. If installation proceeds, it will be replaced by the selected release." }
    } elseif ($hasApp) {
        Write-Warning "The Solder CLI is missing. It will be installed from the selected release."
    }
    return [pscustomobject]@{ App = $appVersion; Cli = $cliVersion }
}

function Assert-NoImplicitDowngrade {
    param([object]$Installed, [string]$Selected)
    $target = [version](($Selected -replace '^v', '').Split('-')[0])
    foreach ($component in @($Installed.App, $Installed.Cli)) {
        if ($component -and $component -match '^(\d+\.\d+\.\d+)') {
            if ([version]$Matches[1] -gt $target) {
                Fail "An installed component is newer than release $Selected. Nothing was changed. Specify -Version explicitly to install a different release."
            }
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

function Write-SolderAtomicRecord {
    param([string]$Path, [string]$Content)
    Assert-OrdinaryTarget $Path $false
    $replacement = $Path + '.' + [Guid]::NewGuid().ToString('N')
    Write-TransactionRecord $replacement $Content
    try {
        if (Test-Path -LiteralPath $Path) {
            # PowerShell 5.1 turns a null File.Replace backup into an invalid
            # empty path. A unique sibling keeps replacement atomic.
            $previous = $Path + '.previous-' + [Guid]::NewGuid().ToString('N')
            [IO.File]::Replace($replacement, $Path, $previous)
            try { [IO.File]::Delete($previous) } catch { Write-Warning "Previous repair record retained at '$previous'." }
        } else { [IO.File]::Move($replacement, $Path) }
    } finally { if (Test-Path -LiteralPath $replacement) { [IO.File]::Delete($replacement) } }
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

function Recover-SolderFailedPublication {
    param([string]$InstallRoot, [object[]]$Original, [string]$StageIdentity)
    $tx = Join-Path $InstallRoot '.solder-installer-transaction'
    $prepublication = $false
    if ($StageIdentity -and @($Original).Count -eq 3) {
        try {
            $owner = Join-Path $tx 'owner'
            Assert-OrdinaryTarget $owner $false
            $entries = @([IO.Directory]::EnumerateFileSystemEntries($tx) | ForEach-Object { [IO.Path]::GetFileName($_) })
            $current = @((Get-TargetIdentity (Join-Path $InstallRoot 'SolderCAD') $true),
                         (Get-TargetIdentity (Join-Path $InstallRoot 'bin\solder.exe') $false),
                         (Get-TargetIdentity (Join-Path $InstallRoot 'bin\SolderCAD') $true))
            if ((Get-TargetIdentity $tx $true) -ceq $StageIdentity -and
                (Test-Path -LiteralPath $owner -PathType Leaf) -and
                [IO.File]::ReadAllText($owner) -ceq 'solder-installer-transaction-v1' -and
                'journal.json' -notin $entries -and 'committed' -notin $entries -and
                $current[0] -ceq $Original[0] -and $current[1] -ceq $Original[1] -and $current[2] -ceq $Original[2]) {
                $prepublication = $true
            }
        } catch { }
    }
    # Before the journal exists, the same owned staging directory and the
    # unchanged live pair prove that no component was published. Cleaning that
    # staging tree is safe even if a new editor has just opened. All other
    # states retain the normal running-process guard before recovery.
    if (-not $prepublication) { Assert-SolderProcessesClosed -InstallRoot $InstallRoot }
    Recover-SolderTransaction -InstallRoot $InstallRoot
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

function Initialize-SolderWindowApi {
    if ("SolderInstaller.Windows" -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
namespace SolderInstaller {
  public static class Windows {
    private delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr parameter);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern bool IsWindow(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern IntPtr SendMessageTimeoutW(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam, uint flags, uint timeout, out IntPtr result);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern IntPtr GetPropW(IntPtr hwnd, string name);
    [DllImport("kernel32.dll", SetLastError=true)] private static extern bool GetNamedPipeServerProcessId(IntPtr pipe, out uint processId);
    [DllImport("kernel32.dll", SetLastError=true)] private static extern bool PeekNamedPipe(IntPtr pipe, IntPtr buffer, uint size, IntPtr read, out uint available, IntPtr remaining);
    [DllImport("kernel32.dll")] public static extern uint GetErrorMode();
    [DllImport("kernel32.dll")] public static extern uint SetErrorMode(uint mode);
    public static long[] TopLevelWindows(uint pid) {
      var result = new List<long>();
      EnumWindows((hwnd, unused) => {
        uint owner; GetWindowThreadProcessId(hwnd, out owner);
        if (owner == pid && IsWindowVisible(hwnd))
          result.Add(hwnd.ToInt64());
        return true;
      }, IntPtr.Zero);
      return result.ToArray();
    }
    public static long[] CapableWindows(uint pid) {
      var result = new List<long>();
      EnumWindows((hwnd, unused) => {
        uint owner; GetWindowThreadProcessId(hwnd, out owner);
        if (owner == pid && SupportsSafeClose(hwnd.ToInt64())) result.Add(hwnd.ToInt64());
        return true;
      }, IntPtr.Zero);
      return result.ToArray();
    }
    public static uint Owner(long handle) {
      uint owner; GetWindowThreadProcessId(new IntPtr(handle), out owner); return owner;
    }
    public static bool Exists(long handle) { return IsWindow(new IntPtr(handle)); }
    public static bool SupportsSafeClose(long handle) {
      return GetPropW(new IntPtr(handle), "SolderCAD.UpdateCloseProtocol.v1") == new IntPtr(1);
    }
    // A responsive native save dialog may take as long as the user needs.
    // Abort if the window stops responding; never force-close the process.
    public static bool RequestClose(long handle) {
      IntPtr result;
      return SendMessageTimeoutW(new IntPtr(handle), 0x0010, IntPtr.Zero, IntPtr.Zero, 0x000B, 5000, out result) != IntPtr.Zero;
    }
    public static uint PipeOwner(IntPtr handle) {
      uint pid;
      if (!GetNamedPipeServerProcessId(handle, out pid)) throw new System.ComponentModel.Win32Exception();
      return pid;
    }
    public static bool PipeReady(IntPtr handle) {
      uint available;
      return PeekNamedPipe(handle, IntPtr.Zero, 0, IntPtr.Zero, out available, IntPtr.Zero) && available == 0;
    }
  }
}
'@
}

function Get-SolderGuiProcesses {
    param([string]$InstallRoot)
    $app = (Join-Path $InstallRoot 'SolderCAD').TrimEnd('\') + '\'
    $names = @('kicad.exe', 'eeschema.exe', 'pcbnew.exe', 'gerbview.exe', 'pcb_calculator.exe', 'pl_editor.exe', 'bitmap2component.exe')
    $result = New-Object 'System.Collections.Generic.List[object]'
    foreach ($process in @(Get-CimInstance Win32_Process -ErrorAction Stop)) {
        if ($process.Name -notin $names) { continue }
        if ([string]::IsNullOrWhiteSpace($process.ExecutablePath)) {
            $again = @(Get-CimInstance Win32_Process -Filter ("ProcessId = " + [int]$process.ProcessId) -ErrorAction Stop)
            if ($again.Count -eq 0) { continue }
            $process = $again[0]
            if ([string]::IsNullOrWhiteSpace($process.ExecutablePath)) {
                if (-not (Test-SolderProcessAlive ([int]$process.ProcessId))) { continue }
                Fail "A running SolderCAD window could not be inspected. Close it and retry."
            }
        }
        $path = Resolve-PhysicalPath $process.ExecutablePath
        if ($path.StartsWith($app, [StringComparison]::OrdinalIgnoreCase)) {
            $result.Add([pscustomobject]@{ Id = [int]$process.ProcessId; Path = $path; CommandLine = $process.CommandLine; Created = $process.CreationDate })
        }
    }
    return $result.ToArray()
}

function Test-SolderProcessInstance {
    param([object]$Captured)
    $current = @(Get-CimInstance Win32_Process -Filter ("ProcessId = " + [int]$Captured.Id) -ErrorAction Stop)
    if ($current.Count -eq 0) { return $false }
    if ($current.Count -ne 1 -or $current[0].CreationDate -ne $Captured.Created -or
        [string]::IsNullOrWhiteSpace($current[0].ExecutablePath) -or
        -not (Resolve-PhysicalPath $current[0].ExecutablePath).Equals($Captured.Path, [StringComparison]::OrdinalIgnoreCase)) {
        if (-not (Test-SolderProcessAlive $Captured.Id)) { return $false }
        Fail "A Solder process changed while preparing the update. Retry."
    }
    return $true
}

function Assert-SolderReopenSession {
    param([object]$State)
    if ($null -eq $State.Session -or
        (Get-TargetIdentity $State.Session.Request $false) -cne $State.Session.RequestIdentity) {
        Fail 'The update session changed unexpectedly. No further windows were closed; recovery records were preserved.'
    }
}

function New-SolderReopenSession {
    param([string]$InstallRoot, [object]$State, [bool]$RequireNative = $false)
    $request = Join-Path $InstallRoot '.solder-update-reopen-request.json'
    if (@([IO.Directory]::EnumerateFileSystemEntries($InstallRoot, '.solder-update-reopen-request.json')).Count -ne 0) {
        Assert-OrdinaryTarget $request $false
        try {
            $previous = Get-Content -LiteralPath $request -Raw | ConvertFrom-Json
            if ($previous.schemaVersion -ne 1 -or $previous.component -cne 'soldercad-update' -or
                $previous.nonce -cnotmatch '\A[0-9a-f]{32}\z' -or $previous.coordinatorStartTime -cnotmatch '\A[0-9]+\z') { throw 'invalid' }
            $previousProcess = Get-Process -Id ([int]$previous.coordinatorPid) -ErrorAction SilentlyContinue
            if ($null -ne $previousProcess -and $previousProcess.StartTime.ToUniversalTime().ToFileTimeUtc().ToString() -ceq $previous.coordinatorStartTime) {
                Fail 'Another SolderCAD update is already closing windows. Wait for it to finish.'
            }
        } catch {
            if ($_.Exception.Message -like 'Another SolderCAD*') { throw }
            Fail 'An unrecognized update session was preserved. SolderCAD was not closed.'
        }
        $stale = Join-Path $InstallRoot ('.solder-update-reopen-request-previous-' + [Guid]::NewGuid().ToString('N') + '.json')
        [IO.File]::Move($request, $stale)
        Write-Warning "A previous update session was preserved at '$stale'."
    }
    $nonce = [Guid]::NewGuid().ToString('N')
    $directory = Join-Path $InstallRoot ('.solder-update-reopen-' + $nonce)
    New-Item -ItemType Directory -Path $directory | Out-Null
    $record = [ordered]@{ schemaVersion=1; component='soldercad-update'; nonce=$nonce; coordinatorPid=$PID;
                          coordinatorStartTime=([Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().ToFileTimeUtc().ToString()) } | ConvertTo-Json -Compress
    try { Write-TransactionRecord -Path $request -Content $record }
    catch { [IO.Directory]::Delete($directory); throw }
    $State.Session = [pscustomobject]@{ Nonce=$nonce; InstallRoot=$InstallRoot; Directory=$directory; Request=$request;
        RequestIdentity=(Get-TargetIdentity $request $false); RequireNative=$RequireNative; Processes=@(); CliProcesses=(New-Object 'System.Collections.Generic.List[object]'); Windows=(New-Object 'System.Collections.Generic.List[object]');
        Opened=(New-Object 'System.Collections.Generic.HashSet[string]'); RecordIdentities=@{} }
}

function Get-SolderReopenEntry {
    param([object]$Session, [object]$Window, [string]$CallerProject, [int]$CallerPid, [bool]$Required)
    $recordPath = Join-Path $Session.Directory ("$($Window.Process.Id)-$($Window.Handle).json")
    if (Test-Path -LiteralPath $recordPath -PathType Leaf) {
        Assert-OrdinaryTarget $recordPath $false
        $file = Get-Item -LiteralPath $recordPath -Force
        if ($file.Length -gt 16384) { Fail 'An update reopen record is too large. Recovery files were preserved.' }
        # Native reopen records are UTF-8; Windows PowerShell 5.1's default
        # Get-Content encoding is the active ANSI code page, not UTF-8.
        $record = [IO.File]::ReadAllText($recordPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        if ($record.schemaVersion -ne 1 -or $record.nonce -cne $Session.Nonce -or
            $record.pid -ne $Window.Process.Id -or [string]$record.hwnd -cne [string]$Window.Handle -or
            $record.executable -isnot [string] -or $record.project -isnot [string] -or $record.frameType -cnotin @('manager', 'schematic', 'pcb') -or
            -not ([IO.Path]::GetFullPath($record.executable)).Equals($Window.Process.Path, [StringComparison]::OrdinalIgnoreCase)) {
            Fail 'An update reopen record could not be verified. Recovery files were preserved.'
        }
        $target = switch -CaseSensitive ($record.frameType) {
            'manager' { @{ Exe='kicad.exe'; Extension='.kicad_pro' } }
            'schematic' { @{ Exe='eeschema.exe'; Extension='.kicad_sch' } }
            'pcb' { @{ Exe='pcbnew.exe'; Extension='.kicad_pcb' } }
        }
        if ($record.project) {
            if ([IO.Path]::GetExtension($record.project).ToLowerInvariant() -cne $target.Extension -or
                -not [IO.Path]::IsPathRooted($record.project) -or -not (Test-Path -LiteralPath $record.project -PathType Leaf)) {
                Fail 'A saved SolderCAD document is unavailable or does not match its window. Recovery files were preserved.'
            }
        }
        $Session.RecordIdentities[$recordPath] = Get-TargetIdentity $recordPath $false
        return [pscustomobject]@{ Key=$recordPath; Executable=(Join-Path $Session.InstallRoot ('SolderCAD\bin\' + $target.Exe)); Project=$record.project }
    }
    if ($Required) { Fail 'A closed SolderCAD window did not provide its saved document. Recovery files were preserved.' }
    $project = ''
    if ($Window.Process.Id -eq $CallerPid -and $CallerProject) { $project = $CallerProject }
    elseif ($Window.Process.CommandLine) {
        foreach ($arg in @([SolderInstaller.NativePath]::SplitCommandLine($Window.Process.CommandLine))) {
            if ([IO.Path]::IsPathRooted($arg) -and [IO.Path]::GetExtension($arg).ToLowerInvariant() -in @('.kicad_pro', '.kicad_sch', '.kicad_pcb') -and
                (Test-Path -LiteralPath $arg -PathType Leaf)) { $project = $arg; break }
        }
    }
    return [pscustomobject]@{ Key=('legacy-' + $Window.Process.Id); Executable=$Window.Process.Path; Project=$project }
}

function Assert-SolderClosedWindowRecords {
    param([object]$State, [string]$CallerProject, [int]$CallerPid)
    Assert-SolderReopenSession $State
    foreach ($window in $State.Session.Windows) {
        if ([SolderInstaller.Windows]::Exists($window.Handle) -and [SolderInstaller.Windows]::Owner($window.Handle) -eq $window.Process.Id) {
            Fail 'A SolderCAD window is still closing. Retry when it has finished.'
        }
        [void](Get-SolderReopenEntry $State.Session $window $CallerProject $CallerPid $true)
    }
    # Manager-owned hidden children may not have appeared among visible windows.
    # Validate their records too, before the paired installation is published.
    foreach ($file in @(Get-ChildItem -LiteralPath $State.Session.Directory -File -Force -Filter '*.json')) {
        if ($file.Name -cmatch '\Acli-[0-9]+\.json\z') { continue }
        if ($file.Name -cnotmatch '\A([0-9]+)-([0-9]+)\.json\z') { Fail 'An unrecognized update reopen record was preserved.' }
        $processId = [int]$Matches[1]; $handle = [long]$Matches[2]
        $process = @($State.Session.Processes | Where-Object { $_.Id -eq $processId })
        if ($process.Count -ne 1 -or $handle -le 0) { Fail 'An update reopen record names an unknown window. Recovery files were preserved.' }
        [void](Get-SolderReopenEntry $State.Session ([pscustomobject]@{Handle=$handle; Process=$process[0]}) $CallerProject $CallerPid $true)
    }
}

function Open-SolderReopenSession {
    param([string]$InstallRoot, [object]$State, [string]$CallerProject, [int]$CallerPid, [bool]$Required)
    if ($null -eq $State.Session) { return }
    Assert-OrdinaryTarget $State.Session.Directory $true
    foreach ($file in @(Get-ChildItem -LiteralPath $State.Session.Directory -File -Force -Filter '*.json')) {
        if ($file.Name -cmatch '\Acli-[0-9]+\.json\z') { continue }
        if ($file.Name -cnotmatch '\A([0-9]+)-([0-9]+)\.json\z') { Fail 'An unrecognized update reopen record was preserved.' }
        $processId = [int]$Matches[1]
        $handle = [long]$Matches[2]
        $process = @($State.Session.Processes | Where-Object { $_.Id -eq $processId })
        if ($process.Count -ne 1 -or $handle -le 0) { Fail 'An update reopen record names an unknown window. Recovery files were preserved.' }
        if (@($State.Session.Windows | Where-Object { $_.Handle -eq $handle -and $_.Process.Id -eq $processId }).Count -eq 0) {
            $State.Session.Windows.Add([pscustomobject]@{ Handle=$handle; Process=$process[0]; ExpectedRecord=$true })
        }
    }
    foreach ($window in $State.Session.Windows) {
        if ([SolderInstaller.Windows]::Exists($window.Handle) -and [SolderInstaller.Windows]::Owner($window.Handle) -eq $window.Process.Id) { continue }
        # Native EDA frames guarantee records themselves; auxiliary top-level
        # windows may not be EDA frames. Require only the initiating frame.
        $mustHaveRecord = $Required -and $window.ExpectedRecord
        $recordPath = Join-Path $State.Session.Directory ("$($window.Process.Id)-$($window.Handle).json")
        if ($State.Session.RequireNative -and -not $mustHaveRecord -and -not (Test-Path -LiteralPath $recordPath -PathType Leaf) -and
            $window.Handle -ne $State.Session.CallerWindow) { continue }
        $entry = Get-SolderReopenEntry $State.Session $window $CallerProject $CallerPid $mustHaveRecord
        if ($State.Session.Opened.Contains($entry.Key)) { continue }
        Open-SolderAfterUpdate -InstallRoot $InstallRoot -Executable $entry.Executable -Project $entry.Project
        [void]$State.Session.Opened.Add($entry.Key)
        $callerWindow = $State.Session.PSObject.Properties['CallerWindow']
        if ($CallerPid -gt 0 -and $null -ne $callerWindow -and $window.Process.Id -eq $CallerPid -and
            $window.Handle -eq $callerWindow.Value -and $entry.Key -ceq $recordPath) {
            # Persist across Retry: the restored caller gets a new PID, and a
            # Save As record can differ from the original launch argument.
            $State.CallerReopened = $true
        }
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $State.Session.Directory -File -Force -Filter 'cli-*.json')) {
        if ($file.Name -cnotmatch '\Acli-([0-9]+)\.json\z') { Fail 'An unrecognized terminal recovery record was preserved.' }
        $pidValue = [int]$Matches[1]
        $captured = @($State.Session.CliProcesses | Where-Object { $_.Id -eq $pidValue })
        if ($captured.Count -ne 1) { Fail 'A terminal recovery record names an unknown process. Recovery files were preserved.' }
        Assert-OrdinaryTarget $file.FullName $false
        if ($file.Length -gt 16384) { Fail 'A terminal recovery record is too large. Recovery files were preserved.' }
        $record = [IO.File]::ReadAllText($file.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json
        if ($record.schemaVersion -ne 1 -or $record.nonce -cne $State.Session.Nonce -or $record.pid -ne $pidValue -or
            $record.kind -cne 'cli' -or $record.executable -isnot [string] -or $record.projectDir -isnot [string] -or
            $record.conversationId -isnot [string] -or $record.conversationId -cnotmatch '\A[A-Za-z0-9_-]{1,128}\z' -or
            -not ([IO.Path]::GetFullPath($record.executable)).Equals($captured[0].Path, [StringComparison]::OrdinalIgnoreCase)) {
            Fail 'A terminal recovery record could not be verified. Recovery files were preserved.'
        }
        $workingDirectory = Resolve-PhysicalPath ([IO.Path]::GetFullPath($record.projectDir))
        if (-not (Test-Path -LiteralPath $workingDirectory -PathType Container)) { Fail 'A saved terminal project is not available.' }
        $arguments = New-Object 'System.Collections.Generic.List[string]'
        $board = Get-ReleaseProperty $record 'boardPath'
        if ($board) {
            if ($board -isnot [string] -or [IO.Path]::GetExtension($board).ToLowerInvariant() -cne '.kicad_pcb' -or
                -not (Test-Path -LiteralPath $board -PathType Leaf)) { Fail 'A saved terminal board is not available.' }
            $arguments.Add('pcb'); $arguments.Add('--board'); $arguments.Add((Quote-SolderArgument ([IO.Path]::GetFullPath($board))))
        }
        $url = Get-ReleaseProperty $record 'url'
        if ($url) {
            if ($url -isnot [string] -or $url.Length -gt 2048) { Fail 'A terminal endpoint could not be verified.' }
            $uri = $null
            if (-not [Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin @('http', 'https', 'ws', 'wss') -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) {
                Fail 'A terminal endpoint could not be verified.'
            }
            $arguments.Add('--url'); $arguments.Add((Quote-SolderArgument $url))
        }
        $arguments.Add('--resume'); $arguments.Add((Quote-SolderArgument $record.conversationId))
        $State.Session.RecordIdentities[$file.FullName] = Get-TargetIdentity $file.FullName $false
        if ($State.Session.Opened.Contains($file.FullName)) { continue }
        # A cancelled prepare may have persisted a record before the original
        # process decided to remain open. Never start a second live session.
        if (Test-SolderProcessInstance $captured[0]) { continue }
        $process = Start-Process -FilePath $captured[0].Path -ArgumentList ($arguments -join ' ') -WorkingDirectory $workingDirectory -PassThru
        [void]$process.Handle
        if ($process.WaitForExit(2000)) {
            $process.Refresh()
            if ($process.ExitCode -ne 0) { Fail 'A saved Solder terminal could not reopen. Choose Retry.' }
        }
        [void]$State.Session.Opened.Add($file.FullName)
    }
}

function Complete-SolderReopenSession {
    param([object]$State)
    if ($null -eq $State.Session) { return }
    $session = $State.Session
    if ((Get-TargetIdentity $session.Request $false) -cne $session.RequestIdentity) {
        Fail 'The update session changed unexpectedly. Recovery files were preserved.'
    }
    foreach ($path in @($session.RecordIdentities.Keys)) {
        try {
            if ($session.Opened.Contains($path) -and (Get-TargetIdentity $path $false) -ceq $session.RecordIdentities[$path]) {
                [IO.File]::Delete($path)
            }
        } catch { Write-Warning 'An update reopen record could not be cleaned and was preserved.' }
    }
    [IO.File]::Delete($session.Request)
    # Unknown files survive; never recursively clean an unrecognized record.
    try { [IO.Directory]::Delete($session.Directory, $false) } catch { }
}

function Quote-SolderArgument {
    param([string]$Value)
    # CommandLineToArgvW's inverse for one argument, including trailing slashes.
    $result = New-Object Text.StringBuilder
    [void]$result.Append('"')
    $slashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') { $slashes++; continue }
        if ($character -eq '"') {
            [void]$result.Append(('\' * (2 * $slashes + 1)))
            [void]$result.Append('"')
        } else {
            [void]$result.Append(('\' * $slashes))
            [void]$result.Append($character)
        }
        $slashes = 0
    }
    [void]$result.Append(('\' * (2 * $slashes)))
    [void]$result.Append('"')
    return $result.ToString()
}

function Start-SolderGuiProcess {
    param([string]$Executable, [string]$WorkingDirectory, [string]$Project)
    Initialize-SolderWindowApi
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $Executable
    $start.WorkingDirectory = $WorkingDirectory
    $start.UseShellExecute = $false
    if ($Project) { $start.Arguments = Quote-SolderArgument $Project }
    # A missing dependent DLL can display a Windows loader dialog indefinitely.
    # With CreateProcess and an inherited error mode, the child exits instead;
    # the launcher can then start the repair coordinator without hiding work.
    $previous = [SolderInstaller.Windows]::GetErrorMode()
    [void][SolderInstaller.Windows]::SetErrorMode($previous -bor 0x8003)
    try { $process = [Diagnostics.Process]::Start($start) }
    finally { [void][SolderInstaller.Windows]::SetErrorMode($previous) }
    [void]$process.Handle
    return $process
}

function Open-SolderAfterUpdate {
    param([string]$InstallRoot, [string]$Executable, [string]$Project)
    if ([string]::IsNullOrWhiteSpace($Executable)) { return }
    $app = (Join-Path $InstallRoot 'SolderCAD').TrimEnd('\') + '\'
    $executablePath = [IO.Path]::GetFullPath($Executable)
    if ($Project) {
        $extension = [IO.Path]::GetExtension($Project).ToLowerInvariant()
        $name = switch ($extension) {
            '.kicad_pro' { 'kicad.exe' }
            '.kicad_sch' { 'eeschema.exe' }
            '.kicad_pcb' { 'pcbnew.exe' }
            default { Fail 'The saved SolderCAD document type cannot be reopened automatically.' }
        }
        $executablePath = Join-Path (Join-Path $InstallRoot 'SolderCAD\bin') $name
    }
    if (-not $executablePath.StartsWith($app, [StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-Path -LiteralPath $executablePath -PathType Leaf)) {
        Fail "SolderCAD was installed, but its previous executable could not be reopened."
    }
    $projectPath = ''
    if ($Project) {
        $projectPath = [IO.Path]::GetFullPath($Project)
        if ([IO.Path]::GetExtension($projectPath).ToLowerInvariant() -notin @('.kicad_pro', '.kicad_sch', '.kicad_pcb') -or
            -not (Test-Path -LiteralPath $projectPath -PathType Leaf)) {
            Fail "SolderCAD was installed, but the previous project could not be reopened."
        }
    }
    $process = Start-SolderGuiProcess -Executable $executablePath -WorkingDirectory ([IO.Path]::GetDirectoryName($executablePath)) -Project $projectPath
    if ($process.WaitForExit(2000)) {
        $process.Refresh()
        if ($process.ExitCode -ne 0) { Fail "SolderCAD could not start after the update. Retry opening it." }
    }
}

function Close-SolderForUpdate {
    param([string]$InstallRoot, [object]$State, [int]$CallerPid, [long]$CallerWindow, [object]$Held)
    Initialize-SolderWindowApi
    if ($State.CallerReopened) { $CallerPid = 0; $CallerWindow = 0 }
    $processes = @(Get-SolderGuiProcesses $InstallRoot)
    $State.Session.Processes = $processes
    $State.Session | Add-Member -NotePropertyName CallerWindow -NotePropertyValue $CallerWindow
    if ($CallerPid -gt 0) {
        $caller = @($processes | Where-Object { $_.Id -eq $CallerPid })
        $owner = if ($CallerWindow -gt 0) { [SolderInstaller.Windows]::Owner($CallerWindow) } else { 0 }
        if (($caller.Count -eq 0 -and $owner -ne 0) -or
            ($caller.Count -eq 1 -and $owner -ne 0 -and $owner -ne $CallerPid) -or $caller.Count -gt 1) {
            Fail "The SolderCAD window changed while preparing the update. Retry."
        }
    }
    $windows = New-Object 'System.Collections.Generic.List[long]'
    if ($CallerWindow -gt 0 -and [SolderInstaller.Windows]::Exists($CallerWindow)) { $windows.Add($CallerWindow) }
    foreach ($process in $processes) {
        $capable = @([SolderInstaller.Windows]::CapableWindows($process.Id))
        if ($capable.Count -eq 0 -and (Test-SolderProcessInstance $process)) {
            Fail 'An older SolderCAD window cannot preserve its work automatically. Save and close that window, then choose Retry.'
        }
        foreach ($handle in $capable) {
            if (@($State.Session.Windows | Where-Object { $_.Handle -eq $handle -and $_.Process.Id -eq $process.Id }).Count -eq 0) {
                $State.Session.Windows.Add([pscustomobject]@{ Handle=$handle; Process=$process; ExpectedRecord=$true })
            }
        }
        foreach ($handle in @([SolderInstaller.Windows]::TopLevelWindows($process.Id))) {
            if (-not $windows.Contains($handle)) { $windows.Add($handle) }
        }
    }
    foreach ($handle in $windows) {
        $owner = [SolderInstaller.Windows]::Owner($handle)
        $matches = @($processes | Where-Object { $_.Id -eq $owner })
        if ($matches.Count -eq 1 -and @($State.Session.Windows | Where-Object { $_.Handle -eq $handle -and $_.Process.Id -eq $owner }).Count -eq 0) {
            $State.Session.Windows.Add([pscustomobject]@{ Handle=$handle; Process=$matches[0]; ExpectedRecord=$true })
        }
    }
    # Require capability for every captured top-level window before closing
    # any of them. Older windows cannot checkpoint unsent chat or Save As.
    foreach ($window in $State.Session.Windows) {
        if ([SolderInstaller.Windows]::Exists($window.Handle) -and
            (-not (Test-SolderProcessInstance $window.Process) -or
             [SolderInstaller.Windows]::Owner($window.Handle) -ne $window.Process.Id -or
             -not [SolderInstaller.Windows]::SupportsSafeClose($window.Handle))) {
            Fail 'An older SolderCAD window cannot preserve its work automatically. Save and close that window, then choose Retry.'
        }
    }
    foreach ($handle in $windows) {
        Assert-CoordinatorNotCancelled $State
        Assert-SolderReopenSession $State
        if (-not [SolderInstaller.Windows]::Exists($handle)) { continue }
        $owner = [SolderInstaller.Windows]::Owner($handle)
        $matches = @($processes | Where-Object { $_.Id -eq $owner })
        if ($matches.Count -ne 1 -or -not (Test-SolderProcessInstance $matches[0])) {
            Fail "A SolderCAD window changed while preparing the update. Retry."
        }
        Assert-SolderPreparedHosts -Held $Held -State $State
        Set-CoordinatorProgress $State 'closing' 'Save your work if SolderCAD asks. Select Cancel there to stop the update.'
        # Synchronous WM_CLOSE runs on the worker, not the progress UI. Native
        # save dialogs remain responsive; a veto leaves the window alive.
        $responded = [SolderInstaller.Windows]::RequestClose($handle)
        $grace = [Diagnostics.Stopwatch]::StartNew()
        while ([SolderInstaller.Windows]::Exists($handle) -and $grace.ElapsedMilliseconds -lt 3000) {
            Start-Sleep -Milliseconds 100
        }
        $closed = -not [SolderInstaller.Windows]::Exists($handle)
        if ($closed) { $State.ClosedAny = $true }
        Assert-CoordinatorNotCancelled $State
        Assert-SolderReopenSession $State
        if (-not $responded) {
            Fail "A SolderCAD window is not responding. The update did not proceed; wait for it to respond before retrying."
        }
        if (-not $closed) {
            throw [OperationCanceledException]::new('The update was cancelled in SolderCAD.')
        }
    }
    for ($i = 0; $i -lt 100; $i++) {
        Assert-CoordinatorNotCancelled $State
        foreach ($process in $processes) { [void](Test-SolderProcessInstance $process) }
        if (@(Get-SolderGuiProcesses $InstallRoot).Count -eq 0) { return }
        Start-Sleep -Milliseconds 200
    }
    Fail "SolderCAD is still closing. Please retry once its windows have closed."
}

function Close-SolderTerminalsForUpdate {
    param([string]$InstallRoot, [object]$State)
    Initialize-SolderWindowApi
    $target = Join-Path $InstallRoot 'bin\solder.exe'
    foreach ($entry in @(Get-CimInstance Win32_Process -Filter "Name = 'solder.exe'" -ErrorAction Stop)) {
        Assert-CoordinatorNotCancelled $State
        if ([string]::IsNullOrWhiteSpace($entry.ExecutablePath)) {
            $again = @(Get-CimInstance Win32_Process -Filter ("ProcessId = " + [int]$entry.ProcessId) -ErrorAction Stop)
            if ($again.Count -eq 0 -or -not (Test-SolderProcessAlive ([int]$entry.ProcessId))) { continue }
            $entry = $again[0]
            if ([string]::IsNullOrWhiteSpace($entry.ExecutablePath)) { Fail 'A Solder terminal could not be inspected. Close it and retry.' }
        }
        $path = Resolve-PhysicalPath $entry.ExecutablePath
        if (-not $path.Equals($target, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $captured = [pscustomobject]@{ Id=[int]$entry.ProcessId; Path=$path; Created=$entry.CreationDate }
        if (-not (Test-SolderProcessInstance $captured)) { continue }
        $commandArguments = @(if ($entry.CommandLine) { [SolderInstaller.NativePath]::SplitCommandLine($entry.CommandLine) })
        if ($commandArguments.Length -le 1 -or $commandArguments[1] -cne 'ui-host') {
            $State.Session.CliProcesses.Add($captured)
        }
        try { $process = [Diagnostics.Process]::GetProcessById($captured.Id); [void]$process.Handle }
        catch { if (-not (Test-SolderProcessInstance $captured)) { continue }; throw }
        $pipe = New-Object IO.Pipes.NamedPipeClientStream '.', ("solder-update-shutdown-v1-" + $captured.Id), ([IO.Pipes.PipeDirection]::InOut), ([IO.Pipes.PipeOptions]::Asynchronous)
        try {
            Set-CoordinatorProgress $State 'closing' 'Closing Solder terminal sessions safely...'
            try { $pipe.Connect(2000) }
            catch {
                $arguments = @(if ($entry.CommandLine) { [SolderInstaller.NativePath]::SplitCommandLine($entry.CommandLine) })
                if ($arguments.Length -gt 1 -and $arguments[1] -ceq 'ui-host') {
                    Set-CoordinatorProgress $State 'closing' 'Waiting for the SolderCAD chat session to finish saving...'
                    $wait = [Diagnostics.Stopwatch]::StartNew()
                    while (-not $process.WaitForExit(100) -and $wait.ElapsedMilliseconds -lt 75000) {
                        Assert-CoordinatorNotCancelled $State
                        [void](Test-SolderProcessInstance $captured)
                    }
                    if ($process.HasExited) { continue }
                    Fail 'The SolderCAD chat session is still finishing. Wait for it to close and choose Retry.'
                }
                Fail 'A Solder terminal cannot close automatically. Close that Solder session and choose Retry.'
            }
            if ([SolderInstaller.Windows]::PipeOwner($pipe.SafePipeHandle.DangerousGetHandle()) -ne $captured.Id -or
                -not (Test-SolderProcessInstance $captured)) {
                Fail 'A Solder terminal changed while preparing the update. Retry.'
            }
            $request = [Text.Encoding]::ASCII.GetBytes("shutdown`n")
            $pipe.Write($request, 0, $request.Length)
            $pipe.Flush()
            $reply = New-Object byte[] 8
            $deadline = [Diagnostics.Stopwatch]::StartNew()
            $received = 0
            while ($received -lt $reply.Length -and $deadline.ElapsedMilliseconds -lt 120000) {
                $read = $pipe.ReadAsync($reply, $received, $reply.Length - $received)
                while (-not $read.IsCompleted -and $deadline.ElapsedMilliseconds -lt 120000) {
                    Assert-CoordinatorNotCancelled $State
                    Start-Sleep -Milliseconds 100
                }
                if (-not $read.IsCompleted) { break }
                $count = $read.GetAwaiter().GetResult()
                if ($count -le 0) { break }
                $received += $count
            }
            if ($received -ne 8 -or [Text.Encoding]::ASCII.GetString($reply) -cne "closing`n") {
                Fail 'A Solder terminal did not confirm a safe shutdown. Close that Solder session and choose Retry.'
            }
            $deadline.Restart()
            while (-not $process.WaitForExit(100) -and $deadline.ElapsedMilliseconds -lt 75000) {
                Assert-CoordinatorNotCancelled $State
                [void](Test-SolderProcessInstance $captured)
            }
            if (-not $process.HasExited) { Fail 'A Solder terminal is still closing. Wait for it to finish and choose Retry.' }
        } finally { $pipe.Dispose(); $process.Dispose() }
    }
}

function Read-SolderControlReply {
    param([object]$Pipe, [object]$State)
    $bytes = New-Object 'System.Collections.Generic.List[byte]'
    $deadline = [Diagnostics.Stopwatch]::StartNew()
    while ($bytes.Count -lt 16 -and $deadline.ElapsedMilliseconds -lt 120000) {
        $buffer = New-Object byte[] 1
        $read = $Pipe.ReadAsync($buffer, 0, 1)
        while (-not $read.IsCompleted -and $deadline.ElapsedMilliseconds -lt 120000) {
            Assert-CoordinatorNotCancelled $State
            Start-Sleep -Milliseconds 100
        }
        if (-not $read.IsCompleted) { break }
        if ($read.GetAwaiter().GetResult() -ne 1) { return $null }
        $bytes.Add($buffer[0])
        if ($buffer[0] -eq 10) { return [Text.Encoding]::ASCII.GetString($bytes.ToArray()) }
    }
    Fail 'A SolderCAD chat session could not confirm that its work was saved. No editor was closed.'
}

function Open-SolderPreparedHosts {
    param([string]$InstallRoot, [object]$State)
    Initialize-SolderWindowApi
    $target = Join-Path $InstallRoot 'bin\solder.exe'
    $held = New-Object 'System.Collections.Generic.List[object]'
    try {
        foreach ($entry in @(Get-CimInstance Win32_Process -Filter "Name = 'solder.exe'" -ErrorAction Stop)) {
            Assert-CoordinatorNotCancelled $State
            if ([string]::IsNullOrWhiteSpace($entry.ExecutablePath)) {
                $again = @(Get-CimInstance Win32_Process -Filter ("ProcessId = " + [int]$entry.ProcessId) -ErrorAction Stop)
                if ($again.Count -eq 0 -or -not (Test-SolderProcessAlive ([int]$entry.ProcessId))) { continue }
                $entry = $again[0]
                if ([string]::IsNullOrWhiteSpace($entry.ExecutablePath)) { Fail 'A Solder session could not be inspected.' }
            }
            $path = Resolve-PhysicalPath $entry.ExecutablePath
            if (-not $path.Equals($target, [StringComparison]::OrdinalIgnoreCase)) { continue }
            $arguments = @(if ($entry.CommandLine) { [SolderInstaller.NativePath]::SplitCommandLine($entry.CommandLine) })
            if ($arguments.Length -le 1 -or $arguments[1] -cne 'ui-host') { continue }
            $captured = [pscustomobject]@{ Id=[int]$entry.ProcessId; Path=$path; Created=$entry.CreationDate }
            if (-not (Test-SolderProcessInstance $captured)) { continue }
            $pipe = New-Object IO.Pipes.NamedPipeClientStream '.', ("solder-update-shutdown-v1-" + $captured.Id), ([IO.Pipes.PipeDirection]::InOut), ([IO.Pipes.PipeOptions]::Asynchronous)
            try {
                try { $pipe.Connect(2000) }
                catch {
                    if (-not (Test-SolderProcessInstance $captured)) { $pipe.Dispose(); continue }
                    Fail 'This older SolderCAD chat cannot save its current draft automatically. Close its editor after saving your work, then choose Retry.'
                }
                if ([SolderInstaller.Windows]::PipeOwner($pipe.SafePipeHandle.DangerousGetHandle()) -ne $captured.Id -or
                    -not (Test-SolderProcessInstance $captured)) { Fail 'A SolderCAD chat session changed while preparing the update.' }
                Set-CoordinatorProgress $State 'closing' 'Saving SolderCAD chat sessions...'
                $request = [Text.Encoding]::ASCII.GetBytes("prepare $($State.Session.Nonce)`n")
                $pipe.Write($request, 0, $request.Length)
                $pipe.Flush()
                $reply = Read-SolderControlReply $pipe $State
                if ($reply -ceq "blocked`n") {
                    Set-CoordinatorProgress $State 'chat-busy' 'Let Solder Chat finish, or stop its current and queued work. Answer any open question, then choose Retry.'
                    Fail 'Solder Chat is still working. Your windows remain open.'
                }
                if ($reply -cne "ready`n") {
                    Fail 'A SolderCAD chat session could not save its draft. No editor was closed.'
                }
                $process = [Diagnostics.Process]::GetProcessById($captured.Id)
                [void]$process.Handle
                $held.Add([pscustomobject]@{ Pipe=$pipe; Process=$process; Captured=$captured; Drained=$false })
            } catch { $pipe.Dispose(); throw }
        }
        return ,$held
    } catch {
        foreach ($hostSession in $held) { $hostSession.Pipe.Dispose(); $hostSession.Process.Dispose() }
        throw
    }
}

function Assert-SolderPreparedHosts {
    param([object]$Held, [object]$State)
    foreach ($hostSession in $Held) {
        Assert-CoordinatorNotCancelled $State
        if ($hostSession.Drained) { continue }
        if ([SolderInstaller.Windows]::PipeReady($hostSession.Pipe.SafePipeHandle.DangerousGetHandle())) { continue }
        # A prepared host may disconnect because an earlier editor has closed.
        # Before any close that is never safe to assume; after a close, only
        # accept it once the exact captured host has fully drained and exited.
        if (-not $State.ClosedAny) { Fail 'Solder Chat changed while preparing the update. Your windows remain open; retry when it is ready.' }
        $wait = [Diagnostics.Stopwatch]::StartNew()
        while (-not $hostSession.Process.WaitForExit(100) -and $wait.ElapsedMilliseconds -lt 75000) {
            Assert-CoordinatorNotCancelled $State
            [void](Test-SolderProcessInstance $hostSession.Captured)
        }
        if (-not $hostSession.Process.HasExited) { Fail 'A SolderCAD chat session is still finishing. Retry when it has closed.' }
        $hostSession.Drained = $true
    }
}

function Close-SolderPreparedHosts {
    param([object]$Held, [object]$State)
    foreach ($hostSession in $Held) {
        Assert-CoordinatorNotCancelled $State
        if ($hostSession.Drained) { continue }
        if ($hostSession.Process.HasExited) { continue }
        if (-not (Test-SolderProcessInstance $hostSession.Captured)) { continue }
        $request = [Text.Encoding]::ASCII.GetBytes("shutdown`n")
        $disconnected = $false
        $reply = $null
        try {
            $hostSession.Pipe.Write($request, 0, $request.Length)
            $hostSession.Pipe.Flush()
            $reply = Read-SolderControlReply $hostSession.Pipe $State
        } catch {
            if ($_.Exception -is [OperationCanceledException]) { throw }
            $cause = $_.Exception
            while ($null -ne $cause.InnerException) { $cause = $cause.InnerException }
            if ($cause -is [IO.IOException] -or $cause -is [ObjectDisposedException] -or $hostSession.Process.HasExited) { $disconnected = $true }
            else { throw }
        }
        if (-not $disconnected -and $null -ne $reply -and $reply -cne "closing`n") {
            Fail 'A SolderCAD chat session could not finish saving. Retry when it is ready.'
        }
        # Closing an editor can disconnect its prepared WebView and pipe while
        # its host is still draining. The window was already proven closed;
        # wait for that exact process rather than treating EOF as success.
        $wait = [Diagnostics.Stopwatch]::StartNew()
        while (-not $hostSession.Process.WaitForExit(100) -and $wait.ElapsedMilliseconds -lt 75000) {
            Assert-CoordinatorNotCancelled $State
            [void](Test-SolderProcessInstance $hostSession.Captured)
        }
        if (-not $hostSession.Process.HasExited) { Fail 'A SolderCAD chat session is still closing. Choose Retry when it has finished.' }
    }
}

function Get-SolderLaunchFiles {
    # A bounded launch check: the application entry points, their native cores,
    # and the small bundled chat/runtime files needed for a usable installation.
    return @(
        'bin\solder.exe',
        'SolderCAD\bin\kicad.exe',
        'SolderCAD\bin\kicad-cli.exe',
        'SolderCAD\bin\eeschema.exe',
        'SolderCAD\bin\pcbnew.exe',
        'SolderCAD\bin\kicommon.dll',
        'SolderCAD\bin\_eeschema.dll',
        'SolderCAD\bin\_pcbnew.dll',
        'SolderCAD\bin\python.exe',
        'SolderCAD\bin\python3.dll',
        'SolderCAD\bin\Lib\encodings\__init__.py',
        'SolderCAD\share\kicad\resources\solder_chat\index.html',
        'SolderCAD\share\kicad\resources\solder_chat\chat.html',
        'SolderCAD\share\kicad\resources\solder_chat\app.css',
        'SolderCAD\share\kicad\resources\solder_chat\app.js',
        'SolderCAD\share\kicad\resources\solder_chat\shell.js',
        'SolderCAD\share\kicad\resources\solder_chat\runtime.js',
        'SolderCAD\share\kicad\resources\solder_chat\manifest.json',
        'SolderCAD\share\kicad\resources\solder_chat\solder-release.json'
    )
}

function Write-SolderLaunchHealth {
    param([string]$InstallRoot)
    $entries = foreach ($relative in Get-SolderLaunchFiles) {
        $path = Join-Path $InstallRoot $relative
        Assert-OrdinaryTarget -Path $path -Directory $false
        $file = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if ($file.Length -le 0) { throw "A required installation file is empty: $relative" }
        [ordered]@{ path=$relative; length=$file.Length; sha256=(Get-FileSha256 $path) }
    }
    $record = [ordered]@{ schemaVersion=1; files=@($entries) } | ConvertTo-Json -Depth 4 -Compress
    Write-SolderAtomicRecord -Path (Join-Path $InstallRoot 'repair\launch-health.json') -Content $record
}

function Test-SolderLaunchHealth {
    param([string]$InstallRoot)
    try {
        if (@([IO.Directory]::EnumerateFileSystemEntries($InstallRoot, '.solder-installer-transaction')).Count -ne 0) {
            return $false
        }
        foreach ($directory in @('bin', 'SolderCAD', 'SolderCAD\bin', 'repair')) {
            Assert-OrdinaryTarget -Path (Join-Path $InstallRoot $directory) -Directory $true
        }
        $receipt = Join-Path $InstallRoot 'repair\launch-health.json'
        Assert-OrdinaryTarget -Path $receipt -Directory $false
        $receiptFile = Get-Item -LiteralPath $receipt -Force -ErrorAction Stop
        if ($receiptFile.Length -gt 16384) { return $false }
        $record = Get-Content -LiteralPath $receipt -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $expected = @(Get-SolderLaunchFiles)
        if ($record.schemaVersion -ne 1 -or @($record.files).Count -ne $expected.Count) { return $false }
        for ($i=0; $i -lt $expected.Count; $i++) {
            $entry = $record.files[$i]
            if ($entry.path -cne $expected[$i] -or $entry.sha256 -notmatch '\A[0-9a-fA-F]{64}\z') { return $false }
            $path = Join-Path $InstallRoot $expected[$i]
            Assert-OrdinaryTarget -Path $path -Directory $false
            $file = Get-Item -LiteralPath $path -Force -ErrorAction Stop
            if ($file.Length -le 0 -or $file.Length -ne $entry.length -or
                (Get-FileSha256 $path) -ine $entry.sha256) { return $false }
        }
        return $true
    } catch {
        # The caller starts the same interactive repair for missing, unreadable,
        # malformed, or changed files. It never launches an unverified binary.
        return $false
    }
}

function Start-SolderInstalledApp {
    param([string]$InstallRoot, [string]$RepairScriptPath, [string]$Project)
    $InstallRoot = Resolve-PhysicalPath ([IO.Path]::GetFullPath($InstallRoot))
    $app = Join-Path $InstallRoot 'SolderCAD\bin\kicad.exe'
    $request = Join-Path $InstallRoot '.solder-update-reopen-request.json'
    if (Test-Path -LiteralPath $request -PathType Leaf) {
        try {
            Assert-OrdinaryTarget $request $false
            $record = Get-Content -LiteralPath $request -Raw | ConvertFrom-Json
            if ($record.schemaVersion -eq 1 -and $record.component -ceq 'soldercad-update' -and $record.nonce -cmatch '\A[0-9a-f]{32}\z') {
                $coordinator = Get-Process -Id ([int]$record.coordinatorPid) -ErrorAction SilentlyContinue
                if ($null -ne $coordinator -and $coordinator.StartTime.ToUniversalTime().ToFileTimeUtc().ToString() -ceq $record.coordinatorStartTime) {
                    Add-Type -AssemblyName System.Windows.Forms
                    [void][Windows.Forms.MessageBox]::Show('SolderCAD is finishing an update. Please return to the update window.', 'SolderCAD Update')
                    return
                }
            }
        } catch { }
    }
    $healthy = Test-SolderLaunchHealth -InstallRoot $InstallRoot
    if ($healthy) {
        try {
            $document = ''
            if (-not [string]::IsNullOrWhiteSpace($Project)) {
                $document = [IO.Path]::GetFullPath($Project)
            }
            $process = Start-SolderGuiProcess -Executable $app -WorkingDirectory $InstallRoot -Project $document
            # Normal closure and forwarding to an existing process are success.
            # A loader/startup failure is repaired once by the coordinator.
            if (-not $process.WaitForExit(2000) -or $process.ExitCode -eq 0) { return }
        } catch {
            # The coordinator supplies the visible progress and retry surface.
        }
    }
    Assert-OrdinaryTarget -Path $RepairScriptPath -Directory $false
    $arguments = @{
        InteractiveUpdate=$true; InstallDir=$InstallRoot; NoUserIntegration=$true; ManageLauncher=$true
        RelaunchExecutable=$app; InstallerScriptPath=$RepairScriptPath
    }
    if (-not [string]::IsNullOrWhiteSpace($Project)) { $arguments.RelaunchProject=$Project }
    & ([scriptblock]::Create([IO.File]::ReadAllText($RepairScriptPath))) @arguments
}

function Save-SolderRepairLauncher {
    param([string]$InstallRoot, [string]$Source)
    $directory = Join-Path $InstallRoot 'repair'
    Assert-OrdinaryTarget $directory $true
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $marker = Join-Path $directory 'owner'
    Assert-OrdinaryTarget $marker $false
    if (Test-Path -LiteralPath $marker) {
        if ([IO.File]::ReadAllText($marker) -cne 'solder-repair-v1') { Fail 'The repair directory has an unrecognized owner.' }
    } else { Write-TransactionRecord $marker 'solder-repair-v1' }
    $bytes = [Text.Encoding]::UTF8.GetBytes($Source)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
    $script = Join-Path $directory ("install-$hash.ps1")
    Assert-OrdinaryTarget $script $false
    if (Test-Path -LiteralPath $script) {
        if ((Get-FileSha256 $script) -ine $hash) { Fail 'The saved repair helper has changed unexpectedly.' }
    } else { Write-TransactionRecord $script $Source }
    Write-SolderLaunchHealth $InstallRoot
    $pointer = [ordered]@{ schemaVersion=1; script=[IO.Path]::GetFileName($script); sha256=$hash } | ConvertTo-Json -Compress
    Write-SolderAtomicRecord -Path (Join-Path $directory 'launcher.json') -Content $pointer
    return $script
}

function Get-SolderLauncherArguments {
    param([string]$InstallRoot, [string]$RepairScript, [bool]$Repair)
    # Shell Link arguments are limited in length; derive the installation
    # root from this script's repair directory instead of encoding it twice.
    $mode = if ($Repair) { '-Repair' } else { '-Launch' }
    return '-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File ' + (Quote-SolderArgument $RepairScript) + ' ' + $mode
}

function Test-SolderOwnedShortcut {
    param([string]$ShortcutPath, [string]$InstallRoot)
    if (-not (Test-Path -LiteralPath $ShortcutPath -PathType Leaf)) { return $false }
    try {
        Assert-OrdinaryTarget $ShortcutPath $false
        $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($ShortcutPath)
        $target = [IO.Path]::GetFullPath($shortcut.TargetPath)
        $app = Join-Path $InstallRoot 'SolderCAD\bin\kicad.exe'
        if (Test-Path -LiteralPath $target -PathType Leaf) { $target = Resolve-PhysicalPath $target }
        if ($target.Equals($app, [StringComparison]::OrdinalIgnoreCase)) {
            # Do not erase a person's custom project or other shortcut args.
            return [string]::IsNullOrWhiteSpace($shortcut.Arguments)
        }
        $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (-not $target.Equals($powershell, [StringComparison]::OrdinalIgnoreCase)) { return $false }
        $args = [SolderInstaller.NativePath]::SplitCommandLine($shortcut.Arguments)
        $index = [Array]::IndexOf($args, '-File')
        if ($index -lt 0 -or $index + 1 -ge $args.Length) { return $false }
        if (@($args | Where-Object { $_ -ceq '-Launch' -or $_ -ceq '-Repair' }).Count -ne 1) { return $false }
        $script = [IO.Path]::GetFullPath($args[$index + 1])
        if ([IO.Path]::GetFileName($script) -cnotmatch '\Ainstall-[0-9a-f]{64}\.ps1\z') { return $false }
        $parent = Resolve-PhysicalPath ([IO.Path]::GetDirectoryName($script))
        return $parent.Equals((Join-Path $InstallRoot 'repair'), [StringComparison]::OrdinalIgnoreCase)
    } catch { return $false }
}

function Invoke-SolderShortcutReplace {
    param([string]$Temporary, [string]$ShortcutPath, [string]$Previous,
          [object]$OriginalIdentity, [string]$OriginalHash, [scriptblock]$ReplaceOperation)
    try {
        if ($null -eq $ReplaceOperation) { [IO.File]::Replace($Temporary, $ShortcutPath, $Previous) }
        else { & $ReplaceOperation $Temporary $ShortcutPath $Previous }
    } catch {
        $publicationError = $_
        # ReplaceFile can move the original to the backup and then fail
        # before publishing its replacement. Restore only the same original,
        # and never overwrite a destination created by another process.
        try {
            if (-not (Test-Path -LiteralPath $ShortcutPath) -and
                (Get-TargetIdentity $Previous $false) -ceq $OriginalIdentity -and
                (Get-FileSha256 $Previous) -ceq $OriginalHash) {
                [IO.File]::Move($Previous, $ShortcutPath)
            }
        } catch { }
        try {
            if (Test-Path -LiteralPath $Previous) { Write-Warning "Shortcut backup retained at '$Previous'." }
        } catch { }
        throw $publicationError
    }
}

function Set-SolderManagedShortcut {
    param([string]$ShortcutPath, [string]$InstallRoot, [string]$RepairScript, [bool]$Repair, [bool]$OnlyOwned = $false)
    $shell = New-Object -ComObject WScript.Shell
    $target = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $directory = Split-Path -Parent $ShortcutPath
    Assert-OrdinaryTarget -Path $directory -Directory $true
    Assert-OrdinaryTarget -Path $ShortcutPath -Directory $false
    $originalIdentity = Get-TargetIdentity $ShortcutPath $false
    $originalHash = if ($null -ne $originalIdentity) { Get-FileSha256 $ShortcutPath } else { $null }
    if ($OnlyOwned -and ($null -eq $originalIdentity -or -not (Test-SolderOwnedShortcut -ShortcutPath $ShortcutPath -InstallRoot $InstallRoot))) { return }
    $arguments = Get-SolderLauncherArguments $InstallRoot $RepairScript $Repair
    if ($arguments.Length -gt 1000) { Fail 'The installation path is too long for a Windows shortcut.' }
    # A dot-prefixed name can become Hidden on a redirected macOS desktop,
    # and those attributes may be carried onto the published shortcut.
    $temporary = Join-Path $directory ('solder-shortcut-' + [Guid]::NewGuid().ToString('N') + '.tmp.lnk')
    try {
        $shortcut = $shell.CreateShortcut($temporary)
        $shortcut.TargetPath = $target
        $shortcut.Arguments = $arguments
        $shortcut.WorkingDirectory = $InstallRoot
        $shortcut.IconLocation = (Join-Path $InstallRoot 'SolderCAD\bin\kicad.exe') + ',0'
        $shortcut.Description = if ($Repair) { 'Repair SolderCAD' } else { 'SolderCAD' }
        $shortcut.WindowStyle = 7
        $shortcut.Save()
        # Inspect the file before reopening it: some redirected desktops do
        # not expose a newly saved Shell Link to WScript until it is inspected.
        Assert-OrdinaryTarget -Path $temporary -Directory $false
        if ((Get-Item -LiteralPath $temporary -Force).Length -le 0) { Fail 'Windows could not save the SolderCAD shortcut.' }
        # Require complete, exact readback before replacing an existing link;
        # a bounded retry also accommodates a delayed shared-folder update.
        $readback = [Diagnostics.Stopwatch]::StartNew()
        $verified = $false
        do {
            $saved = (New-Object -ComObject WScript.Shell).CreateShortcut($temporary)
            $verified = $saved.Arguments -ceq $arguments -and $saved.TargetPath.Equals($target, [StringComparison]::OrdinalIgnoreCase)
            if (-not $verified -and $readback.ElapsedMilliseconds -lt 2000) { Start-Sleep -Milliseconds 100 }
        } while (-not $verified -and $readback.ElapsedMilliseconds -lt 2000)
        if (-not $verified) {
            Fail 'Windows could not save the complete SolderCAD shortcut.'
        }
        if ((Get-TargetIdentity $ShortcutPath $false) -cne $originalIdentity -or
            ($null -ne $originalIdentity -and (Get-FileSha256 $ShortcutPath) -cne $originalHash)) {
            Fail 'The SolderCAD shortcut changed while it was being updated. The current shortcut was preserved.'
        }
        if (Test-Path -LiteralPath $ShortcutPath) {
            $previous = Join-Path $directory ('.solder-shortcut-previous-' + [Guid]::NewGuid().ToString('N') + '.lnk')
            Invoke-SolderShortcutReplace -Temporary $temporary -ShortcutPath $ShortcutPath -Previous $previous -OriginalIdentity $originalIdentity -OriginalHash $originalHash
            try { [IO.File]::Delete($previous) } catch { Write-Warning "Previous shortcut retained at '$previous'." }
        } else { [IO.File]::Move($temporary, $ShortcutPath) }
    } finally { if (Test-Path -LiteralPath $temporary) { [IO.File]::Delete($temporary) } }
}

function Write-SolderCoordinatorLog {
    param([string]$InstallRoot, [string]$Stage, [string]$Outcome, [string]$Detail)
    # Keep useful failure detail while stripping whole URLs and common secret
    # values. This log is local; it never records request or response bodies.
    try {
        $directory = Join-Path $InstallRoot 'repair'
        Assert-OrdinaryTarget $directory $true
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        $log = Join-Path $directory 'update-log.jsonl'
        Assert-OrdinaryTarget $log $false
        $safe = $Detail -replace '(?i)https?://\S+', '[url]' `
            -replace '(?i)\bbearer\s+[^\s,;]+', 'Bearer [redacted]' `
            -replace '(?i)\b(authorization|password|token|secret|cookie|signature|api[_-]?key)\s*[:=]\s*[^\r\n,;]*', '$1=[redacted]'
        if ($safe.Length -gt 500) { $safe = $safe.Substring(0, 500) }
        $entry = [ordered]@{ time=[DateTime]::UtcNow.ToString('o'); stage=$Stage; outcome=$Outcome; detail=$safe } | ConvertTo-Json -Compress
        [IO.File]::AppendAllText($log, $entry + [Environment]::NewLine, (New-Object Text.UTF8Encoding $false))
    } catch { }
}

function Open-SolderUpdateWindows {
    param([string]$InstallRoot, [object]$State, [string]$Executable, [string]$Project, [int]$CallerPid, [bool]$Required)
    if ($null -eq $State.Session) { return }
    Open-SolderReopenSession -InstallRoot $InstallRoot -State $State -CallerProject $Project -CallerPid $CallerPid -Required $Required
    $callerWindow = $State.Session.PSObject.Properties['CallerWindow']
    $callerCaptured = $null -ne $callerWindow -and @($State.Session.Windows | Where-Object {
        $_.Process.Id -eq $CallerPid -and $_.Handle -eq $callerWindow.Value
    }).Count -gt 0
    if (-not $State.CallerReopened -and -not $callerCaptured -and -not $State.Session.Opened.Contains('caller-fallback')) {
        Open-SolderAfterUpdate -InstallRoot $InstallRoot -Executable $Executable -Project $Project
        [void]$State.Session.Opened.Add('caller-fallback')
    }
}

function Complete-SolderPublishedInstall {
    param([string]$InstallRoot, [string]$Source, [object]$State, [bool]$NoIntegration, [bool]$Manage,
          [string]$Executable, [string]$Project, [int]$CallerPid, [bool]$Required)
    $canOpen = $false
    try {
        Recover-SolderTransaction -InstallRoot $InstallRoot
        $canOpen = $true
        if ($null -eq $State -or -not $State.SetupComplete) {
            Set-CoordinatorProgress $State 'integration' 'Finishing SolderCAD setup...'
            $helper = Save-SolderRepairLauncher -InstallRoot $InstallRoot -Source $Source
            if (-not $NoIntegration -or $Manage) {
                $desktop = [Environment]::GetFolderPath('DesktopDirectory', 'DoNotVerify')
                if ([string]::IsNullOrWhiteSpace($desktop)) { Fail 'Cannot find the desktop folder for SolderCAD shortcuts.' }
                if (-not $NoIntegration) { New-Item -ItemType Directory -Path $desktop -Force | Out-Null }
                foreach ($shortcut in @(@{ Name='SolderCAD.lnk'; Repair=$false }, @{ Name='SolderCAD Repair.lnk'; Repair=$true })) {
                    $path = Join-Path $desktop $shortcut.Name
                    Set-SolderManagedShortcut -ShortcutPath $path -InstallRoot $InstallRoot -RepairScript $helper -Repair $shortcut.Repair -OnlyOwned $NoIntegration
                }
            }
            if (-not $NoIntegration) {
                $bin = Join-Path $InstallRoot 'bin'
                $app = Join-Path $InstallRoot 'SolderCAD'
                $cli = Join-Path $app 'bin\kicad-cli.exe'
                Add-UserPathEntry -PathToAdd $bin
                [Environment]::SetEnvironmentVariable('KICAD_APP_PATH', $app, 'User')
                [Environment]::SetEnvironmentVariable('KICAD_CLI_PATH', $cli, 'User')
                [Environment]::SetEnvironmentVariable('KICAD_DISABLE_LIBRARY_PRELOAD', '1', 'User')
                [Environment]::SetEnvironmentVariable('KICAD_SOFTWARE_RENDERING', $null, 'User')
                $env:KICAD_APP_PATH = $app
                $env:KICAD_CLI_PATH = $cli
                $env:KICAD_DISABLE_LIBRARY_PRELOAD = '1'
                Remove-Item Env:KICAD_SOFTWARE_RENDERING -ErrorAction SilentlyContinue
            }
            if ($null -ne $State) { $State.SetupComplete = $true }
        }
    } catch {
        if ($canOpen -and $null -ne $State) {
            try { Open-SolderUpdateWindows $InstallRoot $State $Executable $Project $CallerPid $false }
            catch { Write-Warning 'A previously closed SolderCAD window could not be reopened; its recovery records were preserved.' }
        }
        throw
    }
    if ($null -ne $State) {
        $State.PublicationComplete = $true
        Set-CoordinatorProgress $State 'reopening' 'Reopening SolderCAD...'
        Open-SolderUpdateWindows $InstallRoot $State $Executable $Project $CallerPid $Required
        Complete-SolderReopenSession $State
        Set-CoordinatorProgress $State 'complete' 'SolderCAD is up to date.'
    }
}

function New-SolderCoordinatorStartAction {
    param([object]$State, [object]$Ui, [object]$Retry, [object]$Cancel, [object]$Progress,
          [string]$Source, [hashtable]$WorkerParameters)
    return {
        $State.Stage = 'starting'
        $State.Message = 'Preparing the update...'
        $State.CancelRequested = $false
        $reopenOnly = $State.PublicationCommitted -or $State.PendingRestore
        $State.CanCancel = -not $reopenOnly
        if (-not $reopenOnly) { $State.ClosedAny = $false }
        $Ui.Finished = $false
        $Ui.SuccessAt = $null
        $Retry.Visible = $false
        $Cancel.Text = 'Cancel'
        $Cancel.Enabled = $true
        $Progress.Style = [Windows.Forms.ProgressBarStyle]::Marquee
        $worker = [PowerShell]::Create()
        [void]$worker.AddScript($Source)
        # The event callback runs in a dynamic module. Capture all installer
        # options explicitly before creating that closure, not from script scope.
        $parameters = $WorkerParameters.Clone()
        $parameters.InternalReopen = $reopenOnly
        [void]$worker.AddParameters($parameters)
        $Ui.Worker = $worker
        $Ui.Async = $worker.BeginInvoke()
    }.GetNewClosure()
}

function Start-SolderCoordinator {
    param([string]$ScriptPath, [string]$InstallRoot, [string]$Executable, [string]$Project,
          [int]$CallerPid, [long]$CallerWindow, [bool]$NoIntegration, [bool]$Manage,
          [bool]$RequireRecords, [string]$RequestedVersion, [string]$RequestedSource)
    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
        Fail "The update helper could not be opened. Please try again."
    }
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()
    $state = [hashtable]::Synchronized(@{ Stage='starting'; Message='Preparing the update...'; CancelRequested=$false; CanCancel=$true; ClosedAny=$false; PublicationCommitted=$false; PublicationComplete=$false; SetupComplete=$false; PendingRestore=$false; CallerReopened=$false; Session=$null })
    $ui = @{ Worker=$null; Async=$null; Finished=$false; SuccessAt=$null; State=$state }
    $form = New-Object Windows.Forms.Form
    $form.Text = 'SolderCAD Update'
    $form.StartPosition = 'CenterScreen'
    $form.Size = New-Object Drawing.Size(520, 205)
    $form.MinimumSize = $form.Size
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $label = New-Object Windows.Forms.Label
    $label.Location = New-Object Drawing.Point(20, 20)
    $label.Size = New-Object Drawing.Size(465, 70)
    $label.Text = $state.Message
    $form.Controls.Add($label)
    $progress = New-Object Windows.Forms.ProgressBar
    $progress.Location = New-Object Drawing.Point(20, 92)
    $progress.Size = New-Object Drawing.Size(465, 18)
    $progress.Style = [Windows.Forms.ProgressBarStyle]::Marquee
    $form.Controls.Add($progress)
    $retry = New-Object Windows.Forms.Button
    $retry.Text = 'Retry'
    $retry.Location = New-Object Drawing.Point(305, 122)
    $retry.Size = New-Object Drawing.Size(85, 30)
    $retry.Visible = $false
    $form.Controls.Add($retry)
    $cancel = New-Object Windows.Forms.Button
    $cancel.Text = 'Cancel'
    $cancel.Location = New-Object Drawing.Point(400, 122)
    $cancel.Size = New-Object Drawing.Size(85, 30)
    $form.Controls.Add($cancel)
    $source = [IO.File]::ReadAllText($ScriptPath)
    $workerParameters = @{ InstallDir=$InstallRoot; Version=$RequestedVersion; DownloadSource=$RequestedSource;
                           InstallerScriptPath=$ScriptPath; NoUserIntegration=$NoIntegration; ManageLauncher=$Manage;
                           RequireReopenRecords=$RequireRecords; InternalCoordinator=$true; CoordinatorState=$state;
                           RelaunchExecutable=$Executable; RelaunchProject=$Project; CallerProcessId=$CallerPid; CallerWindowHandle=$CallerWindow }
    $startWorker = New-SolderCoordinatorStartAction -State $state -Ui $ui -Retry $retry -Cancel $cancel -Progress $progress -Source $source -WorkerParameters $workerParameters
    $retry.Add_Click({ & $startWorker }.GetNewClosure())
    $cancel.Add_Click({
        if ($ui.Finished) { $form.Close(); return }
        [Threading.Monitor]::Enter($state.SyncRoot)
        try {
            if ($state.CanCancel) {
                $state.CancelRequested = $true
                $label.Text = if ($state.Stage -eq 'closing') { 'Finish any SolderCAD save dialog to cancel safely.' } else { 'Cancelling safely...' }
                $cancel.Enabled = $false
            }
        } finally { [Threading.Monitor]::Exit($state.SyncRoot) }
    }.GetNewClosure())
    $form.Add_FormClosing({
        param($sender, $event)
        if (-not $ui.Finished) {
            $event.Cancel = $true
            [Threading.Monitor]::Enter($state.SyncRoot)
            try {
                if ($state.CanCancel) {
                    $state.CancelRequested = $true
                    $label.Text = 'Cancelling safely...'
                    $cancel.Enabled = $false
                }
            } finally { [Threading.Monitor]::Exit($state.SyncRoot) }
        }
    }.GetNewClosure())
    $timer = New-Object Windows.Forms.Timer
    $timer.Interval = 200
    # The GUI bootstrap invokes this installer from a nested scriptblock.
    # Capture the function itself before the timer's dynamic-module closure is
    # created; an unqualified lookup there cannot see the installer's scope.
    $writeCoordinatorLog = ${function:Write-SolderCoordinatorLog}
    $timer.Add_Tick({
        if (-not $ui.Finished) {
            if (-not $state.CancelRequested) { $label.Text = $state.Message }
            $cancel.Enabled = $state.CanCancel -and -not $state.CancelRequested
            if ($null -ne $ui.Async -and $ui.Async.IsCompleted) {
                try {
                    [void]$ui.Worker.EndInvoke($ui.Async)
                    if ($ui.Worker.HadErrors) { throw $ui.Worker.Streams.Error[$ui.Worker.Streams.Error.Count - 1] }
                    $label.Text = if ($state.Stage -eq 'restored') { 'Your saved sessions were restored. The update was not installed.' } else { 'SolderCAD is up to date.' }
                    $retry.Visible = $false
                    if ($state.Stage -eq 'complete') { $ui.SuccessAt = [Diagnostics.Stopwatch]::StartNew() }
                    & $writeCoordinatorLog $InstallRoot $state.Stage 'success' ''
                } catch {
                    $message = $_.Exception.Message
                    & $writeCoordinatorLog $InstallRoot $state.Stage $(if ($state.CancelRequested) { 'cancelled' } else { 'failure' }) $message
                    if ($state.PendingRestore) {
                        $label.Text = 'A saved session could not reopen. Choose Retry to restore it.'
                    } elseif ($state.PublicationCommitted) {
                        $label.Text = 'SolderCAD was updated, but setup or reopening needs attention. Choose Retry to finish.'
                    } elseif ($state.CancelRequested -or $message -like '*cancelled*') {
                        $label.Text = 'Update cancelled. Your work was not force-closed.'
                    } elseif ($state.Stage -in @('checking', 'downloading')) {
                        $label.Text = 'The download could not finish. Check your connection and choose Retry. SolderCAD remains unchanged.'
                    } elseif ($state.Stage -eq 'chat-busy') {
                        $label.Text = 'Let Solder Chat finish, or stop its current and queued work. Answer any open question, then choose Retry.'
                    } elseif ($state.Stage -eq 'closing') {
                        $label.Text = 'SolderCAD or a Solder terminal could not close safely. Finish saving or close the session, then choose Retry.'
                    } else {
                        $label.Text = 'The update could not finish. Your work was not force-closed. Retry when ready.'
                    }
                    $retry.Visible = $true
                }
                $ui.Worker.Dispose()
                $ui.Finished = $true
                $cancel.Enabled = $true
                $cancel.Text = 'Close'
                $progress.Style = [Windows.Forms.ProgressBarStyle]::Blocks
                $progress.Value = if ($state.Stage -eq 'complete') { 100 } else { 0 }
            }
        } elseif ($null -ne $ui.SuccessAt -and $ui.SuccessAt.ElapsedMilliseconds -ge 1500) {
            $form.Close()
        }
    }.GetNewClosure())
    $form.Add_Shown({ & $startWorker; $timer.Start() }.GetNewClosure())
    try { [void]$form.ShowDialog() }
    finally {
        $timer.Stop()
        $timer.Dispose()
        $form.Dispose()
    }
}

Assert-WindowsX64

if (($Launch -or $Repair) -and -not $PSBoundParameters.ContainsKey('InstallDir')) {
    if (-not $PSCommandPath) { Fail 'The repair launcher path is missing.' }
    $InstallDir = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
}
if ($Repair) {
    $NoUserIntegration = $true
    $ManageLauncher = $true
    $InteractiveUpdate = $true
}
if ($Launch) {
    if (-not $InstallerScriptPath -and $PSCommandPath) { $InstallerScriptPath = $PSCommandPath }
    Start-SolderInstalledApp -InstallRoot $InstallDir -RepairScriptPath $InstallerScriptPath -Project $RelaunchProject
    return
}
$autoInteractive = -not $InternalCoordinator -and -not $DryRun -and -not $NoUserIntegration -and
    [Environment]::UserInteractive -and -not $env:CI -and
    @([Environment]::GetCommandLineArgs() | Where-Object { $_ -ieq '-NonInteractive' -or $_ -ieq '-NonI' }).Count -eq 0
if ($autoInteractive) { $InteractiveUpdate = $true }
if ($InteractiveUpdate) {
    if (-not $InstallerScriptPath -and $PSCommandPath) { $InstallerScriptPath = $PSCommandPath }
    $temporaryHelper = $null
    if (-not $InstallerScriptPath) {
        $temporaryHelper = Join-Path ([IO.Path]::GetTempPath()) ('solder-update-' + [Guid]::NewGuid().ToString('N') + '.ps1')
        [IO.File]::WriteAllText($temporaryHelper, $InstallerSource, (New-Object Text.UTF8Encoding $false))
        $InstallerScriptPath = $temporaryHelper
    }
    if (-not $RelaunchExecutable -and ($autoInteractive -or $Repair)) {
        $RelaunchExecutable = Join-Path ([IO.Path]::GetFullPath($InstallDir)) 'SolderCAD\bin\kicad.exe'
    }
    try { Start-SolderCoordinator -ScriptPath $InstallerScriptPath -InstallRoot $InstallDir -Executable $RelaunchExecutable -Project $RelaunchProject -CallerPid $CallerProcessId -CallerWindow $CallerWindowHandle -NoIntegration $NoUserIntegration -Manage $ManageLauncher -RequireRecords $RequireReopenRecords -RequestedVersion $Version -RequestedSource $DownloadSource }
    finally { if ($temporaryHelper) { [IO.File]::Delete($temporaryHelper) } }
    return
}
if ($InternalCoordinator -and $null -eq $CoordinatorState) { Fail "The update coordinator state is missing." }
$interactive = $InternalCoordinator -and $null -ne $CoordinatorState
if ($interactive) { $RequireReopenRecords = $true }
if ($InternalReopen) {
    if (-not $interactive -or (-not $CoordinatorState.PublicationCommitted -and -not $CoordinatorState.PendingRestore)) { Fail 'There is no update recovery to finish.' }
    $InstallDir = Resolve-PhysicalPath ([IO.Path]::GetFullPath($InstallDir))
    $finishLease = Enter-SolderInstallLease -InstallRoot $InstallDir
    try {
        if ($CoordinatorState.PublicationCommitted) {
            Complete-SolderPublishedInstall -InstallRoot $InstallDir -Source $InstallerSource -State $CoordinatorState -NoIntegration $NoUserIntegration -Manage $ManageLauncher -Executable $RelaunchExecutable -Project $RelaunchProject -CallerPid $CallerProcessId -Required $RequireReopenRecords
        } else {
            $pendingTransaction = Join-Path $InstallDir '.solder-installer-transaction'
            if (Test-Path -LiteralPath $pendingTransaction) {
                Assert-SolderProcessesClosed $InstallDir
                Recover-SolderTransaction $InstallDir
            }
            Open-SolderReopenSession -InstallRoot $InstallDir -State $CoordinatorState -CallerProject $RelaunchProject -CallerPid $CallerProcessId -Required $false
            Complete-SolderReopenSession $CoordinatorState
            $CoordinatorState.PendingRestore = $false
            Set-CoordinatorProgress $CoordinatorState 'restored' 'Your saved sessions were restored. The update was not installed.'
        }
    } finally { $finishLease.Stop() }
    return
}

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
if (-not $NoUserIntegration -or $ManageLauncher) {
    # Ask Windows for the configured desktop, including redirected folders.
    $desktopDir = [Environment]::GetFolderPath("DesktopDirectory", "DoNotVerify")
    if ([string]::IsNullOrWhiteSpace($desktopDir)) {
        Fail "cannot resolve the current user's desktop folder for the SolderCAD shortcut"
    }
    $desktopShortcutPath = Join-Path $desktopDir "SolderCAD.lnk"
    $repairShortcutPath = Join-Path $desktopDir "SolderCAD Repair.lnk"
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
    if (-not $interactive) {
        Assert-SolderProcessesClosed -InstallRoot $InstallDir
        Recover-SolderTransaction -InstallRoot $InstallDir
    } elseif (Test-Path -LiteralPath $tx) {
        # A recognized interrupted transaction can be restored even when the
        # network is down, provided no target process is still running.
        $canRecover = $true
        try { Assert-SolderProcessesClosed -InstallRoot $InstallDir }
        catch { $canRecover = $false }
        if ($canRecover) {
            Set-CoordinatorProgress $CoordinatorState 'recovering' 'Recovering the previous installation...'
            Recover-SolderTransaction -InstallRoot $InstallDir
        }
    }
    foreach ($previousUpdate in @(Get-ChildItem -LiteralPath $InstallDir -Directory -Force -Filter '.SolderCAD.update-*')) {
        $previousApp = Join-Path $previousUpdate.FullName 'previous'
        if (Test-Path -LiteralPath $previousApp -PathType Container) {
            Write-Warning "An earlier Solder update retained the previous application at '$previousApp'. It will be preserved."
        }
    }
    foreach ($oldBackup in @(Get-ChildItem -LiteralPath $InstallDir -Force -Filter '.solder-installer-*-previous-*')) {
        Write-Warning "An earlier installer retained a previous component at '$($oldBackup.FullName)'. It will be preserved."
    }
    foreach ($oldVerifier in @(Get-ChildItem -LiteralPath $InstallDir -File -Force -Filter '.solder-verify-*.exe')) {
        Write-Warning "An earlier installer retained an unpublished verifier at '$($oldVerifier.FullName)'. It will be preserved."
    }
    $original = @((Get-TargetIdentity $solderCadDestination $true), (Get-TargetIdentity $cliDestination $false), (Get-TargetIdentity $oldSidecarSolderCadDestination $true))

    Set-CoordinatorProgress $CoordinatorState 'checking' 'Checking for updates...'
    Assert-CoordinatorNotCancelled $CoordinatorState
    $download = $null
    for ($attempt = 1; $attempt -le $(if ($interactive) { 2 } else { 1 }); $attempt++) {
        try { $download = Resolve-ReleaseDownload -RequestedVersion $Version -Source $DownloadSource; break }
        catch {
            if (-not $interactive -or $attempt -eq 2 -or $_.Exception.Message -notlike 'failed to read GitHub release metadata:*') { throw }
            Write-SolderCoordinatorLog $InstallDir 'checking' 'retry' $_.Exception.Message
            Set-CoordinatorProgress $CoordinatorState 'checking' 'Connection interrupted. Trying again...'
            Assert-CoordinatorNotCancelled $CoordinatorState
            Start-Sleep -Seconds 1
        }
    }
    $Version = $download.Version
    if (-not $explicitVersion) {
        Assert-NoImplicitDowngrade -Installed (Get-InstalledVersions $InstallDir) -Selected $Version
    }
    $work = if ($interactive) { Join-Path $InstallDir ('.solder-installer-stage-' + [Guid]::NewGuid().ToString('N')) } else { $tx }
    $archivePath = Join-Path $work $download.AssetName
    $extractDir = Join-Path $work "extract"
    # Create the ownership marker before publishing the fixed recovery path.
    # A crash during this preparation cannot strand an unrecognized marker.
    $preparing = Join-Path $InstallDir ('.solder-installer-preparing-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $preparing | Out-Null
    try {
        Write-TransactionRecord -Path (Join-Path $preparing 'owner') -Content 'solder-installer-transaction-v1'
        [IO.Directory]::Move($preparing, $work)
    } catch {
        if (Test-Path -LiteralPath $preparing) { Remove-Item -LiteralPath $preparing -Recurse -Force }
        throw
    }

    $verifiedCli = $null
    $stageIdentity = $null
    try {
        Write-Host "Downloading $($download.DownloadUrl)"
        Set-CoordinatorProgress $CoordinatorState 'downloading' 'Downloading the update...'
        for ($attempt = 1; $attempt -le $(if ($interactive) { 2 } else { 1 }); $attempt++) {
            try {
                Save-SolderDownload -Uri $download.DownloadUrl -Destination $archivePath -Size $download.Size -State $CoordinatorState
                break
            } catch {
                if ($interactive -and $CoordinatorState.CancelRequested) { throw [OperationCanceledException]::new('The update was cancelled.') }
                if (-not $interactive -or $attempt -eq 2) {
                    if ($interactive) { Write-SolderCoordinatorLog $InstallDir 'downloading' 'failure' $_.Exception.Message }
                    Fail "$($download.Source) download failed; no other source was tried. Check the connection and retry."
                }
                Write-SolderCoordinatorLog $InstallDir 'downloading' 'retry' $_.Exception.Message
                if (Test-Path -LiteralPath $archivePath) { [IO.File]::Delete($archivePath) }
                Set-CoordinatorProgress $CoordinatorState 'downloading' 'Connection interrupted. Trying again...'
                Assert-CoordinatorNotCancelled $CoordinatorState
                Start-Sleep -Seconds 1
            }
        }

        Write-Host "Verifying archive size and SHA-256..."
        Set-CoordinatorProgress $CoordinatorState 'verifying' 'Verifying the download...'
        Assert-CoordinatorNotCancelled $CoordinatorState
        Assert-ArchiveIntegrity -ArchivePath $archivePath -Download $download

        Write-Host "Extracting $($download.AssetName)"
        Set-CoordinatorProgress $CoordinatorState 'extracting' 'Preparing SolderCAD...'
        Assert-CoordinatorNotCancelled $CoordinatorState
        Expand-ZipArchive -ArchivePath $archivePath -DestinationPath $extractDir
        Assert-CoordinatorNotCancelled $CoordinatorState
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
        # Avoid "installer"/"setup" in the executable name: Windows installer
        # detection can otherwise request elevation for an unsigned CLI.
        $verifiedCli = Join-Path $InstallDir ('.solder-verify-' + [Guid]::NewGuid().ToString('N') + '.exe')
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

        if ($interactive) {
            Assert-CoordinatorNotCancelled $CoordinatorState
            New-SolderReopenSession -InstallRoot $InstallDir -State $CoordinatorState -RequireNative $RequireReopenRecords
            $heldHosts = Open-SolderPreparedHosts -InstallRoot $InstallDir -State $CoordinatorState
            try {
                Close-SolderForUpdate -InstallRoot $InstallDir -State $CoordinatorState -CallerPid $CallerProcessId -CallerWindow $CallerWindowHandle -Held $heldHosts
                Close-SolderPreparedHosts -Held $heldHosts -State $CoordinatorState
            } finally { foreach ($held in $heldHosts) { $held.Pipe.Dispose(); $held.Process.Dispose() } }
            Assert-CoordinatorNotCancelled $CoordinatorState
            Close-SolderTerminalsForUpdate -InstallRoot $InstallDir -State $CoordinatorState
            Assert-CoordinatorNotCancelled $CoordinatorState
            Assert-SolderClosedWindowRecords -State $CoordinatorState -CallerProject $RelaunchProject -CallerPid $CallerProcessId
            Assert-SolderProcessesClosed -InstallRoot $InstallDir
            if (Test-Path -LiteralPath $tx) {
                Recover-SolderTransaction -InstallRoot $InstallDir
                $original = @((Get-TargetIdentity $solderCadDestination $true), (Get-TargetIdentity $cliDestination $false), (Get-TargetIdentity $oldSidecarSolderCadDestination $true))
                if (-not $explicitVersion) {
                    Assert-NoImplicitDowngrade -Installed (Get-InstalledVersions $InstallDir) -Selected $Version
                }
            }
            $relativePayload = $payloadRoot.Substring($work.Length).TrimStart('\')
            $stageIdentity = Get-TargetIdentity $work $true
            [IO.Directory]::Move($work, $tx)
            $work = $tx
            $payloadRoot = Join-Path $tx $relativePayload
            [Threading.Monitor]::Enter($CoordinatorState.SyncRoot)
            try {
                Assert-CoordinatorNotCancelled $CoordinatorState
                $CoordinatorState.CanCancel = $false
            } finally { [Threading.Monitor]::Exit($CoordinatorState.SyncRoot) }
            Set-CoordinatorProgress $CoordinatorState 'installing' 'Installing the update...'
        }
        Write-Host "Installing Solder and SolderCAD together..."
        Publish-SolderTransaction -InstallRoot $InstallDir -PayloadRoot $payloadRoot -Original $original -NewCliPath $verifiedCli
        if ($interactive) { $CoordinatorState.PublicationCommitted = $true }
    }
    catch {
        $installError = $_
        if ($interactive -and $null -ne $CoordinatorState.Session) { $CoordinatorState.PendingRestore = $true }
        try {
            if ($verifiedCli -and (Test-Path -LiteralPath $verifiedCli -PathType Leaf)) {
                Write-Warning "The uninstalled verifier was preserved at '$verifiedCli'."
            }
            if ($interactive -and $work -cne $tx) {
                if (Test-Path -LiteralPath $work) {
                    $extendedWork = ConvertTo-ExtendedPath $work
                    Assert-NoReparseTree -Directory $extendedWork
                    [IO.Directory]::Delete($extendedWork, $true)
                }
            } else {
                Recover-SolderFailedPublication -InstallRoot $InstallDir -Original $original -StageIdentity $stageIdentity
            }
            if ($interactive -and $null -ne $CoordinatorState.Session) {
                Open-SolderReopenSession -InstallRoot $InstallDir -State $CoordinatorState -CallerProject $RelaunchProject -CallerPid $CallerProcessId -Required $false
                Complete-SolderReopenSession $CoordinatorState
                $CoordinatorState.PendingRestore = $false
            }
        } catch {
            throw "Installation failed: $($installError.Exception.Message) Automatic recovery could not finish: $($_.Exception.Message) Close SolderCAD and retry; recovery files remain at $tx."
        }
        throw $installError
    }

    Complete-SolderPublishedInstall -InstallRoot $InstallDir -Source $InstallerSource -State $CoordinatorState -NoIntegration $NoUserIntegration -Manage $ManageLauncher -Executable $RelaunchExecutable -Project $RelaunchProject -CallerPid $CallerProcessId -Required $RequireReopenRecords
    Write-Host ""
    Write-Host "Solder $Version installed."
    Write-Host "CLI:            $cliDestination"
    Write-Host "SolderCAD:      $solderCadDestination"
    if ($NoUserIntegration) {
        if ($ManageLauncher) { Write-Host "Existing user environment was not changed; owned shortcuts were migrated when present." }
        else { Write-Host "Existing user environment and desktop shortcuts were not changed." }
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
