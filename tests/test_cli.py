"""CLI surface tests for wtf-rdp.

These validate the pure-Python wiring — kit registration, tool-manifest
integrity, and top-level help/epilog — without touching the Windows session
APIs the PowerShell tools use (those are covered by the human checklist and
were validated live on a real LocalSystem service).
"""

import json
from pathlib import Path

import pytest

PKG = Path(__file__).resolve().parent.parent / "wtf_rdp"

# The tools the sessfix kit is expected to register, and the .ps1 each dispatches to.
EXPECTED_TOOLS = {
    "status": "status.ps1",
    "query": "query.ps1",
    "install": "install.ps1",
    "recover": "recover.ps1",
    "logs": "logs.ps1",
    "config": "config.ps1",
    "uninstall": "uninstall.ps1",
    "test": "test.ps1",
}


def _kit():
    return json.loads((PKG / "kits" / "sessfix.kit.json").read_text(encoding="utf-8"))


def test_kit_registers_every_expected_tool():
    listed = {t.split(":", 1)[1] for t in _kit()["tools"]}
    assert listed == set(EXPECTED_TOOLS), f"kit tools {listed} != expected {set(EXPECTED_TOOLS)}"


@pytest.mark.parametrize("tool,script", sorted(EXPECTED_TOOLS.items()))
def test_tool_manifest_and_script_exist(tool, script):
    tdir = PKG / "tools" / "sessfix" / tool
    manifest = tdir / ".wtf-rdp.json"
    assert manifest.is_file(), f"missing manifest for {tool}"
    m = json.loads(manifest.read_text(encoding="utf-8"))
    assert m["name"] == tool
    assert m["category"] == "sessfix"
    # Runtime must be the shell/powershell shape the dazzlecmd runner understands
    # (type "powershell" is NOT a valid runtime type — that bug bit us once).
    rt = m["runtime"]
    assert rt["type"] == "shell"
    assert rt["shell"] == "powershell"
    assert rt["script_path"] == script
    assert (tdir / script).is_file(), f"missing {script} for {tool}"


@pytest.mark.parametrize("tool,script", sorted(EXPECTED_TOOLS.items()))
def test_every_tool_script_handles_help(tool, script):
    """Each .ps1 must accept -h/--help via the Alias('h')/ValueFromRemainingArguments
    pattern, so `rdp <tool> -h` never dies with 'parameter cannot be found'."""
    text = (PKG / "tools" / "sessfix" / tool / script).read_text(encoding="utf-8")
    assert "[Alias('h')][switch] $Help" in text, f"{tool}: no -h alias"
    assert "ValueFromRemainingArguments" in text, f"{tool}: no --help catch-all"


def test_pyproject_packages_the_dotfile_manifests():
    """Regression guard for the 0.3.1 packaging bug: the per-tool manifests are
    named `.wtf-rdp.json` (leading dot), and setuptools' `*` glob skips dotfiles,
    so `tools/**/*` alone drops every manifest from the wheel and the installed
    CLI reports "No tools found". package-data MUST list the dotfile explicitly."""
    text = (PKG.parent / "pyproject.toml").read_text(encoding="utf-8")
    assert "tools/**/.wtf-rdp.json" in text, (
        "pyproject package-data must explicitly include the leading-dot "
        ".wtf-rdp.json manifests, or the built wheel ships no tool manifests."
    )


def test_cli_epilog_lists_all_tools(capsys):
    """`rdp -h` epilog should enumerate every registered tool."""
    from wtf_rdp.cli import main

    with pytest.raises(SystemExit) as exc:
        main(["-h"])
    assert exc.value.code == 0
    out = capsys.readouterr().out
    for tool in EXPECTED_TOOLS:
        assert tool in out, f"{tool} missing from `rdp -h` output"
