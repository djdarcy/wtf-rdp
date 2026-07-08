"""Shared library code for wtf-rdp tools.

Python is the primary language; PowerShell scripts and bundled binaries (e.g.
nssm.exe) are used where the task demands them. This package is the one home
for common helpers that every ``sessfix`` (and future kit) tool imports,
mirroring the wtf-windows shared-lib convention.

The reusable *session* machinery (WTS enumeration, wedge detection, and the
SYSTEM ``tscon`` rescue) currently lives in the bundled PowerShell watchdog
(``wtf_rdp/assets/Watch-RdpSession.ps1``). As the install/recover/query tools
land, that logic is factored into a shared PowerShell module alongside this
package (e.g. ``WtfRdp.Sessions.psm1``) so the watchdog and the tools share one
implementation rather than re-deriving it per tool.
"""
