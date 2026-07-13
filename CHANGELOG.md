# Changelog

All notable changes to this project are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.4.0] - 2026-07-12
### Added
- **LSM session-arbitration-block detector** — `Get-WtfRdpArbitrationVerdict` (pure, unit-testable) + `Get-WtfRdpArbitrationBlock` (live/evtx wrapper) in `lib/WtfRdp.Sessions.psm1`. Detects the REAL reboot/logoff-only block: a *stuck arbitration* (Operational `Id=41` "Begin session arbitration" with no completing `Id=42`), which is a **different** failure from Event 36 (the shipped watchdog keys on Event 36 and is structurally blind to this). Never trusts `qwinsta` "Active". Verified (AC-D1) against the real captured block's `.evtx`: `Blocked=true` in the incident window, `false` before/after. Pester test `tests/one-offs/test-arbitration-verdict.Tests.ps1` (8 cases).
- **`sessfix:test`** — a two-machine reproducer/detector for the arbitration block. `rdp test client -RdpHost <server>` storms a server with overlapping reconnects and reads the verdict on the server over WinRM; `rdp test server` detects the block on the local host. Loopback is deliberately unsupported (shortcuts the TCP stack; unverified for this bug). **WIP:** the storm reliably *triggers* the block, but a 100%-repeatable *persistent* strand is still being finalized (l#22).
- **Per-tool `version` field** in every `.wtf-rdp.json` manifest, surfaced by `rdp info <tool>` (mature tools `0.3.0`; the WIP `test` tool `0.1.0`).
### Known
- The arbitration detector's sibling count is parsed from LSM message text and **undercounts** a live storm's session pileup (fix — count the live session table — tracked as l#13; the `test` tool's host-side detection already counts the session table).

## [0.3.3] - 2026-07-11
### Fixed
- **Recovery could falsely report success.** `Invoke-WtfRdpRescue` trusted `tscon`'s exit code (0), but a session under a hardened Local Session Manager block reconnects to the console and then decays back to *Disconnected* within ~2 minutes — so `rdp recover` reported "reconnected, locked=True" and the watchdog logged "RESCUE OK" for a rescue that never held. Added a verification gate: after `tscon`, the rescue polls the session and reports success (`Verified`) only if it reaches Active/Connected **and stays there** through a window (default 20s). `rdp recover` and the watchdog now distinguish *recovered-and-held* from *decayed (hardened LSM block — needs reboot/prevention)* / *unconfirmed* / *failed*. Validated live: a reproduced Event-36 wedge now logs `RESCUE INEFFECTIVE ... DECAYED` instead of a false `RESCUE OK`.
- `Get-WtfRdpWedgeEventSid` returned a double-wrapped array, so wedge-candidate log lines printed `sids: System.Object[]` instead of the session ids.
### Added
- `Get-WtfRdpVerifyVerdict` (pure, exported) — the verdict logic behind the verification gate, with a Pester test (`tests/one-offs/test-ac1-verify-verdict.Tests.ps1`, 8 cases).

## [0.3.2] - 2026-07-08
### Fixed
- **Installed wheel found no tools** ("No tools found" / `rdp install` reported an invalid choice). The per-tool manifests are named `.wtf-rdp.json` (leading dot), and setuptools' `*` glob skips dotfiles, so `package-data`'s `tools/**/*` silently dropped every manifest from the wheel — the `.ps1` scripts shipped but not the manifests that dispatch them. Added an explicit `tools/**/.wtf-rdp.json` pattern, and a test that guards it. (0.3.0/0.3.1 were only usable from an editable/source checkout.)

## [0.3.1] - 2026-07-08
### Added
- `release.yml` gains a `workflow_dispatch` trigger, so the PyPI build + publish can also be run manually from the Actions tab (in addition to firing on a published GitHub Release).
### Ops
- First public release: trusted-publisher (OIDC) wiring to PyPI via the `pypi` environment.

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

[Unreleased]: https://github.com/djdarcy/wtf-rdp/compare/v0.4.0...HEAD
[0.3.3]: https://github.com/djdarcy/wtf-rdp/compare/v0.3.2...v0.3.3
[0.3.2]: https://github.com/djdarcy/wtf-rdp/compare/v0.3.1...v0.3.2
[0.3.1]: https://github.com/djdarcy/wtf-rdp/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/djdarcy/wtf-rdp/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/djdarcy/wtf-rdp/compare/v0.1.2...v0.2.0
[0.1.2]: https://github.com/djdarcy/wtf-rdp/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/djdarcy/wtf-rdp/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/djdarcy/wtf-rdp/releases/tag/v0.1.0
