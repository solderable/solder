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
            # Newer .NET re-applies ExclusiveAddressUse when Server is read;
            # that fails once the socket is bound. Capture it before Start
            # and use the same socket on Windows PowerShell and PowerShell 7.
            $serverSocket = $listener.Server
            $listener.Start()
            # PowerShell 5.1 creates inheritable sockets. A reopened GUI child
            # must not keep this process lease alive after the worker exits.
            [SolderInstaller.NativePath]::PreventInheritance($serverSocket.Handle)
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

function Move-SolderTransactionItem {
    param([string]$InstallRoot, [string]$Source, [string]$Destination, [string]$ExpectedIdentity,
          [bool]$Directory, [object]$State, [scriptblock]$OnRetry)
    $deadline = [Diagnostics.Stopwatch]::StartNew()
    $notified = $false
    while ($true) {
        if ((Get-TargetIdentity $Source $Directory) -cne $ExpectedIdentity) {
            Fail 'A Solder component changed while waiting for Windows. Recovery files were preserved.'
        }
        $parent = [IO.Path]::GetDirectoryName($Destination)
        $name = [IO.Path]::GetFileName($Destination)
        $conflict = @([IO.Directory]::EnumerateFileSystemEntries($parent) | Where-Object {
            [IO.Path]::GetFileName($_).Equals($name, [StringComparison]::OrdinalIgnoreCase)
        })
        if ($conflict.Count) { Fail 'A Solder recovery path appeared while installing. Recovery files were preserved.' }
        Assert-SolderProcessesClosed -InstallRoot $InstallRoot
        try {
            if ($Directory) { [IO.Directory]::Move($Source, $Destination) }
            else { [IO.File]::Move($Source, $Destination) }
            return
        } catch {
            $failure = $_
            $cause = $_.Exception
            while ($null -ne $cause.InnerException) { $cause = $cause.InnerException }
            # ERROR_ACCESS_DENIED, ERROR_SHARING_VIOLATION, ERROR_LOCK_VIOLATION.
            if ($cause.HResult -notin @(-2147024891, -2147024864, -2147024863) -or
                $deadline.ElapsedMilliseconds -ge 5000) { throw $failure }
            if (-not $notified) {
                Set-CoordinatorProgress $State 'installing' 'Waiting briefly for Windows to release installation files...'
                if ($null -ne $State) { Write-SolderCoordinatorLog $InstallRoot 'installing' 'retry' 'Waiting for Windows to release an installation file.' }
                $notified = $true
            }
            if ($null -ne $OnRetry) { & $OnRetry }
            Start-Sleep -Milliseconds 250
        }
    }
}

function Publish-SolderTransaction {
    param([string]$InstallRoot, [string]$PayloadRoot, [object[]]$Original, [string]$NewCliPath,
          [object]$CoordinatorState, [scriptblock]$OnMoveRetry)
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
    if ($null -ne $Original[0]) { Move-SolderTransactionItem $InstallRoot $app $paths.backupApp $Original[0] $true $CoordinatorState $OnMoveRetry }
    if ($null -ne $Original[1]) { Move-SolderTransactionItem $InstallRoot $cli $paths.backupCli $Original[1] $false $CoordinatorState $OnMoveRetry }
    if ($null -ne $Original[2]) { Move-SolderTransactionItem $InstallRoot $sidecar $paths.backupSidecar $Original[2] $true $CoordinatorState $OnMoveRetry }
    Move-SolderTransactionItem $InstallRoot (Join-Path $PayloadRoot 'SolderCAD') $app $newApp $true $CoordinatorState $OnMoveRetry
    Move-SolderTransactionItem $InstallRoot $NewCliPath $cli $newCli $false $CoordinatorState $OnMoveRetry
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
        $compilerOptions = @{}
        if ($PSVersionTable.PSEdition -eq 'Desktop') {
            $compilerOptions.ReferencedAssemblies = @([IO.Compression.ZipArchive].Assembly.Location, [IO.Compression.ZipFile].Assembly.Location)
        }
        # Core's default references include compression and must be retained;
        # supplying only the Framework additions hides its other assemblies.
        Add-Type @compilerOptions -TypeDefinition @'
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
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern uint RegisterWindowMessageW(string name);
    [DllImport("user32.dll", SetLastError=true)] private static extern bool PostMessageW(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);
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
      return GetPropW(new IntPtr(handle), "SolderCAD.UpdateCloseProtocol.v2") == new IntPtr(1);
    }
    public static void WakeManager(long handle) {
      uint message = RegisterWindowMessageW("SolderCAD.UpdateReopen.v1");
      if (message == 0 || !PostMessageW(new IntPtr(handle), message, IntPtr.Zero, IntPtr.Zero))
        throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
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
            $instance = $null
            try {
                $instance = [Diagnostics.Process]::GetProcessById([int]$process.ProcessId)
                $started = $instance.StartTime.ToUniversalTime().ToFileTimeUtc().ToString()
                $captured = [pscustomobject]@{ Id = [int]$process.ProcessId; Path = $path; CommandLine = $process.CommandLine;
                                               Created = $process.CreationDate; StartFileTime = $started }
                if (Test-SolderProcessInstance $captured) { $result.Add($captured) }
            } catch {
                if (Test-SolderProcessAlive ([int]$process.ProcessId)) { throw }
            } finally { if ($null -ne $instance) { $instance.Dispose() } }
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
        (Get-TargetIdentity $State.Session.Request $false) -cne $State.Session.RequestIdentity -or
        (Get-FileSha256 $State.Session.Request) -cne $State.Session.RequestHash) {
        Fail 'The update session changed unexpectedly. No further windows were closed; recovery records were preserved.'
    }
}

function Set-SolderSessionReopening {
    param([object]$State, [scriptblock]$ReplaceOperation)
    Assert-SolderReopenSession $State
    $session = $State.Session
    if ($session.Phase -ceq 'reopening') { return }
    if ($session.Phase -cne 'closing') { Fail 'The update session phase could not be verified. Recovery records were preserved.' }
    $record = [IO.File]::ReadAllText($session.Request, [Text.Encoding]::UTF8) | ConvertFrom-Json
    if ($record.phase -cne 'closing' -or $record.nonce -cne $session.Nonce -or
        $record.coordinatorPid -ne $session.CoordinatorPid -or $record.coordinatorStartTime -cne $session.CoordinatorStartTime) {
        Fail 'The update session changed unexpectedly. Recovery records were preserved.'
    }
    $record.phase = 'reopening'
    $content = $record | ConvertTo-Json -Compress
    $replacement = $session.Request + '.' + [Guid]::NewGuid().ToString('N') + '.next'
    $previous = $session.Request + '.' + [Guid]::NewGuid().ToString('N') + '.previous'
    Write-TransactionRecord $replacement $content
    $replacementIdentity = Get-TargetIdentity $replacement $false
    $replacementHash = Get-FileSha256 $replacement
    Assert-SolderReopenSession $State
    # Validate the old backup before adopting a new identity. A concurrent
    # replacement cannot silently become a fresh trusted session baseline.
    $replaceError = $null
    try {
        # The shared ReplaceFile wrapper also restores the verified old file
        # when Windows moves it to backup before reporting a partial failure.
        Invoke-SolderShortcutReplace $replacement $session.Request $previous $session.RequestIdentity $session.RequestHash $ReplaceOperation 3>$null
    } catch { $replaceError = $_ }
    if ((Get-TargetIdentity $session.Request $false) -ceq $session.RequestIdentity -and
        (Get-FileSha256 $session.Request) -ceq $session.RequestHash) {
        # Nothing was published (or the shared wrapper restored the old file).
        # Keep the original authority so the next Retry can try again.
        if ((Get-TargetIdentity $replacement $false) -ceq $replacementIdentity -and
            (Get-FileSha256 $replacement) -ceq $replacementHash) { [IO.File]::Delete($replacement) }
        if ($null -ne $replaceError) { throw $replaceError }
        Fail 'The update session phase was not published. Choose Retry to continue restoring windows.'
    }
    if ((Get-TargetIdentity $previous $false) -cne $session.RequestIdentity -or
        (Get-FileSha256 $previous) -cne $session.RequestHash -or
        (Get-TargetIdentity $session.Request $false) -cne $replacementIdentity -or
        (Get-FileSha256 $session.Request) -cne $replacementHash) {
        Fail 'The update session changed while restoring windows. Recovery records were preserved.'
    }
    $session.RequestIdentity = $replacementIdentity
    $session.RequestHash = $replacementHash
    $session.Phase = 'reopening'
    try { [IO.File]::Delete($previous) }
    catch { Write-Warning 'A verified previous update phase was preserved.' }
}

function New-SolderReopenSession {
    param([string]$InstallRoot, [object]$State, [bool]$RequireNative = $false)
    $request = Join-Path $InstallRoot '.solder-update-reopen-request.json'
    if (@([IO.Directory]::EnumerateFileSystemEntries($InstallRoot, '.solder-update-reopen-request.json')).Count -ne 0) {
        Assert-OrdinaryTarget $request $false
        try {
            $previous = Get-Content -LiteralPath $request -Raw | ConvertFrom-Json
            if ($previous.schemaVersion -ne 1 -or $previous.component -cne 'soldercad-update' -or
                $previous.nonce -cnotmatch '\A[0-9a-f]{32}\z' -or $previous.coordinatorStartTime -cnotmatch '\A[0-9]+\z' -or
                $previous.phase -cnotin @('closing', 'reopening')) { throw 'invalid' }
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
    $started = [Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().ToFileTimeUtc().ToString()
    $record = [ordered]@{ schemaVersion=1; component='soldercad-update'; nonce=$nonce; coordinatorPid=$PID;
                          coordinatorStartTime=$started; phase='closing' } | ConvertTo-Json -Compress
    try { Write-TransactionRecord -Path $request -Content $record }
    catch { [IO.Directory]::Delete($directory); throw }
    $State.Session = [pscustomobject]@{ Nonce=$nonce; InstallRoot=$InstallRoot; Directory=$directory; Request=$request;
        RequestIdentity=(Get-TargetIdentity $request $false); RequestHash=(Get-FileSha256 $request);
        CoordinatorPid=$PID; CoordinatorStartTime=$started; Phase='closing';
        RequireNative=$RequireNative; Processes=@(); CliProcesses=(New-Object 'System.Collections.Generic.List[object]'); Windows=(New-Object 'System.Collections.Generic.List[object]');
        Opened=(New-Object 'System.Collections.Generic.HashSet[string]'); RecordIdentities=@{}; RecordHashes=@{}; Managers=@{}; Standalones=@{};
        MailboxIdentities=@{}; Mailboxes=@{}; ReopenAttempts=@{} }
}

function Assert-SolderRecordedDocument {
    param([string]$Project, [string]$Extension, [bool]$Existed, [bool]$ManagerOwned)
    if (-not $Project) {
        if ($Existed -or $ManagerOwned) { Fail 'A saved SolderCAD document could not be verified. Recovery files were preserved.' }
        return
    }
    if (-not [IO.Path]::IsPathRooted($Project) -or [IO.Path]::GetExtension($Project).ToLowerInvariant() -cne $Extension) {
        Fail 'A saved SolderCAD document does not match its window. Recovery files were preserved.'
    }
    if ($Existed) {
        if (-not (Test-Path -LiteralPath $Project -PathType Leaf)) {
            Fail 'A saved SolderCAD document is unavailable. Recovery files were preserved.'
        }
        return
    }
    # A named, never-saved document can be recreated only if its parent
    # is ordinary and no file, directory, or dangling link has appeared.
    $path = [IO.Path]::GetFullPath($Project)
    $parent = [IO.Path]::GetDirectoryName($path)
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        Fail 'A new SolderCAD document parent is unavailable. Recovery files were preserved.'
    }
    Assert-OrdinaryTarget $parent $true
    $name = [IO.Path]::GetFileName($path)
    if (@([IO.Directory]::EnumerateFileSystemEntries($parent) | Where-Object {
        [IO.Path]::GetFileName($_).Equals($name, [StringComparison]::OrdinalIgnoreCase)
    }).Count) { Fail 'A new SolderCAD document path changed. Recovery files were preserved.' }
}

function Get-SolderReopenEntry {
    param([object]$Session, [object]$Window, [string]$CallerProject, [int]$CallerPid, [bool]$Required)
    $recordPath = Join-Path $Session.Directory ("$($Window.Process.Id)-$($Window.Handle).json")
    if (Test-Path -LiteralPath $recordPath -PathType Leaf) {
        Assert-OrdinaryTarget $recordPath $false
        $file = Get-Item -LiteralPath $recordPath -Force
        if ($file.Length -gt 16384) { Fail 'An update reopen record is too large. Recovery files were preserved.' }
        $identity = Get-TargetIdentity $recordPath $false
        $hash = Get-FileSha256 $recordPath
        # Native reopen records are UTF-8; Windows PowerShell 5.1's default
        # Get-Content encoding is the active ANSI code page, not UTF-8.
        $record = [IO.File]::ReadAllText($recordPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        if ((Get-TargetIdentity $recordPath $false) -cne $identity -or (Get-FileSha256 $recordPath) -cne $hash) {
            Fail 'An update reopen record changed. Recovery files were preserved.'
        }
        if ($Session.RecordIdentities.ContainsKey($recordPath) -and
            ($Session.RecordIdentities[$recordPath] -cne $identity -or $Session.RecordHashes[$recordPath] -cne $hash)) {
            Fail 'An update reopen record changed. Recovery files were preserved.'
        }
        if ($record.schemaVersion -ne 1 -or $record.nonce -cne $Session.Nonce -or
            $record.pid -ne $Window.Process.Id -or [string]$record.hwnd -cne [string]$Window.Handle -or
            $record.executable -isnot [string] -or $record.project -isnot [string] -or $record.frameType -cnotin @('manager', 'schematic', 'pcb') -or
            $record.managerHwnd -isnot [string] -or $record.managerHwnd -cnotmatch '\A[0-9]+\z' -or
            $record.managerStartTime -isnot [string] -or $record.managerStartTime -cnotmatch '\A[0-9]+\z' -or
            $record.managerProject -isnot [string] -or $record.documentExisted -isnot [bool] -or
            -not ([IO.Path]::GetFullPath($record.executable)).Equals($Window.Process.Path, [StringComparison]::OrdinalIgnoreCase)) {
            Fail 'An update reopen record could not be verified. Recovery files were preserved.'
        }
        $managerHandle = [long]0
        if (-not [long]::TryParse($record.managerHwnd, [ref]$managerHandle) -or $managerHandle -lt 0) {
            Fail 'A SolderCAD manager identity could not be verified. Recovery files were preserved.'
        }
        if ($managerHandle -eq 0) {
            if ($record.frameType -ceq 'manager' -or $record.managerStartTime -cne '0' -or $record.managerProject) {
                Fail 'A SolderCAD manager identity could not be verified. Recovery files were preserved.'
            }
        } else {
            if ($record.managerStartTime -ceq '0' -or $record.managerStartTime -cne $Window.Process.StartFileTime) {
                Fail 'A SolderCAD manager identity could not be verified. Recovery files were preserved.'
            }
            if ($record.frameType -ceq 'manager') {
                if ($managerHandle -ne $Window.Handle -or $record.managerProject -cne $record.project) {
                    Fail 'A SolderCAD manager record could not be verified. Recovery files were preserved.'
                }
            } elseif ($managerHandle -eq $Window.Handle -or -not $record.managerProject -or
                      -not [IO.Path]::IsPathRooted($record.managerProject) -or
                      [IO.Path]::GetExtension($record.managerProject).ToLowerInvariant() -cne '.kicad_pro' -or
                      -not (Test-Path -LiteralPath $record.managerProject -PathType Leaf) -or -not $record.project) {
                Fail 'A manager-owned editor record could not be verified. Recovery files were preserved.'
            }
        }
        $target = switch -CaseSensitive ($record.frameType) {
            'manager' { @{ Exe='kicad.exe'; Extension='.kicad_pro' } }
            'schematic' { @{ Exe='eeschema.exe'; Extension='.kicad_sch' } }
            'pcb' { @{ Exe='pcbnew.exe'; Extension='.kicad_pcb' } }
        }
        $managerOwned = $managerHandle -ne 0 -and $record.frameType -cne 'manager'
        # Once a request has been sent, the user may already be editing or
        # saving the restored document even if its acknowledgement was lost.
        # The manager validates the original state and idempotent replay.
        if (-not $Session.Opened.Contains($recordPath) -and -not $Session.ReopenAttempts.ContainsKey($recordPath)) {
            Assert-SolderRecordedDocument -Project $record.project -Extension $target.Extension -Existed $record.documentExisted -ManagerOwned $managerOwned
        }
        $Session.RecordIdentities[$recordPath] = $identity
        $Session.RecordHashes[$recordPath] = $hash
        return [pscustomobject]@{ Key=$recordPath; Executable=(Join-Path $Session.InstallRoot ('SolderCAD\bin\' + $target.Exe)); Project=$record.project;
                                 FrameType=$record.frameType; ManagerHwnd=$managerHandle; ManagerStartTime=$record.managerStartTime;
                                 ManagerProject=$record.managerProject; DocumentExisted=$record.documentExisted }
    }
    if ($Session.RecordIdentities.ContainsKey($recordPath)) { Fail 'An update reopen record disappeared. Recovery files were preserved.' }
    if ($Required) { Fail 'A closed SolderCAD window did not provide its saved document. Recovery files were preserved.' }
    $project = ''
    if ($Window.Process.Id -eq $CallerPid -and $CallerProject) { $project = $CallerProject }
    elseif ($Window.Process.CommandLine) {
        foreach ($arg in @([SolderInstaller.NativePath]::SplitCommandLine($Window.Process.CommandLine))) {
            if ([IO.Path]::IsPathRooted($arg) -and [IO.Path]::GetExtension($arg).ToLowerInvariant() -in @('.kicad_pro', '.kicad_sch', '.kicad_pcb') -and
                (Test-Path -LiteralPath $arg -PathType Leaf)) { $project = $arg; break }
        }
    }
    return [pscustomobject]@{ Key=('legacy-' + $Window.Process.Id); Executable=$Window.Process.Path; Project=$project;
                             FrameType='legacy'; ManagerHwnd=[long]0; ManagerStartTime='0'; ManagerProject=''; DocumentExisted=[bool]$project }
}

function Test-SolderManagerRecordMatches {
    param([object]$Manager, [object]$Child)
    $sameProject = if (-not $Manager.ManagerProject -and -not $Child.ManagerProject) { $true }
                   elseif (-not $Manager.ManagerProject -or -not $Child.ManagerProject) { $false }
                   else { ([IO.Path]::GetFullPath($Manager.ManagerProject)).Equals([IO.Path]::GetFullPath($Child.ManagerProject), [StringComparison]::OrdinalIgnoreCase) }
    return $Manager.FrameType -ceq 'manager' -and $Manager.ManagerHwnd -eq $Child.ManagerHwnd -and
           $Manager.ManagerStartTime -ceq $Child.ManagerStartTime -and $sameProject
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
        $entry = Get-SolderReopenEntry $State.Session ([pscustomobject]@{Handle=$handle; Process=$process[0]}) $CallerProject $CallerPid $true
        if ($entry.ManagerHwnd -ne 0 -and $entry.FrameType -cne 'manager') {
            $managers = @($State.Session.Windows | Where-Object { $_.Process.Id -eq $processId -and $_.Handle -eq $entry.ManagerHwnd })
            if ($managers.Count -ne 1) { Fail 'An editor names an unknown SolderCAD manager. Recovery records were preserved.' }
            $manager = Get-SolderReopenEntry $State.Session $managers[0] $CallerProject $CallerPid $true
            if (-not (Test-SolderManagerRecordMatches $manager $entry)) {
                Fail 'A SolderCAD manager record does not match its editors. Recovery records were preserved.'
            }
        }
    }
}

function Mark-SolderReopenEntry {
    param([object]$State, [object]$Window, [object]$Entry, [int]$CallerPid)
    [void]$State.Session.Opened.Add($Entry.Key)
    $callerWindow = $State.Session.PSObject.Properties['CallerWindow']
    $recordPath = Join-Path $State.Session.Directory ("$($Window.Process.Id)-$($Window.Handle).json")
    if ($CallerPid -gt 0 -and $null -ne $callerWindow -and $Window.Process.Id -eq $CallerPid -and
        $Window.Handle -eq $callerWindow.Value -and $Entry.Key -ceq $recordPath) {
        # Persist across Retry: the restored caller gets a new PID, and a
        # Save As record can differ from the original launch argument.
        $State.CallerReopened = $true
    }
}

function Test-SolderManagerTarget {
    param([object]$Target)
    return (Test-SolderProcessInstance $Target.Captured) -and
           [SolderInstaller.Windows]::Exists($Target.Handle) -and
           [SolderInstaller.Windows]::Owner($Target.Handle) -eq $Target.Captured.Id -and
           [SolderInstaller.Windows]::SupportsSafeClose($Target.Handle)
}

function Remove-SolderExitedReopenTargets {
    param([object]$State, [int]$CallerPid)
    $session = $State.Session
    foreach ($cache in @($session.Managers, $session.Standalones)) {
      foreach ($key in @($cache.Keys)) {
        $target = $cache[$key]
        $target.Process.Refresh()
        if (-not $target.Process.HasExited) { continue }
        foreach ($recordKey in $target.Keys) {
            [void]$session.Opened.Remove($recordKey)
            $callerWindow = $session.PSObject.Properties['CallerWindow']
            if ($CallerPid -gt 0 -and $null -ne $callerWindow -and
                $recordKey -ceq (Join-Path $session.Directory ("$CallerPid-$($callerWindow.Value).json"))) {
                $State.CallerReopened = $false
            }
        }
        $target.Process.Dispose()
        [void]$cache.Remove($key)
      }
    }
}

function Wait-SolderNativeReopenTarget {
    param([string]$InstallRoot, [object]$State, [string]$Key, [object]$ManagerWindow,
          [object]$ManagerEntry, [int]$CallerPid, [int]$TimeoutMs = 30000, [object]$Target = $null)
    $session = $State.Session
    $target = if ($null -ne $Target) { $Target } else { $session.Managers[$Key] }
    $process = $target.Process
    $deadline = [Diagnostics.Stopwatch]::StartNew()
    while ($deadline.ElapsedMilliseconds -lt $TimeoutMs) {
        Assert-SolderReopenSession $State
        if ((Get-TargetIdentity $ManagerEntry.Key $false) -cne $session.RecordIdentities[$ManagerEntry.Key] -or
            (Get-FileSha256 $ManagerEntry.Key) -cne $session.RecordHashes[$ManagerEntry.Key]) {
            Fail 'A SolderCAD window record changed. Recovery records were preserved.'
        }
        $process.Refresh()
        if ($process.HasExited) {
            Remove-SolderExitedReopenTargets $State $CallerPid
            Fail 'A restored SolderCAD window exited before it was ready. Recovery records were preserved.'
        }
        $handle = [long]$process.MainWindowHandle
        if ($handle -gt 0 -and [SolderInstaller.Windows]::Owner($handle) -eq $process.Id -and
            [SolderInstaller.Windows]::SupportsSafeClose($handle)) {
            $captured = @(Get-SolderGuiProcesses $InstallRoot | Where-Object { $_.Id -eq $process.Id })
            if ($captured.Count -eq 1) {
                $target.Captured = $captured[0]
                $target.Handle = $handle
                if (Test-SolderManagerTarget $target) { return $target }
            }
        }
        Start-Sleep -Milliseconds 200
    }
    # Keep the exact still-live process across Retry; starting a second manager
    # would compete for the same project while this one is still starting.
    Fail 'A restored SolderCAD window did not become ready. Recovery records were preserved.'
}

function Get-SolderManagerTarget {
    param([string]$InstallRoot, [object]$State, [object]$Window, [object]$Entry, [int]$CallerPid)
    $session = $State.Session
    $key = "$($Window.Process.Id)-$($Entry.ManagerHwnd)-$($Entry.ManagerStartTime)"
    if ($session.Managers.ContainsKey($key)) {
        $target = $session.Managers[$key]
        $sameProject = if (-not $target.ManagerProject -and -not $Entry.ManagerProject) { $true }
                       elseif (-not $target.ManagerProject -or -not $Entry.ManagerProject) { $false }
                       else { ([IO.Path]::GetFullPath($target.ManagerProject)).Equals([IO.Path]::GetFullPath($Entry.ManagerProject), [StringComparison]::OrdinalIgnoreCase) }
        if (-not $sameProject) { Fail 'A SolderCAD manager record does not match its editors. Recovery records were preserved.' }
        $target.Process.Refresh()
        if ($target.Process.HasExited) {
            Remove-SolderExitedReopenTargets $State $CallerPid
            Fail 'A restored SolderCAD manager exited. Choose Retry to restore its windows.'
        }
        if ($null -eq $target.Captured) {
            $managerWindows = @($session.Windows | Where-Object { $_.Process.Id -eq $Window.Process.Id -and $_.Handle -eq $Entry.ManagerHwnd })
            if ($managerWindows.Count -ne 1) { Fail 'An editor names an unknown SolderCAD manager. Recovery records were preserved.' }
            $managerEntry = Get-SolderReopenEntry $session $managerWindows[0] '' $CallerPid $true
            if (-not (Test-SolderManagerRecordMatches $managerEntry $Entry)) {
                Fail 'A SolderCAD manager record does not match its editors. Recovery records were preserved.'
            }
            return Wait-SolderNativeReopenTarget $InstallRoot $State $key $managerWindows[0] $managerEntry $CallerPid
        }
        if (-not (Test-SolderManagerTarget $target)) { Fail 'A restored SolderCAD manager is no longer available. Recovery records were preserved.' }
        return $target
    }
    $managerWindows = @($session.Windows | Where-Object {
        $_.Process.Id -eq $Window.Process.Id -and $_.Handle -eq $Entry.ManagerHwnd
    })
    if ($managerWindows.Count -ne 1) { Fail 'An editor names an unknown SolderCAD manager. Recovery records were preserved.' }
    $managerWindow = $managerWindows[0]
    if ([SolderInstaller.Windows]::Exists($Entry.ManagerHwnd) -and
        [SolderInstaller.Windows]::Owner($Entry.ManagerHwnd) -eq $Window.Process.Id) {
        $process = Get-Process -Id $Window.Process.Id -ErrorAction Stop
        [void]$process.Handle
        $target = [pscustomobject]@{ Captured=$managerWindow.Process; Handle=$Entry.ManagerHwnd; Process=$process;
            ManagerProject=$Entry.ManagerProject; Keys=(New-Object 'System.Collections.Generic.HashSet[string]') }
        if (-not (Test-SolderManagerTarget $target) -or $target.Captured.StartFileTime -cne $Entry.ManagerStartTime) {
            $process.Dispose()
            Fail 'A SolderCAD manager changed while restoring its editors. Recovery records were preserved.'
        }
        $session.Managers[$key] = $target
        return $target
    }
    $managerEntry = Get-SolderReopenEntry $session $managerWindow '' $CallerPid $true
    if (-not (Test-SolderManagerRecordMatches $managerEntry $Entry)) {
        Fail 'A SolderCAD manager record does not match its editors. Recovery records were preserved.'
    }
    $hint = "$($session.Nonce):$($Window.Process.Id):$($Entry.ManagerHwnd)"
    $process = Open-SolderAfterUpdate -InstallRoot $InstallRoot -Executable $managerEntry.Executable -Project $managerEntry.Project -ManagerHint $hint -PassThru
    $session.Managers[$key] = [pscustomobject]@{ Captured=$null; Handle=[long]0; Process=$process;
        ManagerProject=$managerEntry.ManagerProject; Keys=(New-Object 'System.Collections.Generic.HashSet[string]') }
    return Wait-SolderNativeReopenTarget $InstallRoot $State $key $managerWindow $managerEntry $CallerPid
}

function Get-SolderStandaloneReopenTarget {
    param([string]$InstallRoot, [object]$State, [object]$Window, [object]$Entry, [int]$CallerPid)
    $session = $State.Session
    $key = "$($Window.Process.Id)-$($Window.Handle)"
    if (-not $session.Standalones.ContainsKey($key)) {
        $hint = "$($session.Nonce):$($Window.Process.Id):$($Window.Handle)"
        $newDocument = -not $Entry.DocumentExisted -and -not [string]::IsNullOrWhiteSpace($Entry.Project)
        $process = Open-SolderAfterUpdate -InstallRoot $InstallRoot -Executable $Entry.Executable -Project $Entry.Project -StandaloneHint $hint -NewDocument:$newDocument -PassThru
        # Store the exact process before readiness/ACK waits. Retry must not
        # start a second editor while this one is still loading its file.
        $session.Standalones[$key] = [pscustomobject]@{ Captured=$null; Handle=[long]0; Process=$process;
            Keys=(New-Object 'System.Collections.Generic.HashSet[string]') }
    }
    $target = $session.Standalones[$key]
    if ($null -ne $target.Captured -and (Test-SolderManagerTarget $target)) { return $target }
    return Wait-SolderNativeReopenTarget $InstallRoot $State $key $Window $Entry $CallerPid -Target $target
}

function Invoke-SolderManagerReopen {
    param([object]$State, [object]$Window, [object]$Entry, [object]$Target, [int]$TimeoutMs = 30000)
    $session = $State.Session
    Assert-SolderReopenSession $State
    if (-not (Test-SolderManagerTarget $Target) -or
        (Get-TargetIdentity $Entry.Key $false) -cne $session.RecordIdentities[$Entry.Key] -or
        (Get-FileSha256 $Entry.Key) -cne $session.RecordHashes[$Entry.Key]) {
        Fail 'A SolderCAD window or its recovery record changed. Recovery records were preserved.'
    }
    $mailbox = $session.Mailboxes[$Entry.Key]
    if ($null -eq $mailbox -or $mailbox.TargetPid -ne $Target.Captured.Id -or
        $mailbox.TargetHwnd -ne $Target.Handle -or $mailbox.TargetStartTime -cne $Target.Captured.StartFileTime) {
        $requestId = [Guid]::NewGuid().ToString('N')
        $base = Join-Path $session.Directory ('reopen-' + $requestId)
        $temporary = $base + '.tmp'
        $request = $base + '.request'
        $ack = $base + '.ack'
        $record = [ordered]@{ schemaVersion=1; nonce=$session.Nonce; requestId=$requestId;
            sourcePid=$Window.Process.Id; sourceHwnd=[string]$Window.Handle;
            targetPid=$Target.Captured.Id; targetHwnd=[string]$Target.Handle;
            targetStartTime=$Target.Captured.StartFileTime } | ConvertTo-Json -Compress
        Write-TransactionRecord $temporary $record
        [IO.File]::Move($temporary, $request)
        $requestIdentity = Get-TargetIdentity $request $false
        $mailbox = [pscustomobject]@{ Id=$requestId; Request=$request; Ack=$ack; Identity=$requestIdentity;
            Hash=(Get-FileSha256 $request); TargetPid=$Target.Captured.Id; TargetHwnd=$Target.Handle; TargetStartTime=$Target.Captured.StartFileTime }
        $session.Mailboxes[$Entry.Key] = $mailbox
        $session.MailboxIdentities[$request] = $requestIdentity
    }
    $requestId=$mailbox.Id; $request=$mailbox.Request; $ack=$mailbox.Ack; $requestIdentity=$mailbox.Identity
    $session.ReopenAttempts[$Entry.Key] = $true
    $deadline = [Diagnostics.Stopwatch]::StartNew()
    while ($deadline.ElapsedMilliseconds -lt $TimeoutMs) {
        Assert-SolderReopenSession $State
        if (-not (Test-SolderManagerTarget $Target) -or (Get-TargetIdentity $request $false) -cne $requestIdentity -or
            (Get-FileSha256 $request) -cne $mailbox.Hash -or
            (Get-TargetIdentity $Entry.Key $false) -cne $session.RecordIdentities[$Entry.Key] -or
            (Get-FileSha256 $Entry.Key) -cne $session.RecordHashes[$Entry.Key]) {
            Fail 'A SolderCAD window or its recovery record changed. Recovery records were preserved.'
        }
        if (Test-Path -LiteralPath $ack -PathType Leaf) {
            Assert-OrdinaryTarget $ack $false
            $file = Get-Item -LiteralPath $ack -Force
            if ($file.Length -le 0 -or $file.Length -gt 4096) { Fail 'A SolderCAD manager response could not be verified. Recovery records were preserved.' }
            $ackIdentity = Get-TargetIdentity $ack $false
            $ackHash = Get-FileSha256 $ack
            $response = [IO.File]::ReadAllText($ack, [Text.Encoding]::UTF8) | ConvertFrom-Json
            if ((Get-TargetIdentity $ack $false) -cne $ackIdentity -or (Get-FileSha256 $ack) -cne $ackHash) {
                Fail 'A SolderCAD manager response changed. Recovery records were preserved.'
            }
            if ($response.schemaVersion -ne 1 -or $response.nonce -cne $session.Nonce -or
                $response.requestId -cne $requestId -or $response.status -cnotin @('opened', 'already_open', 'conflict', 'error')) {
                Fail 'A SolderCAD manager response could not be verified. Recovery records were preserved.'
            }
            $session.MailboxIdentities[$ack] = $ackIdentity
            if ($response.status -cnotin @('opened', 'already_open')) {
                # A negative response is final for this request. Retire its
                # verified request first so Retry can issue a fresh request
                # after the user resolves the conflict; an old ACK alone is
                # never interpreted as a new request by the manager.
                if ((Get-TargetIdentity $request $false) -cne $requestIdentity -or (Get-FileSha256 $request) -cne $mailbox.Hash -or
                    (Get-TargetIdentity $ack $false) -cne $ackIdentity -or (Get-FileSha256 $ack) -cne $ackHash) {
                    Fail 'A SolderCAD manager response changed. Recovery records were preserved.'
                }
                [IO.File]::Delete($request)
                [void]$session.Mailboxes.Remove($Entry.Key)
                [void]$session.MailboxIdentities.Remove($request)
                try { [IO.File]::Delete($ack); [void]$session.MailboxIdentities.Remove($ack) }
                catch { Write-Warning 'A previous update response could not be cleaned and was preserved.' }
                Fail 'SolderCAD could not confirm that this editor reopened. Recovery records were preserved. Choose Retry.'
            }
            if (-not (Test-SolderManagerTarget $Target) -or
                (Get-TargetIdentity $Entry.Key $false) -cne $session.RecordIdentities[$Entry.Key] -or
                (Get-FileSha256 $Entry.Key) -cne $session.RecordHashes[$Entry.Key] -or
                (Get-TargetIdentity $request $false) -cne $requestIdentity -or (Get-FileSha256 $request) -cne $mailbox.Hash -or
                (Get-TargetIdentity $ack $false) -cne $ackIdentity -or (Get-FileSha256 $ack) -cne $ackHash) {
                Fail 'A restored SolderCAD window or its recovery record changed. Recovery records were preserved.'
            }
            return
        }
        [SolderInstaller.Windows]::WakeManager($Target.Handle)
        Start-Sleep -Milliseconds 200
    }
    Fail 'SolderCAD could not confirm that this window reopened. Recovery records were preserved. Choose Retry.'
}

function Open-SolderReopenSession {
    param([string]$InstallRoot, [object]$State, [string]$CallerProject, [int]$CallerPid, [bool]$Required)
    if ($null -eq $State.Session) { return }
    Assert-OrdinaryTarget $State.Session.Directory $true
    Set-SolderSessionReopening $State
    Remove-SolderExitedReopenTargets $State $CallerPid
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
    $pending = New-Object 'System.Collections.Generic.List[object]'
    foreach ($window in $State.Session.Windows) {
        if ([SolderInstaller.Windows]::Exists($window.Handle) -and [SolderInstaller.Windows]::Owner($window.Handle) -eq $window.Process.Id) { continue }
        # Every frame accepted by the v2 preflight must checkpoint its close,
        # including frames closed before a later window vetoed the update.
        $mustHaveRecord = $window.ExpectedRecord
        $recordPath = Join-Path $State.Session.Directory ("$($window.Process.Id)-$($window.Handle).json")
        if ($State.Session.RequireNative -and -not $mustHaveRecord -and -not (Test-Path -LiteralPath $recordPath -PathType Leaf) -and
            $window.Handle -ne $State.Session.CallerWindow) { continue }
        $entry = Get-SolderReopenEntry $State.Session $window $CallerProject $CallerPid $mustHaveRecord
        if ($State.Session.Opened.Contains($entry.Key)) { continue }
        $pending.Add([pscustomobject]@{ Window=$window; Entry=$entry })
    }
    # Open managers before their owned children. Reopening those children as
    # standalone editors can take the project lock before the manager starts.
    foreach ($item in $pending) {
        if ($item.Entry.FrameType -ceq 'manager') {
            $target = Get-SolderManagerTarget $InstallRoot $State $item.Window $item.Entry $CallerPid
            Invoke-SolderManagerReopen $State $item.Window $item.Entry $target
            Mark-SolderReopenEntry $State $item.Window $item.Entry $CallerPid
            [void]$target.Keys.Add($item.Entry.Key)
        }
    }
    foreach ($item in $pending) {
        if ($item.Entry.ManagerHwnd -ne 0 -and $item.Entry.FrameType -cne 'manager') {
            $target = Get-SolderManagerTarget $InstallRoot $State $item.Window $item.Entry $CallerPid
            Invoke-SolderManagerReopen $State $item.Window $item.Entry $target
            Mark-SolderReopenEntry $State $item.Window $item.Entry $CallerPid
            [void]$target.Keys.Add($item.Entry.Key)
        }
    }
    foreach ($item in $pending) {
        if ($item.Entry.ManagerHwnd -eq 0) {
            if ($item.Entry.FrameType -ceq 'legacy') {
                Open-SolderAfterUpdate -InstallRoot $InstallRoot -Executable $item.Entry.Executable -Project $item.Entry.Project
            } else {
                $target = Get-SolderStandaloneReopenTarget $InstallRoot $State $item.Window $item.Entry $CallerPid
                Invoke-SolderManagerReopen $State $item.Window $item.Entry $target
                [void]$target.Keys.Add($item.Entry.Key)
            }
            Mark-SolderReopenEntry $State $item.Window $item.Entry $CallerPid
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
    Assert-SolderReopenSession $State
    foreach ($path in @($session.RecordIdentities.Keys)) {
        try {
            if ($session.Opened.Contains($path) -and (Get-TargetIdentity $path $false) -ceq $session.RecordIdentities[$path] -and
                (-not $session.RecordHashes.ContainsKey($path) -or (Get-FileSha256 $path) -ceq $session.RecordHashes[$path])) {
                [IO.File]::Delete($path)
            }
        } catch { Write-Warning 'An update reopen record could not be cleaned and was preserved.' }
    }
    foreach ($path in @($session.MailboxIdentities.Keys)) {
        try {
            if ((Get-TargetIdentity $path $false) -ceq $session.MailboxIdentities[$path]) { [IO.File]::Delete($path) }
        } catch { Write-Warning 'An update reopen message could not be cleaned and was preserved.' }
    }
    [IO.File]::Delete($session.Request)
    # Unknown files survive; never recursively clean an unrecognized record.
    try { [IO.Directory]::Delete($session.Directory, $false) } catch { }
    foreach ($target in @($session.Managers.Values) + @($session.Standalones.Values)) {
        if ($null -ne $target.Process) { $target.Process.Dispose() }
    }
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
    param([string]$Executable, [string]$WorkingDirectory, [string]$Project,
          [bool]$NewEmptyManager = $false, [string]$ManagerHint, [string]$StandaloneHint)
    Initialize-SolderWindowApi
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $Executable
    $start.WorkingDirectory = $WorkingDirectory
    $start.UseShellExecute = $false
    if ($Project) { $start.Arguments = Quote-SolderArgument $Project }
    elseif ($NewEmptyManager) { $start.Arguments = '-n' }
    $start.EnvironmentVariables.Remove('SOLDER_UPDATE_REOPEN_MANAGER')
    $start.EnvironmentVariables.Remove('SOLDER_UPDATE_REOPEN_STANDALONE')
    if ($ManagerHint) { $start.EnvironmentVariables['SOLDER_UPDATE_REOPEN_MANAGER'] = $ManagerHint }
    if ($StandaloneHint) { $start.EnvironmentVariables['SOLDER_UPDATE_REOPEN_STANDALONE'] = $StandaloneHint }
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
    param([string]$InstallRoot, [string]$Executable, [string]$Project,
          [string]$ManagerHint, [switch]$PassThru, [string]$StandaloneHint, [switch]$NewDocument)
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
        $extension = [IO.Path]::GetExtension($projectPath).ToLowerInvariant()
        if ($NewDocument) {
            if ($StandaloneHint -cnotmatch '\A[0-9a-f]{32}:[1-9][0-9]*:[1-9][0-9]*\z' -or
                $extension -cnotin @('.kicad_sch', '.kicad_pcb')) {
                Fail 'A new SolderCAD document has no verified restore request. Recovery records were preserved.'
            }
            Assert-SolderRecordedDocument $projectPath $extension $false $false
        } elseif ($extension -cnotin @('.kicad_pro', '.kicad_sch', '.kicad_pcb') -or
                  -not (Test-Path -LiteralPath $projectPath -PathType Leaf)) {
            Fail "SolderCAD was installed, but the previous project could not be reopened."
        }
    }
    $emptyManager = -not $projectPath -and [IO.Path]::GetFileName($executablePath).Equals('kicad.exe', [StringComparison]::OrdinalIgnoreCase)
    $process = Start-SolderGuiProcess -Executable $executablePath -WorkingDirectory ([IO.Path]::GetDirectoryName($executablePath)) -Project $projectPath -NewEmptyManager $emptyManager -ManagerHint $ManagerHint -StandaloneHint $StandaloneHint
    $returned = $false
    try {
        if ($process.WaitForExit(2000)) {
            $process.Refresh()
            if ($process.ExitCode -ne 0 -or $PassThru) { Fail "SolderCAD could not start after the update. Retry opening it." }
        }
        if ($PassThru) { $returned = $true; return $process }
    } finally { if (-not $returned) { $process.Dispose() } }
}

function Assert-SolderStagedReopenCapability {
    param([string]$StagedApp, [object]$State)
    $valid = $false
    try {
        if ($StagedApp -and (Test-Path -LiteralPath $StagedApp -PathType Container)) {
            $directory = $StagedApp
            Assert-OrdinaryTarget $directory $true
            foreach ($part in @('share', 'kicad', 'resources', 'solder_chat')) {
                $directory = Join-Path $directory $part
                Assert-OrdinaryTarget $directory $true
                if (-not (Test-Path -LiteralPath $directory -PathType Container)) { throw 'missing capability directory' }
            }
            $marker = Join-Path $directory 'windows-update-capabilities.json'
            Assert-OrdinaryTarget $marker $false
            if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) { throw 'missing capability marker' }
            $file = Get-Item -LiteralPath $marker -Force
            if ($file.Length -le 0 -or $file.Length -gt 4096) { throw 'invalid capability marker' }
            $identity = Get-TargetIdentity $marker $false
            $hash = Get-FileSha256 $marker
            $capability = [IO.File]::ReadAllText($marker, [Text.Encoding]::UTF8) | ConvertFrom-Json
            $valid = (Get-TargetIdentity $marker $false) -ceq $identity -and (Get-FileSha256 $marker) -ceq $hash -and
                ($capability.schemaVersion -is [int] -or $capability.schemaVersion -is [long]) -and $capability.schemaVersion -eq 1 -and
                $capability.component -is [string] -and $capability.component -ceq 'soldercad' -and
                ($capability.windowsUpdateCloseProtocol -is [int] -or $capability.windowsUpdateCloseProtocol -is [long]) -and $capability.windowsUpdateCloseProtocol -eq 2 -and
                ($capability.windowsManagerReopenProtocol -is [int] -or $capability.windowsManagerReopenProtocol -is [long]) -and $capability.windowsManagerReopenProtocol -eq 1
            $valid = $valid -and
                ($capability.windowsStandaloneReopenProtocol -is [int] -or $capability.windowsStandaloneReopenProtocol -is [long]) -and $capability.windowsStandaloneReopenProtocol -eq 1 -and
                ($capability.windowsUpdateSessionPhaseProtocol -is [int] -or $capability.windowsUpdateSessionPhaseProtocol -is [long]) -and $capability.windowsUpdateSessionPhaseProtocol -eq 1
            $valid = $valid -and
                ($capability.windowsNamedNewStandaloneProtocol -is [int] -or $capability.windowsNamedNewStandaloneProtocol -is [long]) -and $capability.windowsNamedNewStandaloneProtocol -eq 1
        }
    } catch { $valid = $false }
    if (-not $valid) {
        Set-CoordinatorProgress $State 'manual-close' 'Save and close all SolderCAD windows, then choose Retry.'
        Fail 'This SolderCAD release cannot reopen your windows automatically. Save and close them, then choose Retry.'
    }
}

function Test-SolderStagedCliCapabilities {
    param([string]$Executable, [object]$State, [int]$TimeoutMs = 15000)
    $probe = Join-Path ([IO.Path]::GetTempPath()) ('solder-capabilities-' + [Guid]::NewGuid().ToString('N'))
    $stdout = Join-Path $probe 'stdout'; $stderr = Join-Path $probe 'stderr'
    $process = $null
    try {
        Assert-CoordinatorNotCancelled $State
        $identity = Get-TargetIdentity $Executable $false
        $hash = Get-FileSha256 $Executable
        [void][IO.Directory]::CreateDirectory($probe)
        $deadline = [Diagnostics.Stopwatch]::StartNew()
        $process = Start-Process -FilePath $Executable -ArgumentList '--windows-update-capabilities' -NoNewWindow -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        [void]$process.Handle
        while (-not $process.WaitForExit(100)) {
            Assert-CoordinatorNotCancelled $State
            if ($deadline.ElapsedMilliseconds -ge $TimeoutMs -or
                ((Test-Path -LiteralPath $stdout) -and (Get-Item -LiteralPath $stdout).Length -gt 4096) -or
                ((Test-Path -LiteralPath $stderr) -and (Get-Item -LiteralPath $stderr).Length -gt 4096)) { return $false }
        }
        $process.Refresh()
        Assert-CoordinatorNotCancelled $State
        if ($deadline.ElapsedMilliseconds -gt $TimeoutMs -or $process.ExitCode -ne 0 -or (Get-Item -LiteralPath $stdout).Length -gt 4096 -or
            (Get-Item -LiteralPath $stderr).Length -gt 4096 -or (Get-TargetIdentity $Executable $false) -cne $identity -or
            (Get-FileSha256 $Executable) -cne $hash) { return $false }
        $data = [IO.File]::ReadAllText($stdout, [Text.Encoding]::UTF8) | ConvertFrom-Json
        return ($data.schemaVersion -is [int] -or $data.schemaVersion -is [long]) -and $data.schemaVersion -eq 1 -and
            $data.component -is [string] -and $data.component -ceq 'solder-cli' -and
            ($data.terminalDraftRestore -is [int] -or $data.terminalDraftRestore -is [long]) -and $data.terminalDraftRestore -eq 1 -and
            ($data.webDraftRestore -is [int] -or $data.webDraftRestore -is [long]) -and $data.webDraftRestore -eq 1
    } catch [OperationCanceledException] { throw }
    catch { return $false }
    finally {
        if ($null -ne $process) {
            try { if (-not $process.HasExited) { $process.Kill(); [void]$process.WaitForExit(5000) } } catch { }
            $process.Dispose()
        }
        foreach ($file in @($stdout, $stderr)) { try { [IO.File]::Delete($file) } catch { } }
        try { [IO.Directory]::Delete($probe, $false) } catch { }
    }
}

function Assert-SolderStagedCliForRunningSessions {
    param([string]$InstallRoot, [object]$State, [bool]$Supported, [object[]]$GuiProcesses)
    if ($Supported) { return }
    $running = $null -ne $GuiProcesses -and $GuiProcesses.Count -gt 0
    if (-not $running) {
        $target = Join-Path $InstallRoot 'bin\solder.exe'
        foreach ($entry in @(Get-CimInstance Win32_Process -Filter "Name = 'solder.exe'" -ErrorAction Stop)) {
            if ([string]::IsNullOrWhiteSpace($entry.ExecutablePath)) {
                if (Test-SolderProcessAlive ([int]$entry.ProcessId)) { $running = $true; break }
                continue
            }
            if ((Resolve-PhysicalPath $entry.ExecutablePath).Equals($target, [StringComparison]::OrdinalIgnoreCase)) {
                $running = $true; break
            }
        }
    }
    if ($running) {
        Set-CoordinatorProgress $State 'manual-close' 'Save and close SolderCAD and Solder terminal sessions, then choose Retry.'
        Fail 'This Solder release cannot restore open sessions automatically. Save and close them, then choose Retry.'
    }
}

function Close-SolderForUpdate {
    param([string]$InstallRoot, [object]$State, [int]$CallerPid, [long]$CallerWindow, [object]$Held, [string]$StagedApp, [bool]$CliRestoreSupported)
    Initialize-SolderWindowApi
    Assert-SolderReopenSession $State
    if ($State.Session.Phase -cne 'closing') { Fail 'A recovery session cannot close additional windows. Choose Retry to continue restoring them.' }
    if ($State.CallerReopened) { $CallerPid = 0; $CallerWindow = 0 }
    $processes = @(Get-SolderGuiProcesses $InstallRoot)
    $State.Session.Processes = $processes
    Assert-SolderStagedCliForRunningSessions $InstallRoot $State $CliRestoreSupported $processes
    # The incoming release must be able to restore the records produced by
    # the currently running v2 windows. Older packages remain installable
    # after those windows are closed manually.
    if ($processes.Count -gt 0) { Assert-SolderStagedReopenCapability $StagedApp $State }
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
        # A receiver can exit while processing WM_CLOSE, before Windows
        # returns its response. A gone captured HWND is closed; the native
        # record validation below still gates publication for every frame.
        if (-not $responded -and -not $closed) {
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
    param([string]$InstallRoot, [object]$State, [bool]$CliRestoreSupported)
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
        if (-not $CliRestoreSupported) {
            Set-CoordinatorProgress $State 'manual-close' 'Save and close SolderCAD and Solder terminal sessions, then choose Retry.'
            Fail 'This Solder release cannot restore open sessions automatically. Save and close them, then choose Retry.'
        }
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
    # An anonymous repair request is satisfied by a restored manager or a
    # captured manager that survived Cancel. kicad --frame is an editor, so
    # verify the captured invocation as well as its live process and window.
    $anonymousManagerSatisfied = $false
    if ($CallerPid -le 0 -and [string]::IsNullOrWhiteSpace($Project) -and
        [string]::Equals([IO.Path]::GetFileName($Executable), 'kicad.exe', [StringComparison]::OrdinalIgnoreCase)) {
        $anonymousManagerSatisfied = $State.Session.Managers.Count -gt 0
        if (-not $anonymousManagerSatisfied) {
            foreach ($window in $State.Session.Windows) {
                if (-not [string]::Equals([IO.Path]::GetFileName($window.Process.Path), 'kicad.exe', [StringComparison]::OrdinalIgnoreCase) -or
                    [string]::IsNullOrWhiteSpace($window.Process.CommandLine)) { continue }
                $arguments = @([SolderInstaller.NativePath]::SplitCommandLine($window.Process.CommandLine))
                $frameArguments = @($arguments | Select-Object -Skip 1 | Where-Object {
                    $_.StartsWith('-f', [StringComparison]::OrdinalIgnoreCase) -or $_.StartsWith('/f', [StringComparison]::OrdinalIgnoreCase) -or
                    $_.StartsWith('--frame', [StringComparison]::OrdinalIgnoreCase)
                })
                if ($arguments.Count -gt 0 -and $frameArguments.Count -eq 0 -and
                    (Test-SolderProcessInstance $window.Process) -and [SolderInstaller.Windows]::Exists($window.Handle) -and
                    [SolderInstaller.Windows]::Owner($window.Handle) -eq $window.Process.Id -and
                    [SolderInstaller.Windows]::SupportsSafeClose($window.Handle)) {
                    $anonymousManagerSatisfied = $true
                    break
                }
            }
        }
    }
    if (-not $State.CallerReopened -and -not $callerCaptured -and -not $anonymousManagerSatisfied -and
        -not $State.Session.Opened.Contains('caller-fallback')) {
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
    # Official resources/bitmaps_png/icons/icon_soldercad.ico from kicad-source-mirror.
    # Embedded so fresh installs and repairs never depend on an installed executable.
    # SHA256: 48b05838958bba7b6994031e21019680fe2d4a52a61f54c050fec8255bc84abc
    $iconStream = [IO.MemoryStream]::new([Convert]::FromBase64String(@'
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
yxYtG1QHglRiLEgY3RUrhJBJovTJgF8vsEqJna5jp+tYJasFOLzq2V3tsLtasUqJPkZ2dnZY7ezS9Su61YrUd/PAiGCVSxIC2+3I2c2Wu+67n1tv+zQf/NAtfOyTn+DuvX3iaufuvqx/7M9uftdrbrvtts2DQacHjQHacfXVTzr8uEdf9+1f8cSveMWzv/KZz/3yGx8nD7nsCkQi27GwWWfGoU4p4RgjsQvGGDEgER+Z7io5
CrETfLyuS5B5ixI9Cumaw8yIToja3E67LtXFpDCWYViZJN2ihi2p0yJ8xcrSPdyrxdLKtWRqHv/f9u4mJWIgiALwSyeNCCISRRTBTRaewL13Fc/hxp2oa2EWIhiQSUYzE/PTvy4qQS8wLuR9mxygikCq0v3k6eVLI4YIbw3GscfY9ei7DsNgYLxkKXz1BnXT4r1q8NH2WNuAZjBx0493VbO6fnl8vSnLh26b9dl6A/xWFMVx
np9fnRyeXub7Rxe7O3tnCtmBc1KGeRaglFxEqdIMKsmm9I0Uqc6QToHOWmsorZDpVM7fZYkELKtEmmRKpo9zIqdKkCj5OyfAy5EzpeSqo3k8PL32ZSMhA525+DLQSaQhvPtpCsgeIDgDby3idGglxIDoAecsjLXw3sPaeVUdMBqLthvQDvZzY/zbejTP9XJ1X5X17WLxtPzLuhAREREREREREREREdE/9Q2Xs9s3oU9MvwAA
AABJRU5ErkJggolQTkcNChoKAAAADUlIRFIAAAEAAAABAAgGAAAAXHKoZgAAAAZiS0dEAP8A/wD/oL2nkwAAIABJREFUeJzsvXnQbddVH/hba5/7fd8b9Z5myU+jZVlY8jwhz5ax8cBgKBwCxNB0J3Qq3U2RpIDu6qGqK9UFobq6kibpdLordHUzNDQYPCQGY2IDYTIewQN4lo1HCct6etJ7371n77X6j99ae5/vmSS2kZ5k
192qT+8O55x7hr3W+q3fGjawHduxHduxHduxHduxHduxHduxHduxHduxHduxHduxHduxHduxHduxHduxHduxHduxHduxHduxHduxHduxHduxHduxHduxHduxHduxHduxHduxHduxHduxHduxHduxHduxHduxHduxHduxHduxHduxHduxHduxHduxHduxHduxHduxHduxHduxHduxHduxHduxHduxHduxHduxHQ/ekIf7BC7g
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
'@))
    $updateIcon = [Drawing.Icon]::new($iconStream)
    $form.Icon = $updateIcon
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
                    } elseif ($state.Stage -eq 'manual-close') {
                        $label.Text = 'This release cannot restore open sessions automatically. Save and close SolderCAD and Solder terminals, then choose Retry.'
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
        $updateIcon.Dispose()
        $iconStream.Dispose()
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
            $cliRestoreSupported = Test-SolderStagedCliCapabilities $verifiedCli $CoordinatorState
            Assert-SolderStagedCliForRunningSessions $InstallDir $CoordinatorState $cliRestoreSupported @(Get-SolderGuiProcesses $InstallDir)
            New-SolderReopenSession -InstallRoot $InstallDir -State $CoordinatorState -RequireNative $RequireReopenRecords
            $heldHosts = Open-SolderPreparedHosts -InstallRoot $InstallDir -State $CoordinatorState
            try {
                Close-SolderForUpdate -InstallRoot $InstallDir -State $CoordinatorState -CallerPid $CallerProcessId -CallerWindow $CallerWindowHandle -Held $heldHosts -StagedApp $payloadSolderCad -CliRestoreSupported $cliRestoreSupported
                Close-SolderPreparedHosts -Held $heldHosts -State $CoordinatorState
            } finally { foreach ($held in $heldHosts) { $held.Pipe.Dispose(); $held.Process.Dispose() } }
            Assert-CoordinatorNotCancelled $CoordinatorState
            Close-SolderTerminalsForUpdate -InstallRoot $InstallDir -State $CoordinatorState -CliRestoreSupported $cliRestoreSupported
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
        Publish-SolderTransaction -InstallRoot $InstallDir -PayloadRoot $payloadRoot -Original $original -NewCliPath $verifiedCli -CoordinatorState $CoordinatorState
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
