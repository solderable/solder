# Solder

Solder helps you design electronics through chat. Use the terminal client or
SolderCAD, the KiCad-based desktop app, to create schematics, source components,
review a design, and edit or route a PCB.

The installers in this repository install **Solder CLI and SolderCAD together**.
Release packages are built from Solderable's core engine and native editor
repositories.

## Current release: 1.38.0

[Release notes](https://github.com/solderable/solder/releases/tag/1.38.0) ·
[macOS Apple silicon](https://github.com/solderable/solder/releases/download/1.38.0/solder-1.38.0-macos-arm64.zip) ·
[Windows x64](https://github.com/solderable/solder/releases/download/1.38.0/solder-1.38.0-windows-x64.zip) ·
[Arch Linux x86_64](https://github.com/solderable/solder/releases/download/1.38.0/soldercad-1.38.0-1-x86_64.pkg.tar.zst)

On macOS, this release adds browser sign-in and assigned projects in SolderCAD,
project submissions to dedicated work branches, and a centered control for
switching between schematic and PCB editors. It also includes cleaner chat
labels and the Arch Linux package alongside the macOS and Windows downloads.

| Platform | Package |
| --- | --- |
| macOS on Apple silicon | `macos-arm64` |
| Windows x64 | `windows-x64`; also runs under x64 emulation on Windows 11 ARM64 |
| Arch Linux x86_64 | `soldercad-1.38.0-1-x86_64.pkg.tar.zst`; install with `pacman -U` |

The 1.38.0 macOS binaries are Developer ID signed but not Apple-notarized. Windows
executables are unsigned and may show an unknown-publisher or SmartScreen prompt.
See the release notes for build provenance and any release-specific notices.

## Install

The macOS and Windows installers use the download source in the release metadata:
UploadThing when a CDN URL is present, or GitHub otherwise. Version 1.38.0 uses
GitHub downloads. Before installing, both installers verify the ZIP's byte size
and SHA-256 against the GitHub release asset.

A failed CDN download or invalid CDN metadata stops installation. To select
GitHub explicitly, pass `--download-source github` on macOS or
`-DownloadSource GitHub` on Windows.

### macOS

Install the latest release:

```bash
curl -fsSL https://raw.githubusercontent.com/solderable/solder/main/install.sh | bash
```

Install 1.38.0 specifically:

```bash
curl -fsSL https://raw.githubusercontent.com/solderable/solder/main/install.sh | bash -s -- --version 1.38.0
```

The installer selects `solder-<version>-macos-<arch>.zip`, installs the CLI to
`~/.local/bin/solder`, and installs SolderCAD to `~/Applications/SolderCAD.app`.
Release 1.38.0 provides an Apple silicon package.

### Windows

From `cmd.exe`:

```cmd
powershell -ExecutionPolicy Bypass -Command "Invoke-WebRequest -Uri https://raw.githubusercontent.com/solderable/solder/main/install.ps1 -OutFile install.ps1"
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

From Windows PowerShell 5.1 or PowerShell 7:

```powershell
Invoke-WebRequest -Uri https://raw.githubusercontent.com/solderable/solder/main/install.ps1 -OutFile install.ps1
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

Install 1.38.0 specifically:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Version 1.38.0
```

The installer downloads `solder-<version>-windows-x64.zip` and installs:

- Solder CLI to `$env:LOCALAPPDATA\Solder\bin\solder.exe`.
- SolderCAD to `$env:LOCALAPPDATA\Solder\SolderCAD`.
- **SolderCAD** and **SolderCAD Repair** desktop shortcuts.

It adds the installed `bin` directory to the user `PATH`, sets `KICAD_APP_PATH`,
`KICAD_CLI_PATH`, and `KICAD_DISABLE_LIBRARY_PRELOAD`, and clears any previous
`KICAD_SOFTWARE_RENDERING` override. The SolderCAD shortcut checks essential files
and offers repair when they are damaged or missing. The **SolderCAD Repair**
shortcut remains available; the old **Repair Solder** action inside native chat
error panels was removed in 1.37.1.

An interactive update downloads and verifies both components while SolderCAD
remains open. It then asks open windows to close normally, leaving their usual
Save and Cancel dialogs in control, and reopens saved documents after
installation. Recent Solder terminal sessions can close cooperatively. Save and
close older windows or sessions yourself if they cannot confirm that work is
preserved. The installer does not forcibly close them.

If installation is interrupted, run the installer again to recover the previous
installation. Noninteractive installations require existing windows and terminal
sessions to be closed before starting. Latest-release installation refuses to
replace a known newer component; an explicit `-Version` deliberately selects
that version, including an older one.

To repair a custom installation without changing the current user's environment
variables or desktop shortcuts:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -InstallDir 'C:\path\to\Solder' -NoUserIntegration
```

Add `-ManageLauncher` to migrate existing shortcuts belonging to that same
installation to the repairable launcher. It does not create or replace shortcuts
belonging to another installation.

### Arch Linux (x86_64)

Download the [pacman package](https://github.com/solderable/solder/releases/download/1.38.0/soldercad-1.38.0-1-x86_64.pkg.tar.zst)
and its [SHA-256 file](https://github.com/solderable/solder/releases/download/1.38.0/soldercad-1.38.0-1-x86_64.pkg.tar.zst.sha256)
into the same directory, then verify and install them:

```bash
sha256sum -c soldercad-1.38.0-1-x86_64.pkg.tar.zst.sha256
sudo pacman -U soldercad-1.38.0-1-x86_64.pkg.tar.zst
```

The package installs the CLI and SolderCAD under `/opt/soldercad`. Run `solder`
for terminal chat or `soldercad` for the desktop app. Arch packages are upgraded
with `pacman -U`; the CLI's self updater does not yet support Linux.

### Check before installing

Both installers support a dry run that resolves the release and shows the
download source, URL, byte size, and SHA-256 without downloading or installing:

```bash
curl -fsSL https://raw.githubusercontent.com/solderable/solder/main/install.sh | bash -s -- --dry-run
```

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -DryRun
```

The older `install-solder-release.sh` is a separate GitHub/custom-URL installer.
Use `install.sh` or `install.ps1` above for CDN downloads and checksum verification.

## Start a project

```bash
mkdir my-board
cd my-board
solder
```

Run `/auth` in chat to sign in through your browser with Google or your email and
a sign-in code. The installed client uses a browser-approved device credential;
you do not need to paste a manually issued API key.

Describe what you want to build:

```text
Build a 3.3 V ESP32 sensor board with USB-C power, a battery charger, and an I2C temperature sensor.
```

Solder initializes the project in the current directory. You can also run
`solder init` to initialize a project without opening chat.

Solder keeps circuit intent in `.sheet` files under `workfiles/`, with generated
KiCad schematics and PCB files in the project directory. A typical project
includes:

```text
workfiles/
  main.sheet
  circuit.net
  schematic.sync
  libs/
circuit.kicad_sch
circuit.kicad_pro
circuit.kicad_pcb
.solder/
  project.json
```

Chat connects to Solderable's backend; the client performs project file
operations and launches the local KiCad tools. The default connection is
`wss://auth.solderable.dev/remote-tui`. Saved projects and generated artifacts
remain in your project directory.

## Work in SolderCAD or the terminal

Open SolderCAD from Applications on macOS or its desktop shortcut on Windows.
Use the schematic editor's **Solder Chat** toolbar button, or the PCB editor's
**PCB Chat** button, to open chat. Both editors start with chat closed.

Ask for circuit changes, component research, or a design review. `/mode ask`
inspects and answers without editing; `/mode build` allows edits. Saved schematic
changes can be reconciled back into the circuit source with `/sync`.

In a Ghostty terminal with at least 110 columns and 18 rows, press **F4** or click
**Schematic** to view saved schematics beside chat. Choose sheets, pan, zoom, or
drag the divider to resize the panes. The view refreshes after saves and does not
edit the drawing. The image view requires Kitty graphics support and is not
enabled inside tmux or screen.

### PCB placement, routing, and production files

Open a PCB in SolderCAD and use **PCB Chat**, or start from a terminal:

```bash
solder pcb --board circuit.kicad_pcb
```

In Build mode, ask to place parts, route the board, or export production files.
Release packages include the KiCadRoutingTools runtime, native router, and
Python dependencies; no separate routing installation is required.

Production export writes a Gerber/drill ZIP, BOM, placements, designator counts,
and IPC netlist to the board's sibling `production/` directory. In an attached
editor, it includes current unsaved board changes without changing the board.
Use the agent's `run_drc` tool to check the current board and review the results
before fabrication.

## Useful commands

| Command | Action |
| --- | --- |
| `solder --help` | Show current CLI options and chat commands. |
| `solder --version` | Print the installed CLI version. |
| `solder update` | Update Solder CLI and SolderCAD to the latest stable release. |
| `solder --resume <id>` | Resume a session from the same project directory. |
| `/auth` | Sign in through the browser or view account access. |
| `/compile` | Compile the circuit source and generate its schematic. |
| `/schematic` | Arrange and wire the schematic. |
| `/schematic quality` | Choose a schematic quality level from 1 to 6. |
| `/schematic regen [file.sheet]` | Run placement and routing again, optionally for one source sheet. |
| `/schematic reroute` | Reroute the existing schematic. |
| `/sync` | Reconcile saved schematic edits with circuit source. |
| `/update-pcb preview` | Preview schematic-to-PCB changes. |
| `/update-pcb apply` | Apply schematic-to-PCB changes. |
| `/mode ask` / `/mode build` | Select read-only assistance or editing. |
| `/model` | Choose an available model. |
| `/cancel` | Cancel the current run. |
| `/exit` | Exit chat. |

For one-shot use, `solder --once` reads a prompt from standard input and exits
after the run. Add `--plain` for the final answer or `--jsonl` for structured
events. `--once` implies `--no-ask`; exit code 3 means further interaction is
required.

## Installer checks

The installer contract suite checks release selection, archive integrity,
Windows installation transactions, and recovery:

```bash
bun test --timeout 30000 __tests__/installers.test.ts __tests__/windows-install-transaction.test.ts __tests__/windows-seamless-update.test.ts
```

CI exercises Windows PowerShell 5.1 and PowerShell 7.6.9. The fixtures replace
network responses and do not install Solder or SolderCAD. Public release and
hosted-installer smoke tests provide separate evidence for downloadable builds.
