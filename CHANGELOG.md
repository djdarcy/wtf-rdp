# Changelog

All notable changes to this project are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

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

[Unreleased]: https://github.com/djdarcy/wtf-rdp/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/djdarcy/wtf-rdp/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/djdarcy/wtf-rdp/releases/tag/v0.1.0
