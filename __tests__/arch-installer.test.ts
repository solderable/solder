import { describe, expect, test } from "bun:test";
import { chmodSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, readlinkSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const installer = join(import.meta.dir, "..", "install-arch.sh");
const packageName = "soldercad-1.2.3-1-x86_64.pkg.tar.zst";
// FIPS 180-4's short "abc" example; "abd" is a same-length corrupt download.
const sha256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
const legacy = '#!/bin/sh\nexec "$HOME/.bun/bin/bun" "$HOME/.local/bin/solder-main.js" "$@"\n';
const canonicalUrl = `https://github.com/solderable/solder/releases/download/1.2.3/${packageName}`;
function metadata() {
  return { tag_name: "1.2.3", draft: false, assets: [{ name: packageName, size: 3, digest: `sha256:${sha256}`, browser_download_url: canonicalUrl }] };
}

function fixture() {
  const root = mkdtempSync(join(tmpdir(), "solder-arch-contract-"));
  const home = join(root, "user");
  const bin = join(root, "boundary-bin");
  const userBin = join(home, ".local", "bin");
  mkdirSync(userBin, { recursive: true });
  mkdirSync(bin);
  const release = join(root, "release.json"), archive = join(root, "archive"), operations = join(root, "operations.jsonl");
  writeFileSync(release, JSON.stringify(metadata()));
  writeFileSync(archive, "abc");
  const env = { ...process.env, PATH: `${bin}:${userBin}:${process.env.PATH}`, SOLDER_TEST_RELEASE: release, SOLDER_TEST_ARCHIVE: archive, SOLDER_TEST_OPERATIONS: operations };
  delete env.SOLDER_BINARY_PATH;
  // Replace only external boundaries. The actual parser, integrity checks,
  // launcher inspection, backups, and filesystem changes remain unchanged.
  writeFileSync(join(bin, "curl"), `#!/usr/bin/env python3
import json,os,pathlib,shutil,sys
args=sys.argv[1:]; target=args[args.index('-o')+1]; url=args[-1]
with open(os.environ['SOLDER_TEST_OPERATIONS'],'a') as f: f.write(json.dumps({'boundary':'network','url':url})+'\\n')
if os.environ.get('SOLDER_TEST_DOWNLOAD_FAIL') and '/releases/download/' in url: sys.exit(22)
source=os.environ['SOLDER_TEST_RELEASE'] if url.startswith('https://api.github.com/') else os.environ['SOLDER_TEST_ARCHIVE']
shutil.copyfile(source,target)
`, { mode: 0o755 });
  writeFileSync(join(bin, "sudo"), '#!/bin/sh\nexec "$@"\n', { mode: 0o755 });
  writeFileSync(join(bin, "pacman"), `#!/usr/bin/env python3
import json,os,pathlib,sys
args=sys.argv[1:]
if args[0]=='-Q':
 print(os.environ.get('SOLDER_TEST_INSTALLED_VERSION','soldercad 1.2.3-1'));sys.exit(0)
package=pathlib.Path(args[-1])
with open(os.environ['SOLDER_TEST_OPERATIONS'],'a') as f: f.write(json.dumps({'boundary':'install','bytes':package.read_text(),'name':package.name})+'\\n')
if os.environ.get('SOLDER_TEST_PACMAN_FAIL'): sys.exit(1)
`, { mode: 0o755 });
  const run = (args: { version?: string; dryRun?: boolean; extraEnv?: Record<string, string>; command?: string } = {}) => {
    const command = args.command ?? 'source "$1"; arch_install_release "$2" "$3" 1 "$4" "$5"';
    const result = Bun.spawnSync(["bash", "-c", command, "arch-test", installer, args.version ?? "", args.dryRun ? "1" : "0", home, env.PATH], {
      env: { ...env, ...args.extraEnv }, stdout: "pipe", stderr: "pipe",
    });
    return { code: result.exitCode, output: result.stdout.toString(), error: result.stderr.toString() };
  };
  const events = () => existsSync(operations) ? readFileSync(operations, "utf8").trim().split("\n").filter(Boolean).map(line => JSON.parse(line)) : [];
  return { root, home, bin, userBin, archive, release, env, run, events, close: () => rmSync(root, { recursive: true, force: true }) };
}

function withFixture(body: (f: ReturnType<typeof fixture>) => void) {
  const f = fixture();
  try { body(f); } finally { f.close(); }
}

describe("Arch package installation", () => {
  test("installs the verified Latest package before reporting success", () => withFixture(f => {
    const result = f.run();
    expect(result.code).toBe(0);
    expect(f.events()).toEqual([
      { boundary: "network", url: "https://api.github.com/repos/solderable/solder/releases/latest" },
      { boundary: "network", url: canonicalUrl },
      { boundary: "install", bytes: "abc", name: packageName },
    ]);
  }));
  test("uses the requested version endpoint", () => withFixture(f => {
    expect(f.run({ version: "1.2.3" }).code).toBe(0);
    expect(f.events()[0]).toEqual({ boundary: "network", url: "https://api.github.com/repos/solderable/solder/releases/tags/1.2.3" });
  }));
  test("dry run fetches metadata but leaves user launchers unchanged", () => withFixture(f => {
    const path = join(f.userBin, "solder"); writeFileSync(path, legacy, { mode: 0o755 });
    const result = f.run({ dryRun: true });
    expect({ code: result.code, error: result.error }).toEqual({ code: 0, error: "" });
    expect(f.events()).toEqual([{ boundary: "network", url: "https://api.github.com/repos/solderable/solder/releases/latest" }]);
    expect(readFileSync(path, "utf8")).toBe(legacy);
    expect(readdirSync(f.userBin)).toEqual(["solder"]);
  }));
  test("does not install same-size corrupt bytes", () => withFixture(f => {
    writeFileSync(f.archive, "abd");
    const result = f.run();
    expect(result.code).toBe(1);
    expect(result.error).toContain("SHA-256 does not match");
    expect(f.events().filter(event => event.boundary === "install")).toEqual([]);
  }));
  test("does not install a truncated download", () => withFixture(f => {
    writeFileSync(f.archive, "ab");
    const result = f.run();
    expect(result.code).toBe(1);
    expect(result.error).toContain("size does not match");
    expect(f.events().filter(event => event.boundary === "install")).toEqual([]);
  }));
  test("keeps the old launcher when downloading fails", () => withFixture(f => {
    const path = join(f.userBin, "solder"); writeFileSync(path, legacy, { mode: 0o755 });
    const result = f.run({ extraEnv: { SOLDER_TEST_DOWNLOAD_FAIL: "1" } });
    expect(result.code).toBe(1);
    expect(readFileSync(path, "utf8")).toBe(legacy);
    expect(f.events().filter(event => event.boundary === "install")).toEqual([]);
  }));
  test("keeps the old launcher when pacman fails", () => withFixture(f => {
    const path = join(f.userBin, "solder"); writeFileSync(path, legacy, { mode: 0o755 });
    expect(f.run({ extraEnv: { SOLDER_TEST_PACMAN_FAIL: "1" } }).code).toBe(1);
    expect(readFileSync(path, "utf8")).toBe(legacy);
    expect(readdirSync(f.userBin)).toEqual(["solder"]);
  }));
  test("requires pacman to report the requested installed version", () => withFixture(f => {
    const path = join(f.userBin, "solder"); writeFileSync(path, legacy, { mode: 0o755 });
    const result = f.run({ extraEnv: { SOLDER_TEST_INSTALLED_VERSION: "soldercad 1.2.2-1" } });
    expect(result.code).toBe(1);
    expect(result.error).toContain("requested installed Solder version");
    expect(readFileSync(path, "utf8")).toBe(legacy);
  }));
});

for (const scenario of [
  { name: "rejects a different release", change: (value: ReturnType<typeof metadata>) => { value.tag_name = "1.2.4"; }, requested: "1.2.3", message: "different release version" },
  { name: "rejects draft metadata", change: (value: ReturnType<typeof metadata>) => { value.draft = true; }, message: "invalid release metadata" },
  { name: "rejects duplicate package assets", change: (value: ReturnType<typeof metadata>) => { value.assets.push({ ...value.assets[0]! }); }, message: "exactly one" },
  { name: "rejects a credential-bearing download URL", change: (value: ReturnType<typeof metadata>) => { value.assets[0]!.browser_download_url = canonicalUrl + "?token=secret"; }, message: "unexpected download URL" },
  { name: "rejects a malformed digest", change: (value: ReturnType<typeof metadata>) => { value.assets[0]!.digest = "sha256:abc"; }, message: "valid SHA-256" },
]) {
  test(scenario.name, () => withFixture(f => {
    const value = metadata(); scenario.change(value); writeFileSync(f.release, JSON.stringify(value));
    const result = f.run({ version: scenario.requested });
    expect(result.code).toBe(1);
    expect(result.error).toContain(scenario.message);
    expect(f.events().filter(event => event.boundary === "install")).toEqual([]);
  }));
}

describe("legacy user launchers", () => {
  test("preserves and replaces a known old Bun launcher only after installation", () => withFixture(f => {
    const path = join(f.userBin, "solder"); writeFileSync(path, legacy, { mode: 0o755 });
    const result = f.run();
    expect(result.code).toBe(0);
    expect(readlinkSync(path)).toBe("/usr/bin/solder");
    const backup = readdirSync(f.userBin).find(name => name.startsWith(".solder-launcher-backup-"))!;
    expect(readFileSync(join(f.userBin, backup, "solder"), "utf8")).toBe(legacy);
  }));
  test("refuses an unknown user launcher before any network or install operation", () => withFixture(f => {
    const path = join(f.userBin, "solder"); const custom = '#!/bin/sh\necho custom\n'; writeFileSync(path, custom, { mode: 0o755 });
    const result = f.run();
    expect(result.code).toBe(1);
    expect(result.error).toContain("not a recognized old Solder launcher");
    expect(readFileSync(path, "utf8")).toBe(custom);
    expect(f.events()).toEqual([]);
  }));
  test("refuses a user symlink to an unknown executable without altering its target", () => withFixture(f => {
    const target = join(f.home, "custom"); writeFileSync(target, '#!/bin/sh\necho custom\n', { mode: 0o755 });
    const path = join(f.userBin, "solder"); symlinkSync(target, path);
    expect(f.run().code).toBe(1);
    expect(readlinkSync(path)).toBe(target);
    expect(readFileSync(target, "utf8")).toBe('#!/bin/sh\necho custom\n');
    expect(f.events()).toEqual([]);
  }));
  test("does not rewrite a local launcher that comes after the system directory", () => withFixture(f => {
    const path = join(f.userBin, "solder"); const custom = '#!/bin/sh\necho custom\n'; writeFileSync(path, custom, { mode: 0o755 });
    const result = f.run({ command: 'source "$1"; arch_install_release "$2" "$3" 1 "$4" "/usr/bin:$5"' });
    expect(result.code).toBe(0);
    expect(readFileSync(path, "utf8")).toBe(custom);
  }));
  test("does not alter existing links to the package launcher", () => withFixture(f => {
    const path = join(f.userBin, "solder"); symlinkSync("/usr/bin/solder", path);
    expect(f.run().code).toBe(0);
    expect(readlinkSync(path)).toBe("/usr/bin/solder");
    expect(readdirSync(f.userBin)).toEqual(["solder"]);
  }));
  test("keeps a legacy symlink target intact while replacing only the shadowing alias", () => withFixture(f => {
    const target = join(f.home, "old-solder"); writeFileSync(target, legacy, { mode: 0o755 });
    const path = join(f.userBin, "solder"); symlinkSync(target, path);
    expect(f.run().code).toBe(0);
    expect(readlinkSync(path)).toBe("/usr/bin/solder");
    expect(readFileSync(target, "utf8")).toBe(legacy);
    const backup = readdirSync(f.userBin).find(name => name.startsWith(".solder-launcher-backup-"))!;
    expect(readlinkSync(join(f.userBin, backup, "solder"))).toBe(target);
  }));
  test("does not treat a non-executable file as a shadowing command", () => withFixture(f => {
    const path = join(f.userBin, "solder"); writeFileSync(path, "notes", { mode: 0o600 });
    expect(f.run().code).toBe(0);
    expect(readFileSync(path, "utf8")).toBe("notes");
    expect(readdirSync(f.userBin)).toEqual(["solder"]);
  }));
  test("refuses replacing a launcher through a symlinked user bin directory", () => withFixture(f => {
    rmSync(f.userBin, { recursive: true });
    const redirected = join(f.home, "redirected"); mkdirSync(redirected);
    writeFileSync(join(redirected, "solder"), legacy, { mode: 0o755 }); symlinkSync(redirected, f.userBin);
    const result = f.run();
    expect(result.code).toBe(1);
    expect(result.error).toContain("symbolic-link directory");
    expect(readFileSync(join(redirected, "solder"), "utf8")).toBe(legacy);
    expect(f.events()).toEqual([]);
  }));
  test("refuses replacing launchers in a directory writable by other users", () => withFixture(f => {
    chmodSync(f.userBin, 0o777);
    writeFileSync(join(f.userBin, "solder"), legacy, { mode: 0o755 });
    const result = f.run();
    expect(result.code).toBe(1);
    expect(result.error).toContain("ownership and permissions");
    expect(f.events()).toEqual([]);
  }));
  test("refuses launcher changes after the initial plan", () => withFixture(f => {
    const path = join(f.userBin, "solder"); writeFileSync(path, legacy, { mode: 0o755 });
    const result = f.run({ command: 'source "$1"; arch_user_launchers plan "$4" "$5" "$4/plan.json"; printf "#!/bin/sh\\necho changed\\n" > "$4/.local/bin/solder"; arch_user_launchers apply "$4" "$5" "$4/plan.json"' });
    expect(result.code).toBe(1);
    expect(result.error).toContain("not a recognized old Solder launcher");
    expect(readFileSync(path, "utf8")).toBe('#!/bin/sh\necho changed\n');
    expect(lstatSync(path).isSymbolicLink()).toBe(false);
  }));
});
