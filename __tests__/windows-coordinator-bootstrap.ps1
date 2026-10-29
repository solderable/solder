param([Parameter(Mandatory=$true)][string]$Installer)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Windows.Forms
[Windows.Forms.Application]::SetUnhandledExceptionMode([Windows.Forms.UnhandledExceptionMode]::CatchException)
$onError = [Threading.ThreadExceptionEventHandler]{
    param($sender, $event)
    [Console]::Error.WriteLine('Unhandled coordinator event: ' + $event.Exception.Message)
    [Environment]::Exit(91)
}
[Windows.Forms.Application]::add_ThreadException($onError)
if (Get-Command Write-SolderCoordinatorLog -ErrorAction SilentlyContinue) { throw 'The installer logger must not be loaded in the bootstrap scope' }

$root=Join-Path $env:TEMP ('solder-coordinator-bootstrap-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$worker=Join-Path $root 'worker.ps1'
$workerSource=@'
[CmdletBinding()]
param([string]$InstallDir,[string]$Version,[string]$DownloadSource,[string]$InstallerScriptPath,
      [switch]$NoUserIntegration,[switch]$ManageLauncher,[switch]$RequireReopenRecords,
      [switch]$InternalCoordinator,[switch]$InternalReopen,[object]$CoordinatorState,
      [string]$RelaunchExecutable,[string]$RelaunchProject,[int]$CallerProcessId,[long]$CallerWindowHandle)
$mode=[IO.File]::ReadAllText((Join-Path $InstallDir 'mode'))
$attempts=Join-Path $InstallDir 'attempts'
[IO.File]::AppendAllText($attempts, 'x')
$CoordinatorState.Stage='downloading'
if ($mode -ceq 'cancel') {
    [IO.File]::WriteAllText((Join-Path $InstallDir 'running'), 'ready')
    while (-not $CoordinatorState.CancelRequested) { Start-Sleep -Milliseconds 25 }
    throw [OperationCanceledException]::new('The update was cancelled.')
}
if ($mode -ceq 'retry' -and [IO.File]::ReadAllText($attempts).Length -eq 1) {
    throw 'fixture failed: https://example.invalid/private?token=hidden Authorization: Bearer hidden-value'
}
$CoordinatorState.Stage='complete'
'@
[IO.File]::WriteAllText($worker,$workerSource)
$source=[IO.File]::ReadAllText($Installer,[Text.Encoding]::UTF8)
try {
    foreach ($mode in @('cancel','retry','success')) {
        $case=Join-Path $root $mode
        New-Item -ItemType Directory -Path $case | Out-Null
        [IO.File]::WriteAllText((Join-Path $case 'mode'), $mode)
        $script:bootstrapMode=$mode
        $script:bootstrapCase=$case
        $script:cancelClicked=$false
        $script:retryClicked=$false
        $script:deadline=[Diagnostics.Stopwatch]::StartNew()
        $timer=New-Object Windows.Forms.Timer
        $timer.Interval=50
        $timer.Add_Tick({
            if ($script:deadline.ElapsedMilliseconds -gt 15000) {
                [Console]::Error.WriteLine('Coordinator bootstrap timed out: ' + $script:bootstrapMode)
                [Environment]::Exit(92)
            }
            foreach ($window in @([Windows.Forms.Application]::OpenForms)) {
                if ($window.Text -cne 'SolderCAD Update') { continue }
                foreach ($control in $window.Controls) {
                    if ($control -isnot [Windows.Forms.Button] -or -not $control.Visible -or -not $control.Enabled) { continue }
                    if ($script:bootstrapMode -ceq 'cancel' -and -not $script:cancelClicked -and
                        $control.Text -ceq 'Cancel' -and [IO.File]::Exists((Join-Path $script:bootstrapCase 'running'))) {
                        $script:cancelClicked=$true
                        $control.PerformClick()
                    } elseif ($script:bootstrapMode -ceq 'cancel' -and $script:cancelClicked -and $control.Text -ceq 'Close') {
                        $control.PerformClick()
                    } elseif ($script:bootstrapMode -ceq 'retry' -and -not $script:retryClicked -and $control.Text -ceq 'Retry') {
                        $script:retryClicked=$true
                        $control.PerformClick()
                    }
                }
            }
        })
        $timer.Start()
        try {
            # This is the GUI bootstrap's actual invocation form. The worker is
            # a boundary fixture so the form can run without downloading a release.
            & ([scriptblock]::Create($source)) -InteractiveUpdate -InstallDir $case -InstallerScriptPath $worker -NoUserIntegration
        } finally { $timer.Stop(); $timer.Dispose() }
        $logPath=Join-Path $case 'repair\update-log.jsonl'
        if (-not [IO.File]::Exists($logPath)) { throw "No coordinator log for $mode" }
        $lines=@([IO.File]::ReadAllLines($logPath,[Text.Encoding]::UTF8))
        $events=@($lines | ForEach-Object { $_ | ConvertFrom-Json })
        if ($mode -ceq 'cancel') {
            if (-not $script:cancelClicked -or $events.Count -ne 1 -or $events[0].stage -cne 'downloading' -or $events[0].outcome -cne 'cancelled') { throw 'Cancel did not complete and log a cancellation' }
        } elseif ($mode -ceq 'retry') {
            if (-not $script:retryClicked -or $events.Count -ne 2 -or $events[0].stage -cne 'downloading' -or
                $events[0].outcome -cne 'failure' -or $events[1].stage -cne 'complete' -or $events[1].outcome -cne 'success') { throw 'Failure and retry did not complete and log both outcomes' }
            if ($lines[0].Contains('example.invalid') -or $lines[0].Contains('hidden-value') -or $lines[0].Contains('token=hidden')) { throw 'Failure log leaked fixture secrets' }
            if (-not $events[0].detail.Contains('fixture failed') -or -not $events[0].detail.Contains('[url]') -or
                -not $events[0].detail.Contains('[redacted]')) { throw 'Failure log lost its safe diagnostic detail' }
            if ([IO.File]::ReadAllText((Join-Path $case 'attempts')).Length -ne 2) { throw 'Retry did not execute the worker exactly twice' }
        } elseif ($events.Count -ne 1 -or $events[0].stage -cne 'complete' -or $events[0].outcome -cne 'success') {
            throw 'Success did not complete and log its outcome'
        }
    }
    'PASS coordinator-bootstrap'
} finally {
    [Windows.Forms.Application]::remove_ThreadException($onError)
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
