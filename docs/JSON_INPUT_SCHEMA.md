# JSON Input Schema (`--input <file.json>`)

Zest supports executing command pipelines from JSON files in engine mode.

## Top-Level

```json
{
  "version": 1,
  "settings": {
    "measure_time": false
  },
  "env": [
    { "name": "KEY", "value": "VALUE", "exported": true }
  ],
  "sequence": [
    {
      "pipeline": [
        { "cmd": "echo", "args": ["hello"] },
        { "cmd": "count" }
      ],
      "redirects": {
        "stdin": "in.txt",
        "stdout": "out.txt",
        "stderr": "err.txt",
        "stdout_append": false,
        "stderr_append": false,
        "merge_stderr_to_stdout": false
      },
      "background": false,
      "operator": "semicolon"
    }
  ]
}
```

## Fields

- `version` (`u8`, required): currently must be `1`.
- `settings.measure_time` (`bool`, optional): same timing behavior as `time ...`.
- `env` (`[]`, optional): environment entries applied before execution.
- `sequence` (`[]`, required): ordered execution groups.

## Sequence Entry

- `pipeline` (`[]`, required): one or more commands connected by `|`.
- `redirects` (optional):
  - `stdin`, `stdout`, `stderr` path strings
  - `stdout_append`, `stderr_append` booleans
  - `merge_stderr_to_stdout` boolean
- `background` (`bool`, optional): run entry as background job (interactive mode only).
- `operator` (`string`, optional): relation to the next entry.
  - Supported: `"semicolon"` / `";"`, `"and"` / `"&&"`, `"or"` / `"||"`.
  - Final entry can use `"none"` or omit `operator`.

## Command Entry

- `cmd` (`string`, required): command/builtin name.
- `args` (`[]string`, optional): command args.
- `substitute-cmd` (object, optional): append command-substitution output as an argument.
  - Shape:
    - `cmd` (`string`, required): command to execute in subshell.
    - `args` (`[]string`, optional): args for the subshell command.
  - Equivalent shell syntax: `$(cmd args...)`

Example:

```json
{
  "cmd": "echo",
  "args": ["result:"],
  "substitute-cmd": {
    "cmd": "echo",
    "args": ["hello world"]
  }
}
```

```json 
{
  "version": 1,
  "settings": {
    "measure_time": false
  },
  "env": [
    {
      "name": "ZEST_SAMPLE",
      "value": "ok",
      "exported": true
    }
  ],
  "sequence": [
    {
      "pipeline": [
        { "cmd": "cat" },
        { "cmd": "upper" }
      ],
      "redirects": {
        "stdin": "README.md",
        "stdout": "out.txt",
        "stderr": "err.txt",
        "stdout_append": false,
        "stderr_append": false,
        "merge_stderr_to_stdout": false
      },
      "operator": "none"
    }
  ]
}
```
