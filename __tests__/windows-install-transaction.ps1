param([Parameter(Mandatory=$true)][string]$Installer, [Parameter(Mandatory=$true)][string]$Scenario, [string]$LeaseRoot)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Exercise the installer's real functions with disposable files and real Windows
# handles. No registry, desktop shortcut, network, or user installation is used.
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($Installer, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw $errors[0].Message }
foreach ($statement in $ast.EndBlock.Statements) {
    if ($statement -is [Management.Automation.Language.FunctionDefinitionAst]) {
        . ([scriptblock]::Create($statement.Extent.Text))
    }
}

function Assert-Condition([bool]$Value, [string]$Message) {
    if (-not $Value) { throw $Message }
}

function New-TestFixture([string]$Root) {
    $bin = Join-Path $Root 'bin'
    $app = Join-Path $Root 'SolderCAD'
    $tx = Join-Path $Root '.solder-installer-transaction'
    $payload = Join-Path $tx 'payload'
    foreach ($dir in @($bin, $app, $tx, $payload, (Join-Path $payload 'SolderCAD'))) {
        New-Item -ItemType Directory -Path $dir | Out-Null
    }
    Set-Content -LiteralPath (Join-Path $app 'old.txt') -Value 'old app'
    Set-Content -LiteralPath (Join-Path $bin 'solder.exe') -Value 'old cli'
    Set-Content -LiteralPath (Join-Path $payload 'SolderCAD\new.txt') -Value 'new app'
    Set-Content -LiteralPath (Join-Path $payload 'solder.exe') -Value 'new cli'
    Write-TransactionRecord (Join-Path $tx 'owner') 'solder-installer-transaction-v1'
}

function Start-TestJournal([string]$Root) {
    $tx = Join-Path $Root '.solder-installer-transaction'
    $payload = Join-Path $tx 'payload'
    $token = '0123456789abcdef0123456789abcdef'
    $paths = Get-TransactionPaths $Root $token
    $record = [ordered]@{
        schemaVersion = 3
        token = $token
        oldApp = Get-TargetIdentity (Join-Path $Root 'SolderCAD') $true
        oldCli = Get-TargetIdentity (Join-Path $Root 'bin\solder.exe') $false
        oldSidecar = Get-TargetIdentity (Join-Path $Root 'bin\SolderCAD') $true
        newApp = Get-TargetIdentity (Join-Path $payload 'SolderCAD') $true
        newCli = Get-TargetIdentity (Join-Path $payload 'solder.exe') $false
    } | ConvertTo-Json -Compress
    Write-TransactionRecord (Join-Path $tx 'journal.json') $record
    return $paths
}

$root = Join-Path $env:TEMP ('solder-installer-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
try {
    $root = Resolve-PhysicalPath $root
    switch ($Scenario) {
        'lease-v2-port' {
            $owner = Enter-SolderInstallLease $LeaseRoot
            try {
                $ports = @($owner.Listeners | ForEach-Object { $_.LocalEndpoint.Port })
                Write-Output ("PORTS=" + ($ports -join ','))
            } finally { $owner.Stop() }
        }
        'interrupted-verifier' {
            $tx = Join-Path $root '.solder-installer-transaction'
            New-Item -ItemType Directory $tx | Out-Null
            Write-TransactionRecord (Join-Path $tx 'owner') 'solder-installer-transaction-v1'
            Set-Content (Join-Path $tx 'unexecuted-payload.txt') 'safe'
            $verifier = Join-Path $root '.solder-installer-verified-0123456789abcdef0123456789abcdef.exe'
            Add-Type -OutputAssembly $verifier -OutputType ConsoleApplication -TypeDefinition 'public class VerifierFixture { public static void Main() { System.Threading.Thread.Sleep(120000); } }'
            $child = Start-Process -FilePath $verifier -WindowStyle Hidden -PassThru
            try {
                Assert-SolderProcessesClosed $root
                Recover-SolderTransaction $root
                Assert-Condition (-not (Test-Path $tx)) 'an active verifier blocked transaction recovery'
                Assert-Condition (Test-Path $verifier) 'the verifier was not preserved'
                Assert-Condition (-not $child.HasExited) 'recovery closed the verifier process'
            } finally { Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue }
        }
        'downgrade-policy' {
            $app = Join-Path $root 'SolderCAD'
            $bin = Join-Path $root 'bin'
            $resources = Join-Path $app 'share\kicad\resources\solder_chat'
            New-Item -ItemType Directory -Force $resources, $bin | Out-Null
            Set-Content -LiteralPath (Join-Path $resources 'solder-release.json') -Value '{"schemaVersion":1,"component":"soldercad","version":"1.35.0"}'
            $cli = Join-Path $bin 'solder.exe'
            Add-Type -OutputAssembly $cli -OutputType ConsoleApplication -TypeDefinition 'public class VersionProbe { public static void Main() { System.Console.WriteLine("solder v1.37.0"); } }'
            $versions = Get-InstalledVersions $root
            Assert-Condition ($versions.App -ceq '1.35.0') 'the installed app version was not detected'
            Assert-Condition ($versions.Cli -ceq '1.37.0') 'the installed CLI version was not detected'
            $failed = $false
            try { Assert-NoImplicitDowngrade $versions '1.36.0' } catch { $failed = $true }
            Assert-Condition $failed 'a newer installed CLI would be downgraded'
            $failed = $false
            try { Assert-NoImplicitDowngrade ([pscustomobject]@{App='1.37.0';Cli='1.35.0'}) '1.36.0' } catch { $failed = $true }
            Assert-Condition $failed 'a newer installed app would be downgraded'
            Assert-NoImplicitDowngrade ([pscustomobject]@{App=$null;Cli='1.35.0'}) '1.36.0'
        }
        'long-archive-path' {
            Add-Type -AssemblyName System.IO.Compression
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $archivePath = Join-Path $root 'fixture.zip'
            $archive = [IO.Compression.ZipFile]::Open($archivePath, [IO.Compression.ZipArchiveMode]::Create)
            try {
                $relative = ('nested-' + ('a' * 110) + '/' + ('b' * 110) + '/content.txt')
                $entry = $archive.CreateEntry($relative)
                $writer = New-Object IO.StreamWriter ($entry.Open())
                try { $writer.Write('long path contents') } finally { $writer.Dispose() }
            } finally { $archive.Dispose() }
            $destination = Join-Path $root ('install-' + ('c' * 60))
            Expand-ZipArchive $archivePath $destination
            $file = Join-Path $destination ($relative.Replace('/', '\'))
            Assert-Condition ($file.Length -gt 260) 'fixture did not cross the Windows path limit'
            Assert-Condition ([IO.File]::ReadAllText((ConvertTo-ExtendedPath $file)) -ceq 'long path contents') 'long archive entry was not extracted'
        }
        'unsafe-archive' {
            Add-Type -AssemblyName System.IO.Compression
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $cases = New-Object 'System.Collections.Generic.List[object]'
            $cases.Add([string[]]@('../escaped.txt'))
            $cases.Add([string[]]@('folder/CON.txt'))
            $cases.Add([string[]]@('folder/a.txt', 'folder/A.txt'))
            for ($i = 0; $i -lt $cases.Count; $i++) {
                $archivePath = Join-Path $root "unsafe-$i.zip"
                $archive = [IO.Compression.ZipFile]::Open($archivePath, [IO.Compression.ZipArchiveMode]::Create)
                try { foreach ($name in $cases[$i]) { [void]$archive.CreateEntry($name) } }
                finally { $archive.Dispose() }
                $destination = Join-Path $root "extract-$i"
                $failed = $false
                try { Expand-ZipArchive $archivePath $destination } catch { $failed = $true }
                Assert-Condition $failed "unsafe archive case $i was accepted"
                Assert-Condition (-not (Test-Path $destination)) 'an unsafe archive was extracted before validation'
            }
        }
        'unicode-extra-field' {
            # The primary name and 0x7075 Unicode extra field disagree. The
            # validator and extractor must use the same name, not two decoders.
            $archivePath = Join-Path (Split-Path -Parent $Installer) '__tests__\fixtures\windows-unicode-path-extra.zip'
            $destination = Join-Path $root 'extract'
            Expand-ZipArchive $archivePath $destination
            $good = Join-Path $destination 'safe\good.txt'
            $alternate = Join-Path $destination ('safe\alternate-' + [char]0x03c0 + '.txt')
            Assert-Condition ([IO.File]::ReadAllText($good) -ceq 'hello') 'validated primary name was not extracted'
            Assert-Condition (-not (Test-Path -LiteralPath $alternate)) 'a different Unicode extra-field name was extracted'
        }
        { $_ -in @('version-mismatch', 'locked-publish') } {
            # Exercise the full installer with a deterministic release boundary.
            # The staged executable runs but reports a different version.
            Add-Type -AssemblyName System.IO.Compression
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $testInstall = Join-Path $root 'install'
            New-Item -ItemType Directory -Force -Path (Join-Path $testInstall 'bin'), (Join-Path $testInstall 'SolderCAD') | Out-Null
            Set-Content (Join-Path $testInstall 'bin\solder.exe') 'old cli'
            Set-Content (Join-Path $testInstall 'SolderCAD\old.txt') 'old app'
            $fakeExe = Join-Path $root 'fake.exe'
            $fakeVersion = if ($Scenario -eq 'version-mismatch') { '1.0.0' } else { '1.36.0' }
            $source = 'public class VersionFixture { public static void Main() { System.Console.WriteLine("solder v' + $fakeVersion + '"); } }'
            Add-Type -OutputAssembly $fakeExe -OutputType ConsoleApplication -TypeDefinition $source
            $fixtureZip = Join-Path $root 'release.zip'
            $archive = [IO.Compression.ZipFile]::Open($fixtureZip, [IO.Compression.ZipArchiveMode]::Create)
            try {
                $prefix = 'solder-1.36.0-windows-x64/'
                [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $fakeExe, ($prefix + 'solder.exe'))
                foreach ($file in @('INSTALL.txt', 'SolderCAD/bin/kicad.exe', 'SolderCAD/bin/kicad-cli.exe',
                                    'SolderCAD/bin/python.exe', 'SolderCAD/bin/Lib/encodings/__init__.py',
                                    'SolderCAD/share/kicad/placeholder.txt')) {
                    [void]$archive.CreateEntry($prefix + $file)
                }
                $metadata = $archive.CreateEntry($prefix + 'SolderCAD/share/kicad/resources/solder_chat/solder-release.json')
                $writer = New-Object IO.StreamWriter ($metadata.Open())
                try { $writer.Write('{"schemaVersion":1,"component":"soldercad","version":"1.36.0"}') }
                finally { $writer.Dispose() }
            } finally { $archive.Dispose() }
            $sha = [Security.Cryptography.SHA256]::Create()
            try { $hash = ([BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($fixtureZip)))).Replace('-', '').ToLowerInvariant() }
            finally { $sha.Dispose() }
            $fixtureRelease = [pscustomobject]@{
                tag_name = '1.36.0'; draft = $false; body = ''
                assets = @([pscustomobject]@{
                    name = 'solder-1.36.0-windows-x64.zip'
                    size = (Get-Item -LiteralPath $fixtureZip).Length
                    digest = 'sha256:' + $hash
                    browser_download_url = 'https://github.com/solderable/solder/releases/download/1.36.0/solder-1.36.0-windows-x64.zip'
                })
            }
            function Invoke-RestMethod { param($Uri, $TimeoutSec, $Headers) return $fixtureRelease }
            function Invoke-WebRequest { param($Uri, $OutFile, $TimeoutSec, $Headers) [IO.File]::Copy($fixtureZip, $OutFile) }
            $failed = $false
            $handle = $null
            if ($Scenario -eq 'locked-publish') {
                $handle = [IO.File]::Open((Join-Path $testInstall 'bin\solder.exe'), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
            }
            try {
                try { & ([scriptblock]::Create((Get-Content -LiteralPath $Installer -Raw))) -Version '1.36.0' -InstallDir $testInstall -NoUserIntegration }
                catch {
                    $failed = if ($Scenario -eq 'version-mismatch') { $_.Exception.Message -like '*did not identify itself as v1.36.0*' } else { $true }
                }
            } finally { if ($null -ne $handle) { $handle.Dispose() } }
            Assert-Condition $failed 'invalid installation unexpectedly succeeded'
            Assert-Condition ((Get-Content (Join-Path $testInstall 'bin\solder.exe') -Raw).Trim() -ceq 'old cli') 'old CLI was changed'
            Assert-Condition ((Get-Content (Join-Path $testInstall 'SolderCAD\old.txt') -Raw).Trim() -ceq 'old app') 'old app was changed'
            Assert-Condition (-not (Test-Path (Join-Path $testInstall '.solder-installer-transaction'))) 'failed validation left a blocking transaction'
            $unpublished = @(Get-ChildItem -LiteralPath $testInstall -File -Filter '.solder-installer-verified-*.exe')
            Assert-Condition ($unpublished.Count -eq 1) 'the executed unpublished CLI was not preserved'
        }
        'lease' {
            $first = Enter-SolderInstallLease $root
            try {
                $blocked = $false
                try { $second = Enter-SolderInstallLease $root; $second.Stop() } catch { $blocked = $true }
                Assert-Condition $blocked 'a second owner acquired the same lease'
            } finally { $first.Stop() }
            $next = Enter-SolderInstallLease $root
            $next.Stop()
        }
        'locked-cli-rollback' {
            New-TestFixture $root
            $app = Join-Path $root 'SolderCAD'
            $cli = Join-Path $root 'bin\solder.exe'
            $payload = Join-Path $root '.solder-installer-transaction\payload'
            $original = @((Get-TargetIdentity $app $true), (Get-TargetIdentity $cli $false), $null)
            # Deny delete-sharing so the real filesystem rejects the CLI move
            # after the original SolderCAD directory has already moved.
            $handle = [IO.File]::Open($cli, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
            try {
                $failed = $false
                try { Publish-SolderTransaction $root $payload $original } catch { $failed = $true }
                Assert-Condition $failed 'publication succeeded despite a locked CLI'
            } finally { $handle.Dispose() }
            Recover-SolderTransaction $root
            Assert-Condition ((Get-Content (Join-Path $app 'old.txt') -Raw).Trim() -ceq 'old app') 'old SolderCAD was not restored'
            Assert-Condition ((Get-Content $cli -Raw).Trim() -ceq 'old cli') 'old CLI was not restored'
        }
        'interrupted-publication' {
            New-TestFixture $root
            $paths = Start-TestJournal $root
            $tx = Join-Path $root '.solder-installer-transaction'
            [IO.Directory]::Move((Join-Path $root 'SolderCAD'), $paths.backupApp)
            [IO.File]::Move((Join-Path $root 'bin\solder.exe'), $paths.backupCli)
            [IO.Directory]::Move((Join-Path $tx 'payload\SolderCAD'), (Join-Path $root 'SolderCAD'))
            [IO.File]::Move((Join-Path $tx 'payload\solder.exe'), (Join-Path $root 'bin\solder.exe'))
            Recover-SolderTransaction $root
            Assert-Condition ((Get-Content (Join-Path $root 'SolderCAD\old.txt') -Raw).Trim() -ceq 'old app') 'old app was not restored'
            Assert-Condition ((Get-Content (Join-Path $root 'bin\solder.exe') -Raw).Trim() -ceq 'old cli') 'old cli was not restored'
            $recovered = @(Get-ChildItem -LiteralPath $root -Directory -Filter '.solder-installer-recovered-*')
            Assert-Condition ($recovered.Count -eq 1) 'partial payload was not retained for recovery'
            Assert-Condition ((Get-Content (Join-Path $paths.failedApp 'new.txt') -Raw).Trim() -ceq 'new app') 'published files were lost'
            Assert-Condition ((Get-Content $paths.failedCli -Raw).Trim() -ceq 'new cli') 'published CLI was lost'
        }
        'foreign-target' {
            New-TestFixture $root
            $paths = Start-TestJournal $root
            $tx = Join-Path $root '.solder-installer-transaction'
            [IO.Directory]::Move((Join-Path $root 'SolderCAD'), $paths.backupApp)
            New-Item -ItemType Directory -Path (Join-Path $root 'SolderCAD') | Out-Null
            Set-Content (Join-Path $root 'SolderCAD\foreign.txt') 'user data'
            $failed = $false
            try { Recover-SolderTransaction $root } catch { $failed = $true }
            Assert-Condition $failed 'recovery accepted an unrelated directory'
            Assert-Condition ((Get-Content (Join-Path $root 'SolderCAD\foreign.txt') -Raw).Trim() -ceq 'user data') 'unrelated data was modified'
            Assert-Condition (Test-Path (Join-Path $paths.backupApp 'old.txt')) 'the original backup was lost'
        }
        'foreign-backup' {
            New-TestFixture $root
            $paths = Start-TestJournal $root
            [IO.Directory]::Move((Join-Path $root 'SolderCAD'), $paths.backupApp)
            [IO.Directory]::Move($paths.backupApp, (Join-Path $root 'saved-original'))
            New-Item -ItemType Directory $paths.backupApp | Out-Null
            Set-Content (Join-Path $paths.backupApp 'foreign.txt') 'foreign data'
            $failed = $false
            try { Recover-SolderTransaction $root } catch { $failed = $true }
            Assert-Condition $failed 'recovery accepted an unrelated backup'
            Assert-Condition ((Get-Content (Join-Path $paths.backupApp 'foreign.txt') -Raw).Trim() -ceq 'foreign data') 'unrelated backup was modified'
            Assert-Condition (Test-Path (Join-Path $root 'saved-original\old.txt')) 'the original app was lost'
        }
        'interrupted-move-sequence' {
            # Every prefix of the actual five moves represents a possible crash.
            for ($phase = 0; $phase -le 5; $phase++) {
                $caseRoot = Join-Path $root ("phase-" + $phase)
                New-Item -ItemType Directory $caseRoot | Out-Null
                New-TestFixture $caseRoot
                New-Item -ItemType Directory (Join-Path $caseRoot 'bin\SolderCAD') | Out-Null
                Set-Content (Join-Path $caseRoot 'bin\SolderCAD\old.txt') 'old sidecar'
                $paths = Start-TestJournal $caseRoot
                $tx = Join-Path $caseRoot '.solder-installer-transaction'
                if ($phase -ge 1) { [IO.Directory]::Move((Join-Path $caseRoot 'SolderCAD'), $paths.backupApp) }
                if ($phase -ge 2) { [IO.File]::Move((Join-Path $caseRoot 'bin\solder.exe'), $paths.backupCli) }
                if ($phase -ge 3) { [IO.Directory]::Move((Join-Path $caseRoot 'bin\SolderCAD'), $paths.backupSidecar) }
                if ($phase -ge 4) { [IO.Directory]::Move((Join-Path $tx 'payload\SolderCAD'), (Join-Path $caseRoot 'SolderCAD')) }
                if ($phase -ge 5) { [IO.File]::Move((Join-Path $tx 'payload\solder.exe'), (Join-Path $caseRoot 'bin\solder.exe')) }
                Recover-SolderTransaction $caseRoot
                Assert-Condition ((Get-Content (Join-Path $caseRoot 'SolderCAD\old.txt') -Raw).Trim() -ceq 'old app') "old app not restored at phase $phase"
                Assert-Condition ((Get-Content (Join-Path $caseRoot 'bin\solder.exe') -Raw).Trim() -ceq 'old cli') "old CLI not restored at phase $phase"
                Assert-Condition ((Get-Content (Join-Path $caseRoot 'bin\SolderCAD\old.txt') -Raw).Trim() -ceq 'old sidecar') "old sidecar not restored at phase $phase"
                Assert-Condition (-not (Test-Path $tx)) "active transaction remained at phase $phase"
            }
        }
        'completed-publication' {
            New-TestFixture $root
            $app = Join-Path $root 'SolderCAD'
            $cli = Join-Path $root 'bin\solder.exe'
            $tx = Join-Path $root '.solder-installer-transaction'
            $original = @((Get-TargetIdentity $app $true), (Get-TargetIdentity $cli $false), $null)
            Publish-SolderTransaction $root (Join-Path $tx 'payload') $original
            Recover-SolderTransaction $root
            Assert-Condition ((Get-Content (Join-Path $app 'new.txt') -Raw).Trim() -ceq 'new app') 'new app was rolled back'
            Assert-Condition ((Get-Content $cli -Raw).Trim() -ceq 'new cli') 'new CLI was rolled back'
            Assert-Condition (-not (Test-Path $tx)) 'completed transaction was not cleaned'
        }
        'committed-target-changed' {
            foreach ($mode in @('missing', 'foreign')) {
                $caseRoot = Join-Path $root $mode
                New-Item -ItemType Directory $caseRoot | Out-Null
                New-TestFixture $caseRoot
                $app = Join-Path $caseRoot 'SolderCAD'
                $cli = Join-Path $caseRoot 'bin\solder.exe'
                $tx = Join-Path $caseRoot '.solder-installer-transaction'
                $original = @((Get-TargetIdentity $app $true), (Get-TargetIdentity $cli $false), $null)
                Publish-SolderTransaction $caseRoot (Join-Path $tx 'payload') $original
                $record = Get-Content (Join-Path $tx 'journal.json') -Raw | ConvertFrom-Json
                $paths = Get-TransactionPaths $caseRoot $record.token
                [IO.Directory]::Move($app, (Join-Path $caseRoot 'saved-new'))
                if ($mode -eq 'foreign') {
                    New-Item -ItemType Directory $app | Out-Null
                    Set-Content (Join-Path $app 'foreign.txt') 'foreign data'
                }
                $failed = $false
                try { Recover-SolderTransaction $caseRoot } catch { $failed = $true }
                Assert-Condition $failed "cleanup accepted a $mode committed app"
                Assert-Condition (Test-Path (Join-Path $paths.backupApp 'old.txt')) 'original app backup was removed'
                Assert-Condition (Test-Path $paths.backupCli) 'original CLI backup was removed'
                Assert-Condition (Test-Path (Join-Path $tx 'journal.json')) 'recovery journal was removed'
                if ($mode -eq 'foreign') {
                    Assert-Condition ((Get-Content (Join-Path $app 'foreign.txt') -Raw).Trim() -ceq 'foreign data') 'foreign data was modified'
                }
            }
        }
        'locked-cleanup' {
            New-TestFixture $root
            $app = Join-Path $root 'SolderCAD'
            $cli = Join-Path $root 'bin\solder.exe'
            $tx = Join-Path $root '.solder-installer-transaction'
            $original = @((Get-TargetIdentity $app $true), (Get-TargetIdentity $cli $false), $null)
            Publish-SolderTransaction $root (Join-Path $tx 'payload') $original
            $lockedPath = Join-Path $tx 'held.txt'
            Set-Content -LiteralPath $lockedPath -Value 'busy'
            $handle = [IO.File]::Open($lockedPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
            try {
                try { Recover-SolderTransaction $root } catch { }
                if (Test-Path $tx) {
                    Assert-Condition (Test-Path (Join-Path $tx 'owner')) 'cleanup removed the active owner marker'
                    Assert-Condition (Test-Path (Join-Path $tx 'journal.json')) 'cleanup removed the active journal'
                    Assert-Condition (Test-Path (Join-Path $tx 'committed')) 'cleanup removed the active commit marker'
                } else {
                    $cleanup = @(Get-ChildItem -LiteralPath $root -Directory -Filter '.solder-installer-cleanup-*')
                    Assert-Condition ($cleanup.Count -eq 1) 'partial cleanup was not isolated from the active marker'
                }
                Assert-Condition ((Get-Content (Join-Path $app 'new.txt') -Raw).Trim() -ceq 'new app') 'cleanup changed the installed app'
                Assert-Condition ((Get-Content $cli -Raw).Trim() -ceq 'new cli') 'cleanup changed the installed CLI'
            } finally { $handle.Dispose() }
            Recover-SolderTransaction $root
            Assert-Condition (-not (Test-Path $tx)) 'recovery marker remained after releasing the file'
        }
        'linked-bin' {
            $outside = Join-Path $root 'outside'
            New-Item -ItemType Directory -Path $outside | Out-Null
            Set-Content (Join-Path $outside 'keep.txt') 'user data'
            $bin = Join-Path $root 'bin'
            New-Item -ItemType Junction -Path $bin -Target $outside | Out-Null
            $failed = $false
            try { Assert-OrdinaryTarget $bin $true } catch { $failed = $true }
            Assert-Condition $failed 'a junction was accepted as the binary directory'
            Assert-Condition ((Get-Content (Join-Path $outside 'keep.txt') -Raw).Trim() -ceq 'user data') 'junction target was modified'
            [IO.Directory]::Delete($bin)
        }
        'running-app' {
            $bin = Join-Path $root 'SolderCAD\bin'
            New-Item -ItemType Directory -Path $bin -Force | Out-Null
            $executable = Join-Path $bin 'kicad.exe'
            Copy-Item -LiteralPath (Join-Path $PSHOME 'powershell.exe') -Destination $executable
            $command = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes('Start-Sleep -Seconds 120'))
            $child = Start-Process -FilePath $executable -ArgumentList @('-NoProfile', '-EncodedCommand', $command) -WindowStyle Hidden -PassThru
            try {
                $failed = $false
                try { Assert-SolderProcessesClosed $root } catch { $failed = $true }
                Assert-Condition $failed 'an executable under the target was not detected'
                Assert-Condition (-not $child.HasExited) 'the installer closed the target process'
            } finally { Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue }
        }
        'external-update' {
            $target = Join-Path $root 'target'
            $elsewhere = Join-Path $root 'elsewhere'
            New-Item -ItemType Directory $target, $elsewhere | Out-Null
            $executable = Join-Path $elsewhere 'solder.exe'
            Add-Type -OutputAssembly $executable -OutputType ConsoleApplication -TypeDefinition 'public class TestCli { public static void Main(string[] args) { System.Threading.Thread.Sleep(120000); } }'
            $child = Start-Process -FilePath $executable -ArgumentList 'update' -WindowStyle Hidden -PassThru
            try {
                $failed = $false
                try { Assert-SolderProcessesClosed $target } catch { $failed = $true }
                Assert-Condition $failed 'an update from another CLI was not detected'
                Assert-Condition (-not $child.HasExited) 'the installer closed the other CLI'
            } finally { Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue }
            $child = Start-Process -FilePath $executable -ArgumentList 'chat' -WindowStyle Hidden -PassThru
            try {
                Assert-SolderProcessesClosed $target
                Assert-Condition (-not $child.HasExited) 'the unrelated session was closed'
            } finally { Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue }
        }
        default { throw "unknown test scenario: $Scenario" }
    }
    Write-Output "PASS $Scenario"
} finally {
    [IO.Directory]::Delete((ConvertTo-ExtendedPath $root), $true)
}
