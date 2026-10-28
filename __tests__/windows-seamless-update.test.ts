import { expect, test } from "bun:test";
import { join } from "node:path";

// The contract depends on real Windows process identities, window messages,
// named pipes, shell shortcuts, and filesystem operations.
if (process.platform === "win32") {
  test("safely closes cooperative sessions, restores saved windows and detects damaged launches", () => {
    const result = Bun.spawnSync([
      "powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
      "-File", join(import.meta.dir, "windows-seamless-update.ps1"),
      "-Installer", join(import.meta.dir, "..", "install.ps1"),
    ], { stdout: "pipe", stderr: "pipe" });
    expect({ code: result.exitCode, stderr: result.stderr.toString(), stdout: result.stdout.toString() })
      .toEqual({ code: 0, stderr: "", stdout: "PASS seamless-update\r\n" });
  }, 180_000);
}
