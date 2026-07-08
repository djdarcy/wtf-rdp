# Roadmap

Living roadmap: [Issue #1](https://github.com/djdarcy/wtf-rdp/issues/1).

| Phase | Focus | Status |
|---|---|---|
| 0.1.x | Aggregator scaffold (`rdp`) + `sessfix status`; validated watchdog + clicker bundled as assets | In progress |
| 0.2.x | `rdp setup sessfix` installs the NSSM LocalSystem watchdog; `recover` (safe `tscon` **+ lock**); `logs` / `config` / `query` / `uninstall` | Planned |
| 0.3.x | Harden detection — add the error-64 / RdpCoreTS-226 secondary signal so wedges without LSM Event 36 aren't missed; **lock-after-rescue** so recovery never leaves a box unlocked | Planned |
| 0.4.x | PyPI release; self-contained wheel (bundled `nssm.exe`); trusted-publisher CI | Planned |

See `private/claude/` for the full design record (postmortem, dev-workflow-process, and the session-rescue watchdog design note).
