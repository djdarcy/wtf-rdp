"""wtf-rdp CLI entry point (`rdp`).

Built on dazzlecmd-lib's AggregatorEngine. Tools are dispatched from
``kits/sessfix.kit.json`` -> ``tools/sessfix/<tool>/.wtf-rdp.json`` -> the
``.ps1`` named in each manifest's ``runtime.script_path``. The PowerShell
runner ships in dazzlecmd-lib; wtf-rdp is CLI wiring around it, plus the
bundled ``assets/`` (the watchdog service script, the RDP auto-connect
clicker, and nssm.exe).

Each tool's ``.ps1`` is also runnable standalone, e.g.:
    powershell -File wtf_rdp/tools/sessfix/status/status.ps1

The first tool category is ``sessfix`` (session-fix): install/uninstall the
NSSM-hosted LocalSystem watchdog, query/status the live session state, and
manually recover a wedged session. Future categories (diagnose, keepalive)
attach as additional kits without changing this wiring.
"""
from __future__ import annotations

import sys
from pathlib import Path

from dazzlecmd_lib import AggregatorEngine

from ._version import DISPLAY_VERSION, __app_name__, __version__


def main(argv: list[str] | None = None) -> int:
    if argv is None:
        argv = sys.argv[1:]

    # Flat layout: wtf_rdp/cli.py -> the package dir holds kits/, tools/, assets/.
    package_root = Path(__file__).resolve().parent

    engine = AggregatorEngine(
        name=__app_name__,
        command="rdp",
        tools_dir="tools",
        kits_dir="kits",
        manifest=".wtf-rdp.json",
        version_info=(DISPLAY_VERSION, __version__),
        description="Windows RDP session-rescue tooling (wtf-windows family).",
        project_root=str(package_root),
    )
    return engine.run(argv)


if __name__ == "__main__":
    sys.exit(main())
