# Zest Scripting Schema

This document defines the current scripting grammar and validation rules implemented in `src/lib-core/core/scripting.zig`.

## File-Level Rules

- A linted zest script is expected to:
- End with `.sh`.

Notes:
- `source <path>` executes script content regardless of extension.
- `lint <path>` enforces these file-level rules.

## Lexical Rules

- Empty lines and lines starting with `#` are ignored.
- Control keywords are line-oriented: `if`, `then`, `elif`, `else`, `fi`, `for`, `in`, `do`, `done`, `while`, `switch`, `case`, `default`, `break`, `continue`.

## Top-Level Statements

A script line can be one of:
- Function definition: `def <name> [<params>] { ... }`.
- `if`/`elif`/`else`/`fi` block.
- `for ... in ...`/`do`/`done` block.
- `while ...`/`do`/`done` block.
- `switch [value] { case ...: ... default: ... }` block.
- `break` / `continue`.
- `set -e` / `set +e`.
- `local` declarations.
- `exit [code]` / `return [code]`.
- Normal command/pipeline/sequence parsed by the command parser.

Unexpected standalone control keywords in normal mode are syntax errors.

## Function Definitions

Syntax:

```sh
def name [param1 param2? typed:int payload:map] {
  ...
}
```

Rules:
- Function names must be non-empty and appear before `[ ... ]`.
- Parameters support:
- Optional marker: `?` suffix.
- Type annotation: `name:type`.
- Optional legacy `$` prefix in parameter token is accepted and stripped.
- Supported types:
- `any`
- `text` (`string`, `str` aliases)
- `int` (`integer` alias)
- `float`
- `bool` (`boolean` alias)
- `list`
- `map` (`record`, `object` aliases)
- Function bodies must be brace-balanced.
- Later definitions overwrite earlier definitions of the same function name.

## Function Invocation And Type Rules

- Script functions are invoked as normal command lines when the command name matches a defined script function.
- Arity must match required/optional parameter bounds.
- Typed parameter checks:
- `text`: accepts raw token text.
- `int`: integer literal parse required.
- `float`: float literal parse required.
- `bool`: must be `true` or `false`.
- `list`: JSON list literal required.
- `map`: JSON object literal required.
- `any`: inferred from bool/int/float/JSON, otherwise text.

## If / Elif / Else

Supported forms:

```sh
if <condition>
then
  ...
elif <condition>
then
  ...
else
  ...
fi
```

Also supported:

```sh
if <condition>; then
  ...
fi
```

Rules:
- Nested `if` blocks are supported.
- `fi` closes the nearest open `if` block.

## For Loops

Syntax:

```sh
for <var> in <item1> <item2> ...
do
  ...
done
```

Rules:
- `in` keyword is required.
- Loop variable must be non-empty.
- Nested `for` blocks are supported.

## While Loops

Syntax:

```sh
while <condition>
do
  ...
done
```

Rules:
- Condition can be multiline until `do`.
- Nested `while` blocks are supported.
- Runtime execution has infinite-loop protection (`MAX_WHILE_ITERATIONS`).

## Switch Blocks

Syntax:

```sh
switch [value] {
  case 1:
    ...
    break;
  case two:
    ...
    break;
  default:
    ...
}
```

Rules:
- Header must be `switch [<value_expr>]` with `{` either same line or next non-comment line.
- Cases use `case <label>:`.
- Default uses `default:`.
- Matching is direct equality after variable expansion and quote trimming.
- If no case matches and no default exists, runtime raises `SwitchNoMatch`.

## Transfer And Flow Keywords

- `break` and `continue` allowed (optional trailing `;`).
- `exit` and `return` accept optional numeric code (fallback behavior follows runtime parser).

## Lint Contract (`lint <path>`)

- Performs static script validation without executing commands.
- Reports violations to stdout in `file line:col ErrorType token` format.
- Returns exit code `0` on pass.
- Returns non-zero on validation failure.

Lint checks include:
- File-level checks (`.sh`).
- Grammar/control-flow structure (`if/fi`, `for/done`, `while/done`, `switch` form).
- Command-line parse validity for script command lines and conditions.
- Script-function invocation arity/type incompatibilities that are statically determinable.

## Examples 

See scripts/tests for a range of scripting examples supported by the shell
engine
