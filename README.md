# Solder CLI

Solder is the Solderable command-line app for building electronics projects with an AI agent. The `solder` binary opens a terminal chat session, connects to the Solderable backend, and lets the agent help create or modify a local KiCad/SKiDL project from your design decisions.

The release assets in this repository are built from Solderable's private core engine repository.

Use Solder when you want to:

- describe a circuit you want to build
- search for sourceable components
- pick parts by constraints such as package, voltage, stock, and LCSC code
- compile SKiDL into a KiCad netlist
- generate or reroute a KiCad schematic
- review datasheets and component details
- iterate on a project through chat instead of editing every file by hand

## Install

macOS:

```bash
curl -fsSL https://raw.githubusercontent.com/solderable/solder/main/install.sh | bash
```

Install a specific release:

```bash
curl -fsSL https://raw.githubusercontent.com/solderable/solder/main/install.sh | bash -s -- --version 0.1.13
```

The macOS installer downloads the matching `solder-<version>-macos-<arch>.zip` release asset, installs the CLI to `~/.local/bin/solder`, and installs `SolderCAD.app` beside the CLI and into `~/Applications/SolderCAD.app` when possible.

Windows from `cmd.exe`:

```cmd
powershell -ExecutionPolicy Bypass -Command "Invoke-WebRequest -Uri https://raw.githubusercontent.com/solderable/solder/main/install.ps1 -OutFile install.ps1"
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

Windows from PowerShell:

```powershell
Invoke-WebRequest -Uri https://raw.githubusercontent.com/solderable/solder/main/install.ps1 -OutFile install.ps1
.\install.ps1
```

Install a specific release:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Version 0.1.13
```

The Windows installer downloads `solder-<version>-windows-x64.zip`, installs to `$env:LOCALAPPDATA\Solder`, adds the installed `bin` directory to the user `PATH` if needed, and sets user `KICAD_APP_PATH`, `KICAD_CLI_PATH`, and `KICAD_SOFTWARE_RENDERING` variables for the bundled SolderCAD tools.

Both installers support dry-run mode:

```bash
curl -fsSL https://raw.githubusercontent.com/solderable/solder/main/install.sh | bash -s -- --dry-run
```

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -DryRun
```

## Quick Start

```bash
solder
```

On first run, Solder asks for a Solderable API key:

```text
Solderable API key>
```

After the key is saved, the CLI opens an interactive chat prompt:

```text
you>
```

From there, describe what you want:

```text
Build a 3.3 V ESP32 sensor board with USB-C power, a battery charger, and an I2C temperature sensor.
```

Solder keeps the local project tied to the current directory. If the directory is empty or missing project scaffolding, the CLI initializes the files needed for a Solderable KiCad project.

## What The Binary Does

The packaged `solder` binary is a remote chat client. It does not run the full schematic agent locally. Instead, it:

1. starts a terminal UI
2. authenticates with your Solderable API key
3. connects to the Solderable websocket service
4. creates or reuses a local project identity in `.solder/project.json`
5. sends your chat messages and attachments to the remote agent
6. lets the remote agent request local project reads, writes, shell commands, and patches
7. saves generated artifacts, such as schematics or images, back into your project directory

The default server is:

```text
wss://sch.up.railway.app/remote-tui
```

The default command is just:

```bash
solder
```

## Options

```bash
solder [options]
```

| Option | Description |
| --- | --- |
| `--url <url>` | Connect to a different Solderable websocket server. `http` and `https` URLs are accepted and converted to websocket URLs by the transport. |
| `--resume <id>` | Resume a previous chat session. The CLI prints a resume command when you exit after connecting. |
| `--version`, `-v` | Print the installed `solder` version. |
| `--help`, `-h` | Print CLI help. |

Examples:

```bash
solder --version
solder --resume session-abc123
solder --url http://localhost:4310
```

## Local Project Files

When Solder starts, it prepares the current directory as a project workspace. A typical project contains:

```text
circuit.py
__init__.py
circuit.net
circuit.kicad_sch
circuit.kicad_pro
circuit.kicad_pcb
sym-lib-table
fp-lib-table
libs/
  Library.kicad_sym
  Library.pretty/
.solder/
  project.json
```

`.solder/project.json` maps each remote server URL to a stable project ID. That lets the hosted agent know that future sessions in the same folder refer to the same local project.

By default, Solder excludes client state and large/unrelated folders from remote file reads:

```text
.git/**
.solder/**
agent-runs/**
node_modules/**
.claude/**
```

## Chat Workflow

You can ask Solder for design help in normal language:

```text
Find a sourceable USB-C connector suitable for hand assembly.
```

```text
Add a buck regulator that can take 12 V input and output 3.3 V at 1 A.
```

```text
Generate the schematic and explain any parts I still need to choose.
```

The remote agent can use local tools through the client. When needed, it can:

- read selected project files
- write generated project files
- apply patches inside the project directory
- run shell commands in the project directory
- return file artifacts such as `circuit.kicad_sch`, `circuit.net`, or preview images

All file operations are constrained to the active project directory.

## Slash Commands

The chat prompt supports slash commands for common workflows:

| Command | Description |
| --- | --- |
| `/compile` | Compile a SKiDL file to a netlist. Defaults to `circuit.py`. |
| `/schematic` | Generate or reroute the project schematic. |
| `/schematic single-group` | Generate `circuit.kicad_sch` as one layout group. |
| `/schematic fresh-layout` | Force a fresh layout pass from `circuit.net`. |
| `/schematic regenerate` | Regenerate `circuit.kicad_sch` from `circuit.net`. |
| `/schematic reroute` | Reroute the existing `circuit.kicad_sch`. |
| `/mode build` | Allow the agent to build and edit the project. |
| `/mode ask` | Ask questions without editing the project. |
| `/style engineer` | Use precise engineering guidance. |
| `/style concise` | Keep responses brief and direct. |
| `/style noob` | Explain concepts for a beginner. |
| `/model gpt-5.5` | Use GPT-5.5 fast mode with xhigh reasoning. |
| `/model opus-4.8` | Use Opus 4.8 with high reasoning. |
| `/datasheet status [C12345]` | Show datasheet and expert-cache status. |
| `/datasheet populate` | Populate missing datasheet and expert caches. |
| `/datasheet refresh C12345` | Force-refresh component expert data for a part. |
| `/cancel` | Cancel the current run. |
| `/exit` | Exit the chat session. |

## Resuming A Session

When you exit after connecting, Solder prints a command like:

```bash
solder --resume session-abc123
```

Run that command from the same project directory to continue the conversation.

If you connected to a custom server, the resume command includes `--url`:

```bash
solder --url http://localhost:4310 --resume session-abc123
```

## Attachments

The terminal UI can forward image and PDF attachments to the remote agent. Attachments are sent as websocket-safe payloads with filename, media type, and byte size metadata.

Use attachments when asking Solder to interpret:

- a datasheet excerpt
- a pinout image
- a reference schematic
- a board or wiring photo
- a screenshot of an error

## Generated Artifacts

When the remote agent returns files, Solder saves them locally and prints the path. By default, artifacts are written into the active project directory.

Common generated files include:

```text
circuit.py
circuit.net
circuit.kicad_sch
circuit.png
```

## Common Workflows

Create a new project:

```bash
mkdir my-board
cd my-board
solder
```

Then say:

```text
Create a low-power BLE environmental sensor with USB-C charging and a single-cell LiPo.
```

Search for a component:

```text
Find a sourceable 3.3 V regulator for 500 mA output in a small hand-solderable package.
```

Generate a schematic:

```text
Use the selected parts and generate the schematic.
```

Or use the slash command:

```text
/schematic
```

Compile the SKiDL project:

```text
/compile
```

Reroute an existing schematic:

```text
/schematic reroute
```

Ask without editing:

```text
/mode ask
Review this design and tell me what is risky before changing anything.
```
