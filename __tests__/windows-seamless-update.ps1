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
    return [hashtable]::Synchronized(@{ Stage=''; Message=''; CancelRequested=$false; CanCancel=$true; ClosedAny=$false; PublicationCommitted=$false; PublicationComplete=$false; SetupComplete=$false; PendingRestore=$false; CallerReopened=$false; Session=$null })
}
function Wait-For([scriptblock]$Condition, [string]$Message) {
    $deadline = [Diagnostics.Stopwatch]::StartNew()
    while ($deadline.ElapsedMilliseconds -lt 15000) {
        if (& $Condition) { return }
        Start-Sleep -Milliseconds 100
    }
    throw $Message
}
function Close-TestRestoredManagers([object]$State) {
    foreach($target in @($State.Session.Managers.Values) + @($State.Session.Standalones.Values)) {
        if($null -ne $target.Process -and -not $target.Process.HasExited) {
            if(-not $target.Process.CloseMainWindow() -or -not $target.Process.WaitForExit(10000)) { throw 'A disposable restored manager did not close normally' }
        }
    }
}

$root = Join-Path $env:TEMP ('solder-seamless-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$children = New-Object 'System.Collections.Generic.List[System.Diagnostics.Process]'
try {
    $root = Resolve-PhysicalPath $root
    # The close marker becomes a reopen-only marker before launching any
    # restored window. Retry must preserve that exact trusted replacement.
    $phaseState=New-State
    New-SolderReopenSession $root $phaseState $true
    $initialRequest=[IO.File]::ReadAllText($phaseState.Session.Request)|ConvertFrom-Json
    Assert-Condition ($initialRequest.phase -ceq 'closing') 'a new update was not in its closing phase'
    Open-SolderReopenSession $root $phaseState '' 0 $true
    $reopenRequest=[IO.File]::ReadAllText($phaseState.Session.Request)|ConvertFrom-Json
    $reopenIdentity=$phaseState.Session.RequestIdentity
    Assert-Condition ($reopenRequest.phase -ceq 'reopening' -and $reopenRequest.nonce -ceq $initialRequest.nonce -and
        $reopenRequest.coordinatorPid -eq $initialRequest.coordinatorPid -and $reopenRequest.coordinatorStartTime -ceq $initialRequest.coordinatorStartTime) 'the reopening transition changed coordinator authority'
    Open-SolderReopenSession $root $phaseState '' 0 $true
    Assert-Condition ($phaseState.Session.RequestIdentity -ceq $reopenIdentity) 'recovery Retry rewrote its trusted phase marker'
    $refused=$false
    try { Close-SolderForUpdate $root $phaseState 0 0 } catch {$refused=$true}
    Assert-Condition $refused 'a reopening session could close more windows'
    Complete-SolderReopenSession $phaseState
    $phaseState=New-State
    New-SolderReopenSession $root $phaseState $true
    $originalMarker=[IO.File]::ReadAllText($phaseState.Session.Request)
    [IO.File]::WriteAllText($phaseState.Session.Request,$originalMarker.Replace('"closing"','"foreign"'))
    $refused=$false
    try { Set-SolderSessionReopening $phaseState } catch {$refused=$true}
    Assert-Condition ($refused -and ([IO.File]::ReadAllText($phaseState.Session.Request)).Contains('"foreign"')) 'an in-place marker change became a trusted phase baseline'
    [IO.File]::WriteAllText($phaseState.Session.Request,$originalMarker)
    Complete-SolderReopenSession $phaseState
    foreach ($mode in @('before-replace', 'after-backup', 'after-publish', 'foreign')) {
        $phaseState=New-State
        New-SolderReopenSession $root $phaseState $true
        $oldIdentity=$phaseState.Session.RequestIdentity
        $script:phaseReplacementMode=$mode
        $replaceFailure={param($source,$target,$backup)
            if($script:phaseReplacementMode -ceq 'before-replace'){throw 'fixture phase replace failure'}
            [IO.File]::Move($target,$backup)
            if($script:phaseReplacementMode -ceq 'after-publish'){[IO.File]::Move($source,$target)}
            if($script:phaseReplacementMode -ceq 'foreign'){[IO.File]::WriteAllText($target,'foreign phase')}
            throw 'fixture phase replace failure'
        }
        $refused=$false
        try { Set-SolderSessionReopening $phaseState $replaceFailure } catch {$refused=$true}
        if($mode -ceq 'after-publish'){
            Assert-Condition (-not $refused -and $phaseState.Session.Phase -ceq 'reopening' -and
                $phaseState.Session.RequestIdentity -cne $oldIdentity) 'a verified published phase was lost after a reported ReplaceFile failure'
        } elseif($mode -ceq 'foreign') {
            Assert-Condition ($refused -and ([IO.File]::ReadAllText($phaseState.Session.Request)) -ceq 'foreign phase' -and
                $phaseState.Session.Phase -ceq 'closing') 'a foreign phase marker was overwritten or adopted'
            $backup=@(Get-ChildItem -LiteralPath $root -File -Filter '.solder-update-reopen-request.json.*.previous' | Where-Object {
                (Get-TargetIdentity $_.FullName $false) -ceq $oldIdentity
            })
            Assert-Condition ($backup.Count -eq 1) 'the verified original phase backup was lost'
            [IO.File]::Delete($phaseState.Session.Request)
            [IO.File]::Move($backup[0].FullName,$phaseState.Session.Request)
        } else {
            Assert-Condition ($refused -and $phaseState.Session.Phase -ceq 'closing' -and
                (Get-TargetIdentity $phaseState.Session.Request $false) -ceq $oldIdentity) 'an unpublished phase could not be retried with its original authority'
        }
        Set-SolderSessionReopening $phaseState
        Complete-SolderReopenSession $phaseState
    }
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
  if (args.Length == 1 && args[0] == "--windows-update-capabilities") {
   string mode = Environment.GetEnvironmentVariable("SOLDER_TEST_CAPABILITY_MODE");
   if (mode == "timeout") { Thread.Sleep(60000); return; }
   if (mode == "oversized") { Console.Write(new string('x', 5000)); return; }
   if (mode == "malformed") { Console.Write("not json"); return; }
   if (mode == "wrong-type") { Console.Write("{\"schemaVersion\":1,\"component\":\"solder-cli\",\"terminalDraftRestore\":\"1\",\"webDraftRestore\":1}"); return; }
   if (mode == "nonzero") { Environment.Exit(1); return; }
   Console.Write("{\"schemaVersion\":1,\"component\":\"solder-cli\",\"terminalDraftRestore\":1,\"webDraftRestore\":1}\n"); return;
  }
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
    $state = New-State
    $env:SOLDER_TEST_CAPABILITY_MODE='valid'
    Assert-Condition (Test-SolderStagedCliCapabilities $cli $state) 'a compatible target CLI was rejected'
    foreach ($mode in @('malformed', 'oversized', 'wrong-type', 'nonzero', 'timeout')) {
        $env:SOLDER_TEST_CAPABILITY_MODE=$mode
        Assert-Condition (-not (Test-SolderStagedCliCapabilities $cli $state 500)) ('an incompatible target CLI was accepted: ' + $mode)
    }
    Remove-Item Env:SOLDER_TEST_CAPABILITY_MODE
    # Unknown target support is allowed only after all existing sessions have
    # closed. The guard must not prepare or terminate a live terminal/UI host.
    Assert-SolderStagedCliForRunningSessions $root $state $false @()
    $env:SOLDER_TEST_PIPE_READY = Join-Path $root 'pipe-ready'
    $child = Start-Process -FilePath $cli -PassThru -WindowStyle Hidden
    $children.Add($child)
    Wait-For { Test-Path -LiteralPath $env:SOLDER_TEST_PIPE_READY } 'the fixture pipe did not start'
    $state = New-State
    New-SolderReopenSession $root $state
    $refused=$false
    try { Close-SolderTerminalsForUpdate $root $state $false } catch { $refused=$true }
    Assert-Condition ($refused -and -not $child.HasExited -and $state.Stage -ceq 'manual-close') 'an old target CLI shut down a live terminal'
    Close-SolderTerminalsForUpdate $root $state $true
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
    $refused=$false
    try { Assert-SolderStagedCliForRunningSessions $root $state $false @() } catch { $refused=$true }
    Assert-Condition ($refused -and -not $hostChild.HasExited -and $state.Stage -ceq 'manual-close') 'an old target CLI accepted a live UI host'
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
using System.Collections.Generic;
using System.Diagnostics;
using System.Web.Script.Serialization;
public class ManagerFixture : Form {
 [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern uint RegisterWindowMessageW(string name);
 static readonly uint Wake = RegisterWindowMessageW("SolderCAD.UpdateReopen.v1");
 protected override void WndProc(ref Message m) {
  if ((uint)m.Msg == Wake) {
   string root = Environment.GetEnvironmentVariable("SOLDER_TEST_FIXTURE_ROOT");
   string marker = Path.Combine(root, ".solder-update-reopen-request.json");
   if (File.Exists(marker)) {
    var json = new JavaScriptSerializer();
    var session = json.Deserialize<Dictionary<string,object>>(File.ReadAllText(marker));
    string nonce = (string)session["nonce"];
    string dir = Path.Combine(root, ".solder-update-reopen-" + nonce);
    foreach (string path in Directory.GetFiles(dir,"*.request")) {
     var request = json.Deserialize<Dictionary<string,object>>(File.ReadAllText(path));
     if (Convert.ToInt32(request["targetPid"]) != Process.GetCurrentProcess().Id ||
         (string)request["targetHwnd"] != Handle.ToInt64().ToString() || (string)request["nonce"] != nonce) continue;
     string ack = Path.ChangeExtension(path,".ack");
     string statusFile = Environment.GetEnvironmentVariable("SOLDER_TEST_MANAGER_STATUS");
     string status = File.Exists(statusFile) ? File.ReadAllText(statusFile).Trim() : "already_open";
     if (File.Exists(ack) || status == "noack") continue;
     var result = new Dictionary<string,object> { {"schemaVersion",1}, {"nonce",nonce},
         {"requestId",request["requestId"]}, {"status",status} };
     string temp = ack + "." + Guid.NewGuid().ToString("N") + ".tmp";
     File.WriteAllText(temp,json.Serialize(result)); File.Move(temp,ack);
     File.AppendAllText(Environment.GetEnvironmentVariable("SOLDER_TEST_MANAGER_REQUESTS"),
       request["sourcePid"] + "-" + request["sourceHwnd"] + "|" + request["targetPid"] + "|" + status + "\n");
    }
   }
  }
  base.WndProc(ref m);
 }
}
public class GuiFixture {
 [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern bool SetPropW(IntPtr hwnd, string name, IntPtr value);
 [STAThread] public static void Main(string[] args) {
  if (args.Length == 0 || (args[0] != "close" && args[0] != "veto" && args[0] != "exit" && args[0] != "hung" && args[0] != "delayed" && args[0] != "legacy" && args[0] != "owned" && args[0] != "untitled")) {
   File.AppendAllText(Environment.GetEnvironmentVariable("SOLDER_TEST_OPENED"), Path.GetFileName(Application.ExecutablePath) + "|" + (args.Length == 0 || args[0] == "-n" ? "(empty)" : args[0]) + "\n");
   if (Environment.GetEnvironmentVariable("SOLDER_TEST_KEEP_REOPENED") != "1" && String.IsNullOrEmpty(Environment.GetEnvironmentVariable("SOLDER_UPDATE_REOPEN_MANAGER")) && Path.GetFileName(Application.ExecutablePath).Equals("kicad.exe",StringComparison.OrdinalIgnoreCase)) return;
   args = new[] { "close" };
  }
  var f = new ManagerFixture(); f.Text="Solder fixture"; f.StartPosition=FormStartPosition.Manual;
  f.HandleCreated += (sender,e) => {
   if (args[0] == "legacy") return;
   string ready = Environment.GetEnvironmentVariable("SOLDER_TEST_MANAGER_READY_FILE");
   if (String.IsNullOrEmpty(ready)) SetPropW(f.Handle,"SolderCAD.UpdateCloseProtocol.v2",new IntPtr(1));
   else {
    var timer = new System.Windows.Forms.Timer(); timer.Interval = 100; f.Tag = timer;
    timer.Tick += (s,a) => { if(File.Exists(ready)) { SetPropW(f.Handle,"SolderCAD.UpdateCloseProtocol.v2",new IntPtr(1)); timer.Stop(); timer.Dispose(); } };
    timer.Start();
   }
  };
  f.Location=new Point(-3000,-3000); f.ShowInTaskbar=true;
  if (args[0]=="owned") f.Shown += (sender,e) => {
   var hidden = new Form(); hidden.Text="Hidden child";
   hidden.HandleCreated += (s,a) => SetPropW(hidden.Handle,"SolderCAD.UpdateCloseProtocol.v2",new IntPtr(1));
   hidden.Show(f); hidden.Hide();
  };
  if (args[0]=="untitled") f.Shown += (sender,e) => {
   var unknown = new Form(); unknown.Text=""; unknown.ShowInTaskbar=false; unknown.Show(f);
  };
  f.FormClosing += (sender,e) => { if(args[0]=="veto") e.Cancel=true; if(args[0]=="exit") Environment.Exit(0); if(args[0]=="hung") Thread.Sleep(30000); if(args[0]=="delayed") Thread.Sleep(1500); };
  Application.Run(f);
 }
}
'@
    Add-Type -OutputAssembly $gui -OutputType WindowsApplication -ReferencedAssemblies @('System.Windows.Forms','System.Drawing','System.Web.Extensions') -TypeDefinition $guiSource
    foreach ($editor in @('eeschema.exe', 'pcbnew.exe')) {
        $path = Join-Path $root ('SolderCAD\bin\' + $editor)
        Remove-Item -LiteralPath $path -Force
        [IO.File]::Copy($gui, $path)
    }
    $env:SOLDER_TEST_OPENED = Join-Path $root 'opened.txt'
    $env:SOLDER_TEST_FIXTURE_ROOT = $root
    $env:SOLDER_TEST_MANAGER_REQUESTS = Join-Path $root 'manager-requests.txt'
    $env:SOLDER_TEST_MANAGER_STATUS = Join-Path $root 'manager-status.txt'
    $stagedApp=Join-Path $root 'SolderCAD'
    $capabilityPath=Join-Path $stagedApp 'share\kicad\resources\solder_chat\windows-update-capabilities.json'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $capabilityPath) | Out-Null
    $capability='{"schemaVersion":1,"component":"soldercad","windowsUpdateCloseProtocol":2,"windowsManagerReopenProtocol":1,"windowsStandaloneReopenProtocol":1,"windowsUpdateSessionPhaseProtocol":1,"windowsNamedNewStandaloneProtocol":1}'
    [IO.File]::WriteAllText($capabilityPath, $capability)
    $project = Join-Path $root ("saved project " + [char]0x03c0 + "'s.kicad_pro")
    New-Item -ItemType File -Path $project | Out-Null

    # An older target can install after manual closure, but a window that
    # starts after staging must never be closed for an unverified target.
    Remove-Item -LiteralPath $capabilityPath
    $state=New-State
    New-SolderReopenSession $root $state
    Close-SolderForUpdate $root $state 0 0 -StagedApp $stagedApp -CliRestoreSupported $true
    Complete-SolderReopenSession $state
    $state=New-State
    New-SolderReopenSession $root $state
    $late=Start-Process -FilePath $gui -ArgumentList 'close' -PassThru
    $children.Add($late)
    Wait-For { $late.Refresh(); $late.MainWindowHandle -ne 0 } 'the late window fixture did not start'
    foreach($badCapability in @('', '{"schemaVersion":1,"component":"soldercad","windowsUpdateCloseProtocol":"2","windowsManagerReopenProtocol":1}',
        '{"schemaVersion":1,"component":"soldercad","windowsUpdateCloseProtocol":2,"windowsManagerReopenProtocol":2}',
        '{"schemaVersion":1,"component":"soldercad","windowsUpdateCloseProtocol":2,"windowsManagerReopenProtocol":1}',
        '{"schemaVersion":1,"component":"soldercad","windowsUpdateCloseProtocol":2,"windowsManagerReopenProtocol":1,"windowsStandaloneReopenProtocol":1}',
        '{"schemaVersion":1,"component":"soldercad","windowsUpdateCloseProtocol":2,"windowsManagerReopenProtocol":1,"windowsStandaloneReopenProtocol":1,"windowsUpdateSessionPhaseProtocol":1}')) {
        if ($badCapability) { [IO.File]::WriteAllText($capabilityPath, $badCapability) }
        else { Remove-Item -LiteralPath $capabilityPath -ErrorAction SilentlyContinue }
        $refused=$false
        try { Close-SolderForUpdate $root $state $late.Id ([long]$late.MainWindowHandle) -StagedApp $stagedApp -CliRestoreSupported $true } catch { $refused=$true }
        Assert-Condition ($refused -and $state.Stage -ceq 'manual-close' -and -not $late.HasExited) 'an unverified target closed a late SolderCAD window'
    }
    [IO.File]::WriteAllText($capabilityPath, $capability)
    Close-SolderForUpdate $root $state $late.Id ([long]$late.MainWindowHandle) -StagedApp $stagedApp -CliRestoreSupported $true
    Assert-Condition $late.HasExited 'a capable target did not permit the normal close path'
    Complete-SolderReopenSession $state

    $legacy = Start-Process -FilePath $gui -ArgumentList 'legacy' -PassThru
    $children.Add($legacy)
    Wait-For { $legacy.Refresh(); $legacy.MainWindowHandle -ne 0 } 'the legacy fixture window did not start'
    $state = New-State
    New-SolderReopenSession $root $state
    $refused = $false
    try { Close-SolderForUpdate $root $state $legacy.Id ([long]$legacy.MainWindowHandle) -StagedApp $stagedApp -CliRestoreSupported $true }
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
    try { Close-SolderForUpdate $root $state $untitled.Id ([long]$untitled.MainWindowHandle) -StagedApp $stagedApp -CliRestoreSupported $true }
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
    try { Close-SolderForUpdate $root $state $guardedWindow.Id ([long]$guardedWindow.MainWindowHandle) $held -StagedApp $stagedApp -CliRestoreSupported $true }
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
    Close-SolderForUpdate $root $state $owned.Id ([long]$owned.MainWindowHandle) -StagedApp $stagedApp -CliRestoreSupported $true
    Assert-Condition ($state.Session.Windows.Count -ge 2) 'an owned or hidden capable frame was not captured'
    Complete-SolderReopenSession $state

    # Windows returns no SendMessageTimeout response when the receiver exits
    # inside WM_CLOSE. The HWND is nevertheless gone. Publication must still
    # require the same production native close-record gate as any other close.
    $exitProbe=Start-Process -FilePath $gui -ArgumentList 'exit' -PassThru
    $children.Add($exitProbe)
    Wait-For { $exitProbe.Refresh(); $exitProbe.MainWindowHandle -ne 0 } 'the receiver-exit probe did not start'
    $exitHandle=[long]$exitProbe.MainWindowHandle
    $responded=[SolderInstaller.Windows]::RequestClose($exitHandle)
    Assert-Condition ($exitProbe.WaitForExit(5000) -and -not $responded -and
        -not [SolderInstaller.Windows]::Exists($exitHandle)) 'the native receiver-exit probe did not exercise a missing Windows response'
    foreach($withRecord in @($true,$false)) {
        $receiver=Start-Process -FilePath $gui -ArgumentList 'exit' -PassThru
        $children.Add($receiver)
        Wait-For { $receiver.Refresh(); $receiver.MainWindowHandle -ne 0 } 'the receiver-exit coordinator fixture did not start'
        $handle=[long]$receiver.MainWindowHandle
        $state=New-State
        New-SolderReopenSession $root $state $true
        $recordPath=Join-Path $state.Session.Directory ("$($receiver.Id)-$handle.json")
        if($withRecord) {
            $captured=@(Get-SolderGuiProcesses $root | Where-Object {$_.Id -eq $receiver.Id})[0]
            $record=[ordered]@{schemaVersion=1;nonce=$state.Session.Nonce;pid=$receiver.Id;hwnd=[string]$handle;
                executable=$gui;project='';frameType='manager';managerHwnd=[string]$handle;
                managerStartTime=$captured.StartFileTime;managerProject='';documentExisted=$false}|ConvertTo-Json -Compress
            Write-TransactionRecord $recordPath $record
        }
        Close-SolderForUpdate $root $state 0 0 -StagedApp $stagedApp -CliRestoreSupported $true
        Assert-Condition ($receiver.WaitForExit(5000) -and $state.ClosedAny) 'a receiver-exit close was treated as a live unresponsive window'
        $recordFailure=$null
        try { Assert-SolderClosedWindowRecords $state '' 0 } catch {$recordFailure=$_.Exception.Message}
        if($withRecord) {
            Assert-Condition ($null -eq $recordFailure) 'a valid native record did not allow publication after receiver exit'
            Remove-Item -LiteralPath $recordPath
        } else {
            Assert-Condition ($recordFailure -like '*did not provide its saved document*') 'a missing receiver-exit record did not block publication'
        }
        Complete-SolderReopenSession $state
    }
    $hung=Start-Process -FilePath $gui -ArgumentList 'hung' -PassThru
    $children.Add($hung)
    Wait-For { $hung.Refresh(); $hung.MainWindowHandle -ne 0 } 'the unresponsive receiver fixture did not start'
    $state=New-State
    New-SolderReopenSession $root $state $true
    $hungFailure=$null
    try { Close-SolderForUpdate $root $state 0 0 -StagedApp $stagedApp -CliRestoreSupported $true }
    catch {$hungFailure=$_.Exception.Message}
    Assert-Condition ($hungFailure -like '*window is not responding*' -and -not $hung.HasExited) 'a live unresponsive receiver was allowed to publish'
    Stop-Process -Id $hung.Id -Force
    [void]$hung.WaitForExit(5000)
    Complete-SolderReopenSession $state

    $veto = Start-Process -FilePath $gui -ArgumentList 'veto' -PassThru
    $children.Add($veto)
    Wait-For { $veto.Refresh(); $veto.MainWindowHandle -ne 0 } 'the veto fixture window did not start'
    $state = New-State
    New-SolderReopenSession $root $state
    $cancelled = $false
    try { Close-SolderForUpdate $root $state $veto.Id ([long]$veto.MainWindowHandle) -StagedApp $stagedApp -CliRestoreSupported $true }
    catch [OperationCanceledException] { $cancelled = $true }
    Assert-Condition $cancelled 'an editor veto did not cancel the update'
    Assert-Condition (-not $veto.HasExited) 'the vetoed window was force-closed'
    Remove-Item -LiteralPath $env:SOLDER_TEST_OPENED -ErrorAction SilentlyContinue
    $env:SOLDER_TEST_KEEP_REOPENED='1'
    Open-SolderUpdateWindows $root $state $gui '' 0 $true
    Open-SolderUpdateWindows $root $state $gui '' 0 $true
    $afterVeto=@(Get-SolderGuiProcesses $root)
    Assert-Condition ($state.Session.Managers.Count -eq 0 -and $afterVeto.Count -eq 1 -and
        $afterVeto[0].Id -eq $veto.Id -and -not (Test-Path -LiteralPath $env:SOLDER_TEST_OPENED)) 'anonymous repair duplicated the original manager after a close veto'
    $env:SOLDER_TEST_KEEP_REOPENED='0'
    Complete-SolderReopenSession $state
    Stop-Process -Id $veto.Id -Force
    [void]$veto.WaitForExit(5000)

    $delayed = Start-Process -FilePath $gui -ArgumentList 'delayed' -PassThru
    $children.Add($delayed)
    Wait-For { $delayed.Refresh(); $delayed.MainWindowHandle -ne 0 } 'the delayed fixture window did not start'
    $delayedHandle = [long]$delayed.MainWindowHandle
    $state = New-State
    New-SolderReopenSession $root $state
    $cancel = [PowerShell]::Create()
    [void]$cancel.AddScript('param($s) Start-Sleep -Milliseconds 500; $s.CancelRequested=$true').AddArgument($state)
    $pending = $cancel.BeginInvoke()
    $cancelled = $false
    try { Close-SolderForUpdate $root $state $delayed.Id $delayedHandle -StagedApp $stagedApp -CliRestoreSupported $true }
    catch [OperationCanceledException] { $cancelled = $true }
    [void]$cancel.EndInvoke($pending); $cancel.Dispose()
    Assert-Condition ($cancelled -and $state.ClosedAny) 'cancellation lost a window that had finished closing'
    $refused=$false
    try { Open-SolderReopenSession $root $state $project $delayed.Id $false } catch { $refused=$true }
    Assert-Condition ($refused -and -not (Test-Path -LiteralPath $env:SOLDER_TEST_OPENED)) 'a closed v2 frame without a checkpoint was silently discarded'
    $delayedCaptured=@($state.Session.Processes | Where-Object {$_.Id -eq $delayed.Id})[0]
    $record=[ordered]@{schemaVersion=1;nonce=$state.Session.Nonce;pid=$delayed.Id;hwnd=[string]$delayedHandle;
        executable=$gui;project=$project;frameType='manager';managerHwnd=[string]$delayedHandle;
        managerStartTime=$delayedCaptured.StartFileTime;managerProject=$project;documentExisted=$true}|ConvertTo-Json -Compress
    Write-TransactionRecord (Join-Path $state.Session.Directory ("$($delayed.Id)-$delayedHandle.json")) $record
    Open-SolderReopenSession $root $state $project $delayed.Id $false
    Assert-Condition (([IO.File]::ReadAllText($env:SOLDER_TEST_OPENED)).Trim() -ceq ('kicad.exe|' + $project)) 'a safely closed window was not restored with its project'
    Close-TestRestoredManagers $state
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
    Close-SolderForUpdate $root $state $fixture.Id $handle -StagedApp $stagedApp -CliRestoreSupported $true
    $refused = $false
    try { Assert-SolderClosedWindowRecords $state '' $fixture.Id } catch { $refused = $true }
    Assert-Condition $refused 'publication would proceed without the closed-window record'
    $fixtureCaptured=@($state.Session.Processes | Where-Object {$_.Id -eq $fixture.Id})[0]
    foreach ($item in @(@{ hwnd=$handle; project=$project; frameType='manager' }, @{ hwnd=987654321; project=$saved2; frameType='pcb' }, @{ hwnd=987654320; project=''; frameType='schematic' })) {
        $isManager=$item.frameType -ceq 'manager'
        $record = [ordered]@{ schemaVersion=1; nonce=$state.Session.Nonce; pid=$fixture.Id; hwnd=[string]$item.hwnd; executable=$gui; project=$item.project; frameType=$item.frameType;
            managerHwnd=$(if($isManager){[string]$item.hwnd}else{'0'});managerStartTime=$(if($isManager){$fixtureCaptured.StartFileTime}else{'0'});
            managerProject=$(if($isManager){$item.project}else{''});documentExisted=[bool]$item.project } | ConvertTo-Json -Compress
        Write-TransactionRecord (Join-Path $state.Session.Directory ("$($fixture.Id)-$($item.hwnd).json")) $record
    }
    Assert-SolderClosedWindowRecords $state '' $fixture.Id
    Open-SolderReopenSession $root $state '' $fixture.Id $true
    Open-SolderReopenSession $root $state '' $fixture.Id $true
    $opened = @([IO.File]::ReadAllLines($env:SOLDER_TEST_OPENED))
    Assert-Condition ($opened.Count -eq 3 -and $opened -ccontains ('kicad.exe|' + $project) -and
        $opened -ccontains ('pcbnew.exe|' + $saved2) -and $opened -ccontains 'eeschema.exe|(empty)') 'post-save, hidden-child and empty documents were not reopened once each'
    Close-TestRestoredManagers $state
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
    Close-SolderForUpdate $root $state $first.Id $firstHandle -StagedApp $stagedApp -CliRestoreSupported $true
    $firstCaptured=@($state.Session.Processes | Where-Object {$_.Id -eq $first.Id})[0]
    $record=[ordered]@{ schemaVersion=1; nonce=$state.Session.Nonce; pid=$first.Id; hwnd=[string]$firstHandle;
        executable=$gui; project=$project; frameType='manager';managerHwnd=[string]$firstHandle;
        managerStartTime=$firstCaptured.StartFileTime;managerProject=$project;documentExisted=$true } | ConvertTo-Json -Compress
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
    Close-TestRestoredManagers $state
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

    # A cancelled attempt can reopen the initiating frame with a new PID.
    # Retry must reopen the new record once, without also launching a stale
    # original path (including after Save As or an untitled window).
    function Assert-CallerRetry([string]$CallerProject, [string]$SavedProject, [string]$Expected, [bool]$ReusedHandle) {
        Remove-Item -LiteralPath $env:SOLDER_TEST_OPENED -ErrorAction SilentlyContinue
        $env:SOLDER_TEST_KEEP_REOPENED='1'
        $caller=Start-Process -FilePath $gui -ArgumentList 'close' -PassThru
        $children.Add($caller)
        Wait-For { $caller.Refresh(); $caller.MainWindowHandle -ne 0 } 'the original caller did not start'
        $callerHandle=[long]$caller.MainWindowHandle
        $state=New-State
        New-SolderReopenSession $root $state $true
        Close-SolderForUpdate $root $state $caller.Id $callerHandle -StagedApp $stagedApp -CliRestoreSupported $true
        $callerCaptured=@($state.Session.Processes | Where-Object {$_.Id -eq $caller.Id})[0]
        $record=[ordered]@{ schemaVersion=1; nonce=$state.Session.Nonce; pid=$caller.Id; hwnd=[string]$callerHandle;
            executable=$gui; project=$SavedProject; frameType='manager';managerHwnd=[string]$callerHandle;
            managerStartTime=$callerCaptured.StartFileTime;managerProject=$SavedProject;documentExisted=[bool]$SavedProject } | ConvertTo-Json -Compress
        Write-TransactionRecord (Join-Path $state.Session.Directory ("$($caller.Id)-$callerHandle.json")) $record
        Open-SolderReopenSession $root $state $CallerProject $caller.Id $false
        Complete-SolderReopenSession $state
        $restored=$null
        Wait-For {
            $running=@(Get-SolderGuiProcesses $root)
            if($running.Count -ne 1 -or $running[0].Id -eq $caller.Id){return $false}
            $script:retryRestoredId=$running[0].Id
            $restoredProcess=Get-Process -Id $running[0].Id
            $restoredProcess.Refresh()
            return $restoredProcess.MainWindowHandle -ne 0
        } 'the original caller was not restored with a new process'
        $restored=Get-Process -Id $script:retryRestoredId
        $children.Add($restored)
        $restoredHandle=[long]$restored.MainWindowHandle
        $env:SOLDER_TEST_KEEP_REOPENED='0'
        New-SolderReopenSession $root $state $true
        $retryHandle=if($ReusedHandle){$restoredHandle}else{$callerHandle}
        Close-SolderForUpdate $root $state $caller.Id $retryHandle -StagedApp $stagedApp -CliRestoreSupported $true
        $restoredCaptured=@($state.Session.Processes | Where-Object {$_.Id -eq $restored.Id})[0]
        $record=[ordered]@{ schemaVersion=1; nonce=$state.Session.Nonce; pid=$restored.Id; hwnd=[string]$restoredHandle;
            executable=$gui; project=$SavedProject; frameType='manager';managerHwnd=[string]$restoredHandle;
            managerStartTime=$restoredCaptured.StartFileTime;managerProject=$SavedProject;documentExisted=[bool]$SavedProject } | ConvertTo-Json -Compress
        Write-TransactionRecord (Join-Path $state.Session.Directory ("$($restored.Id)-$restoredHandle.json")) $record
        Open-SolderUpdateWindows $root $state $gui $CallerProject $caller.Id $true
        $opened=@([IO.File]::ReadAllLines($env:SOLDER_TEST_OPENED))
        Assert-Condition ($opened.Count -eq 2 -and $opened[0] -ceq ('kicad.exe|' + $Expected) -and
            $opened[1] -ceq ('kicad.exe|' + $Expected)) 'retry reopened a saved caller twice or used a stale document path'
        Close-TestRestoredManagers $state
        Complete-SolderReopenSession $state
    }
    $savedAs=Join-Path $root 'saved-as.kicad_pro'
    [IO.File]::Copy($project,$savedAs)
    Assert-CallerRetry $project $savedAs $savedAs $false
    Assert-CallerRetry '' '' '(empty)' $true

    # Repair shortcuts have no caller PID or project. Once a captured manager
    # has been acknowledged, the anonymous launch is satisfied. Requests with
    # an explicit project/caller must retain their existing fallback behavior.
    function Assert-ManagerLaunchRequest([bool]$RestoreManager, [string]$RequestedProject,
                                         [int]$RequestedCaller, [string[]]$ExpectedLaunches) {
        Remove-Item -LiteralPath $env:SOLDER_TEST_OPENED -ErrorAction SilentlyContinue
        $env:SOLDER_TEST_KEEP_REOPENED='1'
        $state=New-State
        New-SolderReopenSession $root $state $true
        try {
            if ($RestoreManager) {
                $source=Start-Process -FilePath $gui -ArgumentList 'close' -PassThru
                $children.Add($source)
                Wait-For { $source.Refresh(); $source.MainWindowHandle -ne 0 } 'the anonymous repair source manager did not start'
                $sourceHandle=[long]$source.MainWindowHandle
                Close-SolderForUpdate $root $state 0 0 -StagedApp $stagedApp -CliRestoreSupported $true
                $captured=@($state.Session.Processes | Where-Object {$_.Id -eq $source.Id})[0]
                $record=[ordered]@{schemaVersion=1;nonce=$state.Session.Nonce;pid=$source.Id;hwnd=[string]$sourceHandle;
                    executable=$gui;project=$project;frameType='manager';managerHwnd=[string]$sourceHandle;
                    managerStartTime=$captured.StartFileTime;managerProject=$project;documentExisted=$true}|ConvertTo-Json -Compress
                Write-TransactionRecord (Join-Path $state.Session.Directory ("$($source.Id)-$sourceHandle.json")) $record
            }
            Open-SolderUpdateWindows $root $state $gui $RequestedProject $RequestedCaller $RestoreManager
            $opened=@([IO.File]::ReadAllLines($env:SOLDER_TEST_OPENED))
            $processes=@(Get-SolderGuiProcesses $root)
            Assert-Condition ($opened.Count -eq $ExpectedLaunches.Count -and
                ($opened -join "`n") -ceq ($ExpectedLaunches -join "`n") -and
                $processes.Count -eq $ExpectedLaunches.Count) 'a manager launch request created an extra window or suppressed an explicit launch'
            $ids=@($processes | ForEach-Object {$_.Id} | Sort-Object)
            Open-SolderUpdateWindows $root $state $gui $RequestedProject $RequestedCaller $RestoreManager
            $retryOpened=@([IO.File]::ReadAllLines($env:SOLDER_TEST_OPENED))
            $retryIds=@(Get-SolderGuiProcesses $root | ForEach-Object {$_.Id} | Sort-Object)
            Assert-Condition ($retryOpened.Count -eq $ExpectedLaunches.Count -and
                ($retryIds -join ',') -ceq ($ids -join ',')) 'retry duplicated a restored manager or its requested fallback'
        } finally {
            foreach($running in @(Get-SolderGuiProcesses $root)) {
                $process=Get-Process -Id $running.Id -ErrorAction SilentlyContinue
                if($process -and (-not $process.CloseMainWindow() -or -not $process.WaitForExit(10000))) {
                    throw 'a disposable manager launch fixture did not close normally'
                }
            }
            Complete-SolderReopenSession $state
            $env:SOLDER_TEST_KEEP_REOPENED='0'
        }
    }
    Assert-ManagerLaunchRequest $true '' 0 @('kicad.exe|' + $project)
    Assert-ManagerLaunchRequest $false '' 0 @('kicad.exe|(empty)')
    Assert-ManagerLaunchRequest $true $savedAs 0 @(('kicad.exe|' + $project), ('kicad.exe|' + $savedAs))
    Assert-ManagerLaunchRequest $true '' 987654 @(('kicad.exe|' + $project), 'kicad.exe|(empty)')

    Remove-Item -LiteralPath $env:SOLDER_TEST_OPENED -ErrorAction SilentlyContinue
    $state=New-State
    New-SolderReopenSession $root $state $true
    Open-SolderUpdateWindows $root $state $gui $project 987654 $false
    Assert-Condition (([IO.File]::ReadAllText($env:SOLDER_TEST_OPENED)).Trim() -ceq ('kicad.exe|' + $project)) 'an uncaptured caller did not use its fallback'
    Complete-SolderReopenSession $state

    # A sibling frame can share the caller PID without being the caller HWND.
    # Its record must not suppress the missing caller's fallback.
    Remove-Item -LiteralPath $env:SOLDER_TEST_OPENED -ErrorAction SilentlyContinue
    $state=New-State
    New-SolderReopenSession $root $state $true
    $state.Session.Processes=@([pscustomobject]@{Id=987654;Path=$gui})
    $state.Session | Add-Member -NotePropertyName CallerWindow -NotePropertyValue ([long]87654321)
    $sibling=[ordered]@{schemaVersion=1;nonce=$state.Session.Nonce;pid=987654;hwnd='987654321';
        executable=$gui;project=$saved2;frameType='pcb';managerHwnd='0';managerStartTime='0';managerProject='';documentExisted=$true}|ConvertTo-Json -Compress
    Write-TransactionRecord (Join-Path $state.Session.Directory '987654-987654321.json') $sibling
    Open-SolderUpdateWindows $root $state $gui $project 987654 $true
    $opened=@([IO.File]::ReadAllLines($env:SOLDER_TEST_OPENED))
    Assert-Condition (-not $state.CallerReopened -and $opened.Count -eq 2 -and
        $opened -ccontains ('pcbnew.exe|' + $saved2) -and $opened -ccontains ('kicad.exe|' + $project)) 'a sibling frame suppressed the uncaptured caller fallback'
    Close-TestRestoredManagers $state
    Complete-SolderReopenSession $state

    # A blank standalone receives a named, absent untitled document. It can
    # reopen that exact path through a scoped native startup hint, without a
    # file being created on disk. A missing ACK retains its exact process.
    Remove-Item -LiteralPath $env:SOLDER_TEST_OPENED -ErrorAction SilentlyContinue
    [IO.File]::WriteAllText($env:SOLDER_TEST_MANAGER_STATUS, 'noack')
    $standaloneExe=Join-Path $root 'SolderCAD\bin\pcbnew.exe'
    $standalone=Start-Process -FilePath $standaloneExe -ArgumentList 'close' -PassThru
    $children.Add($standalone)
    Wait-For { $standalone.Refresh(); $standalone.MainWindowHandle -ne 0 } 'the standalone source did not start'
    $standaloneHandle=[long]$standalone.MainWindowHandle
    $state=New-State
    New-SolderReopenSession $root $state $true
    Close-SolderForUpdate $root $state $standalone.Id $standaloneHandle -StagedApp $stagedApp -CliRestoreSupported $true
    $captured=@($state.Session.Processes | Where-Object {$_.Id -eq $standalone.Id})[0]
    $standalonePath=Join-Path $state.Session.Directory ("$($standalone.Id)-$standaloneHandle.json")
    $newStandaloneDocument=Join-Path $root 'untitled.kicad_pcb'
    $standaloneRecord=[ordered]@{schemaVersion=1;nonce=$state.Session.Nonce;pid=$standalone.Id;hwnd=[string]$standaloneHandle;
        executable=$standaloneExe;project=$newStandaloneDocument;frameType='pcb';managerHwnd='0';managerStartTime='0';managerProject='';documentExisted=$false}|ConvertTo-Json -Compress
    Write-TransactionRecord $standalonePath $standaloneRecord
    $window=@($state.Session.Windows | Where-Object {$_.Process.Id -eq $standalone.Id -and $_.Handle -eq $standaloneHandle})[0]
    [void][IO.Directory]::CreateDirectory($newStandaloneDocument)
    $failed=$false
    try { [void](Get-SolderReopenEntry $state.Session $window '' 0 $true) } catch {$failed=$true}
    Assert-Condition ($failed -and (Test-Path -LiteralPath $newStandaloneDocument -PathType Container) -and
        @([IO.Directory]::EnumerateFileSystemEntries($newStandaloneDocument)).Count -eq 0) 'an occupied new standalone path was accepted or modified'
    [IO.Directory]::Delete($newStandaloneDocument)
    $entry=Get-SolderReopenEntry $state.Session $window '' 0 $true
    Set-SolderSessionReopening $state
    $target=Get-SolderStandaloneReopenTarget $root $state $window $entry 0
    $firstStandaloneId=$target.Process.Id
    $failed=$false
    try { Invoke-SolderManagerReopen $state $window $entry $target 500 } catch {$failed=$true}
    Assert-Condition ($failed -and -not $target.Process.HasExited -and -not $state.Session.Opened.Contains($standalonePath) -and
        (Test-Path -LiteralPath $standalonePath)) 'a live standalone without a document acknowledgement lost its checkpoint'
    [IO.File]::WriteAllText($env:SOLDER_TEST_MANAGER_STATUS, 'already_open')
    Open-SolderReopenSession $root $state '' 0 $true
    Assert-Condition ($state.Session.Opened.Contains($standalonePath) -and @($state.Session.Standalones.Values).Count -eq 1 -and
        @($state.Session.Standalones.Values)[0].Process.Id -eq $firstStandaloneId -and
        @([IO.File]::ReadAllLines($env:SOLDER_TEST_OPENED)).Count -eq 1 -and
        ([IO.File]::ReadAllText($env:SOLDER_TEST_OPENED)).Trim() -ceq ('pcbnew.exe|' + $newStandaloneDocument) -and
        -not (Test-Path -LiteralPath $newStandaloneDocument)) 'new standalone Retry duplicated the editor, changed its path or created a file'
    Close-TestRestoredManagers $state
    Complete-SolderReopenSession $state

    # A closed manager-owned editor returns to its still-running original
    # manager after partial cancellation. Conflict must preserve its record,
    # and Retry must send a new request rather than replay the old refusal.
    Remove-Item -LiteralPath $env:SOLDER_TEST_MANAGER_REQUESTS -ErrorAction SilentlyContinue
    [IO.File]::WriteAllText($env:SOLDER_TEST_MANAGER_STATUS, 'conflict')
    $manager=Start-Process -FilePath $gui -ArgumentList 'close' -PassThru
    $children.Add($manager)
    Wait-For { $manager.Refresh(); $manager.MainWindowHandle -ne 0 } 'the live manager fixture did not start'
    $managerHandle=[long]$manager.MainWindowHandle
    $captured=@(Get-SolderGuiProcesses $root | Where-Object {$_.Id -eq $manager.Id})[0]
    $state=New-State
    New-SolderReopenSession $root $state $true
    $state.Session.Processes=@($captured)
    $state.Session.Windows.Add([pscustomobject]@{Handle=$managerHandle;Process=$captured;ExpectedRecord=$true})
    $childHandle=[long]87650123
    $childPath=Join-Path $state.Session.Directory ("$($manager.Id)-$childHandle.json")
    $childRecord=[ordered]@{schemaVersion=1;nonce=$state.Session.Nonce;pid=$manager.Id;hwnd=[string]$childHandle;
        executable=$gui;project=$saved2;frameType='pcb';managerHwnd=[string]$managerHandle;
        managerStartTime=$captured.StartFileTime;managerProject=$project;documentExisted=$true}|ConvertTo-Json -Compress
    Write-TransactionRecord $childPath $childRecord
    $failed=$false
    try { Open-SolderReopenSession $root $state '' 0 $true } catch { $failed=$true }
    Assert-Condition ($failed -and -not $manager.HasExited -and (Test-Path -LiteralPath $childPath) -and
        -not $state.Session.Opened.Contains($childPath) -and @($state.Session.Mailboxes.Keys).Count -eq 0) 'a manager conflict lost the editor or prevented retry'
    [IO.File]::WriteAllText($env:SOLDER_TEST_MANAGER_STATUS, 'already_open')
    Open-SolderReopenSession $root $state '' 0 $true
    $groupRequests=@([IO.File]::ReadAllLines($env:SOLDER_TEST_MANAGER_REQUESTS))
    Assert-Condition ($state.Session.Opened.Contains($childPath) -and $groupRequests.Count -eq 2 -and
        $groupRequests[0] -ceq ("$($manager.Id)-$childHandle|$($manager.Id)|conflict") -and
        $groupRequests[1] -ceq ("$($manager.Id)-$childHandle|$($manager.Id)|already_open")) 'retry did not restore the child in its original live manager'
    $secondHandle=[long]87650125
    $secondPath=Join-Path $state.Session.Directory ("$($manager.Id)-$secondHandle.json")
    $secondRecord=[ordered]@{schemaVersion=1;nonce=$state.Session.Nonce;pid=$manager.Id;hwnd=[string]$secondHandle;
        executable=$gui;project=$saved2;frameType='pcb';managerHwnd=[string]$managerHandle;
        managerStartTime=$captured.StartFileTime;managerProject=$project;documentExisted=$true}|ConvertTo-Json -Compress
    Write-TransactionRecord $secondPath $secondRecord
    $secondWindow=[pscustomobject]@{Handle=$secondHandle;Process=$captured;ExpectedRecord=$true}
    $secondEntry=Get-SolderReopenEntry $state.Session $secondWindow '' 0 $true
    $liveTarget=@($state.Session.Managers.Values)[0]
    [IO.File]::WriteAllText($env:SOLDER_TEST_MANAGER_STATUS, 'noack')
    $failed=$false
    try { Invoke-SolderManagerReopen $state $secondWindow $secondEntry $liveTarget 500 } catch { $failed=$true }
    $requestId=$state.Session.Mailboxes[$secondPath].Id
    Assert-Condition ($failed -and -not $state.Session.Opened.Contains($secondPath) -and (Test-Path -LiteralPath $secondPath)) 'a missing manager acknowledgement lost the editor record'
    [IO.File]::WriteAllText($env:SOLDER_TEST_MANAGER_STATUS, 'already_open')
    Open-SolderReopenSession $root $state '' 0 $true
    Assert-Condition ($state.Session.Opened.Contains($secondPath) -and $state.Session.Mailboxes[$secondPath].Id -ceq $requestId) 'retry did not reuse the pending source request'
    $originalRecord=[IO.File]::ReadAllText($childPath)
    [IO.File]::WriteAllText($childPath, ($originalRecord.Replace('"frameType":"pcb"','"frameType":"schematic"')))
    $failed=$false
    try { Open-SolderReopenSession $root $state '' 0 $true } catch { $failed=$true }
    Assert-Condition ($failed -and (Test-Path -LiteralPath $childPath) -and -not $manager.HasExited) 'an in-place changed checkpoint became a new trusted baseline'
    [IO.File]::WriteAllText($childPath, $originalRecord)
    Close-TestRestoredManagers $state
    Complete-SolderReopenSession $state

    # A restarted manager and its child use the same verified target. If the
    # manager exits after an ACK, only its group is reopened on the next retry.
    Remove-Item -LiteralPath $env:SOLDER_TEST_MANAGER_REQUESTS -ErrorAction SilentlyContinue
    $manager=Start-Process -FilePath $gui -ArgumentList 'close' -PassThru
    $children.Add($manager)
    Wait-For { $manager.Refresh(); $manager.MainWindowHandle -ne 0 } 'the restart manager fixture did not start'
    $managerHandle=[long]$manager.MainWindowHandle
    $state=New-State
    New-SolderReopenSession $root $state $true
    Close-SolderForUpdate $root $state $manager.Id $managerHandle -StagedApp $stagedApp -CliRestoreSupported $true
    $captured=@($state.Session.Processes | Where-Object {$_.Id -eq $manager.Id})[0]
    $managerPath=Join-Path $state.Session.Directory ("$($manager.Id)-$managerHandle.json")
    $managerRecord=[ordered]@{schemaVersion=1;nonce=$state.Session.Nonce;pid=$manager.Id;hwnd=[string]$managerHandle;
        executable=$gui;project=$project;frameType='manager';managerHwnd=[string]$managerHandle;
        managerStartTime=$captured.StartFileTime;managerProject=$project;documentExisted=$true}|ConvertTo-Json -Compress
    Write-TransactionRecord $managerPath $managerRecord
    $childHandle=[long]87650124
    $childPath=Join-Path $state.Session.Directory ("$($manager.Id)-$childHandle.json")
    $newDocument=Join-Path $root 'not-yet-created.kicad_sch'
    $childRecord=[ordered]@{schemaVersion=1;nonce=$state.Session.Nonce;pid=$manager.Id;hwnd=[string]$childHandle;
        executable=$gui;project=$newDocument;frameType='schematic';managerHwnd=[string]$managerHandle;
        managerStartTime=$captured.StartFileTime;managerProject=$project;documentExisted=$false}|ConvertTo-Json -Compress
    Write-TransactionRecord $childPath $childRecord
    # Keep a slow but live startup across a bounded readiness timeout. Retry
    # must observe the same process rather than starting a second manager.
    $managerWindow=@($state.Session.Windows | Where-Object {$_.Process.Id -eq $manager.Id -and $_.Handle -eq $managerHandle})[0]
    $managerEntry=Get-SolderReopenEntry $state.Session $managerWindow '' $manager.Id $true
    $readyFile=Join-Path $root 'manager-ready'
    $env:SOLDER_TEST_MANAGER_READY_FILE=$readyFile
    $hint="$($state.Session.Nonce):$($manager.Id):$managerHandle"
    Set-SolderSessionReopening $state
    try { $starting=Start-SolderGuiProcess $gui ([IO.Path]::GetDirectoryName($gui)) $project $false $hint }
    finally { Remove-Item Env:SOLDER_TEST_MANAGER_READY_FILE -ErrorAction SilentlyContinue }
    $children.Add($starting)
    $managerKey="$($manager.Id)-$managerHandle-$($captured.StartFileTime)"
    $state.Session.Managers[$managerKey]=[pscustomobject]@{Captured=$null;Handle=[long]0;Process=$starting;
        ManagerProject=$project;Keys=(New-Object 'System.Collections.Generic.HashSet[string]')}
    $failed=$false
    try { [void](Wait-SolderNativeReopenTarget $root $state $managerKey $managerWindow $managerEntry $manager.Id 500) } catch { $failed=$true }
    Assert-Condition ($failed -and -not $starting.HasExited -and $state.Session.Managers[$managerKey].Process.Id -eq $starting.Id) 'a slow live manager was lost at the readiness timeout'
    [IO.File]::WriteAllText($readyFile, 'ready')
    [IO.File]::WriteAllText($env:SOLDER_TEST_MANAGER_STATUS, 'conflict')
    $failed=$false
    try { Open-SolderReopenSession $root $state '' $manager.Id $true } catch { $failed=$true }
    Assert-Condition ($failed -and -not $state.Session.Opened.Contains($managerPath) -and
        -not $state.Session.Opened.Contains($childPath) -and (Test-Path -LiteralPath $managerPath) -and
        $state.Session.Managers[$managerKey].Process.Id -eq $starting.Id) 'a manager with an unconfirmed project was reported restored or restarted'
    [IO.File]::WriteAllText($env:SOLDER_TEST_MANAGER_STATUS, 'already_open')
    Open-SolderReopenSession $root $state '' $manager.Id $true
    $firstTarget=@($state.Session.Managers.Values)[0]
    $firstId=$firstTarget.Process.Id
    Assert-Condition ($state.Session.Opened.Contains($managerPath) -and $state.Session.Opened.Contains($childPath) -and
        -not (Test-Path -LiteralPath $newDocument)) 'the named-new child was not acknowledged by its manager'
    Assert-Condition ($firstTarget.Process.CloseMainWindow() -and $firstTarget.Process.WaitForExit(10000)) 'the disposable restored manager did not exit'
    Open-SolderReopenSession $root $state '' $manager.Id $true
    $secondTarget=@($state.Session.Managers.Values)[0]
    $groupRequests=@([IO.File]::ReadAllLines($env:SOLDER_TEST_MANAGER_REQUESTS))
    Assert-Condition ($secondTarget.Process.Id -ne $firstId -and $state.Session.Opened.Contains($managerPath) -and
        $state.Session.Opened.Contains($childPath) -and $groupRequests.Count -eq 5 -and
        $groupRequests[3] -ceq ("$($manager.Id)-$managerHandle|$($secondTarget.Process.Id)|already_open") -and
        $groupRequests[4] -ceq ("$($manager.Id)-$childHandle|$($secondTarget.Process.Id)|already_open")) 'an exited manager did not restore exactly its own group on retry'
    Close-TestRestoredManagers $state
    Complete-SolderReopenSession $state
    Write-Output 'PASS seamless-update'
} finally {
    foreach ($child in $children) {
        try { if (-not $child.HasExited) { Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue } } catch { }
    }
    Remove-Item Env:SOLDER_TEST_OPENED, Env:SOLDER_TEST_PIPE_READY, Env:SOLDER_TEST_HOST_RELEASED, Env:SOLDER_TEST_CLI_OPENED, Env:SOLDER_TEST_KEEP_REOPENED, Env:SOLDER_TEST_FIXTURE_ROOT, Env:SOLDER_TEST_MANAGER_REQUESTS, Env:SOLDER_TEST_MANAGER_STATUS, Env:SOLDER_TEST_MANAGER_READY_FILE, Env:SOLDER_TEST_CAPABILITY_MODE -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
