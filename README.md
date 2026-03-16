# Zest Shell 

Zest is an experimental shell written in Zig, built to explore shell implementation, structured command execution, CLI tooling, and the Zig language.

It is not intended as a bash/zsh replacement or a production tool — it works for my use cases and is published here as a demo of the implementation work.

The project has two distinct modes with different design goals:
- Interactive REPL — a lightweight shell with prompt rendering, history, aliases, job control, and basic scripting.
- Execution engine — a stateless one-shot command runner with structured JSON input and output, designed to be used programmatically like an API rather than interactively.

## What It Does
- Interactive shell with prompt templating, persistent history, config-driven aliases, and background job control
- One-shot execution via -c or --input with optional structured JSON output (--json)
- Script control flow: if, for, while, switch, function definitions
- Extended builtins for text processing and structured data transforms (where, select, map, reduce, sort, etc.)
- retry builtin with fixed/exponential backoff, jitter, and exit-code filtering

See docs/ for a more indepth description of supported modes, features, scripting and extended builtins.

## Usage

Build:

```bash
zig build
```

Interactive shell (REPL):

```bash
./zig-out/bin/zest
```

One-shot command:

```bash
./zig-out/bin/zest -c "echo hello | upper"
```

Structured JSON output:

```bash
./zig-out/bin/zest -c "echo hello" --json
```

File input (JSON pipeline plan or shell script):

```bash
./zig-out/bin/zest --input ./script.sh
./zig-out/bin/zest --input ./pipeline.json
```

Timing a command:

- `profile <command...>` prints basic timing.

Retrying a command:

- `retry <count>|for <duration> [options...] <command...>` retries one command or pipeline.

Interactive config lives at `~/.config/zest/config.txt`.

- `alias <name> = <command>`
- `prompt = "${user}:${cwd}${git}${status}${prompt_char} "`

See [FEATURES.md](./docs/FEATURES.md) for the current feature support and config details.

## Dependencies

- Zig 0.16.0 to build from source
- Linux (the core process management uses Linux-specific syscalls)

## Scope and Limitations

This is an experimental personal project, not a POSIX-compatible shell. A few things worth knowing before using it:

- Linux only. The fork/exec model and job-control process handling are Linux-specific by design, not an oversight.
- Not fully POSIX-compatible. Behavior will diverge from bash/zsh in edge cases. This is expected.
- Interactive features are intentionally absent from engine mode. History, job handling, alias resolution, PATH caching, and shell state are not available in one-shot execution — the engine is designed to be stateless and lightweight.
- Not exhaustively tested. Edge cases in the command language and builtins may not be handled correctly. The transform builtins and some scripting behavior are still evolving.
