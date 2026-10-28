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
    $helper2 = Save-SolderRepairLauncher $root $source
    Assert-Condition ($helper -ceq $helper2 -and (Test-SolderLaunchHealth $root)) 'refreshing the verified launch receipt failed'
    Write-SolderCoordinatorLog $root 'downloading' 'failure' 'GET https://example.invalid/path?token=secret-url Authorization: Bearer secret-header'
    $log = [IO.File]::ReadAllText((Join-Path $root 'repair\update-log.jsonl'), [Text.Encoding]::UTF8)
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
    $other = Join-Path $root 'other.lnk'
    $link = $shell.CreateShortcut($other)
    $link.TargetPath = Join-Path $env:SystemRoot 'system32\notepad.exe'
    $link.Save()
    Assert-Condition (-not (Test-SolderOwnedShortcut $other $root)) 'an unrelated shortcut was considered owned'

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
    [IO.File]::WriteAllText($board, 'board fixture')
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
    try { Close-SolderPreparedHosts $held $state }
    finally { foreach ($entry in $held) { $entry.Pipe.Dispose(); $entry.Process.Dispose() } }
    Assert-Condition ($disconnectedHost.HasExited) 'a disconnected prepared chat host was not drained'
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
public class GuiFixture {
 [STAThread] public static void Main(string[] args) {
  if (args.Length == 0 || (args[0] != "close" && args[0] != "veto" && args[0] != "delayed")) {
   File.AppendAllText(Environment.GetEnvironmentVariable("SOLDER_TEST_OPENED"), Path.GetFileName(Application.ExecutablePath) + "|" + (args.Length == 0 ? "(empty)" : args[0]) + "\n"); return;
  }
  var f = new Form(); f.Text="Solder fixture"; f.StartPosition=FormStartPosition.Manual;
  f.Location=new Point(-3000,-3000); f.ShowInTaskbar=true;
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
    [IO.File]::WriteAllText($project, 'project fixture')

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
    [IO.File]::WriteAllText($saved2, 'board fixture')
    $fixture = Start-Process -FilePath $gui -ArgumentList 'close' -PassThru
    $children.Add($fixture)
    Wait-For { $fixture.Refresh(); $fixture.MainWindowHandle -ne 0 } 'the save fixture window did not start'
    $handle = [long]$fixture.MainWindowHandle
    $state = New-State
    New-SolderReopenSession $root $state
    Close-SolderForUpdate $root $state $fixture.Id $handle
    foreach ($item in @(@{ hwnd=$handle; project=$project; frameType='manager' }, @{ hwnd=987654321; project=$saved2; frameType='pcb' }, @{ hwnd=987654320; project=''; frameType='schematic' })) {
        $record = [ordered]@{ schemaVersion=1; nonce=$state.Session.Nonce; pid=$fixture.Id; hwnd=[string]$item.hwnd; executable=$gui; project=$item.project; frameType=$item.frameType } | ConvertTo-Json -Compress
        Write-TransactionRecord (Join-Path $state.Session.Directory ("$($fixture.Id)-$($item.hwnd).json")) $record
    }
    Open-SolderReopenSession $root $state '' $fixture.Id $true
    Open-SolderReopenSession $root $state '' $fixture.Id $true
    $opened = @([IO.File]::ReadAllLines($env:SOLDER_TEST_OPENED))
    Assert-Condition ($opened.Count -eq 3 -and $opened -ccontains ('kicad.exe|' + $project) -and
        $opened -ccontains ('pcbnew.exe|' + $saved2) -and $opened -ccontains 'eeschema.exe|(empty)') 'post-save, hidden-child and empty documents were not reopened once each'
    Complete-SolderReopenSession $state
    Write-Output 'PASS seamless-update'
} finally {
    foreach ($child in $children) {
        try { if (-not $child.HasExited) { Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue } } catch { }
    }
    Remove-Item Env:SOLDER_TEST_OPENED, Env:SOLDER_TEST_PIPE_READY, Env:SOLDER_TEST_HOST_RELEASED, Env:SOLDER_TEST_CLI_OPENED -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
