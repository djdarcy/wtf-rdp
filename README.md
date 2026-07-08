# wtf-rdp (`rdp`)

[![PyPI](https://img.shields.io/pypi/v/wtf-rdp?color=green)](https://pypi.org/project/wtf-rdp/)
[![Release Date](https://img.shields.io/github/release-date/djdarcy/wtf-rdp?color=green)](https://github.com/djdarcy/wtf-rdp/releases)
[![Python 3.10+](https://img.shields.io/badge/python-3.10+-blue.svg)](https://www.python.org/downloads/)
[![License: GPL v3](https://img.shields.io/badge/license-GPL%20v3-green.svg)](https://www.gnu.org/licenses/gpl-3.0.html)
[![Installs](https://img.shields.io/endpoint?url=https://gist.githubusercontent.com/djdarcy/ecab69d64a306da6fe53251fd1dc286f/raw/installs.json)](https://djdarcy.github.io/wtf-rdp/stats/#installs)
[![Platform](https://img.shields.io/badge/platform-Windows%2010%20%7C%2011-lightgrey.svg)](#platform)

> **Rescue the RDP session Windows would make you destroy.**

Windows RDP session-rescue tooling. A [wtf-windows](https://github.com/djdarcy/wtf-windows)-family CLI (`rdp`) built on the [DazzleCMD](https://github.com/DazzleTools/dazzlecmd) pattern that detects and non-destructively recovers RDP sessions wedged or blocked by Local Session Manager (LSM). `wtf-rdp` handles the *"You're unable to sign in because you're already signed in to another session that is blocked"* failure that otherwise forces you to sign the session out and lose your work.

## Why wtf-rdp?

Have you ever RDP'd into a machine, had the connection drop ungracefully, and then found yourself locked out of your own session with Windows offering only to sign-out (and destroy) the very session holding your unsaved work?

That's the Local Session Manager block. An ungraceful `mstsc` disconnect can flag your session "blocked by Local Session Manager" after which Windows refuses *every* sign-in (RDP and the physical console) and the only button it gives you is the one that throws your work away. On client Windows (single interactive session), you can't even spin up a second session to fix it. The block counter climbs and never expires.

Enter `wtf-rdp`...

wtf-rdp installs a tiny `SYSTEM` watchdog service (hosted by NSSM as LocalSystem) that watches for the wedge signature (a console session stuck connecting, corroborated by the LSM transition-failure event) and reconnects the stranded session via `tscon` before Windows can garbage-collect it. Because it runs as `SYSTEM` it holds the `SeTcbPrivilege` that `tscon` needs, so recovery works with no change to the machine's admin/token model, and (with the lock-after-rescue step) leaves the box locked, not open.

## Features

- **Non-destructive recovery**: reconnects the blocked session via `tscon` -- it never signs it out, so your running work survives
- **Autonomous watchdog**: a `SYSTEM` service detects the wedge and rescues it on its own, before Windows can destroy the session
- **No OS changes required**: runs as LocalSystem; no `LocalAccountTokenFilterPolicy`, no enabled built-in Administrator, no weakened token model
- **Event-driven detection**: keys on the real LSM wedge signature (not just "disconnected"), so it acts on genuine blocks and stays silent on normal idle disconnects
- **Real Windows service**: NSSM hosts the watchdog as a `LocalSystem` service you can query and control with standard tooling (`Get-Service`, `services.msc`); `rdp setup sessfix` fetches a checksum-verified NSSM, so the PyPi wheel stays pure Python (no bundled binaries)
- **DazzleCMD aggregator**: `rdp <tool> [args]` works anywhere; tools grow as additional kits without changing the CLI

## Installation

```bash
pip install wtf-rdp
rdp install              # deploy + start the LocalSystem watchdog service
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

# install / manage the watchdog and recover a wedged session
rdp install               # deploy + start the LocalSystem watchdog service
rdp recover               # manual one-shot safe rescue (tscon + lock)
rdp uninstall             # stop + remove the service

# Detailed info about a tool
rdp info status

# Version
rdp --version
```

`rdp` is the short command; tools live in the root namespace (`rdp status`), with full FQCN addressing (`wtf-rdp:sessfix:status`) also available.

## Included Tools

wtf-rdp ships one always-active kit today, with more categories planned:

- **sessfix** (always active) -- session-fix tools for the LSM block: `status`, `install`, `recover`, `uninstall` *(shipping)*; `query`, `logs`, `config` *(planned)*
- **diagnose**, **keepalive** *(future kits)* -- attach as additional kits without changing the CLI

Run `rdp list` to see what's active on your machine.

## How It Works

wtf-rdp targets one specific Windows failure and recovers from it *without destroying your session*.

**The failure.** When an RDP connection drops ungracefully, Windows can leave the session in a corrupted state that we call a "wedge" and Local Session Manager flags it "blocked." From then on every sign-in (RDP *and* the physical console) is refused, and the only recovery Windows offers is to sign the session out, which kills everything running in it. The block never times out on its own, and on client Windows (single interactive session) you can't even open a second session to fix it.

**Detection.** A wedge looks, to a naive check, exactly like a healthy machine sitting at its login screen -- so wtf-rdp does *not* act on "a session is disconnected." It watches for a wedge signature: a console session stuck in the connecting state, corroborated by the Local Session Manager transition-failure event a dirty disconnect emits. It then waits a short confirm window; transitions that resolve on their own are ignored, so a normal idle disconnect never triggers a rescue.

**Recovery.** Once a wedge is confirmed, wtf-rdp reconnects the stranded session with **`tscon`**. wtf-rdp *reconnects*, never signs out, so every process in the session keeps running. The rescue runs as **`SYSTEM`** because reconnecting another user's session needs `SeTcbPrivilege`, which only `SYSTEM` holds. This is why nothing about the machine's admin accounts or token policy has to change. Immediately after reconnecting, the session is left locked (not an open desktop), so a recovered box is never left exposed.

**Where it runs.** The rescue logic is a small PowerShell watchdog (`Watch-RdpSession.ps1`) hosted by NSSM as a LocalSystem service, so it keeps watching across reboots and can act even when nobody is logged in. `rdp install` installs it; `rdp status` / `rdp recover` drive it.

Want to add your own RDP tools or a new kit? See **[Extending wtf-rdp](docs/extending.md)**.

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
│   └── assets/                  # bundled scripts: Watch-RdpSession.ps1, Invoke-RdpConnect.ps1
├── docs/                        # platform support + guides
├── tests/
└── scripts/                     # repokit-common: version management + git hooks
```

## Platform

**Windows only.** wtf-rdp targets a Windows RDP / Local Session Manager failure, so the runtime tooling (watchdog, `tscon`, `qwinsta`) runs only on Windows.

| Platform | Status |
|----------|--------|
| Windows 11 (24H2 / 26200) | Tested -- watchdog rescue validated |
| Windows 10 | Expected (same session / WTS / `tscon` / LSM surfaces) |
| Windows Server + RDS | Expected (multi-session; the client single-session limit does not apply) |

The `rdp` CLI is Python and will install elsewhere, but its `sessfix` tools no-op / warn off-Windows. See [Platform Support](docs/platform-support.md).

## Documentation

- **[Extending wtf-rdp](docs/extending.md)** -- add your own tools or a new kit
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
