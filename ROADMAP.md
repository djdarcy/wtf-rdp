# Roadmap

Living roadmap: [Issue #1](https://github.com/djdarcy/wtf-rdp/issues/1).

| Phase | Focus | Status |
|---|---|---|
| 0.1.x | Aggregator scaffold (`rdp`) + `sessfix status`; validated watchdog + clicker bundled as assets | Done |
| 0.2.x | `rdp install` deploys the NSSM LocalSystem watchdog; `recover` (safe `tscon` **+ lock**); `uninstall`; **lock-after-rescue** so recovery never leaves a box unlocked | Done |
| 0.3.x | Round out `sessfix`: `query` / `logs` / `config`; `-h`/`--help` on every tool; checksum-verified NSSM pinned by default | Done |
| 0.4.x | Harden detection — add the error-64 / RdpCoreTS-226 secondary signal so wedges without LSM Event 36 aren't missed | Planned |
| 0.5.x | PyPI release (checksum-verified NSSM fetched at install, wheel stays pure-Python); trusted-publisher CI | Planned |

See `private/claude/` for the full design record (postmortem, dev-workflow-process, and the session-rescue watchdog design note).
