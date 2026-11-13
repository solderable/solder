# Solder

## Install on macOS

```bash
curl -fsSL https://raw.githubusercontent.com/solderable/solder/main/install.sh | bash
```

Open `~/Applications/SolderCAD.app`, or run `solder` for terminal chat.

## Install on Windows

```powershell
Invoke-WebRequest -Uri https://raw.githubusercontent.com/solderable/solder/main/install.ps1 -OutFile install.ps1
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

Open **SolderCAD** from your desktop, or run `solder` for terminal chat.

## Install on Arch Linux (x86_64)

Requires `curl`, `python`, and `sudo`.

```bash
curl -fsSL https://raw.githubusercontent.com/solderable/solder/main/install-arch.sh | bash
```

Run `soldercad` or `solder` as your normal user.

[Installation options and troubleshooting](docs/usage.md#install)
