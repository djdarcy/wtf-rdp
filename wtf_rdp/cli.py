"""wtf-rdp CLI entry point (`rdp`).

Built on dazzlecmd-lib's AggregatorEngine. Tools are dispatched from
``kits/sessfix.kit.json`` -> ``tools/sessfix/<tool>/.wtf-rdp.json`` -> the
``.ps1`` named in each manifest's ``runtime.script_path``. The PowerShell
runner ships in dazzlecmd-lib; wtf-rdp is CLI wiring around it, plus the
bundled ``assets/`` (the watchdog service script and the RDP auto-connect
clicker) and the shared ``lib/`` session module.

The first tool category is ``sessfix`` (session-fix): install/uninstall the
NSSM-hosted LocalSystem watchdog, query status, and manually recover a wedged
session. Future categories attach as additional kits without changing this
wiring.
"""
from __future__ import annotations

import shutil
import sys
from pathlib import Path

from dazzlecmd_lib import AggregatorEngine
from dazzlecmd_lib.default_meta_commands import build_list_entries

from ._version import DISPLAY_VERSION, __app_name__, __version__


# Concrete "getting started" examples for the `rdp -h` epilog. Order = the
# expected user journey (look -> install -> recover).
_HELP_EXAMPLES = [
    ("rdp status", "watchdog service state + live session table"),
    ("rdp install", "install the LocalSystem watchdog service (admin)"),
    ("rdp recover", "manually reconnect + lock a wedged session (admin)"),
    ("rdp uninstall", "stop and remove the service (admin)"),
]


def _build_epilog(projects, engine) -> str:
    """Custom `rdp -h` epilog: the tool inventory + getting-started examples.

    dazzlecmd-lib's default top-level help only shows program-level flags; end
    users expect the subcommand list and a couple of concrete examples. Tool
    rows come from ``build_list_entries`` so alias/kit behavior flows through
    automatically as wtf-rdp grows.
    """
    width = shutil.get_terminal_size((80, 24)).columns
    out = []

    entries = build_list_entries(projects, engine, show_mode="default", kit_filter=None)
    if entries:
        label_w = max(len(e["name"]) for e in entries)
        avail = max(20, width - label_w - 4)
        out.append("")
        out.append("tools:")
        for e in entries:
            desc = e["description"]
            if len(desc) > avail:
                desc = desc[: avail - 3] + "..."
            out.append(f"  {e['name']:<{label_w}}  {desc}")

    ex_w = max(len(label) for label, _ in _HELP_EXAMPLES)
    out.append("")
    out.append("getting started:")
    for label, desc in _HELP_EXAMPLES:
        out.append(f"  {label:<{ex_w}}  {desc}")

    out.append("")
    out.append("run 'rdp <tool> -h' for a tool's flags, or 'rdp info <tool>' for details.")
    return "\n".join(out)


def main(argv: list[str] | None = None) -> int:
    if argv is None:
        argv = sys.argv[1:]

    # Flat layout: wtf_rdp/cli.py -> the package dir holds kits/, tools/, assets/, lib/.
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
    # Closure passes engine into the epilog so build_list_entries gets full
    # kit context (the lib's epilog_builder signature is one-arg).
    engine.epilog_builder = lambda projects: _build_epilog(projects, engine)
    return engine.run(argv)


if __name__ == "__main__":
    sys.exit(main())
