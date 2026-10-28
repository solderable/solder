param([Parameter(Mandatory=$true)][string]$Installer)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($Installer, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw $errors[0].Message }
foreach ($statement in $ast.EndBlock.Statements) {
    if ($statement -is [Management.Automation.Language.FunctionDefinitionAst]) {
        . ([scriptblock]::Create($statement.Extent.Text))
    }
}
function Assert-Condition([bool]$Value, [string]$Message) { if (-not $Value) { throw $Message } }
function New-State {
    return [hashtable]::Synchronized(@{ Stage=''; Message=''; CancelRequested=$false; CanCancel=$true; ClosedAny=$false; PublicationCommitted=$false; PublicationComplete=$false; SetupComplete=$false; PendingRestore=$false; Session=$null })
}
function Wait-For([scriptblock]$Condition, [string]$Message) {
    $deadline = [Diagnostics.Stopwatch]::StartNew()
    while ($deadline.ElapsedMilliseconds -lt 15000) {
        if (& $Condition) { return }
        Start-Sleep -Milliseconds 100
    }
    throw $Message
}

$root = Join-Path $env:TEMP ('solder-seamless-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$children = New-Object 'System.Collections.Generic.List[System.Diagnostics.Process]'
try {
    $root = Resolve-PhysicalPath $root
    # The real Windows Forms event and background PowerShell runspace must
    # retain every caller option, including when the user chooses Retry.
    Add-Type -AssemblyName System.Windows.Forms
    $workerSource = Join-Path $root 'coordinator-options-fixture.ps1'
    $workerText = @'
[CmdletBinding()]
param([string]$InstallDir,[string]$Version,[ValidateSet('Auto','GitHub')][string]$DownloadSource,
      [string]$InstallerScriptPath,[switch]$NoUserIntegration,[switch]$ManageLauncher,
      [switch]$RequireReopenRecords,[switch]$InternalCoordinator,[switch]$InternalReopen,
      [object]$CoordinatorState,[string]$RelaunchExecutable,[string]$RelaunchProject,
      [int]$CallerProcessId,[long]$CallerWindowHandle)
$record=[ordered]@{Version=$Version;DownloadSource=$DownloadSource;NoUserIntegration=[bool]$NoUserIntegration;
 ManageLauncher=[bool]$ManageLauncher;RequireReopenRecords=[bool]$RequireReopenRecords;
 InternalCoordinator=[bool]$InternalCoordinator;InternalReopen=[bool]$InternalReopen;
 InstallerScriptPath=$InstallerScriptPath;InstallDir=$InstallDir;RelaunchExecutable=$RelaunchExecutable;RelaunchProject=$RelaunchProject;
 CallerProcessId=$CallerProcessId;CallerWindowHandle=$CallerWindowHandle}
$path=Join-Path $InstallDir 'coordinator-options.jsonl'
[IO.File]::AppendAllText($path,($record|ConvertTo-Json -Compress)+[Environment]::NewLine)
if(@([IO.File]::ReadAllLines($path)).Count -eq 1){throw 'fixture retry'}
$CoordinatorState.Stage='complete'
'@
    [IO.File]::WriteAllText($workerSource, $workerText)
    $clickRetry = New-Object Windows.Forms.Timer
    $clickRetry.Interval = 100
    $clickRetry.Add_Tick({
        foreach ($window in @([Windows.Forms.Application]::OpenForms)) {
            if ($window.Text -cne 'SolderCAD Update') { continue }
            foreach ($control in $window.Controls) {
                if ($control -is [Windows.Forms.Button] -and $control.Text -ceq 'Retry' -and $control.Visible) { $control.PerformClick() }
            }
        }
    })
    $clickRetry.Start()
    $optionExecutable = Join-Path $root 'app with spaces\kicad.exe'
    $optionProject = Join-Path $root ('project ' + [char]0x03c0 + '.kicad_pro')
    try {
        Start-SolderCoordinator -ScriptPath $workerSource -InstallRoot $root -Executable $optionExecutable -Project $optionProject -CallerPid 4321 -CallerWindow 5678 -NoIntegration $true -Manage $true -RequireRecords $true -RequestedVersion '1.35.0' -RequestedSource 'GitHub'
    } finally { $clickRetry.Stop(); $clickRetry.Dispose() }
    $results=@([IO.File]::ReadAllLines((Join-Path $root 'coordinator-options.jsonl')) | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-Condition ($results.Count -eq 2) 'the coordinator did not retry its worker exactly once'
    foreach ($result in $results) {
        Assert-Condition ($result.Version -ceq '1.35.0' -and $result.DownloadSource -ceq 'GitHub' -and
            $result.NoUserIntegration -and $result.ManageLauncher -and $result.RequireReopenRecords -and
            $result.InternalCoordinator -and -not $result.InternalReopen -and $result.InstallDir -ceq $root -and
            $result.InstallerScriptPath -ceq $workerSource -and $result.RelaunchExecutable -ceq $optionExecutable -and
            $result.RelaunchProject -ceq $optionProject -and $result.CallerProcessId -eq 4321 -and $result.CallerWindowHandle -eq 5678) 'coordinator options changed across the event/runspace boundary'
    }
    foreach ($relative in Get-SolderLaunchFiles) {
        $path = Join-Path $root $relative
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
        [IO.File]::WriteAllText($path, 'fixture-data')
    }
    $source = [IO.File]::ReadAllText($Installer)
    $helper = Save-SolderRepairLauncher $root $source
    $pointer = [IO.File]::ReadAllText((Join-Path $root 'repair\launcher.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
    Assert-Condition ($pointer.schemaVersion -eq 1 -and $pointer.script -ceq [IO.Path]::GetFileName($helper) -and
        $pointer.sha256 -ieq (Get-FileSha256 $helper)) 'the repair pointer does not identify the verified helper'
    Assert-Condition (Test-SolderLaunchHealth $root) 'a healthy installation was rejected'
    $cli = Join-Path $root 'bin\solder.exe'
    [IO.File]::WriteAllText($cli, 'fixture-DATA')
    Assert-Condition (-not (Test-SolderLaunchHealth $root)) 'same-size CLI corruption was not detected'
    [IO.File]::WriteAllText($cli, 'fixture-data')
    Remove-Item $cli
    Assert-Condition (-not (Test-SolderLaunchHealth $root)) 'a missing CLI was not detected'
    [IO.File]::WriteAllText($cli, 'fixture-data')
    $resource = Join-Path $root 'SolderCAD\share\kicad\resources\solder_chat\chat.html'
    Remove-Item $resource
    Assert-Condition (-not (Test-SolderLaunchHealth $root)) 'a missing GUI resource was not detected'
    [IO.File]::WriteAllText($resource, 'fixture-data')
    $metadata = Join-Path $root 'SolderCAD\share\kicad\resources\solder_chat\solder-release.json'
    [IO.File]::WriteAllText($metadata, 'fixture-DATA')
    Assert-Condition (-not (Test-SolderLaunchHealth $root)) 'damaged release metadata was not detected'
    [IO.File]::WriteAllText($metadata, 'fixture-data')
    $helper2 = Save-SolderRepairLauncher $root $source
    Assert-Condition ($helper -ceq $helper2 -and (Test-SolderLaunchHealth $root)) 'refreshing the verified launch receipt failed'
    Write-SolderCoordinatorLog $root 'downloading' 'failure' 'GET https://example.invalid/path?token=secret-url Authorization: Bearer secret-header'
    $lines = [IO.File]::ReadAllLines((Join-Path $root 'repair\update-log.jsonl'), [Text.Encoding]::UTF8)
    $log = $lines[$lines.Length - 1]
    $event = $log | ConvertFrom-Json
    Assert-Condition ($event.stage -ceq 'downloading' -and $event.outcome -ceq 'failure' -and
        -not $log.Contains('secret-url') -and -not $log.Contains('secret-header')) 'update diagnostics leaked secrets or lost their failure stage'
    New-Item -ItemType Directory (Join-Path $root '.solder-installer-transaction') | Out-Null
    Assert-Condition (-not (Test-SolderLaunchHealth $root)) 'a pending transaction was launched instead of recovered'
    Remove-Item (Join-Path $root '.solder-installer-transaction')

    # Verify shortcut ownership without touching the real desktop.
    $shell = New-Object -ComObject WScript.Shell
    $shortcutPath = Join-Path $root 'owned.lnk'
    $link = $shell.CreateShortcut($shortcutPath)
    $link.TargetPath = Join-Path $root 'SolderCAD\bin\kicad.exe'
    $link.Save()
    Assert-Condition (Test-SolderOwnedShortcut $shortcutPath $root) 'the existing app shortcut was not recognized'
    Set-SolderManagedShortcut $shortcutPath $root $helper $false
    Assert-Condition (Test-SolderOwnedShortcut $shortcutPath $root) 'the managed shortcut was not recognized'
    $savedLink = (New-Object -ComObject WScript.Shell).CreateShortcut($shortcutPath)
    $expectedTarget = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Assert-Condition ($savedLink.TargetPath.Equals($expectedTarget, [StringComparison]::OrdinalIgnoreCase) -and
        $savedLink.Arguments -ceq (Get-SolderLauncherArguments $root $helper $false) -and
        ((Get-Item -LiteralPath $shortcutPath -Force).Attributes -band [IO.FileAttributes]::Hidden) -eq 0) 'the saved shortcut has an incorrect target, arguments, or visibility'
    $other = Join-Path $root 'other.lnk'
    $link = $shell.CreateShortcut($other)
    $link.TargetPath = Join-Path $env:SystemRoot 'system32\notepad.exe'
    $link.Save()
    Assert-Condition (-not (Test-SolderOwnedShortcut $other $root)) 'an unrelated shortcut was considered owned'
    $unrelatedHash = Get-FileSha256 $other
    Set-SolderManagedShortcut -ShortcutPath $other -InstallRoot $root -RepairScript $helper -Repair $false -OnlyOwned $true
    Assert-Condition ((Get-FileSha256 $other) -ceq $unrelatedHash) 'an unrelated shortcut was replaced during a managed repair'
    $oldShortcutHash = Get-FileSha256 $shortcutPath
    $refused = $false
    try { Set-SolderManagedShortcut -ShortcutPath $shortcutPath -InstallRoot $root -RepairScript ($helper + [char]0 + 'bad') -Repair $false }
    catch { $refused = $true }
    Assert-Condition ($refused -and (Get-FileSha256 $shortcutPath) -ceq $oldShortcutHash) 'a failed shortcut write changed the existing shortcut'

    # Windows ReplaceFile can move the original to its backup before failing.
    # Inject only that OS failure boundary; the recovery uses real file moves,
    # identity and hashes, including a concurrently created foreign target.
    $partialTarget=Join-Path $root 'partial-target.lnk'
    $partialSource=Join-Path $root 'partial-source.lnk'
    $partialBackup=Join-Path $root 'partial-backup.lnk'
    [IO.File]::Copy($shortcutPath,$partialTarget)
    [IO.File]::Copy($shortcutPath,$partialSource)
    $partialIdentity=Get-TargetIdentity $partialTarget $false
    $partialHash=Get-FileSha256 $partialTarget
    $partialFailure={param($source,$target,$backup) [IO.File]::Move($target,$backup); throw 'fixture ReplaceFile failure'}
    $message=''
    try { Invoke-SolderShortcutReplace $partialSource $partialTarget $partialBackup $partialIdentity $partialHash $partialFailure 3>$null }
    catch { $message=$_.Exception.Message }
    Assert-Condition ($message -ceq 'fixture ReplaceFile failure' -and (Test-Path -LiteralPath $partialTarget) -and
        -not (Test-Path -LiteralPath $partialBackup) -and (Get-TargetIdentity $partialTarget $false) -ceq $partialIdentity -and
        (Get-FileSha256 $partialTarget) -ceq $partialHash) 'a partial shortcut replacement did not restore the original'

    $foreignTarget=Join-Path $root 'foreign-target.lnk'
    $foreignSource=Join-Path $root 'foreign-source.lnk'
    $foreignBackup=Join-Path $root 'foreign-backup.lnk'
    [IO.File]::Copy($shortcutPath,$foreignTarget)
    [IO.File]::Copy($shortcutPath,$foreignSource)
    $foreignIdentity=Get-TargetIdentity $foreignTarget $false
    $foreignHash=Get-FileSha256 $foreignTarget
    $foreignFailure={param($source,$target,$backup) [IO.File]::Move($target,$backup); [IO.File]::WriteAllText($target,'foreign shortcut'); throw 'fixture ReplaceFile failure'}
    $message=''
    try { Invoke-SolderShortcutReplace $foreignSource $foreignTarget $foreignBackup $foreignIdentity $foreignHash $foreignFailure 3>$null }
    catch { $message=$_.Exception.Message }
    Assert-Condition ($message -ceq 'fixture ReplaceFile failure' -and [IO.File]::ReadAllText($foreignTarget) -ceq 'foreign shortcut' -and
        (Get-TargetIdentity $foreignBackup $false) -ceq $foreignIdentity -and (Get-FileSha256 $foreignBackup) -ceq $foreignHash) 'a concurrent shortcut or original backup was overwritten'

    $changedTarget=Join-Path $root 'changed-target.lnk'
    $changedSource=Join-Path $root 'changed-source.lnk'
    $changedBackup=Join-Path $root 'changed-backup.lnk'
    [IO.File]::Copy($shortcutPath,$changedTarget)
    [IO.File]::Copy($shortcutPath,$changedSource)
    $changedIdentity=Get-TargetIdentity $changedTarget $false
    $changedHash=Get-FileSha256 $changedTarget
    $changedFailure={param($source,$target,$backup) [IO.File]::Move($target,$backup); [IO.File]::WriteAllText($backup,'changed backup'); throw 'fixture ReplaceFile failure'}
    $message=''
    try { Invoke-SolderShortcutReplace $changedSource $changedTarget $changedBackup $changedIdentity $changedHash $changedFailure 3>$null }
    catch { $message=$_.Exception.Message }
    Assert-Condition ($message -ceq 'fixture ReplaceFile failure' -and -not (Test-Path -LiteralPath $changedTarget) -and
        [IO.File]::ReadAllText($changedBackup) -ceq 'changed backup') 'a changed shortcut backup was moved or removed'

    # A loopback HTTP endpoint exercises the real streaming downloader and
    # cancellation while a response body is stalled, without external network.
    $socket = New-Object Net.Sockets.TcpListener ([Net.IPAddress]::Loopback), 0
    $socket.Start(); $port = $socket.LocalEndpoint.Port
    $state = New-State
    $server = [PowerShell]::Create()
    [void]$server.AddScript(@'
param($listener, $state)
try {
 $client = $listener.AcceptTcpClient()
 $stream = $client.GetStream()
 $request = New-Object byte[] 4096
 [void]$stream.Read($request, 0, $request.Length)
 $bytes = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Length: 100`r`nConnection: close`r`n`r`nabc")
 $stream.Write($bytes, 0, $bytes.Length)
 $stream.Flush()
 Start-Sleep -Seconds 1
 $state.CancelRequested = $true
 Start-Sleep -Seconds 2
 $client.Close()
} catch { }
'@).AddArgument($socket).AddArgument($state)
    $serverJob = $server.BeginInvoke()
    $downloadCancelled = $false
    try { Save-SolderDownload "http://127.0.0.1:$port/" (Join-Path $root 'partial.zip') 100 $state }
    catch [OperationCanceledException] { $downloadCancelled = $true }
    finally {
        $socket.Stop(); [void]$server.EndInvoke($serverJob); $server.Dispose()
    }
    Assert-Condition $downloadCancelled 'cancellation did not interrupt the stalled response body'
    Assert-Condition ((Get-Item (Join-Path $root 'partial.zip')).Length -lt 100) 'the cancelled response was treated as complete'

    # A short-lived fixture exposes a real PID-scoped named pipe and deliberately
    # splits its response, as permitted by the stream protocol.
    Remove-Item $cli
    $pipeSource = @'
using System;
using System.IO;
using System.IO.Pipes;
using System.Diagnostics;
using System.Text;
using System.Threading;
public class CooperativeFixture {
 public static void Main(string[] args) {
  if (args.Length > 0 && args[0] == "stay") { Thread.Sleep(60000); return; }
  if (args.Length > 0 && (args[0] == "pcb" || args[0] == "--url" || args[0] == "--resume")) {
   File.WriteAllLines(Environment.GetEnvironmentVariable("SOLDER_TEST_CLI_OPENED"), args); return;
  }
  using (var pipe = new NamedPipeServerStream("solder-update-shutdown-v1-" + Process.GetCurrentProcess().Id, PipeDirection.InOut, 1)) {
   File.WriteAllText(Environment.GetEnvironmentVariable("SOLDER_TEST_PIPE_READY"), "ready");
   pipe.WaitForConnection();
   var reader = new StreamReader(pipe, Encoding.ASCII, false, 128, true);
   string request = reader.ReadLine();
   if (args.Length > 0 && args[0] == "ui-host") {
    if (!request.StartsWith("prepare ") || request.Length != 40) return;
    byte[] ready = Encoding.ASCII.GetBytes(args.Length > 1 && args[1] == "blocked" ? "blocked\n" : "ready\n");
    pipe.Write(ready, 0, ready.Length); pipe.Flush();
    if (args.Length > 1 && args[1] == "blocked") return;
    if (args.Length > 1 && args[1] == "disconnect") { pipe.Dispose(); Thread.Sleep(1200); return; }
    string next = reader.ReadLine();
    if (next != "shutdown") { File.WriteAllText(Environment.GetEnvironmentVariable("SOLDER_TEST_HOST_RELEASED"), "released"); return; }
   } else if (request != "shutdown") return;
   byte[] response = Encoding.ASCII.GetBytes("closing\n");
   pipe.Write(response,0,3); pipe.Flush(); Thread.Sleep(100); pipe.Write(response,3,5); pipe.Flush();
  }
 }
}
'@
    Add-Type -OutputAssembly $cli -OutputType ConsoleApplication -TypeDefinition $pipeSource
    $env:SOLDER_TEST_PIPE_READY = Join-Path $root 'pipe-ready'
    $child = Start-Process -FilePath $cli -PassThru -WindowStyle Hidden
    $children.Add($child)
    Wait-For { Test-Path -LiteralPath $env:SOLDER_TEST_PIPE_READY } 'the fixture pipe did not start'
    $state = New-State
    New-SolderReopenSession $root $state
    Close-SolderTerminalsForUpdate $root $state
    Assert-Condition ($child.WaitForExit(5000)) 'a cooperative terminal was not closed'
    $env:SOLDER_TEST_CLI_OPENED = Join-Path $root 'cli-opened.txt'
    $board = Join-Path $root ('board ' + [char]0x03c0 + '.kicad_pcb')
    New-Item -ItemType File -Path $board | Out-Null
    $cliRecord = [ordered]@{ schemaVersion=1; nonce=$state.Session.Nonce; pid=$child.Id; kind='cli'; executable=$cli;
        projectDir=$root; conversationId='saved_session-123'; url='wss://example.invalid/chat'; boardPath=$board } | ConvertTo-Json -Compress
    Write-TransactionRecord (Join-Path $state.Session.Directory ("cli-$($child.Id).json")) $cliRecord
    Open-SolderReopenSession $root $state '' 0 $false
    Wait-For { Test-Path -LiteralPath $env:SOLDER_TEST_CLI_OPENED } 'the restored terminal did not start'
    $actualArgs = @([IO.File]::ReadAllLines($env:SOLDER_TEST_CLI_OPENED))
    $expectedArgs = @('pcb','--board',$board,'--url','wss://example.invalid/chat','--resume','saved_session-123')
    Assert-Condition (($actualArgs -join '|') -ceq ($expectedArgs -join '|')) 'a terminal did not resume its project, board, endpoint and conversation'
    Complete-SolderReopenSession $state

    Remove-Item -LiteralPath $env:SOLDER_TEST_CLI_OPENED
    $live = Start-Process -FilePath $cli -ArgumentList 'stay' -PassThru -WindowStyle Hidden
    $children.Add($live)
    $liveCim = Get-CimInstance Win32_Process -Filter ("ProcessId = " + $live.Id)
    $state = New-State
    New-SolderReopenSession $root $state
    $state.Session.CliProcesses.Add([pscustomobject]@{ Id=$live.Id; Path=(Resolve-PhysicalPath $cli); Created=$liveCim.CreationDate })
    $liveRecord = [ordered]@{ schemaVersion=1; nonce=$state.Session.Nonce; pid=$live.Id; kind='cli'; executable=$cli;
        projectDir=$root; conversationId='saved_session-123'; url='wss://example.invalid/chat' } | ConvertTo-Json -Compress
    $liveRecordPath = Join-Path $state.Session.Directory ("cli-$($live.Id).json")
    Write-TransactionRecord $liveRecordPath $liveRecord
    Open-SolderReopenSession $root $state '' 0 $false
    Assert-Condition ((-not $live.HasExited) -and (-not (Test-Path -LiteralPath $env:SOLDER_TEST_CLI_OPENED))) 'a live terminal was started a second time'
    Complete-SolderReopenSession $state
    Assert-Condition (Test-Path -LiteralPath $liveRecordPath) 'a live terminal recovery record was not preserved'
    Stop-Process -Id $live.Id -Force
    [void]$live.WaitForExit(5000)

    Remove-Item -LiteralPath $env:SOLDER_TEST_PIPE_READY
    $env:SOLDER_TEST_HOST_RELEASED = Join-Path $root 'host-released'
    $hostChild = Start-Process -FilePath $cli -ArgumentList 'ui-host' -PassThru -WindowStyle Hidden
    $children.Add($hostChild)
    Wait-For { Test-Path -LiteralPath $env:SOLDER_TEST_PIPE_READY } 'the fixture chat host did not start'
    $state = New-State
    New-SolderReopenSession $root $state
    $held = Open-SolderPreparedHosts $root $state
    Assert-Condition ($held.Count -eq 1 -and -not $hostChild.HasExited) 'the chat host was not prepared and held'
    foreach ($entry in $held) { $entry.Pipe.Dispose(); $entry.Process.Dispose() }
    Wait-For { Test-Path -LiteralPath $env:SOLDER_TEST_HOST_RELEASED } 'cancelling did not release the prepared chat host'
    Assert-Condition ($hostChild.WaitForExit(5000)) 'the fixture chat host did not finish'
    Complete-SolderReopenSession $state

    Remove-Item -LiteralPath $env:SOLDER_TEST_PIPE_READY
    $disconnectedHost = Start-Process -FilePath $cli -ArgumentList 'ui-host disconnect' -PassThru -WindowStyle Hidden
    $children.Add($disconnectedHost)
    Wait-For { Test-Path -LiteralPath $env:SOLDER_TEST_PIPE_READY } 'the disconnected chat fixture did not start'
    $state = New-State
    New-SolderReopenSession $root $state
    $held = Open-SolderPreparedHosts $root $state
    Wait-For { -not [SolderInstaller.Windows]::PipeReady($held[0].Pipe.SafePipeHandle.DangerousGetHandle()) } 'the revoked fixture pipe remained connected'
    $refused = $false
    try { Assert-SolderPreparedHosts $held $state } catch { $refused = $true }
    Assert-Condition $refused 'a revoked preparation was accepted before any editor closed'
    $state.ClosedAny = $true
    try {
        Assert-SolderPreparedHosts $held $state
        Close-SolderPreparedHosts $held $state
    }
    finally { foreach ($entry in $held) { $entry.Pipe.Dispose(); $entry.Process.Dispose() } }
    Assert-Condition ($disconnectedHost.HasExited) 'a disconnected prepared chat host was not drained'
    Complete-SolderReopenSession $state

    Remove-Item -LiteralPath $env:SOLDER_TEST_PIPE_READY
    $busyHost = Start-Process -FilePath $cli -ArgumentList 'ui-host blocked' -PassThru -WindowStyle Hidden
    $children.Add($busyHost)
    Wait-For { Test-Path -LiteralPath $env:SOLDER_TEST_PIPE_READY } 'the busy chat fixture did not start'
    $state = New-State
    New-SolderReopenSession $root $state
    $blocked = $false
    try { [void](Open-SolderPreparedHosts $root $state) } catch { $blocked = $true }
    Assert-Condition ($blocked -and $state.Stage -ceq 'chat-busy') 'busy chat did not produce the actionable retry state'
    Complete-SolderReopenSession $state

    # Real top-level fixture windows exercise WM_CLOSE and cancellation without
    # using desktop mouse/keyboard automation or touching user applications.
    $gui = Join-Path $root 'SolderCAD\bin\kicad.exe'
    Remove-Item $gui
    $guiSource = @'
using System;
using System.IO;
using System.Threading;
using System.Windows.Forms;
using System.Drawing;
using System.Runtime.InteropServices;
public class GuiFixture {
 [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern bool SetPropW(IntPtr hwnd, string name, IntPtr value);
 [STAThread] public static void Main(string[] args) {
  if (args.Length == 0 || (args[0] != "close" && args[0] != "veto" && args[0] != "delayed" && args[0] != "legacy" && args[0] != "owned" && args[0] != "untitled")) {
   File.AppendAllText(Environment.GetEnvironmentVariable("SOLDER_TEST_OPENED"), Path.GetFileName(Application.ExecutablePath) + "|" + (args.Length == 0 ? "(empty)" : args[0]) + "\n"); return;
  }
  var f = new Form(); f.Text="Solder fixture"; f.StartPosition=FormStartPosition.Manual;
  f.HandleCreated += (sender,e) => { if(args[0]!="legacy") SetPropW(f.Handle,"SolderCAD.UpdateCloseProtocol.v1",new IntPtr(1)); };
  f.Location=new Point(-3000,-3000); f.ShowInTaskbar=true;
  if (args[0]=="owned") f.Shown += (sender,e) => {
   var hidden = new Form(); hidden.Text="Hidden child";
   hidden.HandleCreated += (s,a) => SetPropW(hidden.Handle,"SolderCAD.UpdateCloseProtocol.v1",new IntPtr(1));
   hidden.Show(f); hidden.Hide();
  };
  if (args[0]=="untitled") f.Shown += (sender,e) => {
   var unknown = new Form(); unknown.Text=""; unknown.ShowInTaskbar=false; unknown.Show(f);
  };
  f.FormClosing += (sender,e) => { if(args[0]=="veto") e.Cancel=true; if(args[0]=="delayed") Thread.Sleep(1500); };
  Application.Run(f);
 }
}
'@
    Add-Type -OutputAssembly $gui -OutputType WindowsApplication -ReferencedAssemblies @('System.Windows.Forms','System.Drawing') -TypeDefinition $guiSource
    foreach ($editor in @('eeschema.exe', 'pcbnew.exe')) {
        $path = Join-Path $root ('SolderCAD\bin\' + $editor)
        Remove-Item -LiteralPath $path -Force
        [IO.File]::Copy($gui, $path)
    }
    $env:SOLDER_TEST_OPENED = Join-Path $root 'opened.txt'
    $project = Join-Path $root ("saved project " + [char]0x03c0 + "'s.kicad_pro")
    New-Item -ItemType File -Path $project | Out-Null

    $legacy = Start-Process -FilePath $gui -ArgumentList 'legacy' -PassThru
    $children.Add($legacy)
    Wait-For { $legacy.Refresh(); $legacy.MainWindowHandle -ne 0 } 'the legacy fixture window did not start'
    $state = New-State
    New-SolderReopenSession $root $state
    $refused = $false
    try { Close-SolderForUpdate $root $state $legacy.Id ([long]$legacy.MainWindowHandle) }
    catch { $refused = $_.Exception.Message -like '*older SolderCAD window*' }
    Assert-Condition ($refused -and -not $legacy.HasExited) 'an unprovable legacy window was closed'
    Complete-SolderReopenSession $state
    Stop-Process -Id $legacy.Id -Force
    [void]$legacy.WaitForExit(5000)

    $untitled = Start-Process -FilePath $gui -ArgumentList 'untitled' -PassThru
    $children.Add($untitled)
    Wait-For { @([SolderInstaller.Windows]::TopLevelWindows($untitled.Id)).Count -ge 2 } 'the untitled fixture window did not start'
    $state = New-State
    New-SolderReopenSession $root $state
    $untitled.Refresh()
    $refused = $false
    try { Close-SolderForUpdate $root $state $untitled.Id ([long]$untitled.MainWindowHandle) }
    catch { $refused = $_.Exception.Message -like '*older SolderCAD window*' }
    Assert-Condition ($refused -and -not $untitled.HasExited) 'an unknown untitled window was closed'
    Complete-SolderReopenSession $state
    Stop-Process -Id $untitled.Id -Force
    [void]$untitled.WaitForExit(5000)

    # A prepared chat can revoke its proof while the updater is about to close
    # an editor. The real close path must leave that editor untouched.
    Remove-Item -LiteralPath $env:SOLDER_TEST_PIPE_READY -ErrorAction SilentlyContinue
    $revokedHost = Start-Process -FilePath $cli -ArgumentList 'ui-host disconnect' -PassThru -WindowStyle Hidden
    $children.Add($revokedHost)
    Wait-For { Test-Path -LiteralPath $env:SOLDER_TEST_PIPE_READY } 'the revoked host fixture did not start'
    $guardedWindow = Start-Process -FilePath $gui -ArgumentList 'close' -PassThru
    $children.Add($guardedWindow)
    Wait-For { $guardedWindow.Refresh(); $guardedWindow.MainWindowHandle -ne 0 } 'the guarded editor fixture did not start'
    $state = New-State
    New-SolderReopenSession $root $state
    $held = Open-SolderPreparedHosts $root $state
    Wait-For { -not [SolderInstaller.Windows]::PipeReady($held[0].Pipe.SafePipeHandle.DangerousGetHandle()) } 'the fixture did not revoke its prepared host'
    $refused = $false
    try { Close-SolderForUpdate $root $state $guardedWindow.Id ([long]$guardedWindow.MainWindowHandle) $held }
    catch { $refused = $true }
    finally { foreach ($entry in $held) { $entry.Pipe.Dispose(); $entry.Process.Dispose() } }
    Assert-Condition ($refused -and -not $guardedWindow.HasExited) 'a revoked chat proof allowed its editor to close'
    Complete-SolderReopenSession $state
    Stop-Process -Id $guardedWindow.Id -Force
    [void]$guardedWindow.WaitForExit(5000)

    $owned = Start-Process -FilePath $gui -ArgumentList 'owned' -PassThru
    $children.Add($owned)
    Initialize-SolderWindowApi
    Wait-For { @([SolderInstaller.Windows]::CapableWindows($owned.Id)).Count -ge 2 } 'the hidden child fixture window did not start'
    $state = New-State
    New-SolderReopenSession $root $state
    $owned.Refresh()
    Close-SolderForUpdate $root $state $owned.Id ([long]$owned.MainWindowHandle)
    Assert-Condition ($state.Session.Windows.Count -ge 2) 'an owned or hidden capable frame was not captured'
    Complete-SolderReopenSession $state

    $veto = Start-Process -FilePath $gui -ArgumentList 'veto' -PassThru
    $children.Add($veto)
    Wait-For { $veto.Refresh(); $veto.MainWindowHandle -ne 0 } 'the veto fixture window did not start'
    $state = New-State
    New-SolderReopenSession $root $state
    $cancelled = $false
    try { Close-SolderForUpdate $root $state $veto.Id ([long]$veto.MainWindowHandle) }
    catch [OperationCanceledException] { $cancelled = $true }
    Assert-Condition $cancelled 'an editor veto did not cancel the update'
    Assert-Condition (-not $veto.HasExited) 'the vetoed window was force-closed'
    Complete-SolderReopenSession $state
    Stop-Process -Id $veto.Id -Force
    [void]$veto.WaitForExit(5000)

    $delayed = Start-Process -FilePath $gui -ArgumentList 'delayed' -PassThru
    $children.Add($delayed)
    Wait-For { $delayed.Refresh(); $delayed.MainWindowHandle -ne 0 } 'the delayed fixture window did not start'
    $state = New-State
    New-SolderReopenSession $root $state
    $cancel = [PowerShell]::Create()
    [void]$cancel.AddScript('param($s) Start-Sleep -Milliseconds 500; $s.CancelRequested=$true').AddArgument($state)
    $pending = $cancel.BeginInvoke()
    $cancelled = $false
    try { Close-SolderForUpdate $root $state $delayed.Id ([long]$delayed.MainWindowHandle) }
    catch [OperationCanceledException] { $cancelled = $true }
    [void]$cancel.EndInvoke($pending); $cancel.Dispose()
    Assert-Condition ($cancelled -and $state.ClosedAny) 'cancellation lost a window that had finished closing'
    Open-SolderReopenSession $root $state $project $delayed.Id $false
    Assert-Condition (([IO.File]::ReadAllText($env:SOLDER_TEST_OPENED)).Trim() -ceq ('kicad.exe|' + $project)) 'a safely closed window was not restored with its project'
    Complete-SolderReopenSession $state

    # After-save records include the final document name, including other
    # hidden child frames; each is restored exactly once.
    Remove-Item $env:SOLDER_TEST_OPENED
    $saved2 = Join-Path $root 'other saved board.kicad_pcb'
    New-Item -ItemType File -Path $saved2 | Out-Null
    $fixture = Start-Process -FilePath $gui -ArgumentList 'close' -PassThru
    $children.Add($fixture)
    Wait-For { $fixture.Refresh(); $fixture.MainWindowHandle -ne 0 } 'the save fixture window did not start'
    $handle = [long]$fixture.MainWindowHandle
    $state = New-State
    New-SolderReopenSession $root $state
    Close-SolderForUpdate $root $state $fixture.Id $handle
    $refused = $false
    try { Assert-SolderClosedWindowRecords $state '' $fixture.Id } catch { $refused = $true }
    Assert-Condition $refused 'publication would proceed without the closed-window record'
    foreach ($item in @(@{ hwnd=$handle; project=$project; frameType='manager' }, @{ hwnd=987654321; project=$saved2; frameType='pcb' }, @{ hwnd=987654320; project=''; frameType='schematic' })) {
        $record = [ordered]@{ schemaVersion=1; nonce=$state.Session.Nonce; pid=$fixture.Id; hwnd=[string]$item.hwnd; executable=$gui; project=$item.project; frameType=$item.frameType } | ConvertTo-Json -Compress
        Write-TransactionRecord (Join-Path $state.Session.Directory ("$($fixture.Id)-$($item.hwnd).json")) $record
    }
    Assert-SolderClosedWindowRecords $state '' $fixture.Id
    Open-SolderReopenSession $root $state '' $fixture.Id $true
    Open-SolderReopenSession $root $state '' $fixture.Id $true
    $opened = @([IO.File]::ReadAllLines($env:SOLDER_TEST_OPENED))
    Assert-Condition ($opened.Count -eq 3 -and $opened -ccontains ('kicad.exe|' + $project) -and
        $opened -ccontains ('pcbnew.exe|' + $saved2) -and $opened -ccontains 'eeschema.exe|(empty)') 'post-save, hidden-child and empty documents were not reopened once each'
    Complete-SolderReopenSession $state

    # A new editor can start after the first editor closes but before the
    # publication guard. The unjournaled staging directory is disposable;
    # the newcomer must stay open while the earlier saved window reopens.
    Remove-Item -LiteralPath $env:SOLDER_TEST_OPENED
    $first = Start-Process -FilePath $gui -ArgumentList 'close' -PassThru
    $children.Add($first)
    Wait-For { $first.Refresh(); $first.MainWindowHandle -ne 0 } 'the first editor fixture did not start'
    $firstHandle=[long]$first.MainWindowHandle
    $state=New-State
    New-SolderReopenSession $root $state $true
    Close-SolderForUpdate $root $state $first.Id $firstHandle
    $record=[ordered]@{ schemaVersion=1; nonce=$state.Session.Nonce; pid=$first.Id; hwnd=[string]$firstHandle;
        executable=$gui; project=$project; frameType='manager' } | ConvertTo-Json -Compress
    Write-TransactionRecord (Join-Path $state.Session.Directory ("$($first.Id)-$firstHandle.json")) $record
    $tx=Join-Path $root '.solder-installer-transaction'
    $payload=Join-Path $tx 'payload'
    New-Item -ItemType Directory -Force -Path (Join-Path $payload 'SolderCAD') | Out-Null
    [IO.File]::Copy($cli,(Join-Path $payload 'solder.exe'))
    Write-TransactionRecord (Join-Path $tx 'owner') 'solder-installer-transaction-v1'
    $original=@((Get-TargetIdentity (Join-Path $root 'SolderCAD') $true),
                (Get-TargetIdentity $cli $false), (Get-TargetIdentity (Join-Path $root 'bin\SolderCAD') $true))
    $stageIdentity=Get-TargetIdentity $tx $true
    $originalCliHash=Get-FileSha256 $cli
    $newcomer=Start-Process -FilePath $gui -ArgumentList 'veto' -PassThru
    $children.Add($newcomer)
    Wait-For { $newcomer.Refresh(); $newcomer.MainWindowHandle -ne 0 } 'the later editor fixture did not start'
    $blocked=$false
    try { Publish-SolderTransaction $root $payload $original (Join-Path $payload 'solder.exe') } catch { $blocked=$true }
    Assert-Condition ($blocked -and -not (Test-Path -LiteralPath (Join-Path $tx 'journal.json'))) 'a later editor did not stop publication before its journal'
    Recover-SolderFailedPublication $root $original $stageIdentity
    Assert-Condition (-not (Test-Path -LiteralPath $tx) -and -not $newcomer.HasExited -and
        (Get-TargetIdentity (Join-Path $root 'SolderCAD') $true) -ceq $original[0] -and
        (Get-FileSha256 $cli) -ceq $originalCliHash) 'pre-publication recovery changed the live pair or closed the later editor'
    Open-SolderReopenSession $root $state $project $first.Id $true
    Wait-For { Test-Path -LiteralPath $env:SOLDER_TEST_OPENED } 'the earlier saved window was not reopened'
    Assert-Condition (([IO.File]::ReadAllText($env:SOLDER_TEST_OPENED)).Trim() -ceq ('kicad.exe|' + $project) -and
        -not $newcomer.HasExited) 'the saved window was not restored while the later editor stayed open'
    Complete-SolderReopenSession $state

    # A journal, unknown ownership, changed original, or foreign stage must
    # never take the unjournaled bypass while the later process remains open.
    foreach($mode in @('journal','committed','owner','changed','foreign')) {
        New-Item -ItemType Directory -Path $tx | Out-Null
        $owner=if($mode -ceq 'owner'){'foreign-owner'}else{'solder-installer-transaction-v1'}
        Write-TransactionRecord (Join-Path $tx 'owner') $owner
        if($mode -ceq 'journal'){Write-TransactionRecord (Join-Path $tx 'journal.json') '{}'}
        if($mode -ceq 'committed'){Write-TransactionRecord (Join-Path $tx 'committed') 'committed-v1'}
        $testIdentity=Get-TargetIdentity $tx $true
        $testOriginal=$original.Clone()
        if($mode -ceq 'foreign'){$testIdentity='foreign-stage'}
        if($mode -ceq 'changed'){$testOriginal[0]='foreign-app'}
        $blocked=$false
        try { Recover-SolderFailedPublication $root $testOriginal $testIdentity } catch { $blocked=$true }
        Assert-Condition ($blocked -and (Test-Path -LiteralPath $tx) -and -not $newcomer.HasExited) "recovery bypassed a $mode transaction while an editor was open"
        Remove-Item -LiteralPath $tx -Recurse -Force
    }
    Stop-Process -Id $newcomer.Id -Force
    [void]$newcomer.WaitForExit(5000)
    Write-Output 'PASS seamless-update'
} finally {
    foreach ($child in $children) {
        try { if (-not $child.HasExited) { Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue } } catch { }
    }
    Remove-Item Env:SOLDER_TEST_OPENED, Env:SOLDER_TEST_PIPE_READY, Env:SOLDER_TEST_HOST_RELEASED, Env:SOLDER_TEST_CLI_OPENED -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
