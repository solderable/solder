import { expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

// Windows kernel file IDs, rename sharing, junctions, and processes are the
// contract here. Run against the real filesystem rather than a simulated one.
if (process.platform === "win32") {
  const scenarios: Record<string, string> = {
    "only one installer owns the shared lease": "lease",
    "extracts archive entries beyond the Windows path limit": "long-archive-path",
    "rejects traversal, reserved names, and duplicate ZIP paths before extraction": "unsafe-archive",
    "validates and extracts the same ZIP name when a Unicode extra field differs": "unicode-extra-field",
    "preserves the installed pair when the staged CLI reports a different version": "version-mismatch",
    "recovers after an executed staged CLI and locked old CLI interrupt publication": "locked-publish",
    "restores the old pair when a locked CLI stops publication": "locked-cli-rollback",
    "recovers an interrupted publication and preserves the partial payload": "interrupted-publication",
    "refuses to replace an unrelated path during recovery": "foreign-target",
    "keeps both new components after a committed publication": "completed-publication",
    "keeps recovery records intact if cleanup encounters a locked file": "locked-cleanup",
    "rejects a binary directory junction": "linked-bin",
    "refuses an open target without terminating it": "running-app",
    "waits for updates from other CLIs but allows unrelated sessions": "external-update",
  };
  for (const [name, scenario] of Object.entries(scenarios)) {
    test(name, () => {
      const result = Bun.spawnSync([
        "powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
        "-File", join(import.meta.dir, "windows-install-transaction.ps1"),
        "-Installer", join(import.meta.dir, "..", "install.ps1"), "-Scenario", scenario,
      ], { stdout: "pipe", stderr: "pipe" });
      expect({ code: result.exitCode, stderr: result.stderr.toString() }).toEqual({ code: 0, stderr: "" });
    }, 60_000);
  }

  test("application update lease matches the shared v2 contract through a Unicode junction", () => {
    const scratch = mkdtempSync(join(tmpdir(), "solder-lease-contract-"));
    try {
      const physical = join(scratch, "Dotted-İ-Greek-Σ-Cherokee-Ꭰ");
      const alias = join(scratch, "alias");
      mkdirSync(physical);
      symlinkSync(physical, alias, "junction");
      const resource = join(realpathSync.native(physical), ".SolderCAD.update-lock")
        .replace(/[A-Z]/g, letter => letter.toLowerCase());
      const hash = createHash("sha256").update(`solder-process-lease-v2\0${resource}`).digest();
      const expectedPort = 16_384 + hash.readUInt32BE(0) % 32_768;
      const result = Bun.spawnSync([
        "powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
        "-File", join(import.meta.dir, "windows-install-transaction.ps1"),
        "-Installer", join(import.meta.dir, "..", "install.ps1"),
        "-Scenario", "lease-v2-port", "-LeaseRoot", alias,
      ], { stdout: "pipe", stderr: "pipe" });
      expect({ code: result.exitCode, stderr: result.stderr.toString() }).toEqual({ code: 0, stderr: "" });
      const ports = /PORTS=([\d,]+)/.exec(result.stdout.toString())?.[1]?.split(",").map(Number);
      expect(ports).toContain(expectedPort);
    } finally { rmSync(scratch, { recursive: true, force: true }); }
  }, 60_000);
}
