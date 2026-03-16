# Features

This file documents the main user-facing features in the current beta.

## Execution Modes

- Interactive mode: `zest`
- One-shot command mode: `zest -c "<command>"`
- File input mode:
  - `zest --input file.json` for JSON pipeline plans
  - `zest --input file.sh` for shell scripts
- Structured engine output: `--json`
- Plan generation from parsed commands: `--plan-json`

## Shell Language

- Builtins, external commands, and `NAME=value` assignments
- Pipelines with `|`
- Sequences with `;`, `&&`, and `||`
- Redirects for stdin, stdout, stderr, append, and `2>&1`
- Variable expansion, tilde expansion, globbing, and command substitution

## Scripting

Script execution is shared with the core runtime rather than using a separate interpreter path.

- `if` / `elif` / `else` / `fi`
- `for` / `done`
- `while` / `done`
- `switch` / `case`
- Function definitions and typed functions

## Interactive Features

- Persistent history
- Config-driven aliases
- Prompt templating
- Background jobs with `jobs`, `fg`, `bg`, and `kill`
- Interactive heredoc input via `<<DELIM` and `<<'DELIM'`

## Raw Input Mode

Interactive mode uses a custom raw input handler rather than relying on a line-editing library.

- Character-by-character input with live redraw
- Inline syntax-aware coloring while typing
- Basic line editing including insert, backspace, and delete
- Multi-line input handling with prompt redraw support
- Interactive heredoc capture with `> ` continuation prompts
- Persistent history navigation with Up/Down
- Prefix-filtered history traversal when navigating from partially typed input
- Reverse history search with `Ctrl+R`
- Ghost suggestions from recent history and completions
- `Tab` completion for commands, paths, builtins, and relevant argument contexts
- Git branch completion for common `git checkout`, `git merge`, and `git push origin` flows

Heredoc notes:

- `<<DELIM` captures lines until `DELIM` and expands variables in the body before execution
- `<<'DELIM'` captures literal lines without variable expansion
- Heredocs are an interactive-shell feature and are rewritten to stdin redirection before parsing
- They affect commands that read stdin; output-only commands such as `echo` will ignore heredoc input

Key bindings:

- `Enter`: submit the current line
- `Tab`: trigger completion
- `Left` / `Right`: move the cursor; `Right` accepts a visible ghost suggestion when at end-of-line
- `Up` / `Down`: walk command history
- `Ctrl+C`: cancel the current line
- `Ctrl+L`: clear the screen and redraw the prompt/input buffer
- `Ctrl+A`: jump to the start of the line
- `Ctrl+E`: jump to the end of the line
- `Ctrl+U`: delete from the cursor back to the start of the line
- `Ctrl+K`: delete from the cursor to the end of the line
- `Ctrl+W`: delete the previous word
- `Ctrl+R`: search backward through history using the current buffer as the initial query
- `Backspace` / `Delete`: delete the character before the cursor

Config file: `~/.config/zest/config.txt`

Supported config entries:

- `alias ll = ls -la`
- `prompt = "${user}:${cwd}${git}${status}${prompt_char} "`

Prompt placeholders:

- `${user}`
- `${cwd}`
- `${cwd_tilde}`
- `${cwd_base}`
- `${git}`
- `${status}`
- `${prompt_char}`
- `${shell}`
- `${nl}`

## Meta Commands

- `profile <command...>` for basic `real/user/sys` timing
- `retry <count>|for <duration> [options...] <command...>`

`retry` supports:

- Fixed or exponential backoff
- Delay and max-delay controls
- Optional jitter
- Exit-code allow/block filters
- Quiet and summary output modes

## Builtin Categories

- Shell/session: `exit`, `cd`, `pwd`, `type`, `which`, `help`, `history`, `source`, `alias`, `unalias`
- Environment/state: `export`, `env`, `exitcode`
- Jobs/processes: `jobs`, `fg`, `bg`, `kill`
- Text/utilities: `echo`, `log`, `read`, `upper`, `b64`, `true`, `false`
- Control/expressions: `test`, `expr`, `confirm`
- Data transforms: `where`, `select`, `sort`, `count`, `map`, `reduce`, `lines`, `split`, `join`
