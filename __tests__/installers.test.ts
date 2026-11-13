import { describe, expect, test } from "bun:test";
import { existsSync, mkdtempSync, mkdirSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { delimiter, join } from "node:path";
import fixture from "./fixtures/release.json";

const root = join(import.meta.dir, "..");
const macArch = process.arch === "arm64" ? "arm64" : "x64";
const powershell = process.platform === "win32" ? "powershell.exe" : "pwsh";
type Fixture = typeof fixture;
type Scenario = {
  name: string;
  edit?: (data: Fixture) => void;
  body?: (body: string) => string;
  version?: string;
  source?: "github";
  error?: string;
  github?: boolean;
  legacyHost?: boolean;
};

// "abc" has this SHA-256 (FIPS 180-4's standard short example), independently
// of the installer. Equal-length "abd" must be rejected before any extraction.
const abcSha256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
const scenarios: Scenario[] = [
  { name: "selects the verified UploadThing archive" },
  { name: "accepts the older public UploadThing hostname", edit: data => { for (const detail of Object.values(data.details)) detail.asset.downloadUrl = "https://utfs.io/f/public_123"; }, legacyHost: true },
  { name: "uses GitHub when historical metadata has no CDN URL", edit: data => { for (const detail of Object.values(data.details)) delete (detail.asset as Partial<typeof detail.asset>).downloadUrl; }, github: true },
  { name: "uses GitHub when a historical release has no platform metadata", body: () => "Historical release notes", github: true },
  { name: "allows explicit GitHub selection with damaged CDN metadata", source: "github", body: () => "<!-- solder-release-platform-details invalid -->", github: true },
  { name: "rejects a different release version", version: "1.2.4", error: "different release version than requested" },
  { name: "rejects stale CDN archive sizes", edit: data => { for (const detail of Object.values(data.details)) detail.asset.size = 4; }, error: "does not match the GitHub asset" },
  { name: "rejects stale CDN archive checksums", edit: data => { for (const detail of Object.values(data.details)) detail.asset.digest = "sha256:" + "0".repeat(64); }, error: "does not match the GitHub asset" },
  { name: "rejects a CDN entry for a different artifact", edit: data => { for (const detail of Object.values(data.details)) detail.asset.name = "solder-1.2.2-windows-x64.zip"; }, error: "does not match the GitHub asset" },
  { name: "rejects incomplete CDN metadata comments", body: () => "<!-- solder-release-platform-details {", error: "metadata is malformed" },
  { name: "rejects a metadata marker without its opening delimiter", body: () => "<!-- solder-release-platform-details", error: "metadata is malformed" },
  { name: "rejects duplicate metadata comments", body: body => body + "\n" + body, error: "metadata is malformed" },
  { name: "rejects invalid metadata JSON", body: () => "<!-- solder-release-platform-details {invalid} -->", error: "Release download metadata is invalid JSON" },
  ...[
    "https://solder.ufs.sh/f/key?token=secret",
    "https://solder.ufs.sh/f/key#fragment",
    "https://solder.ufs.sh:443/f/key",
    "https://user@solder.ufs.sh/f/key",
    "https://solder.ufs.sh.attacker.example/f/key",
    "https://solder.ufs.sh/f/key/extra",
    "https://solder.ufs.sh/f/key\n",
    "http://solder.ufs.sh/f/key",
  ].map((url, index): Scenario => ({
    name: `rejects an untrusted CDN URL (${index + 1})`,
    edit: data => { for (const detail of Object.values(data.details)) detail.asset.downloadUrl = url; },
    error: "must be a public UploadThing URL",
  })),
];

function createFixture(scenario: Scenario) {
  // Windows shell links expand DOS short names (e.g. RUNNER~1) on save.
  const scratch = realpathSync.native(mkdtempSync(join(tmpdir(), "solder-installer-contract-")));
  const data = structuredClone(fixture);
  if (macArch === "x64") data.details.macos.asset.name = "solder-1.2.3-macos-x64.zip";
  scenario.edit?.(data);
  const body = `<!-- solder-release-platform-details ${JSON.stringify(data.details)} -->`;
  const metadata = join(scratch, "release.json");
  writeFileSync(metadata, JSON.stringify({ ...data.release, body: scenario.body?.(body) ?? body }));
  const archive = join(scratch, "archive.zip");
  writeFileSync(archive, "abd");
  const bin = join(scratch, "bin");
  const requests = join(scratch, "requests.tsv");
  mkdirSync(bin);
  // Replace the external HTTP boundary. The real shell script, JSON parser,
  // metadata selection, and archive integrity checks all run unchanged.
  writeFileSync(join(bin, "curl"), `#!/usr/bin/env bash
set -euo pipefail
output=""
url=""
authorization=""
maximum_redirects=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) output="$2"; shift 2 ;;
    -H) if [[ "$2" == 'Authorization: '* ]]; then authorization="\${2#Authorization: }"; fi; shift 2 ;;
    --max-redirs) maximum_redirects="$2"; shift 2 ;;
    --connect-timeout|--max-time|--max-filesize|--proto) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
printf '%s\\t%s\\t%s\\n' "$url" "$authorization" "$maximum_redirects" >> "$SOLDER_TEST_REQUESTS"
case "$url" in
  https://api.github.com/repos/solderable/solder/releases/*) cp "$SOLDER_TEST_METADATA" "$output" ;;
  *) cp "$SOLDER_TEST_ARCHIVE" "$output" ;;
esac
`, { mode: 0o755 });
  const pathKey = Object.keys(process.env).find(key => key.toLowerCase() === "path") ?? "PATH";
  const env = { ...process.env, [pathKey]: `${bin}${delimiter}${process.env[pathKey]}`, SOLDER_TEST_METADATA: metadata, SOLDER_TEST_ARCHIVE: archive, SOLDER_TEST_REQUESTS: requests };
  delete env.GH_TOKEN;
  return {
    scratch,
    env,
    requests: () => existsSync(requests) ? readFileSync(requests, "utf8").replace(/\r?\n$/, "").split("\n").map(line => {
      const [url, authorization = "", maximumRedirects = ""] = line.replace(/\r$/, "").split("\t");
      return { url, authorization, maximumRedirects };
    }) : [],
    cleanup: () => rmSync(scratch, { recursive: true, force: true }),
  };
}

function runBash(scenario: Scenario, dryRun = true, token?: string) {
  const state = createFixture(scenario);
  try {
    const args = ["bash", join(root, "install.sh"), "--version", scenario.version ?? "1.2.3"];
    if (dryRun) args.push("--dry-run");
    if (scenario.source) args.push("--download-source", scenario.source);
    const result = Bun.spawnSync(args, { env: { ...state.env, ...(token === undefined ? {} : { GH_TOKEN: token }) }, stdout: "pipe", stderr: "pipe" });
    return { code: result.exitCode, output: result.stdout.toString(), error: result.stderr.toString(), requests: state.requests() };
  } finally { state.cleanup(); }
}

function runPowerShellDriver(body: string, options: { scenario?: Scenario; archiveContent?: string; token?: string; metadataError?: string } = {}) {
  const { scenario = { name: "Windows shortcut" }, archiveContent } = options;
  const state = createFixture(scenario);
  try {
    if (archiveContent !== undefined) writeFileSync(state.env.SOLDER_TEST_ARCHIVE, archiveContent);
    // Load real installer functions via PowerShell's parser without executing
    // Windows installation or bypassing its platform check on a macOS host.
    const driver = join(state.scratch, "driver.ps1");
    writeFileSync(driver, `param([string]$Installer, [string]$Version, [string]$Source, [string]$CheckArchive)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$Repo = "solderable/solder"
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($Installer, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -ne 0) { throw $parseErrors[0].Message }
foreach ($statement in $ast.EndBlock.Statements) {
  if ($statement -is [System.Management.Automation.Language.FunctionDefinitionAst]) { . ([scriptblock]::Create($statement.Extent.Text)) }
}
function Save-TestRequest {
  param($Uri, $Headers, $MaximumRedirection = '')
  $authorization = if ($Headers.ContainsKey('Authorization')) { $Headers['Authorization'] } else { '' }
  ('{0}{1}{2}{1}{3}' -f $Uri, [char]9, $authorization, $MaximumRedirection) | Add-Content -LiteralPath $env:SOLDER_TEST_REQUESTS
}
function Invoke-RestMethod {
  param($Uri, $TimeoutSec, $Headers, $MaximumRedirection)
  Save-TestRequest $Uri $Headers $MaximumRedirection
  if ($env:SOLDER_TEST_METADATA_ERROR) { throw $env:SOLDER_TEST_METADATA_ERROR }
  Get-Content -LiteralPath $env:SOLDER_TEST_METADATA -Raw | ConvertFrom-Json
}
function Invoke-WebRequest {
  param($Uri, $OutFile, $TimeoutSec, $Headers)
  Save-TestRequest $Uri $Headers
  [IO.File]::Copy($env:SOLDER_TEST_ARCHIVE, $OutFile)
}
try {
${body}
} catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }
`);
    const result = Bun.spawnSync([powershell, "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", driver, join(root, "install.ps1"), scenario.version ?? "1.2.3", scenario.source ?? "Auto", archiveContent === undefined ? "no" : "yes"], {
      env: { ...state.env, ...(options.token === undefined ? {} : { GH_TOKEN: options.token }), SOLDER_TEST_METADATA_ERROR: options.metadataError ?? "" }, stdout: "pipe", stderr: "pipe",
    });
    return { code: result.exitCode, output: result.stdout.toString(), error: result.stderr.toString(), scratch: state.scratch, requests: state.requests() };
  } finally { state.cleanup(); }
}

function runPowerShell(scenario: Scenario, archiveContent?: string) {
  return runPowerShellDriver(`
  $result = Resolve-ReleaseDownload -RequestedVersion $Version -Source $Source
  if ($CheckArchive -eq "yes") { Assert-ArchiveIntegrity -ArchivePath $env:SOLDER_TEST_ARCHIVE -Download $result }
  $result | ConvertTo-Json -Compress
`, { scenario, archiveContent });
}

const runtimes = process.platform === "darwin" ? ["macOS", "Windows"] as const : ["Windows"] as const;
for (const runtime of runtimes) {
  describe(`${runtime} release downloads`, () => {
    for (const scenario of scenarios) {
      test(scenario.name, () => {
        const result = runtime === "macOS" ? runBash(scenario) : runPowerShell(scenario);
        if (scenario.error) {
          expect(result.code).toBe(1);
          expect(result.error).toContain(scenario.error);
          return;
        }
        expect(result.code).toBe(0);
        const platform = runtime === "macOS" ? `macos-${macArch}` : "windows-x64";
        const expectedUrl = scenario.github
          ? `https://github.com/solderable/solder/releases/download/1.2.3/solder-1.2.3-${platform}.zip`
          : scenario.legacyHost ? "https://utfs.io/f/public_123"
          : runtime === "macOS" ? "https://solder.ufs.sh/f/macos_123" : "https://solder.ufs.sh/f/windows_123";
        if (runtime === "macOS") {
          const fields = Object.fromEntries(result.output.trim().split("\n").filter(line => line.includes(":")).map(line => {
            const separator = line.indexOf(":");
            return [line.slice(0, separator), line.slice(separator + 1).trim()];
          }));
          expect({ url: fields["Download URL"], source: fields["Download source"], size: fields["Archive bytes"], digest: fields["SHA-256"] }).toEqual({ url: expectedUrl, source: scenario.github ? "github" : "uploadthing", size: "3", digest: abcSha256 });
        } else {
          const selected = JSON.parse(result.output.trim().split("\n").at(-1)!);
          expect(selected).toEqual({ Version: "1.2.3", CliVersion: "1.2.3", AssetName: "solder-1.2.3-windows-x64.zip", DownloadUrl: expectedUrl, Size: 3, Sha256: abcSha256, Source: scenario.github ? "github" : "uploadthing" });
        }
      });
    }
  });
}

for (const runtime of runtimes) {
  for (const scenario of [
    { name: "authenticated CDN download", token: "fixture-api-token" },
    { name: "authenticated GitHub download", token: "fixture-api-token", source: "github" as const },
    { name: "anonymous download", token: "" },
  ]) {
    test(`${runtime} confines credentials to the metadata API for an ${scenario.name}`, () => {
      const result = runtime === "macOS" ? runBash(scenario, false, scenario.token) : runPowerShellDriver(`
  $download = Resolve-ReleaseDownload -RequestedVersion $Version -Source $Source
  $archive = Join-Path (Split-Path -Parent $env:SOLDER_TEST_METADATA) 'download.zip'
  Save-SolderDownload -Uri $download.DownloadUrl -Destination $archive -Size $download.Size -State $null
  Assert-ArchiveIntegrity -ArchivePath $archive -Download $download
`, { scenario, token: scenario.token });
      // The deliberately corrupt archive stops installation after exercising
      // both real request sites and their separate header collections.
      expect(result.code).toBe(1);
      expect(result.error).toContain("SHA-256 does not match the GitHub release asset");
      const platform = runtime === "macOS" ? `macos-${macArch}` : "windows-x64";
      const url = scenario.source === "github"
        ? `https://github.com/solderable/solder/releases/download/1.2.3/solder-1.2.3-${platform}.zip`
        : `https://solder.ufs.sh/f/${runtime === "macOS" ? "macos" : "windows"}_123`;
      expect(result.requests).toEqual([
        { url: "https://api.github.com/repos/solderable/solder/releases/tags/1.2.3", authorization: scenario.token ? `Bearer ${scenario.token}` : "", maximumRedirects: "0" },
        { url, authorization: "", maximumRedirects: "" },
      ]);
      if (scenario.token) expect(result.output + result.error).not.toContain(scenario.token);
    });
  }
}

test("Windows redacts the API credential from upstream failure diagnostics", () => {
  const token = "fixture-secret-token";
  const result = runPowerShellDriver('Resolve-ReleaseDownload -RequestedVersion $Version -Source $Source', {
    token, metadataError: `service rejected ${token}`,
  });
  expect(result.code).toBe(1);
  expect(result.error.trim()).toBe("failed to read GitHub release metadata: service rejected [redacted]");
  expect(result.output + result.error).not.toContain(token);
});

if (process.platform === "darwin") {
  test("macOS rejects same-size altered archive bytes before extraction", () => {
    const result = runBash({ name: "corrupt archive" }, false);
    expect(result.code).toBe(1);
    expect(result.error).toContain("downloaded archive SHA-256 does not match the GitHub release asset");
  });
}

test("Windows rejects same-size altered archive bytes before extraction", () => {
  const result = runPowerShell({ name: "corrupt archive" }, "abd");
  expect(result.code).toBe(1);
  expect(result.error).toContain("downloaded archive SHA-256 does not match the GitHub release asset");
});

test("Windows accepts an archive with its independently known SHA-256", () => {
  const result = runPowerShell({ name: "verified archive" }, "abc");
  expect(result.code).toBe(0);
  expect(JSON.parse(result.output.trim().split("\n").at(-1)!).Sha256).toBe(abcSha256);
});

test("Windows rejects a truncated archive before extraction", () => {
  const result = runPowerShell({ name: "truncated archive" }, "ab");
  expect(result.code).toBe(1);
  expect(result.error).toContain("downloaded archive size does not match the GitHub release asset");
});

test("Windows checks the actual CLI version when a release carries an older binary", () => {
  const result = runPowerShell({
    name: "carried CLI",
    body: body => '<!-- solder-release-binary-versions {"windows":"1.2.2"} -->\n' + body,
  });
  expect({ code: result.code, error: result.error }).toEqual({ code: 0, error: "" });
  expect(JSON.parse(result.output.trim().split("\n").at(-1)!).CliVersion).toBe("1.2.2");
});

test("Windows rejects malformed binary-version metadata", () => {
  const result = runPowerShell({
    name: "invalid CLI version",
    body: body => '<!-- solder-release-binary-versions {"windows":"not-a-version"} -->\n' + body,
  });
  expect(result.code).toBe(1);
  expect(result.error.trim()).toBe("Release binary version metadata does not identify the Windows CLI.");
});

// COM shell links are a Windows boundary: run the real implementation there,
// using only a temporary desktop so local tests never change a user's shortcuts.
if (process.platform === "win32") {
  const shortcutSetup = String.raw`
  $scratch = Split-Path -Parent $env:SOLDER_TEST_METADATA
  $desktop = Join-Path $scratch "Redirected Desktop"
  $shortcutPath = Join-Path $desktop "SolderCAD.lnk"
  $targetPath = Join-Path $scratch "Custom Install\SolderCAD\bin\kicad.exe"
  New-Item -ItemType Directory -Path (Split-Path -Parent $targetPath) -Force | Out-Null
  Set-Content -LiteralPath $targetPath -Value "fixture executable"
  $shell = New-Object -ComObject WScript.Shell
`;
  const readShortcut = `
  $saved = $shell.CreateShortcut($shortcutPath)
  [pscustomobject]@{
    TargetPath = $saved.TargetPath
    WorkingDirectory = $saved.WorkingDirectory
    IconLocation = $saved.IconLocation
    Arguments = $saved.Arguments
    WindowStyle = $saved.WindowStyle
    DesktopFiles = @(Get-ChildItem -LiteralPath $desktop | Select-Object -ExpandProperty Name)
  } | ConvertTo-Json -Compress
`;

  function expectDesktopShortcut(result: ReturnType<typeof runPowerShellDriver>) {
    expect({ code: result.code, error: result.error }).toEqual({ code: 0, error: "" });
    const bin = join(result.scratch, "Custom Install", "SolderCAD", "bin");
    expect(JSON.parse(result.output.trim())).toEqual({
      TargetPath: join(bin, "kicad.exe"),
      WorkingDirectory: bin,
      IconLocation: `${join(bin, "kicad.exe")},0`,
      Arguments: "",
      WindowStyle: 1,
      DesktopFiles: ["SolderCAD.lnk"],
    });
  }

  test("Windows saves an absolute GUI shortcut for a relative install directory with spaces", () => {
    const result = runPowerShellDriver(`${shortcutSetup}
  Set-Location -LiteralPath $scratch
  Set-SolderCadDesktopShortcut -ShortcutPath $shortcutPath -TargetPath (Join-Path "Custom Install" "SolderCAD\\bin\\kicad.exe")
${readShortcut}`);
    expectDesktopShortcut(result);
  });

  test("Windows replaces the old shortcut when reinstalling to a different directory", () => {
    const result = runPowerShellDriver(`${shortcutSetup}
  New-Item -ItemType Directory -Path $desktop -Force | Out-Null
  $old = $shell.CreateShortcut($shortcutPath)
  $old.TargetPath = Join-Path $scratch "Old Install\\SolderCAD\\bin\\kicad.exe"
  $old.Arguments = "obsolete-project.kicad_pro"
  $old.Save()
  Set-SolderCadDesktopShortcut -ShortcutPath $shortcutPath -TargetPath $targetPath
${readShortcut}`);
    expectDesktopShortcut(result);
  });
}

test("Windows refuses to create a shortcut to a missing executable", () => {
  const result = runPowerShellDriver(`
  $scratch = Split-Path -Parent $env:SOLDER_TEST_METADATA
  Set-SolderCadDesktopShortcut -ShortcutPath (Join-Path $scratch "SolderCAD.lnk") -TargetPath (Join-Path $scratch "missing.exe")
`);
  expect(result.code).toBe(1);
  expect(result.error.trim()).toBe(`cannot create SolderCAD desktop shortcut: executable not found at ${join(result.scratch, "missing.exe")}`);
});
