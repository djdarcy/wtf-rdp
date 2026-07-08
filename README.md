# wtf-rdp (`rdp`)

[![PyPI](https://img.shields.io/pypi/v/wtf-rdp?color=green)](https://pypi.org/project/wtf-rdp/)
[![Release Date](https://img.shields.io/github/release-date/djdarcy/wtf-rdp?color=green)](https://github.com/djdarcy/wtf-rdp/releases)
[![Python 3.10+](https://img.shields.io/badge/python-3.10+-blue.svg)](https://www.python.org/downloads/)
[![License: GPL v3](https://img.shields.io/badge/license-GPL%20v3-green.svg)](https://www.gnu.org/licenses/gpl-3.0.html)
[![Platform](https://img.shields.io/badge/platform-Windows%2010%20%7C%2011-lightgrey.svg)](#cross-platform)

> **Rescue the RDP session Windows would make you destroy.**

Windows RDP session-rescue tooling. A [wtf-windows](https://github.com/djdarcy/wtf-windows)-family CLI (`rdp`) built on the [DazzleCMD](https://github.com/DazzleTools/dazzlecmd) pattern that **detects and non-destructively recovers RDP sessions wedged or blocked by Local Session Manager (LSM)** -- the *"You're unable to sign in because you're already signed in to another session that is blocked"* failure that otherwise forces you to sign the session out and lose your work.

## Why wtf-rdp?

Have you ever RDP'd into a machine, had the connection drop ungracefully, and then found yourself **locked out of your own session** -- with Windows offering only to *sign out* (and destroy) the very session holding your unsaved work?

That's the Local Session Manager block. An ungraceful `mstsc` disconnect can flag your session **"blocked by Local Session Manager,"** after which Windows refuses *every* sign-in -- RDP **and** the physical console -- and the only button it gives you is the one that throws your work away. On client Windows (single interactive session), you can't even spin up a second session to fix it. The block counter climbs and never expires.

Enter `rdp`...

wtf-rdp installs a tiny **`SYSTEM` watchdog service** (hosted by NSSM as LocalSystem) that watches for the wedge signature -- a console session stuck connecting, corroborated by the LSM transition-failure event -- and **reconnects the stranded session via `tscon`** before Windows can garbage-collect it. Because it runs as `SYSTEM` it holds the `SeTcbPrivilege` that `tscon` needs, so recovery works with **no change to the machine's admin/token model**, and (with the lock-after-rescue step) leaves the box **locked, not open**.

> Validated on a live target 2026-07-07: a `SYSTEM` `tscon` reconnected a stranded session (logon time unchanged) *and* cleared the console wedge in one move; the watchdog service ran the full detect → confirm → rescue loop autonomously.

## Features

- **Non-destructive recovery**: reconnects the blocked session via `tscon` -- it never signs it out, so your running work survives
- **Autonomous watchdog**: a `SYSTEM` service detects the wedge and rescues it on its own, before Windows can destroy the session
- **No OS changes required**: runs as LocalSystem; no `LocalAccountTokenFilterPolicy`, no enabled built-in Administrator, no weakened token model
- **Event-driven detection**: keys on the real LSM wedge signature (not just "disconnected"), so it acts on genuine blocks and stays silent on normal idle disconnects
- **Self-contained**: the watchdog script and `nssm.exe` ship inside the wheel -- `pip install` and go, no git clone, no manual downloads
- **DazzleCMD aggregator**: `rdp <tool> [args]` works anywhere; tools grow as additional kits without changing the CLI

## Installation

```bash
pip install wtf-rdp
rdp setup sessfix        # bootstrap the LocalSystem watchdog service
```

**On externally-managed Python** (PEP 668), install into a virtual environment or use [pipx](https://pipx.pypa.io):

```bash
pipx install wtf-rdp
```

Or install from source:

```bash
git clone https://github.com/djdarcy/wtf-rdp.git
cd wtf-rdp
pip install -e .
```

## Usage

```bash
# List available tools
rdp list

# Watchdog service state, recent rescues, and the live session table
rdp status

# (planned) install / manage the watchdog and recover a wedged session
rdp setup sessfix         # register the LocalSystem watchdog service
rdp recover               # manual one-shot safe rescue (tscon + lock)
rdp logs                  # tail the watchdog log

# Detailed info about a tool
rdp info status

# Version
rdp --version
```

`rdp` is the short command; tools live in the root namespace (`rdp status`), with full FQCN addressing (`wtf-rdp:sessfix:status`) also available.

## Included Tools

wtf-rdp ships one always-active kit today, with more categories planned:

- **sessfix** (always active) -- session-fix tools for the LSM block: `status` *(shipping)*; `install`/`uninstall`, `recover`, `query`, `logs`, `config` *(planned)*
- **diagnose**, **keepalive** *(future kits)* -- attach as additional kits without changing the CLI

Run `rdp list` to see what's active on your machine.

## How It Works

1. **Discovery**: on startup, `rdp` scans `wtf_rdp/kits/*.kit.json` and the `wtf_rdp/tools/<kit>/<tool>/.wtf-rdp.json` manifests
2. **Dispatch**: each tool's `runtime.type` determines how it runs -- the `sessfix` tools are `shell`/`powershell`, so `rdp` invokes the bundled `.ps1` (each script is also runnable standalone)
3. **The watchdog** (`assets/Watch-RdpSession.ps1`, hosted by NSSM as `SYSTEM`): polls session state, and when it sees a console stuck connecting **corroborated by an LSM transition-failure event**, waits a confirm window and then `tscon`s the stranded user session back -- non-destructively -- before Windows garbage-collects it

New runtime types can be registered by kits (the dispatch is a pluggable factory), and future tools that need to go under the hood can ship as native `binary` runtimes.

## Tool Manifests

Each tool has a `.wtf-rdp.json` manifest. Only `name` and `description` are required; the rest describe how the tool is dispatched:

```json
{
    "name": "status",
    "description": "Show the watchdog service state, recent rescues, and the live session table.",
    "category": "sessfix",
    "runtime": {
        "type": "shell",
        "shell": "powershell",
        "shell_args": ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File"],
        "script_path": "status.ps1"
    }
}
```

## Project Structure

wtf-rdp is a thin aggregator over the [dazzlecmd-lib](https://github.com/DazzleLib/dazzlecmd-lib) engine (discovery, dispatch, kit/state machinery), installed as a dependency.

```
wtf-rdp/
├── wtf_rdp/                     # the `rdp` CLI package
│   ├── cli.py                   # AggregatorEngine entry point (command = rdp)
│   ├── _version.py
│   ├── lib/                     # shared helpers (Python-first; a shared PS module lands as tools grow)
│   ├── kits/
│   │   └── sessfix.kit.json     # the sessfix tool list
│   ├── tools/sessfix/           # per-tool manifests + scripts
│   │   └── status/              # .wtf-rdp.json + status.ps1
│   └── assets/                  # bundled: Watch-RdpSession.ps1, Invoke-RdpConnect.ps1, nssm.exe
├── docs/                        # platform support + guides
├── tests/
└── scripts/                     # repokit-common: version management + git hooks
```

## Cross-Platform

| Platform | Status |
|----------|--------|
| Windows 11 (24H2 / 26200) | Tested -- watchdog rescue validated |
| Windows 10 | Expected (same session / WTS / `tscon` / LSM surfaces) |
| Windows Server + RDS | Expected (multi-session; the client single-session limit does not apply) |

The runtime tooling is Windows-only; the `rdp` CLI installs cross-platform but its `sessfix` tools no-op / warn off-Windows. See [Platform Support](docs/platform-support.md).

## Documentation

- **[Roadmap](ROADMAP.md)** -- phased plan and status
- **[Platform Support](docs/platform-support.md)** -- OS compatibility matrix
- **[Changelog](CHANGELOG.md)** -- release history

## Related Projects

- [dazzlecmd](https://github.com/DazzleTools/dazzlecmd) -- "A tool for tools": the aggregator pattern wtf-rdp is built on
- [dazzlecmd-lib](https://github.com/DazzleLib/dazzlecmd-lib) -- the engine (discovery, dispatch, kit/aggregator/state machinery) that `rdp` runs on
- [wtf-windows](https://github.com/djdarcy/wtf-windows) -- "Many diagnostics, one command": the Windows-diagnostics CLI family wtf-rdp belongs to
- [git-repokit](https://github.com/DazzleTools/git-repokit) -- the standardized repository scaffolding this project was created with

## Contributing

Contributions are welcome! Please read our [Contributing Guide](CONTRIBUTING.md) for details.

Like the project?

[!["Buy Me A Coffee"](https://www.buymeacoffee.com/assets/img/custom_images/orange_img.png)](https://www.buymeacoffee.com/djdarcy)

## License

Copyright (C) 2026 Dustin Darcy

This project is licensed under the GNU General Public License v3.0 -- see the [LICENSE](LICENSE) file for details.
