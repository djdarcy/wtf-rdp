# Changelog

All notable changes to this project are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.2.0] - 2026-07-08
### Added
- Shared session module `lib/WtfRdp.Sessions.psm1`: WTS session enumeration, LSM Event 36 wedge detection, `Lock-WtfRdpSession` (locks a session from SYSTEM via `WTSQueryUserToken` + `CreateProcessAsUser`), and `Invoke-WtfRdpRescue` (`tscon` reconnect **+ lock**).
- `sessfix` tools: `install` (deploy the watchdog + module, download a checksum-verified NSSM, register + start the LocalSystem service), `recover` (manual one-shot reconnect + lock; self-elevates to SYSTEM), and `uninstall`.
### Changed
- Watchdog (v0.3) refactored onto the shared module — the rescue now reconnects **and locks** the session, so a recovered box is never left unlocked (closes the gap where `tscon`-to-console left an open desktop).
- `pyproject` package-data now bundles `lib/*.psm1`.

## [0.1.2] - 2026-07-08
### Changed
- Reworked the README into the DazzleCMD format; "How It Works" now explains the RDP-recovery strategy (failure / detection / recovery / where it runs) rather than aggregator plumbing; renamed the "Cross-Platform" section to "Platform" (Windows-only).
### Added
- `docs/extending.md` — how to add your own kits and tools (moved out of the README).
- Installs badge + GitHub traffic-tracker (ghtraf) dashboard, workflow, and gists.
### Removed
- `nssm.exe` is no longer bundled in the wheel (dropped from `package-data`). `rdp setup sessfix` will download a checksum-verified NSSM at install time, keeping the wheel pure-Python while NSSM stays a real, queryable Windows service.

## [0.1.1] - 2026-07-08
### Changed
- Re-added `.github/dependabot.yml` with the GitHub Actions bumps (`actions/checkout` v7, `actions/cache` v6) pre-applied — held out of the initial push so Dependabot wouldn't consume the reserved Roadmap / Quick Notes issue numbers.
- ROADMAP now links the live Roadmap issue (#1).

## [0.1.0] - 2026-07-08
### Added
- Initial `wtf-rdp` aggregator CLI (`rdp`) built on `dazzlecmd-lib`.
- `sessfix` kit with the `status` tool (watchdog service state + recent rescues + live session table).
- Bundled assets: the `SYSTEM` watchdog service script (`Watch-RdpSession.ps1`), the RDP auto-connect test clicker (`Invoke-RdpConnect.ps1`), and `nssm.exe` — shipped as package data toward a self-contained `pip install`.
- Design record migrated to `private/` (postmortem, dev-workflow-process design, session-rescue watchdog design note) from the validation work on 2026-07-07: the `SYSTEM` `tscon` rescue mechanism and the autonomous detect→confirm→rescue loop, verified on a live target.

[Unreleased]: https://github.com/djdarcy/wtf-rdp/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/djdarcy/wtf-rdp/compare/v0.1.2...v0.2.0
[0.1.2]: https://github.com/djdarcy/wtf-rdp/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/djdarcy/wtf-rdp/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/djdarcy/wtf-rdp/releases/tag/v0.1.0
