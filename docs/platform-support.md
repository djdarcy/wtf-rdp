# Platform Support

| Platform | Status | Notes |
|---|---|---|
| Windows 11 (24H2 / build 26200) | **Tested** | Watchdog `tscon` rescue + autonomous loop validated 2026-07-07 |
| Windows 10 | Expected | Same session / WTS / `tscon` / LSM surfaces |
| Windows Server + RDS | Expected | Multi-session; the client single-session limitation does not apply |
| Linux / macOS / BSD | N/A | Windows RDP / Local Session Manager specific |

The runtime tooling (the watchdog service, `tscon` rescue, `qwinsta`) is **Windows-only**. The `rdp` CLI itself is pure Python and installs cross-platform, but its `sessfix` tools target Windows and no-op / warn elsewhere.
