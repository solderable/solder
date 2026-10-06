import { describe, expect, test } from "bun:test";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
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
  const scratch = mkdtempSync(join(tmpdir(), "solder-installer-contract-"));
  const data = structuredClone(fixture);
  if (macArch === "x64") data.details.macos.asset.name = "solder-1.2.3-macos-x64.zip";
  scenario.edit?.(data);
  const body = `<!-- solder-release-platform-details ${JSON.stringify(data.details)} -->`;
  const metadata = join(scratch, "release.json");
  writeFileSync(metadata, JSON.stringify({ ...data.release, body: scenario.body?.(body) ?? body }));
  const archive = join(scratch, "archive.zip");
  writeFileSync(archive, "abd");
  const bin = join(scratch, "bin");
  mkdirSync(bin);
  // Replace the external HTTP boundary. The real shell script, JSON parser,
  // metadata selection, and archive integrity checks all run unchanged.
  writeFileSync(join(bin, "curl"), `#!/usr/bin/env bash
set -euo pipefail
output=""
url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) output="$2"; shift 2 ;;
    -H|--connect-timeout|--max-time|--max-filesize|--proto) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
case "$url" in
  https://api.github.com/repos/solderable/solder/releases/*) cp "$SOLDER_TEST_METADATA" "$output" ;;
  *) cp "$SOLDER_TEST_ARCHIVE" "$output" ;;
esac
`, { mode: 0o755 });
  const pathKey = Object.keys(process.env).find(key => key.toLowerCase() === "path") ?? "PATH";
  return {
    scratch,
    env: { ...process.env, [pathKey]: `${bin}${delimiter}${process.env[pathKey]}`, SOLDER_TEST_METADATA: metadata, SOLDER_TEST_ARCHIVE: archive },
    cleanup: () => rmSync(scratch, { recursive: true, force: true }),
  };
}

function runBash(scenario: Scenario, dryRun = true) {
  const state = createFixture(scenario);
  try {
    const args = ["bash", join(root, "install.sh"), "--version", scenario.version ?? "1.2.3"];
    if (dryRun) args.push("--dry-run");
    if (scenario.source) args.push("--download-source", scenario.source);
    const result = Bun.spawnSync(args, { env: state.env, stdout: "pipe", stderr: "pipe" });
    return { code: result.exitCode, output: result.stdout.toString(), error: result.stderr.toString() };
  } finally { state.cleanup(); }
}

function runPowerShell(scenario: Scenario, archiveContent?: string) {
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
function Invoke-RestMethod { Get-Content -LiteralPath $env:SOLDER_TEST_METADATA -Raw | ConvertFrom-Json }
try {
  $result = Resolve-ReleaseDownload -RequestedVersion $Version -Source $Source
  if ($CheckArchive -eq "yes") { Assert-ArchiveIntegrity -ArchivePath $env:SOLDER_TEST_ARCHIVE -Download $result }
  $result | ConvertTo-Json -Compress
} catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }
`);
    const result = Bun.spawnSync([powershell, "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", driver, join(root, "install.ps1"), scenario.version ?? "1.2.3", scenario.source ?? "Auto", archiveContent === undefined ? "no" : "yes"], { env: state.env, stdout: "pipe", stderr: "pipe" });
    return { code: result.exitCode, output: result.stdout.toString(), error: result.stderr.toString() };
  } finally { state.cleanup(); }
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
          expect(selected).toEqual({ Version: "1.2.3", AssetName: "solder-1.2.3-windows-x64.zip", DownloadUrl: expectedUrl, Size: 3, Sha256: abcSha256, Source: scenario.github ? "github" : "uploadthing" });
        }
      });
    }
  });
}

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
