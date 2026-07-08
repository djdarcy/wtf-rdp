# Changelog

All notable changes to this project are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.3.0] - 2026-07-08
### Added
- `sessfix` tools `query` (read-only session diagnostic — enumerates sessions and flags stranded / wedge candidates, with `-Json`), `logs` (view the watchdog log: `-Tail` / `-Follow` / `-Full`, or `-Service` for the NSSM stdout/stderr), and `config` (show or change the watchdog's poll interval / confirm window / target user; setting restarts the service).
- Every tool now accepts `-h`, `-help`, and `--help` (via an `Alias('h')` switch + a `ValueFromRemainingArguments` catch-all), so `rdp <tool> -h` prints usage instead of erroring.
- `rdp -h` now lists all registered tools plus a getting-started section (custom epilog over `build_list_entries`).
- CLI surface tests (`tests/test_cli.py`): kit registration, per-tool manifest/runtime integrity, `-h` handling, and epilog contents.
### Changed
- `install` now pins the official `nssm-2.24.zip` SHA256 by default, so downloads are checksum-verified out of the box (override or clear via `-NssmSha256`).
### Fixed
- `config` read the service's `AppParameters` as mojibake (NSSM emits UTF-16LE; the OEM console codepage interleaved NUL bytes), so every value parsed as "(default)"; it now strips the NULs and reads correctly.
- `config` set now restarts the service via the SCM (`Restart-Service`) instead of `nssm restart`, avoiding a transient `SERVICE_PAUSED` error.
- `status` referenced the pre-rename service (`RdpWatchdog`) and log path; it now uses `wtf-rdp-sessfix` and `C:\ProgramData\wtf-rdp\watchdog.log`.
- `install` is now idempotent — a reinstall/reconfigure over a running service stops and removes the old service **before** copying `nssm.exe`, instead of crashing on the in-use file lock.
- `/?` now prints help on every tool (each uses `PositionalBinding=$false`, so a bare `/?` reaches the help catch-all instead of binding to the first parameter).
- Anticipated errors (not elevated, "run install first", missing module / `nssm.exe`, NSSM download or checksum failure) now print a one-line message and exit non-zero, instead of dumping a PowerShell stack trace.

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

[Unreleased]: https://github.com/djdarcy/wtf-rdp/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/djdarcy/wtf-rdp/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/djdarcy/wtf-rdp/compare/v0.1.2...v0.2.0
[0.1.2]: https://github.com/djdarcy/wtf-rdp/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/djdarcy/wtf-rdp/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/djdarcy/wtf-rdp/releases/tag/v0.1.0
