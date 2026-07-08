# Extending wtf-rdp

`rdp` is a [dazzlecmd-lib](https://github.com/DazzleLib/dazzlecmd-lib) `AggregatorEngine`: it discovers tools from JSON manifests and dispatches each one to whatever runtime it declares. Adding a tool -- or a whole new kit -- is a matter of dropping a couple of files in; the CLI itself doesn't change.

## How dispatch works

1. **Discovery** -- on startup `rdp` scans `wtf_rdp/kits/*.kit.json` for the active kits, then loads each tool's `wtf_rdp/tools/<kit>/<tool>/.wtf-rdp.json` manifest.
2. **Dispatch** -- each tool's `runtime.type` selects a runner: `python`, `shell`, `script`, `binary`, `node`, or `docker`. The `sessfix` tools use `shell` with `shell: "powershell"`, so `rdp` invokes the bundled `.ps1`. Every tool script is also runnable standalone.
3. **Extensibility** -- new runtime types can be registered by kits (the dispatch is a pluggable factory), and tools that need to go under the hood (C/C++) can ship as native `binary` runtimes.

## Layout

```
wtf_rdp/
├── kits/
│   └── sessfix.kit.json          # kit manifest: the tool list
├── tools/
│   └── sessfix/
│       └── <tool>/
│           ├── .wtf-rdp.json     # tool manifest (dispatch)
│           └── <tool>.ps1        # the script
└── assets/                       # shared bundled scripts (the watchdog); NSSM is fetched by `rdp install`
```

## Add a tool to an existing kit

1. Create `wtf_rdp/tools/<kit>/<tool>/<tool>.ps1` (or `.py`, etc.).
2. Add its manifest `wtf_rdp/tools/<kit>/<tool>/.wtf-rdp.json` (see below).
3. Register it in the kit's `tools` list, e.g. in `wtf_rdp/kits/sessfix.kit.json`:
   ```json
   "tools": ["sessfix:status", "sessfix:<tool>"]
   ```
4. `rdp list` should now show it; `rdp <tool>` dispatches it.

## Tool manifest (`.wtf-rdp.json`)

Only `name` and `description` are required; the rest describe how the tool is dispatched. A PowerShell tool:

```json
{
    "name": "status",
    "description": "Show the watchdog service state, recent rescues, and the live session table.",
    "category": "sessfix",
    "runtime": {
        "type": "shell",
        "shell": "powershell",
        "shell_args": ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File"],
        "script_path": "status.ps1"
    }
}
```

- `runtime.type: "shell"` + `runtime.shell: "powershell"` runs the script via PowerShell; `shell_args` are inserted before the script path (here: no-profile, bypass execution policy).
- For a Python tool use `runtime.type: "python"` with `script_path` + `entry_point`; for a compiled helper use `runtime.type: "binary"` with `script_path` (the binary) and an optional `dev_command`.

## Add a new kit

1. Create `wtf_rdp/kits/<kit>.kit.json` (mirror `sessfix.kit.json`): `name`, `version`, `description`, `always_active`, `tools_dir`, `manifest`, and a `tools` list.
2. Put its tools under `wtf_rdp/tools/<kit>/<tool>/`.
3. Bundle any new assets by extending `[tool.setuptools.package-data]` in `pyproject.toml`.

Future kits on the roadmap: `diagnose`, `keepalive`. See the [dazzlecmd-lib docs](https://github.com/DazzleLib/dazzlecmd-lib) for the full manifest schema and runtime options.
