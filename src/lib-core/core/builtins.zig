const std = @import("std");
const command = @import("command.zig");
const env = @import("env.zig");
const execute = @import("execute.zig");
const helpers = @import("helpers.zig");
const scripting = @import("scripting.zig");
const transforms = @import("../transforms/transforms.zig");
const stream_ops = @import("../transforms/stream_ops.zig");
const stream_transform_builtins = @import("../transforms/stream_transforms.zig");
const types = @import("types.zig");
const errors = @import("errors.zig");
const Allocator = std.mem.Allocator;
const Base64 = @import("../../lib-serialize/base64.zig").Base64;
const Command = command.Command;
const ExecContext = command.ExecContext;
const List = types.List;
const Map = types.Map;
const RedirConfig = command.RedirConfig;
const ShellError = errors.ShellError;
const ShellExeMode = @import("context.zig").ShellExeMode;
const TypeTag = types.TypeTag;
const Value = types.Value;
const DEFAULT_SHELL_CONFIG_PATH = "~/.config/zest/config.txt";

//  List of all builtins
pub const builtins = [_][]const u8{
    "exit",    "echo",   "log",      "type",   "pwd",
    "which",   "cd",     "history",  "help",   "env",
    "jobs",    "kill",   "exitcode", "source", "lint",
    "test",    "expr",   "read",     "upper",  "fg",
    "bg",      "export", "alias",    "true",   "false",
    "confirm", "where",  "unalias",  "select", "sort",
    "count",   "map",    "reduce",   "lines",  "split",
    "join",    "b64",
};

const help_meta_commands = [_][]const u8{
    "profile",
    "retry",
    "step",
};

// Builtins + meta command help metadata
pub const builtins_metadata = [_]BuiltinMetaData{
    .{
        .name = "exit",
        .syntax = "exit [code]",
        .description = "Exit the shell process.",
        .required_args = &[_][]const u8{},
        .optional_args = &[_][]const u8{"code: integer 0..255 (default 0)"},
        .examples = &[_][]const u8{
            "exit",
            "exit 1",
        },
    },
    .{
        .name = "echo",
        .syntax = "echo [-n] [text ...]",
        .description = "Print text to stdout.",
        .required_args = &[_][]const u8{},
        .optional_args = &[_][]const u8{
            "-n: suppress trailing newline",
            "text ...: words to print",
        },
        .examples = &[_][]const u8{
            "echo hello world",
        },
    },
    .{
        .name = "log",
        .syntax = "log <debug|infor|warn|error> <text ...>",
        .description = "Log text through std.log with an explicit level.",
        .required_args = &[_][]const u8{
            "level: debug | infor | warn | error",
            "text ...: words to log",
        },
        .optional_args = &[_][]const u8{
            "info and err are accepted aliases",
        },
        .examples = &[_][]const u8{
            "log info service started",
            "log error request failed",
        },
    },
    .{
        .name = "profile",
        .syntax = "profile <command...>",
        .description = "Meta prefix: emit basic real/user/sys timing for one command or pipeline.",
        .required_args = &[_][]const u8{"command...: command or pipeline to execute"},
        .optional_args = &[_][]const u8{},
        .examples = &[_][]const u8{
            "profile ls",
            "profile retry 3 false",
        },
    },
    .{
        .name = "retry",
        .syntax = "retry <count>|for <duration> [options...] <command...>",
        .description = "Meta command: retry one command/pipeline on eligible failures.",
        .required_args = &[_][]const u8{
            "count (n attempts) or for <duration>: retry budget",
            "command...: command or pipeline to run",
        },
        .optional_args = &[_][]const u8{
            "--delay <duration>: base delay (default 200ms)",
            "--backoff fixed|exp: delay strategy",
            "--max-delay <duration>: upper cap for delay",
            "--jitter: apply random jitter to delay",
            "--on-exit <codes>: retry only matching exit codes (comma-separated)",
            "--except-exit <codes>: never retry matching exit codes (comma-separated)",
            "--quiet: suppress per-attempt logs",
            "--summary: print final retry summary",
            "scope: one command or one pipeline (no ;, &&, || sequences)",
        },
        .examples = &[_][]const u8{
            "retry 5 curl https://example.com",
            "retry for 10s --delay 200ms --backoff exp curl https://example.com",
            "retry 3 --quiet curl https://example.com",
        },
    },
    .{
        .name = "step",
        .syntax = "step <cmd1 | cmd2 | ...>",
        .description = "Meta command (interactive only): run a pipeline stage-by-stage with y/n confirmation and stdout preview between stages.",
        .required_args = &[_][]const u8{"pipeline: two or more stages connected by |"},
        .optional_args = &[_][]const u8{
            "interactive mode only",
            "does not support sequences (;, &&, ||), background mode, or redirects",
        },
        .examples = &[_][]const u8{
            "step cat README.md | upper | read",
        },
    },
    .{
        .name = "type",
        .syntax = "type <command>",
        .description = "Show whether a command is a builtin or external executable.",
        .required_args = &[_][]const u8{"command: command name"},
        .optional_args = &[_][]const u8{},
        .examples = &[_][]const u8{
            "type retry",
        },
    },
    .{
        .name = "which",
        .syntax = "which [--all] <command> [command ...]",
        .description = "Resolve command source (alias, builtin, external path, or missing).",
        .required_args = &[_][]const u8{"command ...: one or more command names"},
        .optional_args = &[_][]const u8{"--all: include every matching resolution (alias+builtin+external)"},
        .examples = &[_][]const u8{
            "which ls",
            "which --all echo",
            "which echo retry missing-command",
        },
    },
    .{
        .name = "pwd",
        .syntax = "pwd",
        .description = "Print current working directory.",
        .required_args = &[_][]const u8{},
        .optional_args = &[_][]const u8{},
        .examples = &[_][]const u8{
            "pwd",
        },
    },
    .{
        .name = "cd",
        .syntax = "cd [path|-]",
        .description = "Change current working directory.",
        .required_args = &[_][]const u8{},
        .optional_args = &[_][]const u8{
            "path: destination directory",
            "-: switches to OLDPWD and prints resulting path",
            "no args: switches to HOME",
        },
        .examples = &[_][]const u8{
            "cd /tmp",
            "cd",
            "cd -",
        },
    },
    .{
        .name = "history",
        .syntax = "history [n] | history -r|-w|-a <path> | history --contains <term> | history --prefix <term> | history --reverse [n] | history --unique [n]",
        .description = "Read, write, append, or print command history.",
        .required_args = &[_][]const u8{},
        .optional_args = &[_][]const u8{
            "n: show last n entries",
            "-r <path>: read history from file",
            "-w <path>: write history to file (truncate)",
            "-a <path>: append history to file",
            "--contains <term>: filter history entries containing term",
            "--prefix <term>: filter history entries starting with term",
            "--reverse [n]: show latest entries first (optionally limited)",
            "--unique [n]: remove duplicate entries while preserving order",
        },
        .examples = &[_][]const u8{
            "history 20",
            "history -a ~/.zest_history",
            "history --contains deploy",
            "history --reverse 10",
            "history --unique 20",
        },
    },
    .{
        .name = "help",
        .syntax = "help [command] [--all] [--find <term>] [--summary]",
        .description = "Discover command docs, search metadata, and inspect runtime command/features summary.",
        .required_args = &[_][]const u8{},
        .optional_args = &[_][]const u8{
            "command: builtin command name",
            "--all: include all builtins as structured entries",
            "--find <term>: search builtin metadata (name, usage, description)",
            "--summary: runtime command/features summary",
        },
        .examples = &[_][]const u8{
            "help retry",
            "help --all | where .name == retry",
            "help --find history",
            "help --summary",
        },
    },
    .{
        .name = "env",
        .syntax = "env",
        .description = "Print exported environment variables.",
        .required_args = &[_][]const u8{},
        .optional_args = &[_][]const u8{},
        .examples = &[_][]const u8{
            "env",
        },
    },
    .{
        .name = "jobs",
        .syntax = "jobs [-c]",
        .description = "List jobs or clean finished jobs with -c.",
        .required_args = &[_][]const u8{},
        .optional_args = &[_][]const u8{"-c: remove finished jobs from table"},
        .examples = &[_][]const u8{
            "jobs",
            "jobs -c",
        },
    },
    .{
        .name = "kill",
        .syntax = "kill <job_id>",
        .description = "Terminate a background job by id.",
        .required_args = &[_][]const u8{"job_id: numeric job id"},
        .optional_args = &[_][]const u8{},
        .examples = &[_][]const u8{
            "kill 1",
        },
    },
    .{
        .name = "exitcode",
        .syntax = "exitcode",
        .description = "Print exit code of the previously executed command.",
        .required_args = &[_][]const u8{},
        .optional_args = &[_][]const u8{},
        .examples = &[_][]const u8{
            "exitcode",
        },
    },
    .{
        .name = "source",
        .syntax = "source <script_path>",
        .description = "Execute a script in current shell context.",
        .required_args = &[_][]const u8{"script_path: script file path"},
        .optional_args = &[_][]const u8{},
        .examples = &[_][]const u8{
            "source ./script.zest",
        },
    },
    .{
        .name = "lint",
        .syntax = "lint <script_path.sh>",
        .description = "Validate a zest script for syntax/control-flow/type issues without executing it.",
        .required_args = &[_][]const u8{"script_path.sh: script file path ending in .sh"},
        .optional_args = &[_][]const u8{},
        .examples = &[_][]const u8{
            "lint ./scripts/tests/test_switch_case.sh",
        },
    },
    .{
        .name = "test",
        .syntax = "test <expr> | [ <expr> ]",
        .description = "Evaluate file/string/integer test expressions.",
        .required_args = &[_][]const u8{"expr: test expression"},
        .optional_args = &[_][]const u8{
            "-f <path>: file exists",
            "-d <path>: directory exists",
            "-z <str>: empty string check",
            "-n <str>: non-empty string check",
            "<a> = <b> | <a> != <b>: string compare",
            "<a> -eq|-ne|-gt|-lt|-ge|-le <b>: integer compare",
        },
        .examples = &[_][]const u8{
            "test -f README.md",
            "[ 1 -lt 2 ]",
        },
    },
    .{
        .name = "expr",
        .syntax = "expr <left> <operator> <right>",
        .description = "Evaluate integer arithmetic/comparison expressions.",
        .required_args = &[_][]const u8{
            "left: integer",
            "operator: + - * / % < > <= >= = !=",
            "right: integer",
        },
        .optional_args = &[_][]const u8{},
        .examples = &[_][]const u8{
            "expr 7 + 6",
        },
    },
    .{
        .name = "read",
        .syntax = "read [file ...]",
        .description = "Read text from stdin/pipeline/value or files.",
        .required_args = &[_][]const u8{},
        .optional_args = &[_][]const u8{"file ...: files to read"},
        .examples = &[_][]const u8{
            "read README.md",
            "echo hello | read",
        },
    },
    .{
        .name = "upper",
        .syntax = "upper [file ...]",
        .description = "Convert input text to uppercase.",
        .required_args = &[_][]const u8{},
        .optional_args = &[_][]const u8{"file ...: files to transform"},
        .examples = &[_][]const u8{
            "echo hello | upper",
        },
    },

    .{
        .name = "fg",
        .syntax = "fg [%job_id|job_id]",
        .description = "Resume a job in foreground.",
        .required_args = &[_][]const u8{},
        .optional_args = &[_][]const u8{"%job_id|job_id: target job (optional)"},
        .examples = &[_][]const u8{
            "fg %1",
        },
    },
    .{
        .name = "bg",
        .syntax = "bg [%job_id|job_id]",
        .description = "Resume a stopped job in background.",
        .required_args = &[_][]const u8{},
        .optional_args = &[_][]const u8{"%job_id|job_id: target job (optional)"},
        .examples = &[_][]const u8{
            "bg %1",
        },
    },
    .{
        .name = "export",
        .syntax = "export <name> | export <name=value>",
        .description = "Export shell variable to environment scope.",
        .required_args = &[_][]const u8{"name | name=value"},
        .optional_args = &[_][]const u8{},
        .examples = &[_][]const u8{
            "export API_URL=https://example.com",
        },
    },
    .{
        .name = "alias",
        .syntax = "alias | alias <name> | alias <name=value> | alias <name> = <value...>",
        .description = "List, inspect, or persist aliases in the current session.",
        .required_args = &[_][]const u8{},
        .optional_args = &[_][]const u8{
            "no args: list aliases",
            "name: show alias definition",
            "name=value: set alias",
            "name = value...: set alias (spaced assignment form)",
        },
        .examples = &[_][]const u8{
            "alias",
            "alias ll",
            "alias ll='ls -la'",
            "alias gs = git status",
        },
    },
    .{
        .name = "unalias",
        .syntax = "unalias [-a] name [name ...]",
        .description = "Remove aliases from the current session and config file.",
        .required_args = &[_][]const u8{},
        .optional_args = &[_][]const u8{
            "-a: remove all aliases",
            "name ...: alias names to remove",
        },
        .examples = &[_][]const u8{
            "unalias ll",
            "unalias -a",
        },
    },
    .{
        .name = "true",
        .syntax = "true",
        .description = "Return boolean true.",
        .required_args = &[_][]const u8{},
        .optional_args = &[_][]const u8{},
        .examples = &[_][]const u8{
            "true",
        },
    },
    .{
        .name = "false",
        .syntax = "false",
        .description = "Return boolean false.",
        .required_args = &[_][]const u8{},
        .optional_args = &[_][]const u8{},
        .examples = &[_][]const u8{
            "false",
        },
    },
    .{
        .name = "confirm",
        .syntax = "confirm <message ...>",
        .description = "Prompt for y/n confirmation and return success only on yes.",
        .required_args = &[_][]const u8{"message ...: prompt text"},
        .optional_args = &[_][]const u8{
            "accepts y/yes and n/no (case-insensitive)",
            "use with && to gate commands, e.g. confirm \"Delete file?\" && rm file",
        },
        .examples = &[_][]const u8{
            "confirm \"Proceed with deployment?\" && ./deploy.sh",
        },
    },

    .{
        .name = "where",
        .syntax = "where <predicate>",
        .description = "Filter list input by predicate expression.",
        .required_args = &[_][]const u8{
            "predicate: .field <op> <value> | truthy | <op> <value>",
        },
        .optional_args = &[_][]const u8{"op: == != > < >= <= contains"},
        .examples = &[_][]const u8{
            "help --all | where .name == retry",
            "echo 1 2 3 | split | where >= 2",
        },
    },
    .{
        .name = "select",
        .syntax = "select .field ...",
        .description = "Project list(map) input to specific fields.",
        .required_args = &[_][]const u8{".field ...: one or more fields to select"},
        .optional_args = &[_][]const u8{},
        .examples = &[_][]const u8{
            "help --all | select .name .usage",
        },
    },
    .{
        .name = "sort",
        .syntax = "sort [.field]",
        .description = "Sort list input (text/int by value, map by field).",
        .required_args = &[_][]const u8{},
        .optional_args = &[_][]const u8{".field: required for list(map) sort key"},
        .examples = &[_][]const u8{
            "help --all | sort .name",
        },
    },
    .{
        .name = "count",
        .syntax = "count",
        .description = "Return length of list or text input as integer.",
        .required_args = &[_][]const u8{},
        .optional_args = &[_][]const u8{},
        .examples = &[_][]const u8{
            "help --all | count",
        },
    },
    .{
        .name = "map",
        .syntax = "map <expr>",
        .description = "Transform each input list element using a simple expression.",
        .required_args = &[_][]const u8{"expr: identity | .field | upper | lower | trim | len | str | prefix <s> | suffix <s> | add <n> | mul <n>"},
        .optional_args = &[_][]const u8{},
        .examples = &[_][]const u8{
            "echo hello world | split | map upper | join -",
        },
    },
    .{
        .name = "reduce",
        .syntax = "reduce <op> [arg]",
        .description = "Reduce a list to a single value using an accumulator operation.",
        .required_args = &[_][]const u8{"op: sum | concat | merge"},
        .optional_args = &[_][]const u8{"arg: delimiter used by concat"},
        .examples = &[_][]const u8{
            "echo a b c | split | reduce concat ,",
        },
    },
    .{
        .name = "lines",
        .syntax = "lines",
        .description = "Split text input into a list of line values.",
        .required_args = &[_][]const u8{},
        .optional_args = &[_][]const u8{},
        .examples = &[_][]const u8{
            "read README.md | lines",
        },
    },
    .{
        .name = "split",
        .syntax = "split [delimiter]",
        .description = "Split text input by delimiter (or whitespace by default).",
        .required_args = &[_][]const u8{},
        .optional_args = &[_][]const u8{"delimiter: literal separator, chars, or empty for byte-wise split"},
        .examples = &[_][]const u8{
            "echo a,b,c | split ,",
        },
    },
    .{
        .name = "join",
        .syntax = "join [delimiter]",
        .description = "Join list elements into a single text value.",
        .required_args = &[_][]const u8{},
        .optional_args = &[_][]const u8{"delimiter: text inserted between values"},
        .examples = &[_][]const u8{
            "echo a,b,c | split , | join -",
        },
    },
    .{
        .name = "b64",
        .syntax = "b64 [input context]",
        .description = "Encode/decode base64 (auto-detect decode by trailing '=').",
        .required_args = &[_][]const u8{},
        .optional_args = &[_][]const u8{"works with stdin/pipeline/value; file input slots are also supported"},
        .examples = &[_][]const u8{
            "echo hello | b64",
            "echo aGVsbG8= | b64",
        },
    },
};

// Builtin command wrapper for standardized call parameters
pub const BuiltinFn = *const fn (
    exec_ctx: *ExecContext,
    args: [][]const u8,
) Value;

// Struct wrapper around meta data
pub const BuiltinMetaData = struct {
    name: []const u8,
    syntax: []const u8,
    description: []const u8,
    required_args: []const []const u8,
    optional_args: []const []const u8,
    examples: []const []const u8 = &[_][]const u8{},
};

fn isMetaCommandName(name: []const u8) bool {
    for (help_meta_commands) |meta_name| {
        if (std.mem.eql(u8, name, meta_name)) return true;
    }
    return false;
}

fn isMetaCommandAvailableInMode(exe_mode: ShellExeMode, name: []const u8) bool {
    if (std.mem.eql(u8, name, "step")) return exe_mode == .interactive;
    return true;
}

fn isMetadataVisibleInMode(exe_mode: ShellExeMode, meta: BuiltinMetaData) bool {
    if (isMetaCommandName(meta.name)) return isMetaCommandAvailableInMode(exe_mode, meta.name);
    const tag = BuiltinCommand.fromString(meta.name);
    if (tag == .external) return true;
    if (exe_mode == .interactive) return true;
    return BuiltinCommand.allowedInEngine(tag);
}

/// Get metadata for command/help entry that is visible in current mode.
fn findBuiltinMetadata(exe_mode: ShellExeMode, name: []const u8) ?BuiltinMetaData {
    for (builtins_metadata) |meta| {
        if (std.mem.eql(u8, meta.name, name) and isMetadataVisibleInMode(exe_mode, meta)) return meta;
    }
    if (std.mem.eql(u8, name, ".")) return findBuiltinMetadata(exe_mode, "source");
    if (std.mem.eql(u8, name, "[")) return findBuiltinMetadata(exe_mode, "test");
    return null;
}

fn findBuiltinMetadataAnyMode(name: []const u8) ?BuiltinMetaData {
    for (builtins_metadata) |meta| {
        if (std.mem.eql(u8, meta.name, name)) return meta;
    }
    if (std.mem.eql(u8, name, ".")) return findBuiltinMetadataAnyMode("source");
    if (std.mem.eql(u8, name, "[")) return findBuiltinMetadataAnyMode("test");
    return null;
}

/// Transform string array into typed List
fn makeOwnedTextValueList(allocator: Allocator, items: []const []const u8) !*List {
    const list = try allocator.create(List);
    list.* = try List.initCapacity(allocator, items.len);
    for (items) |item| {
        try list.append(allocator, Value{ .text = try allocator.dupe(u8, item) });
    }
    return list;
}

fn putTypeNameOrNull(
    allocator: Allocator,
    map: *Map,
    key: []const u8,
    type_tag: ?TypeTag,
) !void {
    if (type_tag) |tag| {
        try map.put(
            try allocator.dupe(u8, key),
            Value{ .text = try allocator.dupe(u8, @tagName(tag)) },
        );
    } else {
        try map.put(try allocator.dupe(u8, key), Value{ .void = {} });
    }
}

/// Construct structured help record from metadata.
fn buildBuiltinHelpRecordValue(allocator: Allocator, meta: BuiltinMetaData) !Value {
    const root = try allocator.create(Map);
    root.* = Map.init(allocator);

    try root.put(try allocator.dupe(u8, "name"), Value{ .text = try allocator.dupe(u8, meta.name) });
    try root.put(try allocator.dupe(u8, "usage"), Value{ .text = try allocator.dupe(u8, meta.syntax) });
    try root.put(try allocator.dupe(u8, "description"), Value{ .text = try allocator.dupe(u8, meta.description) });
    try root.put(try allocator.dupe(u8, "examples"), Value{ .list = try makeOwnedTextValueList(allocator, meta.examples) });

    const args_map = try allocator.create(Map);
    args_map.* = Map.init(allocator);
    try args_map.put(try allocator.dupe(u8, "required"), Value{ .list = try makeOwnedTextValueList(allocator, meta.required_args) });
    try args_map.put(try allocator.dupe(u8, "optional"), Value{ .list = try makeOwnedTextValueList(allocator, meta.optional_args) });
    try root.put(try allocator.dupe(u8, "args"), Value{ .map = args_map });

    const sig = getTypeSignature(BuiltinCommand.fromString(meta.name));
    const cmd_tag = BuiltinCommand.fromString(meta.name);
    const engine_supported = if (isMetaCommandName(meta.name))
        isMetaCommandAvailableInMode(.engine, meta.name)
    else
        BuiltinCommand.allowedInEngine(cmd_tag);
    const expected_types = try allocator.create(Map);
    expected_types.* = Map.init(allocator);
    try putTypeNameOrNull(allocator, expected_types, "input", sig.input_type);
    try putTypeNameOrNull(allocator, expected_types, "output", sig.output_type);
    try root.put(try allocator.dupe(u8, "expected_types"), Value{ .map = expected_types });
    try root.put(try allocator.dupe(u8, "engine_supported"), Value{ .boolean = engine_supported });
    try root.put(try allocator.dupe(u8, "non_forkable"), Value{ .boolean = BuiltinCommand.isNonForkable(cmd_tag) });
    try root.put(try allocator.dupe(u8, "transform"), Value{ .boolean = BuiltinCommand.isTransform(cmd_tag) });

    return Value{ .map = root };
}

fn buildAllBuiltinHelpRecordsValue(allocator: Allocator, exe_mode: ShellExeMode) !Value {
    var visible_count: usize = 0;
    for (builtins_metadata) |meta| {
        if (isMetadataVisibleInMode(exe_mode, meta)) visible_count += 1;
    }

    const list = try allocator.create(List);
    list.* = try List.initCapacity(allocator, visible_count);
    for (builtins_metadata) |meta| {
        if (!isMetadataVisibleInMode(exe_mode, meta)) continue;
        try list.append(allocator, try buildBuiltinHelpRecordValue(allocator, meta));
    }
    return Value{ .list = list };
}

fn asciiLower(byte: u8) u8 {
    return if (byte >= 'A' and byte <= 'Z') byte + 32 else byte;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len and asciiLower(haystack[i + j]) == asciiLower(needle[j])) : (j += 1) {}
        if (j == needle.len) return true;
    }
    return false;
}

fn metadataMatchesQuery(meta: BuiltinMetaData, query: []const u8) bool {
    return containsIgnoreCase(meta.name, query) or
        containsIgnoreCase(meta.syntax, query) or
        containsIgnoreCase(meta.description, query);
}

fn buildFilteredBuiltinHelpRecordsValue(allocator: Allocator, exe_mode: ShellExeMode, query: []const u8) !Value {
    var match_count: usize = 0;
    for (builtins_metadata) |meta| {
        if (isMetadataVisibleInMode(exe_mode, meta) and metadataMatchesQuery(meta, query)) match_count += 1;
    }

    const list = try allocator.create(List);
    list.* = try List.initCapacity(allocator, match_count);
    for (builtins_metadata) |meta| {
        if (isMetadataVisibleInMode(exe_mode, meta) and metadataMatchesQuery(meta, query)) {
            try list.append(allocator, try buildBuiltinHelpRecordValue(allocator, meta));
        }
    }
    return Value{ .list = list };
}

fn renderHelpStructuredValue(exec_ctx: *ExecContext, value: Value) Value {
    return switch (exec_ctx.output) {
        .capture => value,
        .stream => transforms.renderValue(exec_ctx, value),
        .none => Value{ .err = ShellError.NoOutputRequired },
    };
}

fn buildBuiltinDetailText(allocator: Allocator, meta: BuiltinMetaData) ![]const u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, 192);
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, meta.name);
    try out.appendSlice(allocator, "\n  usage: ");
    try out.appendSlice(allocator, meta.syntax);
    try out.appendSlice(allocator, "\n  description: ");
    try out.appendSlice(allocator, meta.description);

    if (meta.required_args.len > 0) {
        try out.appendSlice(allocator, "\n  required args:");
        for (meta.required_args) |arg| {
            try out.appendSlice(allocator, "\n    - ");
            try out.appendSlice(allocator, arg);
        }
    }

    if (meta.optional_args.len > 0) {
        try out.appendSlice(allocator, "\n  optional args:");
        for (meta.optional_args) |arg| {
            try out.appendSlice(allocator, "\n    - ");
            try out.appendSlice(allocator, arg);
        }
    }

    if (meta.examples.len > 0) {
        try out.appendSlice(allocator, "\n  examples:");
        for (meta.examples) |example| {
            try out.appendSlice(allocator, "\n    - ");
            try out.appendSlice(allocator, example);
        }
    }

    try out.appendSlice(allocator, "\n");
    return out.toOwnedSlice(allocator);
}

fn appendWrappedCsvLine(
    allocator: Allocator,
    out: *std.ArrayList(u8),
    prefix: []const u8,
    indent: []const u8,
    items: []const []const u8,
    max_width: usize,
) !void {
    try out.appendSlice(allocator, prefix);
    var line_len = prefix.len;

    for (items, 0..) |item, idx| {
        const separator = if (idx == 0) "" else ", ";
        const needed = separator.len + item.len;
        if (idx != 0 and line_len + needed > max_width) {
            try out.appendSlice(allocator, "\n");
            try out.appendSlice(allocator, indent);
            line_len = indent.len;
            try out.appendSlice(allocator, item);
            line_len += item.len;
            continue;
        }
        try out.appendSlice(allocator, separator);
        try out.appendSlice(allocator, item);
        line_len += needed;
    }
    try out.append(allocator, '\n');
}

fn buildHelpOverviewText(
    exec_ctx: *ExecContext,
) ![]const u8 {
    const allocator = exec_ctx.allocator;
    const shell_name = exec_ctx.shell_ctx.shell_name;
    const shell_version = exec_ctx.shell_ctx.shell_version;
    const mode_text: []const u8 = switch (exec_ctx.shell_ctx.exe_mode) {
        .interactive => "interactive",
        .engine => "engine",
    };
    const help_meta = findBuiltinMetadataAnyMode("help");
    const help_description = if (help_meta) |meta| meta.description else "Show builtin command help.";
    const help_syntax = if (help_meta) |meta| meta.syntax else "help [command] [--all] [--find <term>] [--summary]";
    const help_usage_forms = [_][]const u8{
        "help",
        "help <command>",
        "help --all",
        "help --find <term>",
        "help --summary",
        "help --all --summary",
        "help --find <term> --summary",
    };

    var out = try std.ArrayList(u8).initCapacity(allocator, 1024);
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, shell_name);
    try out.appendSlice(allocator, " v");
    try out.appendSlice(allocator, shell_version);
    try out.appendSlice(allocator, " help\n");
    try out.appendSlice(allocator, "  mode=");
    try out.appendSlice(allocator, mode_text);
    try out.appendSlice(allocator, "\n\n");

    try out.appendSlice(allocator, "help:\n");
    try out.appendSlice(allocator, "  ");
    try out.appendSlice(allocator, help_description);
    try out.appendSlice(allocator, "\n  syntax: ");
    try out.appendSlice(allocator, help_syntax);
    try out.appendSlice(allocator, "\n  usage:\n");
    for (help_usage_forms) |usage| {
        try out.appendSlice(allocator, "    ");
        try out.appendSlice(allocator, usage);
        try out.append(allocator, '\n');
    }

    var visible_meta = try std.ArrayList([]const u8).initCapacity(allocator, help_meta_commands.len);
    defer visible_meta.deinit(allocator);
    for (help_meta_commands) |meta_name| {
        if (!isMetaCommandAvailableInMode(exec_ctx.shell_ctx.exe_mode, meta_name)) continue;
        try visible_meta.append(allocator, meta_name);
    }

    try out.appendSlice(allocator, "\nmeta commands:\n");
    try out.appendSlice(allocator, "  apply to an entire command or pipeline before execution.\n");
    try appendWrappedCsvLine(allocator, &out, "  ", "  ", visible_meta.items, 88);

    var visible_builtins = try std.ArrayList([]const u8).initCapacity(allocator, builtins.len);
    defer visible_builtins.deinit(allocator);
    for (builtins) |name| {
        const tag = BuiltinCommand.fromString(name);
        if (exec_ctx.shell_ctx.exe_mode == .engine and !BuiltinCommand.allowedInEngine(tag)) continue;
        try visible_builtins.append(allocator, name);
    }

    try out.appendSlice(allocator, "\nbuiltins:\n");
    try appendWrappedCsvLine(allocator, &out, "  ", "  ", visible_builtins.items, 88);

    try out.appendSlice(allocator, "\n");
    return out.toOwnedSlice(allocator);
}

fn emitBuiltinError(exec_ctx: *ExecContext, comptime fmt: []const u8, args: anytype) void {
    var stack_buf: [512]u8 = undefined;
    var heap_msg: ?[]const u8 = null;
    defer if (heap_msg) |msg| exec_ctx.allocator.free(msg);

    const message = std.fmt.bufPrint(&stack_buf, fmt, args) catch blk: {
        heap_msg = std.fmt.allocPrint(exec_ctx.allocator, fmt, args) catch return;
        break :blk heap_msg.?;
    };
    const line = message;

    switch (exec_ctx.err) {
        .stream => |stderr| {
            if (exec_ctx.append) {
                helpers.fileAppendAll(exec_ctx.shell_ctx.io.*, stderr, line) catch {};
                helpers.fileAppendAll(exec_ctx.shell_ctx.io.*, stderr, "\n") catch {};
            } else {
                helpers.fileWriteAll(exec_ctx.shell_ctx.io.*, stderr, line) catch {};
                helpers.fileAppendAll(exec_ctx.shell_ctx.io.*, stderr, "\n") catch {};
            }
        },
        .none => {
            if (exec_ctx.shell_ctx.exe_mode == .interactive) return;
            if (!@import("builtin").is_test) {
                std.log.err("{s}", .{line});
            }
        },
    }
}

fn failBuiltin(exec_ctx: *ExecContext, err: ShellError, comptime fmt: []const u8, args: anytype) Value {
    emitBuiltinError(exec_ctx, fmt, args);
    return Value{ .err = err };
}

fn isValidAliasName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        if (std.ascii.isWhitespace(c)) return false;
        switch (c) {
            '|', '&', ';', '<', '>', '=' => return false,
            else => {},
        }
    }
    return true;
}

fn parseAliasNameFromConfigLine(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "alias")) return null;
    if (trimmed.len == "alias".len or !std.ascii.isWhitespace(trimmed["alias".len])) return null;

    const remainder = std.mem.trimStart(u8, trimmed["alias".len..], " \t");
    const eq_idx = std.mem.indexOfScalar(u8, remainder, '=') orelse return null;
    const name = std.mem.trim(u8, remainder[0..eq_idx], " \t");
    if (!isValidAliasName(name)) return null;
    return name;
}

fn clearRuntimeAliases(exec_ctx: *ExecContext) void {
    const aliases = exec_ctx.shell_ctx.aliases orelse return;
    var iter = aliases.iterator();
    while (iter.next()) |entry| {
        exec_ctx.allocator.free(entry.key_ptr.*);
        exec_ctx.allocator.free(entry.value_ptr.*);
    }
    aliases.clearRetainingCapacity();
}

fn removeRuntimeAlias(exec_ctx: *ExecContext, name: []const u8) bool {
    const aliases = exec_ctx.shell_ctx.aliases orelse return false;
    if (aliases.fetchRemove(name)) |kv| {
        exec_ctx.allocator.free(kv.key);
        exec_ctx.allocator.free(kv.value);
        return true;
    }
    return false;
}

fn upsertRuntimeAlias(exec_ctx: *ExecContext, name: []const u8, value: []const u8) ShellError!void {
    const aliases = exec_ctx.shell_ctx.aliases orelse return ShellError.Unsupported;

    if (aliases.getPtr(name)) |existing| {
        exec_ctx.allocator.free(existing.*);
        existing.* = exec_ctx.allocator.dupe(u8, value) catch return ShellError.AllocFailed;
        return;
    }

    try aliases.put(
        exec_ctx.allocator.dupe(u8, name) catch return ShellError.AllocFailed,
        exec_ctx.allocator.dupe(u8, value) catch return ShellError.AllocFailed,
    );
}

fn formatAliasLine(exec_ctx: *ExecContext, name: []const u8, value: []const u8) ShellError![]const u8 {
    return std.fmt.allocPrint(exec_ctx.allocator, "alias {s} = {s}\n", .{ name, value }) catch return ShellError.AllocFailed;
}

fn upsertAliasInConfigFile(exec_ctx: *ExecContext, name: []const u8, value: []const u8) ShellError!void {
    const abs_path = helpers.expandPathToAbs(exec_ctx.shell_ctx, exec_ctx.allocator, DEFAULT_SHELL_CONFIG_PATH) catch return ShellError.InvalidPath;
    defer exec_ctx.allocator.free(abs_path);

    helpers.ensureDirPath(exec_ctx.shell_ctx, abs_path) catch return ShellError.InvalidPath;

    var existing_content: []const u8 = "";
    var has_existing_file = false;
    var in_file = helpers.getFileFromPath(exec_ctx.shell_ctx, exec_ctx.allocator, abs_path, .{
        .write = false,
        .truncate = false,
        .pre_expanded = true,
    }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return ShellError.ReadFailed,
    };
    if (in_file) |*file| {
        defer file.close(exec_ctx.shell_ctx.io.*);
        existing_content = helpers.fileReadAll(exec_ctx.shell_ctx.io.*, exec_ctx.allocator, file.*) catch return ShellError.ReadFailed;
        has_existing_file = true;
    }
    defer if (has_existing_file) exec_ctx.allocator.free(existing_content);

    var out = std.ArrayList(u8).initCapacity(exec_ctx.allocator, if (existing_content.len > 0) existing_content.len + 64 else 64) catch
        return ShellError.AllocFailed;
    defer out.deinit(exec_ctx.allocator);

    var replaced = false;
    if (existing_content.len > 0) {
        var lines = std.mem.splitScalar(u8, existing_content, '\n');
        var first = true;
        while (lines.next()) |line| {
            if (!first) out.append(exec_ctx.allocator, '\n') catch return ShellError.AllocFailed;
            first = false;

            if (parseAliasNameFromConfigLine(line)) |alias_name| {
                if (std.mem.eql(u8, alias_name, name)) {
                    const formatted = formatAliasLine(exec_ctx, name, value) catch |err| return err;
                    defer exec_ctx.allocator.free(formatted);
                    const trimmed = std.mem.trimEnd(u8, formatted, "\n");
                    out.appendSlice(exec_ctx.allocator, trimmed) catch return ShellError.AllocFailed;
                    replaced = true;
                    continue;
                }
            }
            out.appendSlice(exec_ctx.allocator, line) catch return ShellError.AllocFailed;
        }
    }

    if (!replaced) {
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') {
            out.append(exec_ctx.allocator, '\n') catch return ShellError.AllocFailed;
        }
        const formatted = formatAliasLine(exec_ctx, name, value) catch |err| return err;
        defer exec_ctx.allocator.free(formatted);
        out.appendSlice(exec_ctx.allocator, formatted) catch return ShellError.AllocFailed;
    }

    var out_file = helpers.getFileFromPath(exec_ctx.shell_ctx, exec_ctx.allocator, abs_path, .{
        .write = true,
        .truncate = true,
        .pre_expanded = true,
    }) catch |err| switch (err) {
        else => return ShellError.WriteFailed,
    };
    defer out_file.close(exec_ctx.shell_ctx.io.*);

    helpers.fileWriteAll(exec_ctx.shell_ctx.io.*, out_file, out.items) catch return ShellError.WriteFailed;
}

const AliasEntry = struct {
    name: []const u8,
    value: []const u8,
};

fn collectSortedAliasEntries(allocator: Allocator, aliases: *ShellCtx.AliasMap) ShellError![]AliasEntry {
    var entries = std.ArrayList(AliasEntry).initCapacity(allocator, aliases.count()) catch return ShellError.AllocFailed;
    var iter = aliases.iterator();
    while (iter.next()) |entry| {
        entries.append(allocator, .{
            .name = entry.key_ptr.*,
            .value = entry.value_ptr.*,
        }) catch return ShellError.AllocFailed;
    }
    std.mem.sort(AliasEntry, entries.items, {}, struct {
        fn lessThan(_: void, a: AliasEntry, b: AliasEntry) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lessThan);
    return entries.items;
}

fn buildAliasEntryMap(allocator: Allocator, entry: AliasEntry) ShellError!Value {
    const map = allocator.create(Map) catch return ShellError.AllocFailed;
    map.* = Map.init(allocator);
    try map.put(try allocator.dupe(u8, "name"), .{ .text = try allocator.dupe(u8, entry.name) });
    try map.put(try allocator.dupe(u8, "value"), .{ .text = try allocator.dupe(u8, entry.value) });
    return .{ .map = map };
}

fn emitAliasEntries(exec_ctx: *ExecContext, entries: []const AliasEntry) Value {
    return switch (exec_ctx.output) {
        .stream => |stdout| blk: {
            var out = std.ArrayList(u8).initCapacity(exec_ctx.allocator, entries.len * 16) catch
                break :blk Value{ .err = ShellError.AllocFailed };
            defer out.deinit(exec_ctx.allocator);
            for (entries) |entry| {
                const line = formatAliasLine(exec_ctx, entry.name, entry.value) catch |err|
                    break :blk Value{ .err = err };
                defer exec_ctx.allocator.free(line);
                out.appendSlice(exec_ctx.allocator, line) catch break :blk Value{ .err = ShellError.AllocFailed };
            }
            if (exec_ctx.append) {
                helpers.fileAppendAll(exec_ctx.shell_ctx.io.*, stdout, out.items) catch break :blk Value{ .err = ShellError.WriteFailed };
            } else {
                helpers.fileWriteAll(exec_ctx.shell_ctx.io.*, stdout, out.items) catch break :blk Value{ .err = ShellError.WriteFailed };
            }
            break :blk Value{ .void = {} };
        },
        .capture => blk: {
            const list = exec_ctx.allocator.create(List) catch break :blk Value{ .err = ShellError.AllocFailed };
            list.* = List.initCapacity(exec_ctx.allocator, entries.len) catch break :blk Value{ .err = ShellError.AllocFailed };
            for (entries) |entry| {
                const mapped = buildAliasEntryMap(exec_ctx.allocator, entry) catch |err|
                    break :blk Value{ .err = err };
                list.append(exec_ctx.allocator, mapped) catch break :blk Value{ .err = ShellError.AllocFailed };
            }
            break :blk Value{ .list = list };
        },
        .none => Value{ .void = {} },
    };
}

fn parseAliasAssignment(exec_ctx: *ExecContext, args: [][]const u8) ShellError!?struct { name: []const u8, value: []const u8, owned: bool } {
    if (args.len < 2) return null;

    if (std.mem.indexOfScalar(u8, args[1], '=')) |eq_idx| {
        const name = std.mem.trim(u8, args[1][0..eq_idx], " \t");
        const first_value = std.mem.trim(u8, args[1][eq_idx + 1 ..], " \t");
        if (name.len == 0) return ShellError.InvalidArgument;
        if (args.len == 2) {
            return .{ .name = name, .value = first_value, .owned = false };
        }
        var joined = std.ArrayList(u8).initCapacity(exec_ctx.allocator, first_value.len + 1) catch return ShellError.AllocFailed;
        defer joined.deinit(exec_ctx.allocator);
        if (first_value.len > 0) {
            joined.appendSlice(exec_ctx.allocator, first_value) catch return ShellError.AllocFailed;
        }
        for (args[2..]) |arg| {
            if (joined.items.len > 0) joined.append(exec_ctx.allocator, ' ') catch return ShellError.AllocFailed;
            joined.appendSlice(exec_ctx.allocator, arg) catch return ShellError.AllocFailed;
        }
        return .{
            .name = name,
            .value = exec_ctx.allocator.dupe(u8, joined.items) catch return ShellError.AllocFailed,
            .owned = true,
        };
    }

    if (args.len >= 4 and std.mem.eql(u8, args[2], "=")) {
        const name = std.mem.trim(u8, args[1], " \t");
        const value = std.mem.join(exec_ctx.allocator, " ", args[3..]) catch return ShellError.AllocFailed;
        return .{ .name = name, .value = value, .owned = true };
    }

    if (args.len == 2) return null;
    return ShellError.InvalidArgument;
}

fn emitAliasUsage(exec_ctx: *ExecContext) void {
    emitBuiltinError(exec_ctx, "alias: usage: alias | alias <name> | alias <name=value> | alias <name> = <value...>", .{});
}

fn removeAliasesFromConfigFile(
    exec_ctx: *ExecContext,
    remove_all: bool,
    names: []const []const u8,
    found_in_file: ?[]bool,
) ShellError!void {
    const abs_path = helpers.expandPathToAbs(exec_ctx.shell_ctx, exec_ctx.allocator, DEFAULT_SHELL_CONFIG_PATH) catch return;
    defer exec_ctx.allocator.free(abs_path);

    var file = helpers.getFileFromPath(exec_ctx.shell_ctx, exec_ctx.allocator, abs_path, .{
        .write = false,
        .truncate = false,
        .pre_expanded = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return ShellError.ReadFailed,
    };
    defer file.close(exec_ctx.shell_ctx.io.*);

    const content = helpers.fileReadAll(exec_ctx.shell_ctx.io.*, exec_ctx.allocator, file) catch return ShellError.ReadFailed;
    defer exec_ctx.allocator.free(content);

    var out = std.ArrayList(u8).initCapacity(exec_ctx.allocator, content.len) catch return ShellError.AllocFailed;
    defer out.deinit(exec_ctx.allocator);
    var changed = false;
    var first = true;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (!first) {
            out.append(exec_ctx.allocator, '\n') catch return ShellError.AllocFailed;
        }
        first = false;

        var remove_line = false;
        if (parseAliasNameFromConfigLine(line)) |alias_name| {
            if (remove_all) {
                remove_line = true;
                changed = true;
            } else {
                for (names, 0..) |name, idx| {
                    if (std.mem.eql(u8, alias_name, name)) {
                        remove_line = true;
                        changed = true;
                        if (found_in_file) |found| {
                            found[idx] = true;
                        }
                        break;
                    }
                }
            }
        }

        if (!remove_line) {
            out.appendSlice(exec_ctx.allocator, line) catch return ShellError.AllocFailed;
        }
    }

    if (!changed) return;

    var out_file = helpers.getFileFromPath(exec_ctx.shell_ctx, exec_ctx.allocator, abs_path, .{
        .write = true,
        .truncate = true,
        .pre_expanded = true,
    }) catch |err| switch (err) {
        else => return ShellError.WriteFailed,
    };
    defer out_file.close(exec_ctx.shell_ctx.io.*);

    helpers.fileWriteAll(exec_ctx.shell_ctx.io.*, out_file, out.items) catch return ShellError.WriteFailed;
}

fn emitUnaliasUsage(exec_ctx: *ExecContext) void {
    emitBuiltinError(exec_ctx, "unalias: usage: unalias [-a] name [name ...]", .{});
}

/// List, inspect, or set aliases in the current session.
pub fn alias_builtin(exec_ctx: *ExecContext, args: [][]const u8) Value {
    if (exec_ctx.shell_ctx.exe_mode == .engine) {
        return failBuiltin(exec_ctx, ShellError.Unsupported, "alias: unsupported in engine mode", .{});
    }
    const aliases = exec_ctx.shell_ctx.aliases orelse {
        return failBuiltin(exec_ctx, ShellError.Unsupported, "alias: alias map not available in current mode", .{});
    };

    if (args.len == 1) {
        const entries = collectSortedAliasEntries(exec_ctx.allocator, aliases) catch |err|
            return Value{ .err = err };
        return emitAliasEntries(exec_ctx, entries);
    }

    const assignment = parseAliasAssignment(exec_ctx, args) catch |err| {
        if (err == ShellError.InvalidArgument) emitAliasUsage(exec_ctx);
        return Value{ .err = err };
    };
    if (assignment) |parsed| {
        defer if (parsed.owned) exec_ctx.allocator.free(parsed.value);
        if (!isValidAliasName(parsed.name)) {
            return failBuiltin(exec_ctx, ShellError.InvalidArgument, "alias: invalid alias name '{s}'", .{parsed.name});
        }
        upsertRuntimeAlias(exec_ctx, parsed.name, parsed.value) catch |err| {
            return failBuiltin(exec_ctx, err, "alias: failed to update runtime alias map", .{});
        };
        upsertAliasInConfigFile(exec_ctx, parsed.name, parsed.value) catch |err| {
            return failBuiltin(exec_ctx, err, "alias: failed to update config file ({s})", .{@errorName(err)});
        };
        return Value{ .boolean = true };
    }

    if (args.len != 2) {
        emitAliasUsage(exec_ctx);
        return Value{ .err = ShellError.InvalidArgument };
    }

    const name = args[1];
    const value = aliases.get(name) orelse
        return failBuiltin(exec_ctx, ShellError.InvalidArgument, "alias: {s}: not found", .{name});
    return emitAliasEntries(exec_ctx, &.{.{ .name = name, .value = value }});
}

/// Returns a enum token to represent the builtin command
pub const BuiltinCommand = enum {
    // commands
    cmd_exit,
    cmd_echo,
    cmd_log,
    cmd_type,
    cmd_which,
    cmd_pwd,
    cmd_cd,
    cmd_history,
    cmd_help,
    cmd_env,
    cmd_jobs,
    cmd_kill,
    cmd_exitcode,
    cmd_source,
    cmd_lint,
    cmd_test,
    cmd_expr,
    cmd_read,
    cmd_upper,
    cmd_fg,
    cmd_bg,
    cmd_export,
    cmd_alias,
    cmd_unalias,
    cmd_true,
    cmd_false,
    cmd_confirm,
    cmd_where,
    cmd_select,
    cmd_sort,
    cmd_count,
    cmd_map,
    cmd_reduce,
    cmd_lines,
    cmd_split,
    cmd_join,
    cmd_b64,
    // else case, not a builtin
    external,

    pub fn fromString(word: []const u8) BuiltinCommand {
        const map = std.StaticStringMap(BuiltinCommand).initComptime(.{
            .{ "exit", .cmd_exit },
            .{ "echo", .cmd_echo },
            .{ "log", .cmd_log },
            .{ "type", .cmd_type },
            .{ "which", .cmd_which },
            .{ "pwd", .cmd_pwd },
            .{ "cd", .cmd_cd },
            .{ "history", .cmd_history },
            .{ "help", .cmd_help },
            .{ "env", .cmd_env },
            .{ "jobs", .cmd_jobs },
            .{ "kill", .cmd_kill },
            .{ "exitcode", .cmd_exitcode },
            .{ "source", .cmd_source },
            .{ ".", .cmd_source }, // alias for source
            .{ "lint", .cmd_lint },
            .{ "test", .cmd_test },
            .{ "[", .cmd_test }, // alias for test
            .{ "expr", .cmd_expr },
            .{ "upper", .cmd_upper },
            .{ "read", .cmd_read },
            .{ "fg", .cmd_fg },
            .{ "bg", .cmd_bg },
            .{ "export", .cmd_export },
            .{ "alias", .cmd_alias },
            .{ "unalias", .cmd_unalias },
            .{ "true", .cmd_true },
            .{ "false", .cmd_false },
            .{ "confirm", .cmd_confirm },
            .{ "where", .cmd_where },
            .{ "select", .cmd_select },
            .{ "sort", .cmd_sort },
            .{ "count", .cmd_count },
            .{ "map", .cmd_map },
            .{ "reduce", .cmd_reduce },
            .{ "lines", .cmd_lines },
            .{ "split", .cmd_split },
            .{ "join", .cmd_join },
            .{ "b64", .cmd_b64 },
        });
        return map.get(word) orelse .external;
    }

    /// Shell state changing builtins shoudn't be used in pipelines
    pub fn isNonForkable(cmd_tag: BuiltinCommand) bool {
        switch (cmd_tag) {
            .cmd_cd, .cmd_exit, .cmd_fg, .cmd_bg, .cmd_export, .cmd_alias, .cmd_unalias, .cmd_source => {
                return true;
            },
            else => return false,
        }
    }

    /// Transforms can only be applied on structured data types from builtins
    pub fn isTransform(cmd_tag: BuiltinCommand) bool {
        switch (cmd_tag) {
            .cmd_where, .cmd_select, .cmd_sort, .cmd_count, .cmd_map, .cmd_reduce, .cmd_lines, .cmd_split, .cmd_join => return true,
            else => return false,
        }
    }

    /// Builtins which allow < or > as operators ot redirects
    pub fn allowAngleBracketArgs(cmd_tag: BuiltinCommand) bool {
        switch (cmd_tag) {
            .cmd_test, .cmd_expr, .cmd_where => return true,
            else => return false,
        }
    }

    /// Builtins which can't be run in engine mode
    pub fn allowedInEngine(cmd_tag: BuiltinCommand) bool {
        switch (cmd_tag) {
            .cmd_fg, .cmd_jobs, .cmd_bg, .cmd_history, .cmd_kill, .cmd_alias, .cmd_confirm => {
                return false;
            },
            else => return true,
        }
    }
};

/// Get the builtin function pointer for a builtin command
pub fn getBuiltinFunction(builtin_cmd: BuiltinCommand) BuiltinFn {
    return switch (builtin_cmd) {
        .cmd_echo => echo,
        .cmd_log => log_builtin,
        .cmd_type => printType,
        .cmd_which => which_builtin,
        .cmd_pwd => pwd,
        .cmd_exitcode => exitcode,
        .cmd_help => help,
        .cmd_kill => kill,
        .cmd_jobs => jobs,
        .cmd_history => history,
        .cmd_env => env_builtin,
        .cmd_expr => expr_builtin,
        .cmd_test => test_builtin,
        .cmd_exit => exit,
        .cmd_source => source,
        .cmd_lint => lint_builtin,
        .cmd_cd => cd,
        .cmd_read => read_builtin,
        .cmd_upper => uppercase,
        .cmd_fg => executeFg,
        .cmd_bg => executeBg,
        .cmd_export => export_builtin,
        .cmd_alias => alias_builtin,
        .cmd_unalias => unalias_builtin,
        .cmd_true => true_builtin,
        .cmd_false => false_builtin,
        .cmd_confirm => confirm_builtin,
        .cmd_where => where,
        .cmd_select => select,
        .cmd_sort => sort_builtin,
        .cmd_count => count,
        .cmd_map => stream_transform_builtins.map_builtin,
        .cmd_reduce => stream_transform_builtins.reduce_builtin,
        .cmd_lines => stream_transform_builtins.lines_builtin,
        .cmd_split => stream_transform_builtins.split_builtin,
        .cmd_join => stream_transform_builtins.join_builtin,
        .cmd_b64 => b64,
        .external => external,
    };
}

/// Expected I/O types of known builtins
pub const BuiltinTypeSignature = struct {
    input_type: ?TypeTag = null,
    output_type: ?TypeTag = null,
    strict_input: bool = false, // enforce?
};

/// Map builtin tag to signature
pub fn getTypeSignature(cmd_tag: BuiltinCommand) BuiltinTypeSignature {
    return switch (cmd_tag) {
        .cmd_where => .{
            .input_type = .list,
            .output_type = .list,
            .strict_input = true,
        },
        .cmd_select => .{
            .input_type = .list,
            .output_type = .list,
            .strict_input = true,
        },
        .cmd_sort => .{
            .input_type = .list,
            .output_type = .list,
            .strict_input = true,
        },
        .cmd_count => .{
            .output_type = .integer,
        },
        .cmd_map => .{
            .input_type = .list,
            .output_type = .list,
            .strict_input = true,
        },
        .cmd_reduce => .{
            .input_type = .list,
            .strict_input = true,
        },
        .cmd_lines => .{
            .input_type = .text,
            .output_type = .list,
        },
        .cmd_split => .{
            .input_type = .text,
            .output_type = .list,
        },
        .cmd_join => .{
            .input_type = .list,
            .output_type = .text,
            .strict_input = true,
        },
        .cmd_jobs => .{ .output_type = .list },
        .cmd_history => .{ .output_type = .list },
        .cmd_env => .{ .output_type = .map },
        .cmd_exitcode => .{ .output_type = .integer },
        .cmd_upper => .{
            .input_type = .text,
            .output_type = .text,
        },
        else => .{},
    };
}

/// Dummy builtin for switch return completion
pub fn external(exec_ctx: *ExecContext, args: [][]const u8) Value {
    _ = exec_ctx;
    _ = args;
    return Value{ .err = ShellError.InvalidBuiltinCommand };
}

// true if text command is a builtin
pub fn isBuiltinCmd(cmd: []const u8) bool {
    const res = BuiltinCommand.fromString(cmd);
    return res != .external;
}

//
// ---- Shell state changing builtins
//

/// Builtin exit to exit shell REPL
pub fn exit(exec_ctx: *ExecContext, args: [][]const u8) Value {
    var status_code: u8 = 0;
    if (args.len > 1) {
        status_code = std.fmt.parseInt(u8, args[1], 10) catch 0;
    }

    // persistent changes for interactive shell
    if (exec_ctx.shell_ctx.exe_mode == .interactive) {
        exec_ctx.shell_ctx.persistSession();
    }

    std.process.exit(status_code);
    return Value{ .void = {} };
}

/// Export moves a loal shell builtin to env map which will persist accross shell sessions
/// Unlike bash this will not set values to "" if not found in shell local
pub fn export_builtin(exec_ctx: *ExecContext, args: [][]const u8) Value {
    if (args.len < 2) {
        return failBuiltin(exec_ctx, ShellError.MissingArgument, "export: missing argument", .{});
    }
    var key = args[1];

    // Handle inline assignment before export, eg export VAR=val
    if (helpers.isAssignment(key)) {
        execute.executeAssignment(exec_ctx.shell_ctx, exec_ctx.allocator, key) catch {
            return failBuiltin(exec_ctx, ShellError.InvalidAssignment, "export: invalid assignment '{s}'", .{key});
        };
        // extract key
        const eql_idx = std.mem.find(u8, key, "=");
        if (eql_idx) |idx| {
            key = key[0..idx];
        } else {
            return failBuiltin(exec_ctx, ShellError.ExportFailed, "export: failed to parse export key from '{s}'", .{key});
        }
    }

    const success = try exec_ctx.shell_ctx.env_map.exportVar(key);
    if (success) {
        return Value{ .void = {} };
    }
    return failBuiltin(exec_ctx, ShellError.ExportFailed, "export: failed to export '{s}'", .{key});
}

/// Remove aliases from active map and persisted config file.
pub fn unalias_builtin(exec_ctx: *ExecContext, args: [][]const u8) Value {
    var remove_all = false;
    var idx: usize = 1;

    while (idx < args.len) : (idx += 1) {
        const arg = args[idx];
        if (std.mem.eql(u8, arg, "--")) {
            idx += 1;
            break;
        }
        if (arg.len == 0 or arg[0] != '-') break;
        if (std.mem.eql(u8, arg, "-a")) {
            remove_all = true;
            continue;
        }
        emitBuiltinError(exec_ctx, "unalias: {s}: invalid option", .{arg});
        emitUnaliasUsage(exec_ctx);
        return Value{ .err = ShellError.InvalidArgument };
    }

    const names = args[idx..];
    if (!remove_all and names.len == 0) {
        emitUnaliasUsage(exec_ctx);
        return Value{ .err = ShellError.InvalidArgument };
    }

    if (remove_all) {
        clearRuntimeAliases(exec_ctx);
        removeAliasesFromConfigFile(exec_ctx, true, &.{}, null) catch |err| {
            return failBuiltin(exec_ctx, err, "unalias: failed to update config file ({s})", .{@errorName(err)});
        };
        return Value{ .boolean = true };
    }

    var found = exec_ctx.allocator.alloc(bool, names.len) catch return Value{ .err = ShellError.AllocFailed };
    defer exec_ctx.allocator.free(found);
    for (found) |*entry| entry.* = false;

    for (names, 0..) |name, name_idx| {
        if (removeRuntimeAlias(exec_ctx, name)) {
            found[name_idx] = true;
        }
    }

    removeAliasesFromConfigFile(exec_ctx, false, names, found) catch |err| {
        return failBuiltin(exec_ctx, err, "unalias: failed to update config file ({s})", .{@errorName(err)});
    };

    var ok = true;
    for (names, 0..) |name, name_idx| {
        if (!found[name_idx]) {
            emitBuiltinError(exec_ctx, "unalias: {s}: not found", .{name});
            ok = false;
        }
    }
    return Value{ .boolean = ok };
}

/// True, simply returns success
pub fn true_builtin(exec_ctx: *ExecContext, args: [][]const u8) Value {
    _ = exec_ctx;
    _ = args;
    return Value{ .boolean = true };
}

/// False, simply returns failure
pub fn false_builtin(exec_ctx: *ExecContext, args: [][]const u8) Value {
    _ = exec_ctx;
    _ = args;
    return Value{ .boolean = false };
}

fn readConfirmLineFromStream(exec_ctx: *ExecContext, in_file: std.Io.File) !?[]const u8 {
    var i_buf: [256]u8 = undefined;
    var input_reader = in_file.reader(exec_ctx.shell_ctx.io.*, &i_buf);
    const input = &input_reader.interface;

    var line = try std.ArrayList(u8).initCapacity(exec_ctx.allocator, 32);
    defer line.deinit(exec_ctx.allocator);

    while (true) {
        const ch = input.takeByte() catch |err| switch (err) {
            error.EndOfStream => {
                if (line.items.len == 0) return null;
                return try exec_ctx.allocator.dupe(u8, line.items);
            },
            else => return err,
        };

        if (ch == '\n') return try exec_ctx.allocator.dupe(u8, line.items);
        if (ch == '\r') continue;
        try line.append(exec_ctx.allocator, ch);
    }
}

fn readConfirmAnswer(exec_ctx: *ExecContext) !?[]const u8 {
    return switch (exec_ctx.input) {
        .stream => |in_file| try readConfirmLineFromStream(exec_ctx, in_file),
        .value => |value| blk: {
            const text = value.toString(exec_ctx.allocator) catch return ShellError.ReadFailed;
            defer exec_ctx.allocator.free(text);
            const first_line = if (std.mem.indexOfScalar(u8, text, '\n')) |idx| text[0..idx] else text;
            break :blk try exec_ctx.allocator.dupe(u8, first_line);
        },
        .none => try readConfirmLineFromStream(exec_ctx, std.Io.File.stdin()),
    };
}

fn parseConfirmDecision(raw: []const u8) ?bool {
    const trimmed = std.mem.trim(u8, raw, &std.ascii.whitespace);
    if (trimmed.len == 0) return false;

    var parts = std.mem.tokenizeAny(u8, trimmed, &std.ascii.whitespace);
    const token = parts.next() orelse return false;
    if (std.ascii.eqlIgnoreCase(token, "y") or std.ascii.eqlIgnoreCase(token, "yes")) return true;
    if (std.ascii.eqlIgnoreCase(token, "n") or std.ascii.eqlIgnoreCase(token, "no")) return false;
    return null;
}

fn writeConfirmPrompt(exec_ctx: *ExecContext, message: []const u8) void {
    var prompt_buf: [640]u8 = undefined;
    const prompt = std.fmt.bufPrint(&prompt_buf, "{s} [y/N]: ", .{message}) catch return;

    switch (exec_ctx.output) {
        .stream => |out| {
            helpers.fileAppendAll(exec_ctx.shell_ctx.io.*, out, prompt) catch {};
        },
        .capture, .none => {
            if (!@import("builtin").is_test) {
                exec_ctx.shell_ctx.print("{s}", .{prompt});
            }
        },
    }
}

/// Prompt for y/n confirmation and return boolean success/failure.
/// Intended to gate follow-up commands via `&&`.
pub fn confirm_builtin(exec_ctx: *ExecContext, args: [][]const u8) Value {
    if (exec_ctx.shell_ctx.exe_mode != .interactive) {
        return failBuiltin(exec_ctx, ShellError.Unsupported, "confirm: only supported in interactive mode", .{});
    }
    if (args.len < 2) {
        return failBuiltin(exec_ctx, ShellError.MissingArgument, "confirm: missing confirmation message", .{});
    }

    const message = std.mem.join(exec_ctx.allocator, " ", args[1..]) catch return Value{ .err = ShellError.AllocFailed };
    defer exec_ctx.allocator.free(message);

    var attempts: usize = 0;
    while (attempts < 3) : (attempts += 1) {
        writeConfirmPrompt(exec_ctx, message);

        const answer_opt = readConfirmAnswer(exec_ctx) catch {
            return failBuiltin(exec_ctx, ShellError.ReadFailed, "confirm: failed reading user input", .{});
        };
        if (answer_opt == null) {
            return Value{ .boolean = false };
        }

        const answer = answer_opt.?;
        defer exec_ctx.allocator.free(answer);
        const decision = parseConfirmDecision(answer);
        if (decision != null) return Value{ .boolean = decision.? };

        emitBuiltinError(exec_ctx, "confirm: please answer y/yes or n/no", .{});

        // Value input cannot provide additional responses; abort deterministically.
        if (exec_ctx.input == .value) return Value{ .boolean = false };
    }

    return Value{ .boolean = false };
}

/// Builtin cd navigate command
pub fn cd(exec_ctx: *ExecContext, args: [][]const u8) Value {
    var previous_cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const previous_cwd_n = std.os.linux.getcwd(&previous_cwd_buf, previous_cwd_buf.len);
    const previous_cwd_end = std.mem.indexOfScalar(u8, &previous_cwd_buf, 0) orelse previous_cwd_n;
    const previous_cwd = previous_cwd_buf[0..previous_cwd_end];

    const path_token = if (args.len >= 2) args[1] else "";
    const path = if (path_token.len == 0) blk_home: {
        const home = exec_ctx.shell_ctx.env_map.get("HOME") orelse
            return failBuiltin(exec_ctx, ShellError.InvalidPath, "cd: HOME is not set", .{});
        if (home != .text or home.text.len == 0) {
            return failBuiltin(exec_ctx, ShellError.InvalidPath, "cd: HOME is not set", .{});
        }
        break :blk_home home.text;
    } else if (std.mem.eql(u8, path_token, "-")) blk: {
        const oldpwd = exec_ctx.shell_ctx.env_map.get("OLDPWD") orelse
            return failBuiltin(exec_ctx, ShellError.InvalidPath, "cd: OLDPWD is not set", .{});
        if (oldpwd != .text or oldpwd.text.len == 0) {
            return failBuiltin(exec_ctx, ShellError.InvalidPath, "cd: OLDPWD is not set", .{});
        }
        break :blk oldpwd.text;
    } else path_token;

    // null-terminate for the syscall
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch
        return failBuiltin(exec_ctx, ShellError.InvalidPath, "cd: invalid path '{s}'", .{path});

    const result = std.os.linux.chdir(path_z);
    if (result != 0) return failBuiltin(exec_ctx, ShellError.InvalidPath, "cd: cannot change directory to '{s}'", .{path});

    exec_ctx.shell_ctx.env_map.putShell("OLDPWD", .{ .text = previous_cwd }) catch
        return failBuiltin(exec_ctx, ShellError.InvalidPath, "cd: failed to update OLDPWD", .{});

    var new_cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const new_cwd_n = std.os.linux.getcwd(&new_cwd_buf, new_cwd_buf.len);
    const new_cwd_end = std.mem.indexOfScalar(u8, &new_cwd_buf, 0) orelse new_cwd_n;
    const new_cwd = new_cwd_buf[0..new_cwd_end];
    exec_ctx.shell_ctx.env_map.putShell("PWD", .{ .text = new_cwd }) catch
        return failBuiltin(exec_ctx, ShellError.InvalidPath, "cd: failed to update PWD", .{});

    if (std.mem.eql(u8, path_token, "-")) {
        return switch (exec_ctx.output) {
            .stream => |stdout| blk: {
                const line = std.fmt.allocPrint(exec_ctx.allocator, "{s}\n", .{new_cwd}) catch break :blk Value{ .err = ShellError.AllocFailed };
                defer exec_ctx.allocator.free(line);
                if (exec_ctx.append) {
                    helpers.fileAppendAll(exec_ctx.shell_ctx.io.*, stdout, line) catch break :blk Value{ .err = ShellError.WriteFailed };
                } else {
                    helpers.fileWriteAll(exec_ctx.shell_ctx.io.*, stdout, line) catch break :blk Value{ .err = ShellError.WriteFailed };
                }
                break :blk Value{ .void = {} };
            },
            .capture => Value{ .text = std.fmt.allocPrint(exec_ctx.allocator, "{s}\n", .{new_cwd}) catch return Value{ .err = ShellError.AllocFailed } },
            .none => Value{ .void = {} },
        };
    }

    return Value{ .void = {} };
}

/// Executes a source script using a loop of parseExecute for each provided line
pub fn source(exec_ctx: *ExecContext, args: [][]const u8) Value {
    if (args.len < 2) {
        return failBuiltin(exec_ctx, ShellError.MissingArgument, "source: missing script path", .{});
    }

    const script_path = args[1];
    const abs_path = helpers.expandPathToAbs(exec_ctx.shell_ctx, exec_ctx.allocator, script_path) catch
        return failBuiltin(exec_ctx, ShellError.BadPathName, "source: invalid path '{s}'", .{script_path});

    // Open file
    const file = helpers.getFileFromPath(exec_ctx.shell_ctx, exec_ctx.allocator, abs_path, .{ .write = false, .truncate = false, .pre_expanded = true }) catch |err|
        return switch (err) {
            else => failBuiltin(exec_ctx, ShellError.FileNotFound, "source: file not found '{s}'", .{script_path}),
        };
    defer file.close(exec_ctx.shell_ctx.io.*);

    // Read script file data
    const data = helpers.fileReadAll(exec_ctx.shell_ctx.io.*, exec_ctx.shell_ctx.allocator, file) catch
        return failBuiltin(exec_ctx, ShellError.ReadFailed, "source: failed to read '{s}'", .{script_path});
    defer exec_ctx.shell_ctx.allocator.free(data);

    // Use a new ArenaAllocator for the sourced script's execution
    var script_arena = std.heap.ArenaAllocator.init(exec_ctx.shell_ctx.allocator); // Use ctx.allocator as parent for this transient arena
    defer script_arena.deinit(); // Deinitialize when source command finishes
    const script_arena_alloc = script_arena.allocator();

    // Handle redirect or pipe
    const original_stdout = exec_ctx.shell_ctx.stdout;
    defer exec_ctx.shell_ctx.stdout = original_stdout;

    switch (exec_ctx.output) {
        .stream => |stdout| {
            exec_ctx.shell_ctx.stdout = stdout;
        },
        // TODO:
        .capture => {},
        .none => {},
    }

    // Execute the script with the complete content
    const exit_code = scripting.executeScriptWithExitCode(exec_ctx.shell_ctx, script_arena_alloc, data, script_path) catch
        return failBuiltin(exec_ctx, ShellError.ScriptFailed, "source: script execution failed '{s}'", .{script_path});
    exec_ctx.shell_ctx.last_exit_code = exit_code;

    if (exit_code != 0) {
        exec_ctx.shell_ctx.print("{s}: script exited with code {d}\n", .{ script_path, exit_code });
    }

    return Value{ .void = {} };
}

fn extractQuotedToken(message: []const u8) ?[]const u8 {
    const first = std.mem.indexOfScalar(u8, message, '\'') orelse return null;
    if (first + 1 >= message.len) return null;
    const rest = message[first + 1 ..];
    const second_rel = std.mem.indexOfScalar(u8, rest, '\'') orelse return null;
    const token = rest[0..second_rel];
    if (token.len == 0) return null;
    return token;
}

fn extractQuotedTokenAfter(message: []const u8, needle: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, message, needle) orelse return null;
    const from = start + needle.len;
    if (from >= message.len) return null;
    const rest = message[from..];
    const end_rel = std.mem.indexOfScalar(u8, rest, '\'') orelse return null;
    const token = rest[0..end_rel];
    if (token.len == 0) return null;
    return token;
}

fn compactLintToken(raw_token: []const u8) ?[]const u8 {
    var token = std.mem.trim(u8, raw_token, &std.ascii.whitespace);
    if (token.len == 0) return null;

    if (std.mem.indexOfAny(u8, token, "/\\") != null) {
        token = std.fs.path.basename(token);
        if (token.len == 0) return null;
    }

    if (std.mem.indexOfAny(u8, token, &std.ascii.whitespace)) |ws_idx| {
        if (ws_idx == 0) return null;
        token = token[0..ws_idx];
    }

    return token;
}

fn lintIssueToken(issue_type: []const u8, message: []const u8) []const u8 {
    if (std.mem.indexOf(u8, message, "missing 'fi'") != null) return "if";
    if (std.mem.indexOf(u8, message, "unterminated if")) |_| return "if";
    if (std.mem.indexOf(u8, message, "unterminated for")) |_| return "for";
    if (std.mem.indexOf(u8, message, "unterminated while")) |_| return "while";

    if (std.mem.indexOf(u8, message, "script path must end with .sh") != null) return ".sh";

    if (extractQuotedTokenAfter(message, "got '")) |got_raw| {
        if (compactLintToken(got_raw)) |got| return got;
    }
    if (extractQuotedToken(message)) |quoted_raw| {
        if (compactLintToken(quoted_raw)) |quoted| return quoted;
    }

    return if (std.mem.eql(u8, issue_type, "TypeMismatch")) "value" else "syntax";
}

fn lintIssueType(message: []const u8) []const u8 {
    return if (std.mem.indexOf(u8, message, "expected type") != null)
        "TypeMismatch"
    else
        "InvalidSyntax";
}

fn emitLintIssues(exec_ctx: *ExecContext, script_path: []const u8, issues: []const scripting.ScriptLintIssue) void {
    const file_name = std.fs.path.basename(script_path);
    for (issues) |issue| {
        const issue_type = lintIssueType(issue.message);
        const token = lintIssueToken(issue_type, issue.message);
        const line = std.fmt.allocPrint(exec_ctx.allocator, "{s} {d}:{d} {s} {s}\n", .{
            file_name,
            issue.line,
            issue.column,
            issue_type,
            token,
        }) catch continue;
        defer exec_ctx.allocator.free(line);
        helpers.fileAppendAll(exec_ctx.shell_ctx.io.*, exec_ctx.shell_ctx.stdout, line) catch {};
    }
}

pub fn lint_builtin(exec_ctx: *ExecContext, args: [][]const u8) Value {
    if (args.len < 2) {
        return failBuiltin(exec_ctx, ShellError.MissingArgument, "lint: missing script path", .{});
    }

    const script_path = args[1];
    var script_arena = std.heap.ArenaAllocator.init(exec_ctx.shell_ctx.allocator);
    defer script_arena.deinit();
    const script_arena_alloc = script_arena.allocator();

    var issues = std.ArrayList(scripting.ScriptLintIssue).initCapacity(script_arena_alloc, 8) catch
        return Value{ .err = ShellError.AllocFailed };
    defer issues.deinit(script_arena_alloc);

    if (!std.mem.endsWith(u8, script_path, ".sh")) {
        issues.append(script_arena_alloc, .{ .line = 1, .column = 1, .message = "script path must end with .sh" }) catch
            return Value{ .err = ShellError.AllocFailed };
        emitLintIssues(exec_ctx, script_path, issues.items);
        return Value{ .boolean = false };
    }

    const abs_path = helpers.expandPathToAbs(exec_ctx.shell_ctx, script_arena_alloc, script_path) catch
        return failBuiltin(exec_ctx, ShellError.BadPathName, "lint: invalid path '{s}'", .{script_path});

    const file = helpers.getFileFromPath(exec_ctx.shell_ctx, script_arena_alloc, abs_path, .{
        .write = false,
        .truncate = false,
        .pre_expanded = true,
    }) catch |err| return switch (err) {
        else => failBuiltin(exec_ctx, ShellError.FileNotFound, "lint: file not found '{s}'", .{script_path}),
    };
    defer file.close(exec_ctx.shell_ctx.io.*);

    const data = helpers.fileReadAll(exec_ctx.shell_ctx.io.*, script_arena_alloc, file) catch
        return failBuiltin(exec_ctx, ShellError.ReadFailed, "lint: failed to read '{s}'", .{script_path});

    scripting.lintScript(exec_ctx.shell_ctx, script_arena_alloc, data, script_path, &issues) catch |err|
        return failBuiltin(exec_ctx, ShellError.ScriptFailed, "lint: internal lint failure ({s})", .{@errorName(err)});

    if (issues.items.len > 0) {
        emitLintIssues(exec_ctx, script_path, issues.items);
        return Value{ .boolean = false };
    }

    exec_ctx.shell_ctx.print("lint: pass: {s}\n", .{std.fs.path.basename(script_path)});
    return Value{ .boolean = true };
}

//
// ---- Output only builtins, may take args but no expected input
//

/// Builtin echo command, repeats text to stdout fd
pub fn echo(exec_ctx: *ExecContext, args: [][]const u8) Value {
    if (exec_ctx.output == .none) return Value{ .err = ShellError.NoOutputRequired };

    // Check for -n flag
    var start: usize = 1;
    var newline = true;
    if (args.len > 1 and std.mem.eql(u8, args[1], "-n")) {
        newline = false;
        start = 2;
    }

    const text = if (args.len < 2)
        ""
    else
        std.mem.join(exec_ctx.allocator, " ", args[start..]) catch return Value{ .err = ShellError.AllocFailed };

    //std.debug.print("echo text: {s}, output: {any}\n", .{ text, exec_ctx.output });
    switch (exec_ctx.output) {
        .stream => |stdout| {
            if (exec_ctx.append) {
                helpers.fileAppendAll(exec_ctx.shell_ctx.io.*, stdout, text) catch return Value{ .err = ShellError.WriteFailed };
                helpers.fileAppendAll(exec_ctx.shell_ctx.io.*, stdout, "\n") catch return Value{ .err = ShellError.WriteFailed };
            } else {
                helpers.fileWriteAll(exec_ctx.shell_ctx.io.*, stdout, text) catch return Value{ .err = ShellError.WriteFailed };
                helpers.fileWriteAll(exec_ctx.shell_ctx.io.*, stdout, "\n") catch return Value{ .err = ShellError.WriteFailed };
            }
            return Value{ .void = {} };
        },
        .capture => {
            // For capture, append newline into the text value so caller doesn't need to
            if (!newline) return Value{ .text = text };
            const with_newline = std.fmt.allocPrint(exec_ctx.allocator, "{s}\n", .{text}) catch
                return Value{ .err = ShellError.AllocFailed };
            return Value{ .text = with_newline };
        },
        .none => {
            return Value{ .void = {} };
        },
    }
}

/// Builtin log command, wraps std.log with level + message arguments
pub fn log_builtin(exec_ctx: *ExecContext, args: [][]const u8) Value {
    if (args.len < 2) {
        return failBuiltin(exec_ctx, ShellError.MissingArgument, "log: usage: log <debug|infor|warn|error> <text ...>", .{});
    }
    if (args.len < 3) {
        return failBuiltin(exec_ctx, ShellError.MissingArgument, "log: missing text argument", .{});
    }

    const level = args[1];
    const text = std.mem.join(exec_ctx.allocator, " ", args[2..]) catch return Value{ .err = ShellError.AllocFailed };
    defer exec_ctx.allocator.free(text);

    if (std.mem.eql(u8, level, "debug")) {
        std.log.debug("{s}", .{text});
    } else if (std.mem.eql(u8, level, "info") or std.mem.eql(u8, level, "infor")) {
        std.log.info("{s}", .{text});
    } else if (std.mem.eql(u8, level, "warn")) {
        std.log.warn("{s}", .{text});
    } else if (std.mem.eql(u8, level, "error") or std.mem.eql(u8, level, "err")) {
        std.log.err("{s}", .{text});
    } else {
        return failBuiltin(exec_ctx, ShellError.InvalidArgument, "log: invalid log type '{s}'", .{level});
    }

    return Value{ .void = {} };
}

/// Builtin print type command
pub fn printType(exec_ctx: *ExecContext, args: [][]const u8) Value {
    if (exec_ctx.output == .none) return Value{ .err = ShellError.NoOutputRequired };
    if (args.len < 2) {
        return Value{ .err = ShellError.MissingArgument };
    }

    const search_cmd = args[1];
    var text: []const u8 = undefined;

    if (isBuiltinCmd(search_cmd)) {
        text = std.fmt.allocPrint(
            exec_ctx.allocator,
            "{s} is a shell builtin\n",
            .{search_cmd},
        ) catch return Value{ .err = ShellError.AllocFailed };
    } else if (exec_ctx.shell_ctx.findExe(search_cmd) catch return Value{ .err = ShellError.AllocFailed }) |path| {
        text = std.fmt.allocPrint(
            exec_ctx.allocator,
            "{s} is {s}\n",
            .{ search_cmd, path },
        ) catch return Value{ .err = ShellError.AllocFailed };
    } else {
        text = std.fmt.allocPrint(
            exec_ctx.allocator,
            "{s}: not found\n",
            .{search_cmd},
        ) catch return Value{ .err = ShellError.AllocFailed };
    }

    switch (exec_ctx.output) {
        .stream => |stdout| {
            if (exec_ctx.append) {
                helpers.fileAppendAll(exec_ctx.shell_ctx.io.*, stdout, text) catch return Value{ .err = ShellError.WriteFailed };
            } else {
                helpers.fileWriteAll(exec_ctx.shell_ctx.io.*, stdout, text) catch return Value{ .err = ShellError.WriteFailed };
            }
            return Value{ .void = {} };
        },
        .capture => {
            return Value{ .text = text };
        },
        .none => {
            return Value{ .void = {} };
        },
    }
}

fn putWhichField(allocator: Allocator, map: *Map, key: []const u8, value: []const u8) ShellError!void {
    try map.put(try allocator.dupe(u8, key), .{ .text = try allocator.dupe(u8, value) });
}

fn putBoolField(allocator: Allocator, map: *Map, key: []const u8, value: bool) ShellError!void {
    try map.put(try allocator.dupe(u8, key), .{ .boolean = value });
}

fn buildHelpSummaryValue(exec_ctx: *ExecContext) ShellError!Value {
    const allocator = exec_ctx.allocator;
    const exe_mode = exec_ctx.shell_ctx.exe_mode;
    const root = try allocator.create(Map);
    root.* = Map.init(allocator);
    errdefer {
        var root_value = Value{ .map = root };
        root_value.deinit(allocator);
    }

    var command_count: usize = 0;
    for (builtins) |name| {
        const tag = BuiltinCommand.fromString(name);
        if (exe_mode == .engine and !BuiltinCommand.allowedInEngine(tag)) continue;
        command_count += 1;
    }

    const command_names = try allocator.create(List);
    command_names.* = try List.initCapacity(allocator, command_count);
    var command_names_detached = false;
    errdefer if (!command_names_detached) {
        var command_names_value = Value{ .list = command_names };
        command_names_value.deinit(allocator);
    };
    for (builtins) |name| {
        const tag = BuiltinCommand.fromString(name);
        if (exe_mode == .engine and !BuiltinCommand.allowedInEngine(tag)) continue;
        try command_names.append(allocator, .{
            .text = try allocator.dupe(u8, name),
        });
    }
    try root.put(try allocator.dupe(u8, "commands"), .{ .list = command_names });
    command_names_detached = true;

    var meta_count: usize = 0;
    for (help_meta_commands) |meta_name| {
        if (isMetaCommandAvailableInMode(exe_mode, meta_name)) meta_count += 1;
    }

    const meta_names = try allocator.create(List);
    meta_names.* = try List.initCapacity(allocator, meta_count);
    var meta_names_detached = false;
    errdefer if (!meta_names_detached) {
        var meta_names_value = Value{ .list = meta_names };
        meta_names_value.deinit(allocator);
    };
    for (help_meta_commands) |meta_name| {
        if (!isMetaCommandAvailableInMode(exe_mode, meta_name)) continue;
        try meta_names.append(allocator, .{ .text = try allocator.dupe(u8, meta_name) });
    }
    try root.put(try allocator.dupe(u8, "meta_commands"), .{ .list = meta_names });
    meta_names_detached = true;

    const mode_text: []const u8 = switch (exec_ctx.shell_ctx.exe_mode) {
        .interactive => "interactive",
        .engine => "engine",
    };
    try putWhichField(allocator, root, "name", exec_ctx.shell_ctx.shell_name);
    try putWhichField(allocator, root, "version", exec_ctx.shell_ctx.shell_version);
    try putWhichField(allocator, root, "mode", mode_text);
    return .{ .map = root };
}

fn buildWhichEntry(exec_ctx: *ExecContext, query: []const u8) ShellError!Value {
    const map = exec_ctx.allocator.create(Map) catch return ShellError.AllocFailed;
    map.* = Map.init(exec_ctx.allocator);
    try putWhichField(exec_ctx.allocator, map, "query", query);

    if (exec_ctx.shell_ctx.resolveAlias(query)) |alias_target| {
        try putWhichField(exec_ctx.allocator, map, "kind", "alias");
        try putWhichField(exec_ctx.allocator, map, "target", alias_target);
        return .{ .map = map };
    }
    if (isBuiltinCmd(query)) {
        try putWhichField(exec_ctx.allocator, map, "kind", "builtin");
        try putWhichField(exec_ctx.allocator, map, "target", query);
        return .{ .map = map };
    }
    const can_resolve_external = exec_ctx.shell_ctx.exe_mode == .engine or exec_ctx.shell_ctx.exe_cache != null;
    if (can_resolve_external) {
        if (exec_ctx.shell_ctx.findExe(query) catch null) |path| {
            try putWhichField(exec_ctx.allocator, map, "kind", "external");
            try putWhichField(exec_ctx.allocator, map, "target", path);
            return .{ .map = map };
        }
    }

    try putWhichField(exec_ctx.allocator, map, "kind", "missing");
    try putWhichField(exec_ctx.allocator, map, "target", "");
    return .{ .map = map };
}

fn renderWhichText(exec_ctx: *ExecContext, entry: Value) ShellError![]const u8 {
    const row = if (entry == .map) entry.map else return ShellError.TypeMismatch;
    const query_val = row.get("query") orelse return ShellError.TypeMismatch;
    const kind_val = row.get("kind") orelse return ShellError.TypeMismatch;
    const target_val = row.get("target") orelse return ShellError.TypeMismatch;
    if (query_val != .text or kind_val != .text or target_val != .text) return ShellError.TypeMismatch;

    if (std.mem.eql(u8, kind_val.text, "alias")) {
        return std.fmt.allocPrint(exec_ctx.allocator, "{s}: alias -> {s}\n", .{ query_val.text, target_val.text }) catch ShellError.AllocFailed;
    }
    if (std.mem.eql(u8, kind_val.text, "builtin")) {
        return std.fmt.allocPrint(exec_ctx.allocator, "{s}: builtin\n", .{query_val.text}) catch ShellError.AllocFailed;
    }
    if (std.mem.eql(u8, kind_val.text, "external")) {
        return std.fmt.allocPrint(exec_ctx.allocator, "{s}: {s}\n", .{ query_val.text, target_val.text }) catch ShellError.AllocFailed;
    }
    return std.fmt.allocPrint(exec_ctx.allocator, "{s}: not found\n", .{query_val.text}) catch ShellError.AllocFailed;
}

pub fn which_builtin(exec_ctx: *ExecContext, args: [][]const u8) Value {
    var include_all = false;
    var idx: usize = 1;
    while (idx < args.len and args[idx].len > 0 and args[idx][0] == '-') : (idx += 1) {
        const flag = args[idx];
        if (std.mem.eql(u8, flag, "--all")) {
            include_all = true;
            continue;
        }
        return failBuiltin(exec_ctx, ShellError.InvalidArgument, "which: unknown flag '{s}'", .{flag});
    }

    if (idx >= args.len) {
        return failBuiltin(exec_ctx, ShellError.MissingArgument, "which: missing command argument", .{});
    }

    const queries = args[idx..];
    const list = exec_ctx.allocator.create(List) catch return Value{ .err = ShellError.AllocFailed };
    list.* = List.initCapacity(exec_ctx.allocator, queries.len) catch return Value{ .err = ShellError.AllocFailed };
    for (queries) |query| {
        if (!include_all) {
            const entry = buildWhichEntry(exec_ctx, query) catch |err| return Value{ .err = err };
            list.append(exec_ctx.allocator, entry) catch return Value{ .err = ShellError.AllocFailed };
            continue;
        }

        var matched_any = false;
        if (exec_ctx.shell_ctx.resolveAlias(query)) |alias_target| {
            const alias_map = exec_ctx.allocator.create(Map) catch return Value{ .err = ShellError.AllocFailed };
            alias_map.* = Map.init(exec_ctx.allocator);
            putWhichField(exec_ctx.allocator, alias_map, "query", query) catch |err| return Value{ .err = err };
            putWhichField(exec_ctx.allocator, alias_map, "kind", "alias") catch |err| return Value{ .err = err };
            putWhichField(exec_ctx.allocator, alias_map, "target", alias_target) catch |err| return Value{ .err = err };
            list.append(exec_ctx.allocator, .{ .map = alias_map }) catch return Value{ .err = ShellError.AllocFailed };
            matched_any = true;
        }
        if (isBuiltinCmd(query)) {
            const builtin_map = exec_ctx.allocator.create(Map) catch return Value{ .err = ShellError.AllocFailed };
            builtin_map.* = Map.init(exec_ctx.allocator);
            putWhichField(exec_ctx.allocator, builtin_map, "query", query) catch |err| return Value{ .err = err };
            putWhichField(exec_ctx.allocator, builtin_map, "kind", "builtin") catch |err| return Value{ .err = err };
            putWhichField(exec_ctx.allocator, builtin_map, "target", query) catch |err| return Value{ .err = err };
            list.append(exec_ctx.allocator, .{ .map = builtin_map }) catch return Value{ .err = ShellError.AllocFailed };
            matched_any = true;
        }
        const can_resolve_external = exec_ctx.shell_ctx.exe_mode == .engine or exec_ctx.shell_ctx.exe_cache != null;
        if (can_resolve_external) {
            if (exec_ctx.shell_ctx.findExe(query) catch null) |path| {
                const external_map = exec_ctx.allocator.create(Map) catch return Value{ .err = ShellError.AllocFailed };
                external_map.* = Map.init(exec_ctx.allocator);
                putWhichField(exec_ctx.allocator, external_map, "query", query) catch |err| return Value{ .err = err };
                putWhichField(exec_ctx.allocator, external_map, "kind", "external") catch |err| return Value{ .err = err };
                putWhichField(exec_ctx.allocator, external_map, "target", path) catch |err| return Value{ .err = err };
                list.append(exec_ctx.allocator, .{ .map = external_map }) catch return Value{ .err = ShellError.AllocFailed };
                matched_any = true;
            }
        }
        if (!matched_any) {
            const missing = buildWhichEntry(exec_ctx, query) catch |err| return Value{ .err = err };
            list.append(exec_ctx.allocator, missing) catch return Value{ .err = ShellError.AllocFailed };
        }
    }

    return switch (exec_ctx.output) {
        .capture => .{ .list = list },
        .stream => |stdout| blk: {
            var out = std.ArrayList(u8).initCapacity(exec_ctx.allocator, 128) catch break :blk Value{ .err = ShellError.AllocFailed };
            defer out.deinit(exec_ctx.allocator);
            for (list.items) |entry| {
                const line = renderWhichText(exec_ctx, entry) catch |err| break :blk Value{ .err = err };
                defer exec_ctx.allocator.free(line);
                out.appendSlice(exec_ctx.allocator, line) catch break :blk Value{ .err = ShellError.AllocFailed };
            }
            if (exec_ctx.append) {
                helpers.fileAppendAll(exec_ctx.shell_ctx.io.*, stdout, out.items) catch break :blk Value{ .err = ShellError.WriteFailed };
            } else {
                helpers.fileWriteAll(exec_ctx.shell_ctx.io.*, stdout, out.items) catch break :blk Value{ .err = ShellError.WriteFailed };
            }
            break :blk Value{ .void = {} };
        },
        .none => .{ .void = {} },
    };
}

/// Builtin pwd
pub fn pwd(exec_ctx: *ExecContext, args: [][]const u8) Value {
    if (exec_ctx.output == .none) return Value{ .err = ShellError.NoOutputRequired };
    _ = args;

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.os.linux.getcwd(&buf, buf.len);
    const cwd_len = std.mem.indexOfScalar(u8, &buf, 0) orelse cwd;
    const cwd_str = buf[0..cwd_len]; // trim null terminator
    const text = std.fmt.allocPrint(exec_ctx.allocator, "{s}\n", .{cwd_str}) catch return Value{ .err = ShellError.AllocFailed };

    switch (exec_ctx.output) {
        .stream => |stdout| {
            if (exec_ctx.append) {
                helpers.fileAppendAll(exec_ctx.shell_ctx.io.*, stdout, text) catch return Value{ .err = ShellError.WriteFailed };
            } else {
                helpers.fileWriteAll(exec_ctx.shell_ctx.io.*, stdout, text) catch return Value{ .err = ShellError.WriteFailed };
            }
            return Value{ .void = {} };
        },
        .capture => {
            return Value{ .text = text };
        },
        .none => {
            return Value{ .void = {} };
        },
    }
}

const HistoryQueryMode = enum { contains, prefix };

fn historyEntryMatches(entry: []const u8, query: []const u8, mode: HistoryQueryMode) bool {
    if (query.len == 0) return false;
    return switch (mode) {
        .contains => std.mem.indexOf(u8, entry, query) != null,
        .prefix => std.mem.startsWith(u8, entry, query),
    };
}

fn filterHistoryList(allocator: Allocator, input_list: *List, query: []const u8, mode: HistoryQueryMode) ShellError!*List {
    const out = allocator.create(List) catch return ShellError.AllocFailed;
    out.* = List.initCapacity(allocator, input_list.items.len) catch return ShellError.AllocFailed;

    for (input_list.items) |item| {
        if (item != .text) continue;
        if (!historyEntryMatches(item.text, query, mode)) continue;
        out.append(allocator, item) catch return ShellError.AllocFailed;
    }
    return out;
}

fn renderHistoryListText(allocator: Allocator, list: *List) ShellError![]const u8 {
    var out = std.ArrayList(u8).initCapacity(allocator, 128) catch return ShellError.AllocFailed;
    for (list.items, 1..) |item, idx| {
        if (item != .text) continue;
        const line = std.fmt.allocPrint(allocator, "{d}: {s}\n", .{ idx, item.text }) catch return ShellError.AllocFailed;
        defer allocator.free(line);
        out.appendSlice(allocator, line) catch return ShellError.AllocFailed;
    }
    return out.toOwnedSlice(allocator) catch return ShellError.AllocFailed;
}

fn reverseHistoryList(allocator: Allocator, list: *List) ShellError!*List {
    const out = allocator.create(List) catch return ShellError.AllocFailed;
    out.* = List.initCapacity(allocator, list.items.len) catch return ShellError.AllocFailed;

    var idx = list.items.len;
    while (idx > 0) {
        idx -= 1;
        out.append(allocator, list.items[idx]) catch return ShellError.AllocFailed;
    }
    return out;
}

fn uniqueHistoryList(allocator: Allocator, list: *List) ShellError!*List {
    const out = allocator.create(List) catch return ShellError.AllocFailed;
    out.* = List.initCapacity(allocator, list.items.len) catch return ShellError.AllocFailed;
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    for (list.items) |item| {
        if (item != .text) continue;
        if (seen.contains(item.text)) continue;
        seen.put(item.text, {}) catch return ShellError.AllocFailed;
        out.append(allocator, item) catch return ShellError.AllocFailed;
    }
    return out;
}

/// Builtin history
pub fn history(exec_ctx: *ExecContext, args: [][]const u8) Value {
    if (exec_ctx.shell_ctx.exe_mode == .engine) return failBuiltin(exec_ctx, ShellError.Unsupported, "history: unsupported in engine mode", .{});

    // Handle flag arguments
    if (args.len > 1) {
        const arg = args[1];

        if (std.mem.eql(u8, arg, "--contains") or std.mem.eql(u8, arg, "--prefix")) {
            if (args.len != 3) {
                return failBuiltin(exec_ctx, ShellError.MissingArgument, "history: {s} requires exactly one search term", .{arg});
            }
            const query = args[2];
            const mode: HistoryQueryMode = if (std.mem.eql(u8, arg, "--contains")) .contains else .prefix;

            const full_list = exec_ctx.shell_ctx.historyList(exec_ctx.allocator, null) catch
                return failBuiltin(exec_ctx, ShellError.WriteFailed, "history: failed to query history", .{});
            const filtered = filterHistoryList(exec_ctx.allocator, full_list, query, mode) catch |err|
                return failBuiltin(exec_ctx, err, "history: failed to filter history results", .{});

            return switch (exec_ctx.output) {
                .stream => |stdout| {
                    const output_text = renderHistoryListText(exec_ctx.allocator, filtered) catch
                        return Value{ .err = ShellError.WriteFailed };
                    if (exec_ctx.append) {
                        helpers.fileAppendAll(exec_ctx.shell_ctx.io.*, stdout, output_text) catch return Value{ .err = ShellError.WriteFailed };
                    } else {
                        helpers.fileWriteAll(exec_ctx.shell_ctx.io.*, stdout, output_text) catch return Value{ .err = ShellError.WriteFailed };
                    }
                    return Value{ .void = {} };
                },
                .capture => Value{ .list = filtered },
                .none => Value{ .void = {} },
            };
        }

        if (std.mem.eql(u8, arg, "--reverse")) {
            if (args.len > 3) {
                return failBuiltin(exec_ctx, ShellError.InvalidArgument, "history: --reverse accepts at most one numeric limit", .{});
            }
            const limit: ?u32 = if (args.len == 3)
                std.fmt.parseInt(u32, args[2], 10) catch
                    return failBuiltin(exec_ctx, ShellError.InvalidArgument, "history: invalid numeric limit '{s}'", .{args[2]})
            else
                null;

            const full_list = exec_ctx.shell_ctx.historyList(exec_ctx.allocator, limit) catch
                return failBuiltin(exec_ctx, ShellError.WriteFailed, "history: failed to query history", .{});
            const reversed = reverseHistoryList(exec_ctx.allocator, full_list) catch |err|
                return failBuiltin(exec_ctx, err, "history: failed to reverse history results", .{});

            return switch (exec_ctx.output) {
                .stream => |stdout| {
                    const output_text = renderHistoryListText(exec_ctx.allocator, reversed) catch
                        return Value{ .err = ShellError.WriteFailed };
                    if (exec_ctx.append) {
                        helpers.fileAppendAll(exec_ctx.shell_ctx.io.*, stdout, output_text) catch return Value{ .err = ShellError.WriteFailed };
                    } else {
                        helpers.fileWriteAll(exec_ctx.shell_ctx.io.*, stdout, output_text) catch return Value{ .err = ShellError.WriteFailed };
                    }
                    return Value{ .void = {} };
                },
                .capture => Value{ .list = reversed },
                .none => Value{ .void = {} },
            };
        }

        if (std.mem.eql(u8, arg, "--unique")) {
            if (args.len > 3) {
                return failBuiltin(exec_ctx, ShellError.InvalidArgument, "history: --unique accepts at most one numeric limit", .{});
            }
            const limit: ?u32 = if (args.len == 3)
                std.fmt.parseInt(u32, args[2], 10) catch
                    return failBuiltin(exec_ctx, ShellError.InvalidArgument, "history: invalid numeric limit '{s}'", .{args[2]})
            else
                null;

            const full_list = exec_ctx.shell_ctx.historyList(exec_ctx.allocator, limit) catch
                return failBuiltin(exec_ctx, ShellError.WriteFailed, "history: failed to query history", .{});
            const unique = uniqueHistoryList(exec_ctx.allocator, full_list) catch |err|
                return failBuiltin(exec_ctx, err, "history: failed to deduplicate history results", .{});

            return switch (exec_ctx.output) {
                .stream => |stdout| {
                    const output_text = renderHistoryListText(exec_ctx.allocator, unique) catch
                        return Value{ .err = ShellError.WriteFailed };
                    if (exec_ctx.append) {
                        helpers.fileAppendAll(exec_ctx.shell_ctx.io.*, stdout, output_text) catch return Value{ .err = ShellError.WriteFailed };
                    } else {
                        helpers.fileWriteAll(exec_ctx.shell_ctx.io.*, stdout, output_text) catch return Value{ .err = ShellError.WriteFailed };
                    }
                    return Value{ .void = {} };
                },
                .capture => Value{ .list = unique },
                .none => Value{ .void = {} },
            };
        }

        // flag
        if (arg[0] == '-') {
            if (args.len > 2) {
                const path = args[2];
                switch (arg[1]) {
                    'r' => {
                        exec_ctx.shell_ctx.historyImport(path) catch
                            return failBuiltin(exec_ctx, ShellError.FileNotFound, "history: cannot read history file '{s}'", .{path});
                    },
                    'w' => {
                        exec_ctx.shell_ctx.historyWrite(path, true) catch
                            return failBuiltin(exec_ctx, ShellError.FileNotFound, "history: cannot write history file '{s}'", .{path});
                    },
                    'a' => {
                        exec_ctx.shell_ctx.historyWrite(path, false) catch
                            return failBuiltin(exec_ctx, ShellError.WriteFailed, "history: failed to append history to '{s}'", .{path});
                    },
                    else => {
                        return failBuiltin(exec_ctx, ShellError.InvalidArgument, "history: invalid flag '{s}'", .{arg});
                    },
                }
            } else {
                return failBuiltin(exec_ctx, ShellError.InvalidArgument, "history: flag '{s}' requires a path argument", .{arg});
            }
        } else {
            // Numeric argument
            const n: ?u32 = std.fmt.parseInt(u32, arg, 10) catch null;

            switch (exec_ctx.output) {
                .stream => |stdout| {
                    const output_text = exec_ctx.shell_ctx.historyText(exec_ctx.allocator, n) catch
                        return Value{ .err = ShellError.WriteFailed };

                    if (exec_ctx.append) {
                        helpers.fileAppendAll(exec_ctx.shell_ctx.io.*, stdout, output_text) catch return Value{ .err = ShellError.WriteFailed };
                    } else {
                        helpers.fileWriteAll(exec_ctx.shell_ctx.io.*, stdout, output_text) catch return Value{ .err = ShellError.WriteFailed };
                    }
                    return Value{ .void = {} };
                },
                .capture => {
                    const list = exec_ctx.shell_ctx.historyList(exec_ctx.allocator, n) catch
                        return Value{ .err = ShellError.WriteFailed };
                    return Value{ .list = list };
                },
                .none => {
                    return Value{ .void = {} };
                },
            }
        }
    }

    switch (exec_ctx.output) {
        .stream => |stdout| {
            const output_text = exec_ctx.shell_ctx.historyText(exec_ctx.allocator, null) catch
                return Value{ .err = ShellError.WriteFailed };

            if (exec_ctx.append) {
                helpers.fileAppendAll(exec_ctx.shell_ctx.io.*, stdout, output_text) catch return Value{ .err = ShellError.WriteFailed };
            } else {
                helpers.fileWriteAll(exec_ctx.shell_ctx.io.*, stdout, output_text) catch return Value{ .err = ShellError.WriteFailed };
            }
            return Value{ .void = {} };
        },
        .capture => {
            const list = exec_ctx.shell_ctx.historyList(exec_ctx.allocator, null) catch
                return Value{ .err = ShellError.WriteFailed };
            return Value{ .list = list };
        },
        .none => {
            return Value{ .void = {} };
        },
    }
}

/// `jobs` builtin: return the jobs table as structured list data.
pub fn jobs(exec_ctx: *ExecContext, args: [][]const u8) Value {
    if (exec_ctx.shell_ctx.exe_mode == .engine) return Value{ .err = ShellError.Unsupported };

    // Refresh state before rendering so `jobs` reflects latest status in the same command.
    exec_ctx.shell_ctx.pollBackgroundJobs();

    if (args.len > 1 and std.mem.eql(u8, args[1], "-c")) {
        exec_ctx.shell_ctx.cleanFinishedJobs(false);
        return Value{ .void = {} };
    }

    const jobs_value = exec_ctx.shell_ctx.jobsValue(exec_ctx.allocator) catch
        return Value{ .err = ShellError.WriteFailed };
    const job_list = switch (jobs_value) {
        .list => |l| l,
        else => return Value{ .err = ShellError.TypeMismatch },
    };

    return switch (exec_ctx.output) {
        .stream => transforms.renderValue(exec_ctx, .{ .list = job_list }),
        .capture => Value{ .list = job_list },
        .none => Value{ .void = {} },
    };
}

/// Print all env variables as a map
pub fn env_builtin(exec_ctx: *ExecContext, args: [][]const u8) Value {
    _ = args;

    switch (exec_ctx.output) {
        .stream => |stdout| {
            const env_str = exec_ctx.shell_ctx.env_map.asOwnedMapString(exec_ctx.allocator) catch return Value{ .err = ShellError.AllocFailed };
            if (exec_ctx.append) {
                helpers.fileAppendAll(exec_ctx.shell_ctx.io.*, stdout, env_str) catch return Value{ .err = ShellError.WriteFailed };
            } else {
                helpers.fileWriteAll(exec_ctx.shell_ctx.io.*, stdout, env_str) catch return Value{ .err = ShellError.WriteFailed };
            }
            return Value{ .void = {} };
        },
        .capture => {
            // convert env_map from VarEntry to just Value
            const val_map = exec_ctx.shell_ctx.env_map.getExportedMap(exec_ctx.allocator) catch
                return Value{ .err = ShellError.AllocFailed };
            const map_ptr = exec_ctx.allocator.create(Map) catch return Value{ .err = ShellError.AllocFailed };
            map_ptr.* = val_map;
            return Value{ .map = map_ptr };
        },
        .none => {
            return Value{ .void = {} };
        },
    }
}

/// Print help information for using the shell
pub fn help(exec_ctx: *ExecContext, args: [][]const u8) Value {
    if (exec_ctx.output == .none) return Value{ .err = ShellError.NoOutputRequired };
    var want_all = false;
    var want_summary = false;
    var find_query: ?[]const u8 = null;
    var cmd_name: ?[]const u8 = null;

    var idx: usize = 1;
    while (idx < args.len) : (idx += 1) {
        const arg = args[idx];
        if (std.mem.eql(u8, arg, "--all")) {
            want_all = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--summary")) {
            want_summary = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--find")) {
            if (idx + 1 >= args.len) {
                return failBuiltin(exec_ctx, ShellError.MissingArgument, "help: --find requires a search term", .{});
            }
            if (find_query != null) {
                return failBuiltin(exec_ctx, ShellError.InvalidArgument, "help: --find can only be provided once", .{});
            }
            idx += 1;
            find_query = args[idx];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) {
            return failBuiltin(exec_ctx, ShellError.InvalidArgument, "help: unknown flag '{s}'", .{arg});
        }
        if (cmd_name != null) {
            return failBuiltin(exec_ctx, ShellError.InvalidArgument, "help: too many positional arguments", .{});
        }
        cmd_name = arg;
    }

    if (want_summary and cmd_name != null) {
        return failBuiltin(exec_ctx, ShellError.InvalidArgument, "help: --summary cannot be combined with a command name", .{});
    }
    if (want_all and cmd_name != null) {
        return failBuiltin(exec_ctx, ShellError.InvalidArgument, "help: cannot use command with --all", .{});
    }

    if (want_summary and !want_all and find_query == null) {
        const summary_value = buildHelpSummaryValue(exec_ctx) catch return Value{ .err = ShellError.AllocFailed };
        return switch (exec_ctx.output) {
            .capture => summary_value,
            .stream => |stdout| blk: {
                defer summary_value.deinit(exec_ctx.allocator);
                const mode_text: []const u8 = switch (exec_ctx.shell_ctx.exe_mode) {
                    .interactive => "interactive",
                    .engine => "engine",
                };
                var out = std.ArrayList(u8).initCapacity(exec_ctx.allocator, 512) catch break :blk Value{ .err = ShellError.AllocFailed };
                defer out.deinit(exec_ctx.allocator);
                out.appendSlice(exec_ctx.allocator, exec_ctx.shell_ctx.shell_name) catch break :blk Value{ .err = ShellError.AllocFailed };
                out.appendSlice(exec_ctx.allocator, " v") catch break :blk Value{ .err = ShellError.AllocFailed };
                out.appendSlice(exec_ctx.allocator, exec_ctx.shell_ctx.shell_version) catch break :blk Value{ .err = ShellError.AllocFailed };
                out.appendSlice(exec_ctx.allocator, "\nmode=") catch break :blk Value{ .err = ShellError.AllocFailed };
                out.appendSlice(exec_ctx.allocator, mode_text) catch break :blk Value{ .err = ShellError.AllocFailed };
                out.append(exec_ctx.allocator, '\n') catch break :blk Value{ .err = ShellError.AllocFailed };
                var visible_meta = std.ArrayList([]const u8).initCapacity(exec_ctx.allocator, help_meta_commands.len) catch break :blk Value{ .err = ShellError.AllocFailed };
                defer visible_meta.deinit(exec_ctx.allocator);
                for (help_meta_commands) |meta_name| {
                    if (!isMetaCommandAvailableInMode(exec_ctx.shell_ctx.exe_mode, meta_name)) continue;
                    visible_meta.append(exec_ctx.allocator, meta_name) catch break :blk Value{ .err = ShellError.AllocFailed };
                }
                appendWrappedCsvLine(exec_ctx.allocator, &out, "meta: ", "      ", visible_meta.items, 88) catch break :blk Value{ .err = ShellError.AllocFailed };
                out.appendSlice(exec_ctx.allocator, "commands:\n") catch break :blk Value{ .err = ShellError.AllocFailed };
                for (builtins) |name| {
                    const tag = BuiltinCommand.fromString(name);
                    if (exec_ctx.shell_ctx.exe_mode == .engine and !BuiltinCommand.allowedInEngine(tag)) continue;
                    out.appendSlice(exec_ctx.allocator, "  ") catch break :blk Value{ .err = ShellError.AllocFailed };
                    out.appendSlice(exec_ctx.allocator, name) catch break :blk Value{ .err = ShellError.AllocFailed };
                    out.append(exec_ctx.allocator, '\n') catch break :blk Value{ .err = ShellError.AllocFailed };
                }
                if (exec_ctx.append) {
                    helpers.fileAppendAll(exec_ctx.shell_ctx.io.*, stdout, out.items) catch break :blk Value{ .err = ShellError.WriteFailed };
                } else {
                    helpers.fileWriteAll(exec_ctx.shell_ctx.io.*, stdout, out.items) catch break :blk Value{ .err = ShellError.WriteFailed };
                }
                break :blk Value{ .void = {} };
            },
            .none => Value{ .void = {} },
        };
    }

    if (find_query) |query| {
        if (cmd_name != null) {
            return failBuiltin(exec_ctx, ShellError.InvalidArgument, "help: --find cannot be combined with a command name", .{});
        }
        const filtered = buildFilteredBuiltinHelpRecordsValue(exec_ctx.allocator, exec_ctx.shell_ctx.exe_mode, query) catch return Value{ .err = ShellError.AllocFailed };
        if (want_summary) {
            const summary = buildHelpSummaryValue(exec_ctx) catch return Value{ .err = ShellError.AllocFailed };
            const root = exec_ctx.allocator.create(Map) catch return Value{ .err = ShellError.AllocFailed };
            root.* = Map.init(exec_ctx.allocator);
            root.put(exec_ctx.allocator.dupe(u8, "summary") catch return Value{ .err = ShellError.AllocFailed }, summary) catch
                return Value{ .err = ShellError.AllocFailed };
            root.put(exec_ctx.allocator.dupe(u8, "commands") catch return Value{ .err = ShellError.AllocFailed }, filtered) catch
                return Value{ .err = ShellError.AllocFailed };
            return renderHelpStructuredValue(exec_ctx, .{ .map = root });
        }
        return renderHelpStructuredValue(exec_ctx, filtered);
    }

    if (cmd_name) |name| {
        const metadata = findBuiltinMetadata(exec_ctx.shell_ctx.exe_mode, name) orelse {
            if (findBuiltinMetadataAnyMode(name) != null) {
                const mode_text: []const u8 = switch (exec_ctx.shell_ctx.exe_mode) {
                    .interactive => "interactive",
                    .engine => "engine",
                };
                return failBuiltin(exec_ctx, ShellError.Unsupported, "help: command '{s}' is unavailable in {s} mode", .{ name, mode_text });
            }
            return failBuiltin(exec_ctx, ShellError.InvalidBuiltinCommand, "help: unknown command '{s}'", .{name});
        };
        const detail_structured = buildBuiltinHelpRecordValue(exec_ctx.allocator, metadata) catch return Value{ .err = ShellError.AllocFailed };
        if (exec_ctx.output == .capture) {
            return detail_structured;
        }
        defer detail_structured.deinit(exec_ctx.allocator);
        const detail = buildBuiltinDetailText(exec_ctx.allocator, metadata) catch return Value{ .err = ShellError.AllocFailed };

        return switch (exec_ctx.output) {
            .stream => |stdout| {
                if (exec_ctx.append) {
                    helpers.fileAppendAll(exec_ctx.shell_ctx.io.*, stdout, detail) catch return Value{ .err = ShellError.WriteFailed };
                } else {
                    helpers.fileWriteAll(exec_ctx.shell_ctx.io.*, stdout, detail) catch return Value{ .err = ShellError.WriteFailed };
                }
                return Value{ .void = {} };
            },
            .capture => Value{ .text = detail },
            .none => {
                return Value{ .void = {} };
            },
        };
    }

    if (want_all) {
        const all = buildAllBuiltinHelpRecordsValue(exec_ctx.allocator, exec_ctx.shell_ctx.exe_mode) catch return Value{ .err = ShellError.AllocFailed };
        if (want_summary) {
            const summary = buildHelpSummaryValue(exec_ctx) catch return Value{ .err = ShellError.AllocFailed };
            const root = exec_ctx.allocator.create(Map) catch return Value{ .err = ShellError.AllocFailed };
            root.* = Map.init(exec_ctx.allocator);
            root.put(exec_ctx.allocator.dupe(u8, "summary") catch return Value{ .err = ShellError.AllocFailed }, summary) catch
                return Value{ .err = ShellError.AllocFailed };
            root.put(exec_ctx.allocator.dupe(u8, "commands") catch return Value{ .err = ShellError.AllocFailed }, all) catch
                return Value{ .err = ShellError.AllocFailed };
            return renderHelpStructuredValue(exec_ctx, .{ .map = root });
        }
        return renderHelpStructuredValue(exec_ctx, all);
    }

    const help_message = buildHelpOverviewText(exec_ctx) catch return Value{ .err = ShellError.AllocFailed };

    switch (exec_ctx.output) {
        .stream => |stdout| {
            if (exec_ctx.append) {
                helpers.fileAppendAll(exec_ctx.shell_ctx.io.*, stdout, help_message) catch return Value{ .err = ShellError.WriteFailed };
            } else {
                helpers.fileWriteAll(exec_ctx.shell_ctx.io.*, stdout, help_message) catch return Value{ .err = ShellError.WriteFailed };
            }
            return Value{ .void = {} };
        },
        .capture => {
            return Value{ .text = help_message };
        },
        .none => {
            return Value{ .void = {} };
        },
    }
}

/// Display exitcode of last command
pub fn exitcode(exec_ctx: *ExecContext, args: [][]const u8) Value {
    _ = args; // exitcode doesn't use args
    const code = exec_ctx.shell_ctx.last_exit_code;

    switch (exec_ctx.output) {
        .stream => |stdout| {
            const text = std.fmt.allocPrint(exec_ctx.allocator, "{d}\n", .{exec_ctx.shell_ctx.last_exit_code}) catch return Value{ .err = ShellError.AllocFailed };
            if (exec_ctx.append) {
                helpers.fileAppendAll(exec_ctx.shell_ctx.io.*, stdout, text) catch return Value{ .err = ShellError.WriteFailed };
            } else {
                helpers.fileWriteAll(exec_ctx.shell_ctx.io.*, stdout, text) catch return Value{ .err = ShellError.WriteFailed };
            }
            return Value{ .void = {} };
        },
        .capture => {
            return Value{ .integer = @as(i64, code) };
        },
        .none => {
            return Value{ .void = {} };
        },
    }
}

//
// ---- Execution mode builtins --
//

fn emitStructuredBuiltinValue(exec_ctx: *ExecContext, value: Value) Value {
    return switch (exec_ctx.output) {
        .stream => transforms.renderValue(exec_ctx, value),
        .capture => value,
        .none => Value{ .void = {} },
    };
}

//
// ----- Control flow builtins, evaluate conditions or expressions
//

/// Test builtin for scripting assist, can be used with test <flag> <condition> or [ <flag> <condition> ]
/// Doesn't output result only used to set exit code for control flow logic.
pub fn test_builtin(exec_ctx: *ExecContext, args: [][]const u8) Value {
    // Handle [ ] syntax
    if (args.len < 3) {
        return failBuiltin(exec_ctx, ShellError.MissingArgument, "test: missing arguments", .{});
    }

    // Extract inner condition args
    const has_closing_bracket =
        std.mem.eql(u8, args[args.len - 1], "]");

    const arg_start: usize = 1;
    const arg_end: usize = if (has_closing_bracket) args.len - 1 else args.len;

    const test_args = args[arg_start..arg_end];

    var result: ?bool = null;

    // File tests: [ -f ./path/file]
    if (test_args.len == 2 and std.mem.eql(u8, test_args[0], "-f")) {
        const path = test_args[1];
        result = helpers.fileExists(exec_ctx.shell_ctx.io, path);
    }

    // Directory test: [ -d ./path/dir]
    if (test_args.len == 2 and std.mem.eql(u8, test_args[0], "-d")) {
        const path = test_args[1];
        result = helpers.dirExists(exec_ctx.shell_ctx, path);
    }

    // String equality: [ "$X" = "hello" ]
    if (test_args.len == 3 and std.mem.eql(u8, test_args[1], "=")) {
        result = std.mem.eql(u8, test_args[0], test_args[2]);
    }

    // String inequality: [ "$X" != "hello" ]
    if (test_args.len == 3 and std.mem.eql(u8, test_args[1], "!=")) {
        result = !std.mem.eql(u8, test_args[0], test_args[2]);
    }

    // Empty string: [ -z "" ]
    if (test_args.len == 2 and std.mem.eql(u8, test_args[0], "-z")) {
        result = (test_args[1].len == 0);
    }

    // Non-empty string: [ -n "$X" ]
    if (test_args.len == 2 and std.mem.eql(u8, test_args[0], "-n")) {
        result = (test_args[1].len > 0);
    }

    // Numeric comparisons (-eq, -ne, -gt, -lt, -ge, -le)
    if (test_args.len == 3) {
        const op = std.mem.trim(u8, test_args[1], " ");
        // Check if the operator is one of the supported numeric flags
        if (std.mem.eql(u8, op, "-eq") or std.mem.eql(u8, op, "-ne") or
            std.mem.eql(u8, op, "-gt") or std.mem.eql(u8, op, "-lt") or
            std.mem.eql(u8, op, "-ge") or std.mem.eql(u8, op, "-le"))
        {
            // Parse operands as 64-bit integers
            const lhs = std.fmt.parseInt(i64, test_args[0], 10) catch
                return failBuiltin(exec_ctx, ShellError.FailedIntegerConversion, "test: invalid integer '{s}'", .{test_args[0]});
            const rhs = std.fmt.parseInt(i64, test_args[2], 10) catch
                return failBuiltin(exec_ctx, ShellError.FailedIntegerConversion, "test: invalid integer '{s}'", .{test_args[2]});

            if (std.mem.eql(u8, op, "-eq")) {
                result = lhs == rhs;
            } else if (std.mem.eql(u8, op, "-ne")) {
                result = lhs != rhs;
            } else if (std.mem.eql(u8, op, "-gt")) {
                result = lhs > rhs;
            } else if (std.mem.eql(u8, op, "-lt")) {
                result = lhs < rhs;
            } else if (std.mem.eql(u8, op, "-ge")) {
                result = lhs >= rhs;
            } else if (std.mem.eql(u8, op, "-le")) {
                result = lhs <= rhs;
            }
        }
    }

    // Return bool result if matched test expression
    if (result) |res| {
        switch (exec_ctx.output) {
            .stream, .capture => {
                return Value{ .boolean = res };
            },
            .none => {
                return Value{ .void = {} };
            },
        }
    }

    // No match for expression
    return failBuiltin(exec_ctx, ShellError.InvalidTestExpression, "test: invalid test expression", .{});
}

/// Arithmetic expression evaluation (bash expr command)
/// Supports: +, -, *, stdout, /, %, <, >, <=, >=, =, !=
pub fn expr_builtin(exec_ctx: *ExecContext, args: [][]const u8) Value {
    if (args.len < 4) {
        return failBuiltin(exec_ctx, ShellError.MissingArgument, "expr: missing arguments", .{});
    }

    // Parse: expr NUM1 OPERATOR NUM2
    const left_str = args[1];
    const operator = args[2];
    const right_str = args[3];

    // Try to parse as integers
    const left = std.fmt.parseInt(i64, left_str, 10) catch {
        return failBuiltin(exec_ctx, ShellError.FailedIntegerConversion, "expr: invalid integer '{s}'", .{left_str});
    };

    const right = std.fmt.parseInt(i64, right_str, 10) catch {
        return failBuiltin(exec_ctx, ShellError.FailedIntegerConversion, "expr: invalid integer '{s}'", .{right_str});
    };

    // Perform operation
    const result: i64 = blk: {
        if (std.mem.eql(u8, operator, "+")) {
            break :blk left + right;
        } else if (std.mem.eql(u8, operator, "-")) {
            break :blk left - right;
        } else if (std.mem.eql(u8, operator, "*") or std.mem.eql(u8, operator, "\\*")) {
            break :blk left * right;
        } else if (std.mem.eql(u8, operator, "/")) {
            if (right == 0) {
                return failBuiltin(exec_ctx, ShellError.DivisionByZero, "expr: division by zero", .{});
            }
            break :blk @divTrunc(left, right);
        } else if (std.mem.eql(u8, operator, "%")) {
            if (right == 0) {
                return failBuiltin(exec_ctx, ShellError.DivisionByZero, "expr: modulo by zero", .{});
            }
            break :blk @mod(left, right);
        } else if (std.mem.eql(u8, operator, "<")) {
            break :blk if (left < right) 1 else 0;
        } else if (std.mem.eql(u8, operator, ">")) {
            break :blk if (left > right) 1 else 0;
        } else if (std.mem.eql(u8, operator, "<=")) {
            break :blk if (left <= right) 1 else 0;
        } else if (std.mem.eql(u8, operator, ">=")) {
            break :blk if (left >= right) 1 else 0;
        } else if (std.mem.eql(u8, operator, "=")) {
            break :blk if (left == right) 1 else 0;
        } else if (std.mem.eql(u8, operator, "!=")) {
            break :blk if (left != right) 1 else 0;
        } else {
            return failBuiltin(exec_ctx, ShellError.InvalidIntegerExpression, "expr: unsupported operator '{s}'", .{operator});
        }
    };

    switch (exec_ctx.output) {
        .stream => |stdout| {
            const text = std.fmt.allocPrint(exec_ctx.allocator, "{d}\n", .{result}) catch return Value{ .err = ShellError.AllocFailed };
            if (exec_ctx.append) {
                helpers.fileAppendAll(exec_ctx.shell_ctx.io.*, stdout, text) catch return Value{ .err = ShellError.WriteFailed };
            } else {
                helpers.fileWriteAll(exec_ctx.shell_ctx.io.*, stdout, text) catch return Value{ .err = ShellError.WriteFailed };
            }
            return Value{ .void = {} };
        },
        .capture => {
            // Return integer for programmatic use
            return Value{ .integer = result };
        },
        .none => {
            return Value{ .void = {} };
        },
    }
}

//
// ---- Input & Output builtins, apply data transformations, expected input and output
//

/// Builtin version of cat - reads files or stdin
pub fn read_builtin(exec_ctx: *ExecContext, args: [][]const u8) Value {
    const arena = exec_ctx.allocator;

    var output: []const u8 = &.{};

    // Input types
    switch (exec_ctx.input) {
        // Read from stdin stream
        .stream => |stdin| {
            output = if (exec_ctx.is_pipe)
                helpers.pipeReadAll(exec_ctx.shell_ctx.io.*, exec_ctx.allocator, stdin) catch
                    return failBuiltin(exec_ctx, ShellError.ReadFailed, "read: failed to read from input stream", .{})
            else
                helpers.fileReadAll(exec_ctx.shell_ctx.io.*, exec_ctx.allocator, stdin) catch
                    return failBuiltin(exec_ctx, ShellError.ReadFailed, "read: failed to read from input file", .{});
        },
        // Read from value
        .value => |v| {
            output = v.toString(arena) catch return Value{ .err = ShellError.AllocFailed };
        },
        // Try read from args file if provided
        .none => {
            if (args.len > 1) {
                // Read files
                for (args[1..]) |filename| {
                    const file = helpers.getFileFromPath(exec_ctx.shell_ctx, exec_ctx.allocator, filename, .{
                        .write = false,
                        .truncate = false,
                        .pre_expanded = false,
                    }) catch |err| return switch (err) {
                        else => failBuiltin(exec_ctx, ShellError.FileNotFound, "read: file not found '{s}'", .{filename}),
                    };
                    defer file.close(exec_ctx.shell_ctx.io.*);
                    output = helpers.fileReadAll(exec_ctx.shell_ctx.io.*, exec_ctx.allocator, file) catch
                        return failBuiltin(exec_ctx, ShellError.ReadFailed, "read: failed to read '{s}'", .{filename});
                }
            }
        },
    }

    // Output types
    switch (exec_ctx.output) {
        .stream => |stdout| {
            if (exec_ctx.append) {
                helpers.fileAppendAll(exec_ctx.shell_ctx.io.*, stdout, output) catch return Value{ .err = ShellError.WriteFailed };
            } else {
                helpers.fileWriteAll(exec_ctx.shell_ctx.io.*, stdout, output) catch return Value{ .err = ShellError.WriteFailed };
            }
            return Value{ .void = {} };
        },
        .capture => {
            return Value{ .text = output };
        },
        .none => {
            return Value{ .void = {} };
        },
    }
}

/// Builtin uppercase - convert to uppercase
pub fn uppercase(exec_ctx: *ExecContext, args: [][]const u8) Value {
    const arena = exec_ctx.allocator;
    const io = exec_ctx.shell_ctx.io.*;

    var output_buffer = std.ArrayList(u8).initCapacity(arena, 1024) catch return Value{ .err = ShellError.AllocFailed };

    switch (exec_ctx.input) {
        .stream => |stdin| {
            const data = if (exec_ctx.is_pipe)
                helpers.pipeReadAll(exec_ctx.shell_ctx.io.*, exec_ctx.allocator, stdin) catch
                    return failBuiltin(exec_ctx, ShellError.ReadFailed, "upper: failed to read from input stream", .{})
            else
                helpers.fileReadAll(exec_ctx.shell_ctx.io.*, exec_ctx.allocator, stdin) catch
                    return failBuiltin(exec_ctx, ShellError.ReadFailed, "upper: failed to read from input file", .{});

            for (data) |byte| {
                output_buffer.append(arena, std.ascii.toUpper(byte)) catch
                    return Value{ .err = ShellError.AllocFailed };
            }
        },
        .value => |v| {
            const text = v.toString(arena) catch return Value{ .err = ShellError.AllocFailed };
            for (text) |char| {
                output_buffer.append(arena, std.ascii.toUpper(char)) catch
                    return Value{ .err = ShellError.AllocFailed };
            }
        },
        .none => {
            if (args.len > 1) {
                for (args[1..]) |filename| {
                    const file = helpers.getFileFromPath(exec_ctx.shell_ctx, exec_ctx.allocator, filename, .{
                        .write = false,
                        .truncate = false,
                        .pre_expanded = false,
                    }) catch |err| return switch (err) {
                        else => failBuiltin(exec_ctx, ShellError.InvalidPath, "upper: invalid path '{s}'", .{filename}),
                    };
                    defer file.close(io);

                    const data = helpers.fileReadAll(io, arena, file) catch
                        return failBuiltin(exec_ctx, ShellError.ReadFailed, "upper: failed to read '{s}'", .{filename});
                    for (data) |byte| {
                        output_buffer.append(arena, std.ascii.toUpper(byte)) catch
                            return Value{ .err = ShellError.AllocFailed };
                    }
                }
            }
        },
    }

    switch (exec_ctx.output) {
        .stream => |stdout| {
            if (exec_ctx.append) {
                helpers.fileAppendAll(exec_ctx.shell_ctx.io.*, stdout, output_buffer.items) catch return Value{ .err = ShellError.WriteFailed };
                helpers.fileAppendAll(io, stdout, "\n") catch return Value{ .err = ShellError.WriteFailed };
            } else {
                helpers.fileWriteAll(exec_ctx.shell_ctx.io.*, stdout, output_buffer.items) catch return Value{ .err = ShellError.WriteFailed };
                helpers.fileWriteAll(io, stdout, "\n") catch return Value{ .err = ShellError.WriteFailed };
            }
            return Value{ .void = {} };
        },
        .capture => return Value{ .text = output_buffer.items },
        .none => return Value{ .void = {} },
    }
}

/// Encode or decode base64 input
pub fn b64(exec_ctx: *ExecContext, args: [][]const u8) Value {
    const io = exec_ctx.shell_ctx.io.*;
    const arena = exec_ctx.allocator;

    var input: []const u8 = undefined;

    switch (exec_ctx.input) {
        .stream => |stdin| {
            //std.debug.print("stream in, is pipe: {any}\n", .{exec_ctx.is_pipe});
            const input_raw = if (exec_ctx.is_pipe)
                helpers.pipeReadAll(exec_ctx.shell_ctx.io.*, exec_ctx.allocator, stdin) catch
                    return failBuiltin(exec_ctx, ShellError.ReadFailed, "b64: failed to read from input stream", .{})
            else
                helpers.fileReadAll(exec_ctx.shell_ctx.io.*, exec_ctx.allocator, stdin) catch
                    return failBuiltin(exec_ctx, ShellError.ReadFailed, "b64: failed to read from input file", .{});

            input = std.mem.trimEnd(u8, input_raw, " \n\t");
        },
        .value => |v| {
            const input_raw = v.toString(arena) catch return Value{ .err = ShellError.AllocFailed };
            input = std.mem.trimEnd(u8, input_raw, " \n\t");
        },
        .none => {
            // Note: args[1] is pattern, so files start at args[2]
            if (args.len > 2) {
                for (args[2..]) |filename| {
                    const file = helpers.getFileFromPath(exec_ctx.shell_ctx, exec_ctx.allocator, filename, .{
                        .write = false,
                        .truncate = false,
                        .pre_expanded = false,
                    }) catch |err| return switch (err) {
                        else => failBuiltin(exec_ctx, ShellError.InvalidPath, "b64: invalid path '{s}'", .{filename}),
                    };
                    defer file.close(io);

                    const input_raw = helpers.fileReadAll(io, arena, file) catch
                        return failBuiltin(exec_ctx, ShellError.ReadFailed, "b64: failed to read '{s}'", .{filename});

                    input = std.mem.trimEnd(u8, input_raw, " \n\t");
                }
            } else {
                std.log.warn("b64: received empty input arguement\n", .{});
                input = "";
            }
        },
    }

    // Smart detection for encode/decode
    const base64 = Base64.init();
    const decode = if (input.len > 0 and input[input.len - 1] == '=') true else false;
    const output = if (decode)
        base64.decode(arena, input) catch
            return failBuiltin(exec_ctx, ShellError.Base64ConversionFailed, "b64: failed to decode input", .{})
    else
        base64.encode(arena, input) catch
            return failBuiltin(exec_ctx, ShellError.Base64ConversionFailed, "b64: failed to encode input", .{});

    switch (exec_ctx.output) {
        .stream => |stdout| {
            if (exec_ctx.append) {
                helpers.fileAppendAll(exec_ctx.shell_ctx.io.*, stdout, output) catch return Value{ .err = ShellError.WriteFailed };
            } else {
                helpers.fileWriteAll(exec_ctx.shell_ctx.io.*, stdout, output) catch return Value{ .err = ShellError.WriteFailed };
            }
            return Value{ .void = {} };
        },
        .capture => {
            return Value{ .text = output };
        },
        .none => {
            return Value{ .void = {} };
        },
    }
}

//
// -- Job control builtins, modifies or controls fg and bg threads
//

/// Resumes job in shell foreground
pub fn executeFg(exec_ctx: *ExecContext, args: [][]const u8) Value {
    if (exec_ctx.shell_ctx.exe_mode == .engine) return failBuiltin(exec_ctx, ShellError.Unsupported, "fg: unsupported in engine mode", .{});

    const job_id = if (args.len > 1) blk: {
        const id_str = args[1];
        const clean_str = if (std.mem.startsWith(u8, id_str, "%"))
            id_str[1..]
        else
            id_str;
        const id = std.fmt.parseInt(u32, clean_str, 10) catch {
            return failBuiltin(exec_ctx, ShellError.JobNotFound, "fg: invalid job id '{s}'", .{id_str});
        };
        break :blk id;
    } else blk: {
        const jobs_value = exec_ctx.shell_ctx.jobsValue(exec_ctx.allocator) catch
            return failBuiltin(exec_ctx, ShellError.JobNotFound, "fg: no current job", .{});
        const jobs_list = switch (jobs_value) {
            .list => |list| list,
            else => return failBuiltin(exec_ctx, ShellError.JobNotFound, "fg: no current job", .{}),
        };

        var latest_stopped: u32 = 0;
        var latest_running: u32 = 0;
        var found_stopped = false;
        var found_running = false;
        for (jobs_list.items) |entry| {
            const entry_map = switch (entry) {
                .map => |m| m,
                else => continue,
            };
            const id_val = entry_map.get("id") orelse continue;
            const state_val = entry_map.get("state") orelse continue;
            if (id_val != .integer or state_val != .text) continue;
            const id: u32 = @intCast(id_val.integer);

            if (std.mem.eql(u8, state_val.text, "stopped")) {
                if (!found_stopped or id > latest_stopped) {
                    latest_stopped = id;
                    found_stopped = true;
                }
            } else if (std.mem.eql(u8, state_val.text, "running")) {
                if (!found_running or id > latest_running) {
                    latest_running = id;
                    found_running = true;
                }
            }
        }

        const id = if (found_stopped) latest_stopped else if (found_running) latest_running else {
            return failBuiltin(exec_ctx, ShellError.JobNotFound, "fg: no current job", .{});
        };
        break :blk id;
    };

    exec_ctx.shell_ctx.foregroundJob(job_id) catch |err| {
        errors.report(err, "move job to foreground", null);
        return Value{ .err = ShellError.JobSpawnFailed };
    };

    return Value{ .void = {} };
}

/// Resumes job as a background process
pub fn executeBg(exec_ctx: *ExecContext, args: [][]const u8) Value {
    if (exec_ctx.shell_ctx.exe_mode == .engine) return failBuiltin(exec_ctx, ShellError.Unsupported, "bg: unsupported in engine mode", .{});

    // Default to most recent stopped job if no argument
    const job_id = if (args.len > 1) blk: {
        const id_str = args[1];
        // Handle both "1" and "%1" format
        const clean_str = if (std.mem.startsWith(u8, id_str, "%"))
            id_str[1..]
        else
            id_str;

        const id = std.fmt.parseInt(u32, clean_str, 10) catch {
            return failBuiltin(exec_ctx, ShellError.JobNotFound, "bg: invalid job id '{s}'", .{id_str});
        };
        break :blk id;
    } else blk: {
        const jobs_value = exec_ctx.shell_ctx.jobsValue(exec_ctx.allocator) catch
            return failBuiltin(exec_ctx, ShellError.JobNotFound, "bg: no current job", .{});
        const jobs_list = switch (jobs_value) {
            .list => |list| list,
            else => return failBuiltin(exec_ctx, ShellError.JobNotFound, "bg: no current job", .{}),
        };

        var latest_id: u32 = 0;
        var found = false;
        for (jobs_list.items) |entry| {
            const entry_map = switch (entry) {
                .map => |m| m,
                else => continue,
            };
            const id_val = entry_map.get("id") orelse continue;
            const state_val = entry_map.get("state") orelse continue;
            if (id_val != .integer or state_val != .text) continue;
            if (std.mem.eql(u8, state_val.text, "stopped")) {
                const id: u32 = @intCast(id_val.integer);
                if (!found or id > latest_id) {
                    latest_id = id;
                    found = true;
                }
            }
        }
        if (found) {
            break :blk latest_id;
        } else {
            return failBuiltin(exec_ctx, ShellError.JobNotFound, "bg: no current job", .{});
        }
    };

    exec_ctx.shell_ctx.backgroundJob(job_id) catch |err| {
        errors.report(err, "resume job in background", null);
        return Value{ .err = ShellError.JobSpawnFailed };
    };

    return Value{ .void = {} };
}

/// Kill a background process by id reference
pub fn kill(exec_ctx: *ExecContext, args: [][]const u8) Value {
    if (exec_ctx.shell_ctx.exe_mode == .engine) return failBuiltin(exec_ctx, ShellError.Unsupported, "kill: unsupported in engine mode", .{});

    if (args.len < 2) {
        return failBuiltin(exec_ctx, ShellError.MissingArgument, "kill: missing job id", .{});
    }
    const job_id = std.fmt.parseInt(u32, args[1], 10) catch
        return failBuiltin(exec_ctx, ShellError.InvalidIntegerExpression, "kill: invalid job id '{s}'", .{args[1]});
    exec_ctx.shell_ctx.killJob(job_id) catch
        return failBuiltin(exec_ctx, ShellError.JobNotFound, "kill: job not found '{s}'", .{args[1]});

    const text = std.fmt.allocPrint(exec_ctx.allocator, "Killed job [{d}]\n", .{job_id}) catch return Value{ .err = ShellError.AllocFailed };

    switch (exec_ctx.output) {
        .stream => |stdout| {
            if (exec_ctx.append) {
                helpers.fileAppendAll(exec_ctx.shell_ctx.io.*, stdout, text) catch return Value{ .err = ShellError.WriteFailed };
            } else {
                helpers.fileWriteAll(exec_ctx.shell_ctx.io.*, stdout, text) catch return Value{ .err = ShellError.WriteFailed };
            }
            return Value{ .void = {} };
        },
        .capture => {
            return Value{ .text = text };
        },
        .none => {
            return Value{ .void = {} };
        },
    }
}

//
// ---- Transform builtins, take structured data from builtin Value and filter/transform the output
//

fn returnTransformList(exec_ctx: *ExecContext, list: *List) Value {
    return switch (exec_ctx.output) {
        .stream => {
            const rendered = transforms.renderValue(exec_ctx, .{ .list = list });
            if (rendered == .err) return rendered;
            return Value{ .void = {} };
        },
        .capture => Value{ .list = list },
        .none => Value{ .void = {} },
    };
}

/// Select specific map fields from list(map) input
pub fn select(exec_ctx: *ExecContext, args: [][]const u8) Value {
    if (args.len < 2) {
        return failBuiltin(exec_ctx, ShellError.MissingArgument, "select: missing field arguments", .{});
    }

    const input_list = switch (exec_ctx.input) {
        .value => |v| switch (v) {
            .list => |l| l,
            else => return failBuiltin(exec_ctx, ShellError.TypeMismatch, "select: expected list input value", .{}),
        },
        else => return failBuiltin(exec_ctx, ShellError.TypeMismatch, "select: missing list input", .{}),
    };

    const selected = transforms.selectFields(exec_ctx.allocator, input_list, args[1..]) catch |err| switch (err) {
        ShellError.InvalidArgument => return failBuiltin(exec_ctx, err, "select: invalid field or missing field in input", .{}),
        ShellError.TypeMismatch => return failBuiltin(exec_ctx, err, "select: expected list(map) input", .{}),
        else => return Value{ .err = ShellError.AllocFailed },
    };

    return returnTransformList(exec_ctx, selected);
}

/// Sort list input by value or by map field
pub fn sort_builtin(exec_ctx: *ExecContext, args: [][]const u8) Value {
    const field: ?[]const u8 = if (args.len > 1) args[1] else null;
    if (args.len > 2) {
        return failBuiltin(exec_ctx, ShellError.TooManyArgs, "sort: too many arguments", .{});
    }

    const input_list = switch (exec_ctx.input) {
        .value => |v| switch (v) {
            .list => |l| l,
            else => return failBuiltin(exec_ctx, ShellError.TypeMismatch, "sort: expected list input value", .{}),
        },
        else => return failBuiltin(exec_ctx, ShellError.TypeMismatch, "sort: missing list input", .{}),
    };

    const sorted = transforms.sortValues(exec_ctx.allocator, input_list, field) catch |err| switch (err) {
        ShellError.MissingArgument => return failBuiltin(exec_ctx, err, "sort: missing field for list(map) input", .{}),
        ShellError.InvalidArgument => return failBuiltin(exec_ctx, err, "sort: invalid field argument", .{}),
        ShellError.TypeMismatch => return failBuiltin(exec_ctx, err, "sort: unsupported list element type or mixed types", .{}),
        else => return Value{ .err = ShellError.AllocFailed },
    };

    return returnTransformList(exec_ctx, sorted);
}

/// Count length of list or text input
pub fn count(exec_ctx: *ExecContext, args: [][]const u8) Value {
    if (args.len > 1) {
        return failBuiltin(exec_ctx, ShellError.TooManyArgs, "count: too many arguments", .{});
    }

    const input_value = switch (exec_ctx.input) {
        .value => |v| v,
        else => return failBuiltin(exec_ctx, ShellError.TypeMismatch, "count: requires list or text input value", .{}),
    };

    const length = transforms.lengthOfValue(input_value) catch
        return failBuiltin(exec_ctx, ShellError.TypeMismatch, "count: supports only list or text input", .{});

    switch (exec_ctx.output) {
        .stream => |stdout| {
            const text = std.fmt.allocPrint(exec_ctx.allocator, "{d}\n", .{length}) catch return Value{ .err = ShellError.AllocFailed };
            if (exec_ctx.append) {
                helpers.fileAppendAll(exec_ctx.shell_ctx.io.*, stdout, text) catch return Value{ .err = ShellError.WriteFailed };
            } else {
                helpers.fileWriteAll(exec_ctx.shell_ctx.io.*, stdout, text) catch return Value{ .err = ShellError.WriteFailed };
            }
            return Value{ .void = {} };
        },
        .capture => return Value{ .integer = length },
        .none => return Value{ .void = {} },
    }
}

/// Filter input and only return Values meeting a condition
pub fn where(exec_ctx: *ExecContext, args: [][]const u8) Value {
    if (args.len < 2) {
        return failBuiltin(exec_ctx, ShellError.InvalidArgument, "where: invalid predicate", .{});
    }

    // Get input - must be a list from previous pipeline stage
    const input_list = switch (exec_ctx.input) {
        .value => |v| switch (v) {
            .list => |l| l,
            else => return failBuiltin(exec_ctx, ShellError.TypeMismatch, "where: expected list input value", .{}),
        },
        else => return failBuiltin(exec_ctx, ShellError.TypeMismatch, "where: missing list input", .{}),
    };

    const result = stream_ops.filterValues(exec_ctx.allocator, input_list, args[1..]) catch |err| switch (err) {
        ShellError.MissingArgument, ShellError.InvalidArgument => {
            return failBuiltin(exec_ctx, ShellError.InvalidArgument, "where: invalid predicate", .{});
        },
        ShellError.TypeMismatch => {
            return failBuiltin(exec_ctx, ShellError.TypeMismatch, "where: expected list input value", .{});
        },
        else => return Value{ .err = err },
    };

    return returnTransformList(exec_ctx, result);
}

//
// ----- TESTING ----- //
//

const testing = std.testing;
const ShellCtx = @import("context.zig").ShellCtx;

// MOCKS
fn makeTestCtx(arena: std.mem.Allocator) !ExecContext {
    // Minimal shell context - adjust fields to match your actual ShellCtx
    const shell_ctx = arena.create(ShellCtx) catch unreachable;
    shell_ctx.* = try ShellCtx.initTest(arena);

    return ExecContext{
        .shell_ctx = shell_ctx,
        .allocator = arena,
        .input = .none,
        .output = .capture,
        .err = .none,
    };
}

fn makeTextList(arena: std.mem.Allocator, items: []const []const u8) *List {
    const list = arena.create(List) catch unreachable;
    list.* = List.initCapacity(arena, items.len) catch unreachable;
    for (items) |s| {
        list.append(arena, Value{ .text = arena.dupe(u8, s) catch unreachable }) catch unreachable;
    }
    return list;
}

fn makeMapList(arena: std.mem.Allocator, rows: []const struct { key: []const u8, val: []const u8 }) *List {
    const list = arena.create(List) catch unreachable;
    list.* = List.initCapacity(arena, rows.len) catch unreachable;
    for (rows) |row| {
        const map = arena.create(Map) catch unreachable;
        map.* = Map.init(arena);
        map.put(arena.dupe(u8, row.key) catch unreachable, Value{ .text = arena.dupe(u8, row.val) catch unreachable }) catch unreachable;
        list.append(arena, Value{ .map = map }) catch unreachable;
    }
    return list;
}

// ---- Tests ----

test "builtins functions" {
    // isBuiltinCmd
    try testing.expect(isBuiltinCmd("exit"));
    try testing.expect(isBuiltinCmd("echo"));
    try testing.expect(isBuiltinCmd("log"));
    try testing.expect(isBuiltinCmd("which"));
    try testing.expect(isBuiltinCmd("help"));
    try testing.expect(isBuiltinCmd("confirm"));
    try testing.expect(isBuiltinCmd("alias"));
    try testing.expect(isBuiltinCmd("unalias"));
    try testing.expect(!isBuiltinCmd("cat"));
    try testing.expect(!isBuiltinCmd(""));
}

test "help --summary returns runtime summary map" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        testing.expect(status == .ok) catch unreachable;
    }
    const alloc = gpa.allocator();

    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    var io = threaded.io();

    var env_map = try @import("env.zig").EnvMap.init(alloc);
    defer env_map.deinit();

    var shell_ctx = try ShellCtx.initEngine(&io, alloc, env_map);
    defer shell_ctx.deinit();

    var exec_ctx = ExecContext{
        .shell_ctx = &shell_ctx,
        .allocator = alloc,
        .input = .none,
        .output = .capture,
        .err = .none,
    };

    var args = [_][]const u8{ "help", "--summary" };
    var value = help(&exec_ctx, args[0..]);
    defer value.deinit(alloc);

    try testing.expect(value == .map);
    const name = value.map.get("name") orelse return error.TestExpectedEqual;
    try testing.expect(name == .text);
    try testing.expectEqualStrings(shell_ctx.shell_name, name.text);
    const commands = value.map.get("commands") orelse return error.TestExpectedEqual;
    try testing.expect(commands == .list);
}

test "historyEntryMatches supports contains and prefix modes" {
    try testing.expect(historyEntryMatches("deploy prod", "ploy", .contains));
    try testing.expect(!historyEntryMatches("deploy prod", "prod", .prefix));
    try testing.expect(historyEntryMatches("deploy prod", "deploy", .prefix));
}

test "filterHistoryList keeps only matching text entries" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const list = try alloc.create(List);
    list.* = try List.initCapacity(alloc, 3);
    try list.append(alloc, .{ .text = try alloc.dupe(u8, "deploy prod") });
    try list.append(alloc, .{ .text = try alloc.dupe(u8, "git status") });
    try list.append(alloc, .{ .text = try alloc.dupe(u8, "deploy staging") });

    const filtered = try filterHistoryList(alloc, list, "deploy", .prefix);
    try testing.expectEqual(@as(usize, 2), filtered.items.len);
    try testing.expectEqualStrings("deploy prod", filtered.items[0].text);
    try testing.expectEqualStrings("deploy staging", filtered.items[1].text);
}

test "reverseHistoryList returns entries in reverse order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const list = try alloc.create(List);
    list.* = try List.initCapacity(alloc, 3);
    try list.append(alloc, .{ .text = try alloc.dupe(u8, "one") });
    try list.append(alloc, .{ .text = try alloc.dupe(u8, "two") });
    try list.append(alloc, .{ .text = try alloc.dupe(u8, "three") });

    const reversed = try reverseHistoryList(alloc, list);
    try testing.expectEqual(@as(usize, 3), reversed.items.len);
    try testing.expectEqualStrings("three", reversed.items[0].text);
    try testing.expectEqualStrings("two", reversed.items[1].text);
    try testing.expectEqualStrings("one", reversed.items[2].text);
}

test "uniqueHistoryList removes duplicates preserving first occurrence order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const list = try alloc.create(List);
    list.* = try List.initCapacity(alloc, 5);
    try list.append(alloc, .{ .text = try alloc.dupe(u8, "one") });
    try list.append(alloc, .{ .text = try alloc.dupe(u8, "two") });
    try list.append(alloc, .{ .text = try alloc.dupe(u8, "one") });
    try list.append(alloc, .{ .text = try alloc.dupe(u8, "three") });
    try list.append(alloc, .{ .text = try alloc.dupe(u8, "two") });

    const unique = try uniqueHistoryList(alloc, list);
    try testing.expectEqual(@as(usize, 3), unique.items.len);
    try testing.expectEqualStrings("one", unique.items[0].text);
    try testing.expectEqualStrings("two", unique.items[1].text);
    try testing.expectEqualStrings("three", unique.items[2].text);
}

test "history builtin search mode requires a query term" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = try makeTestCtx(arena.allocator());

    var args = [_][]const u8{ "history", "--contains" };
    const result = history(&ctx, &args);
    try testing.expect(result == .err);
    try testing.expectEqual(ShellError.MissingArgument, result.err);
}

test "confirm_builtin: fail - missing message returns MissingArgument" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = try makeTestCtx(arena.allocator());
    ctx.shell_ctx.exe_mode = .interactive;

    var args = [_][]const u8{"confirm"};
    const result = confirm_builtin(&ctx, &args);

    try testing.expect(result == .err);
    try testing.expectEqual(ShellError.MissingArgument, result.err);
}

test "confirm_builtin: yes returns success" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = try makeTestCtx(arena.allocator());
    ctx.shell_ctx.exe_mode = .interactive;
    ctx.input = .{ .value = Value{ .text = "yes" } };

    var args = [_][]const u8{ "confirm", "Proceed?" };
    const result = confirm_builtin(&ctx, &args);

    try testing.expect(result == .boolean);
    try testing.expectEqual(true, result.boolean);
}

test "confirm_builtin: no returns failure" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = try makeTestCtx(arena.allocator());
    ctx.shell_ctx.exe_mode = .interactive;
    ctx.input = .{ .value = Value{ .text = "n" } };

    var args = [_][]const u8{ "confirm", "Proceed?" };
    const result = confirm_builtin(&ctx, &args);

    try testing.expect(result == .boolean);
    try testing.expectEqual(false, result.boolean);
}

test "confirm_builtin: invalid value input returns failure" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = try makeTestCtx(arena.allocator());
    ctx.shell_ctx.exe_mode = .interactive;
    ctx.input = .{ .value = Value{ .text = "maybe" } };

    var args = [_][]const u8{ "confirm", "Proceed?" };
    const result = confirm_builtin(&ctx, &args);

    try testing.expect(result == .boolean);
    try testing.expectEqual(false, result.boolean);
}

test "confirm_builtin: engine mode returns Unsupported" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = try makeTestCtx(arena.allocator());
    ctx.shell_ctx.exe_mode = .engine;

    var args = [_][]const u8{ "confirm", "Proceed?" };
    const result = confirm_builtin(&ctx, &args);
    try testing.expect(result == .err);
    try testing.expectEqual(ShellError.Unsupported, result.err);
}

test "log_builtin: fail - missing text returns MissingArgument" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = try makeTestCtx(arena.allocator());

    var args = [_][]const u8{ "log", "warn" };
    const result = log_builtin(&ctx, &args);

    try testing.expect(result == .err);
    try testing.expectEqual(ShellError.MissingArgument, result.err);
}

test "log_builtin: fail - invalid level returns InvalidArgument" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = try makeTestCtx(arena.allocator());

    var args = [_][]const u8{ "log", "nope", "hello" };
    const result = log_builtin(&ctx, &args);

    try testing.expect(result == .err);
    try testing.expectEqual(ShellError.InvalidArgument, result.err);
}

test "alias_builtin lists aliases in capture mode" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ctx = try makeTestCtx(alloc);

    var aliases = ShellCtx.AliasMap.init(alloc);
    defer aliases.deinit();
    ctx.shell_ctx.aliases = &aliases;
    try aliases.put(try alloc.dupe(u8, "ll"), try alloc.dupe(u8, "ls -la"));
    try aliases.put(try alloc.dupe(u8, "gs"), try alloc.dupe(u8, "git status"));

    var args = [_][]const u8{"alias"};
    const result = alias_builtin(&ctx, &args);
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 2), result.list.items.len);
}

test "alias_builtin sets alias and updates config file" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    defer {
        _ = gpa.deinit();
    }

    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    var io = threaded.io();

    var env_map = try @import("env.zig").EnvMap.init(alloc);
    defer env_map.deinit();

    var shell_ctx = try ShellCtx.initEngine(&io, alloc, env_map);
    defer shell_ctx.deinit();
    shell_ctx.exe_mode = .interactive;

    var aliases = ShellCtx.AliasMap.init(alloc);
    defer {
        var iter = aliases.iterator();
        while (iter.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            alloc.free(entry.value_ptr.*);
        }
        aliases.deinit();
    }
    shell_ctx.aliases = &aliases;

    const home = try std.fmt.allocPrint(alloc, "/tmp/zest-alias-test-{d}-{d}", .{
        std.os.linux.getpid(),
        std.Io.Clock.now(.real, io).nanoseconds,
    });
    defer alloc.free(home);
    try shell_ctx.env_map.putExported("HOME", Value{ .text = home });

    var exec_ctx = ExecContext{
        .shell_ctx = &shell_ctx,
        .allocator = alloc,
        .input = .none,
        .output = .capture,
        .err = .none,
    };

    var args = [_][]const u8{ "alias", "ll=ls -la" };
    const result = alias_builtin(&exec_ctx, &args);
    try testing.expect(result == .boolean);
    try testing.expect(result.boolean);
    try testing.expect(std.mem.eql(u8, aliases.get("ll").?, "ls -la"));

    const cfg_path = try helpers.expandPathToAbs(&shell_ctx, alloc, DEFAULT_SHELL_CONFIG_PATH);
    defer alloc.free(cfg_path);
    var file = try helpers.getFileFromPath(&shell_ctx, alloc, cfg_path, .{
        .write = false,
        .truncate = false,
        .pre_expanded = true,
    });
    defer file.close(shell_ctx.io.*);
    const content = try helpers.fileReadAll(shell_ctx.io.*, alloc, file);
    defer alloc.free(content);
    try testing.expect(std.mem.indexOf(u8, content, "alias ll = ls -la") != null);
}

test "cd dash requires OLDPWD to be set" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = try makeTestCtx(arena.allocator());

    var args = [_][]const u8{ "cd", "-" };
    const result = cd(&ctx, &args);

    try testing.expect(result == .err);
    try testing.expectEqual(ShellError.InvalidPath, result.err);
}

test "cd with no args switches to HOME" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = try makeTestCtx(arena.allocator());

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_n = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_end = std.mem.indexOfScalar(u8, &cwd_buf, 0) orelse cwd_n;
    const cwd = cwd_buf[0..cwd_end];
    try ctx.shell_ctx.env_map.putShell("HOME", .{ .text = cwd });

    var args = [_][]const u8{"cd"};
    const result = cd(&ctx, &args);
    try testing.expect(result == .void);
}

test "cd dash switches to OLDPWD and returns path in capture mode" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = try makeTestCtx(arena.allocator());

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_n = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_end = std.mem.indexOfScalar(u8, &cwd_buf, 0) orelse cwd_n;
    const cwd = cwd_buf[0..cwd_end];
    try ctx.shell_ctx.env_map.putShell("OLDPWD", .{ .text = cwd });

    var args = [_][]const u8{ "cd", "-" };
    const result = cd(&ctx, &args);

    try testing.expect(result == .text);
    try testing.expectEqualStrings(try std.fmt.allocPrint(arena.allocator(), "{s}\n", .{cwd}), result.text);
}

test "which builtin resolves builtin command in capture mode" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = try makeTestCtx(arena.allocator());

    var args = [_][]const u8{ "which", "echo" };
    const result = which_builtin(&ctx, &args);
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 1), result.list.items.len);
    try testing.expect(result.list.items[0] == .map);

    const row = result.list.items[0].map;
    const kind = row.get("kind") orelse return error.TestExpectedEqual;
    try testing.expect(kind == .text);
    try testing.expectEqualStrings("builtin", kind.text);
}

test "which builtin marks unknown command as missing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = try makeTestCtx(arena.allocator());

    var args = [_][]const u8{ "which", "definitely-not-a-real-command-zest" };
    const result = which_builtin(&ctx, &args);
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 1), result.list.items.len);
    const row = result.list.items[0].map;
    const kind = row.get("kind") orelse return error.TestExpectedEqual;
    try testing.expect(kind == .text);
    try testing.expectEqualStrings("missing", kind.text);
}

test "which --all includes alias and builtin matches" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ctx = try makeTestCtx(alloc);

    var aliases = ShellCtx.AliasMap.init(alloc);
    defer aliases.deinit();
    ctx.shell_ctx.aliases = &aliases;
    try aliases.put(try alloc.dupe(u8, "echo"), try alloc.dupe(u8, "printf test"));

    var args = [_][]const u8{ "which", "--all", "echo" };
    const result = which_builtin(&ctx, &args);
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 2), result.list.items.len);

    const first_kind = result.list.items[0].map.get("kind") orelse return error.TestExpectedEqual;
    const second_kind = result.list.items[1].map.get("kind") orelse return error.TestExpectedEqual;
    try testing.expect(first_kind == .text);
    try testing.expect(second_kind == .text);
    try testing.expectEqualStrings("alias", first_kind.text);
    try testing.expectEqualStrings("builtin", second_kind.text);
}

test "help summary returns structured runtime metadata" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = try makeTestCtx(arena.allocator());
    ctx.shell_ctx.shell_name = "zest";
    ctx.shell_ctx.shell_version = "vtest";

    var args = [_][]const u8{ "help", "--summary" };
    const result = help(&ctx, &args);
    try testing.expect(result == .map);

    const root = result.map;
    const name = root.get("name") orelse return error.TestExpectedEqual;
    const version = root.get("version") orelse return error.TestExpectedEqual;
    const mode = root.get("mode") orelse return error.TestExpectedEqual;
    const builtins_value = root.get("commands") orelse return error.TestExpectedEqual;

    try testing.expect(name == .text);
    try testing.expect(version == .text);
    try testing.expect(mode == .text);
    try testing.expect(builtins_value == .list);
    try testing.expectEqualStrings("zest", name.text);
    try testing.expectEqualStrings("vtest", version.text);
}

test "unalias_builtin: no args returns InvalidArgument" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = try makeTestCtx(arena.allocator());

    var args = [_][]const u8{"unalias"};
    const result = unalias_builtin(&ctx, &args);

    try testing.expect(result == .err);
    try testing.expectEqual(ShellError.InvalidArgument, result.err);
}

test "unalias_builtin: invalid option returns InvalidArgument" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = try makeTestCtx(arena.allocator());

    var args = [_][]const u8{ "unalias", "-x" };
    const result = unalias_builtin(&ctx, &args);

    try testing.expect(result == .err);
    try testing.expectEqual(ShellError.InvalidArgument, result.err);
}

test "unalias_builtin removes alias from runtime map and config file" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    defer {
        _ = gpa.deinit();
    }

    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    var io = threaded.io();

    var env_map = try @import("env.zig").EnvMap.init(alloc);
    defer env_map.deinit();

    var shell_ctx = try ShellCtx.initEngine(&io, alloc, env_map);
    defer shell_ctx.deinit();
    shell_ctx.exe_mode = .interactive;

    var aliases = ShellCtx.AliasMap.init(alloc);
    defer {
        var iter = aliases.iterator();
        while (iter.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            alloc.free(entry.value_ptr.*);
        }
        aliases.deinit();
    }
    shell_ctx.aliases = &aliases;
    try aliases.put(try alloc.dupe(u8, "ll"), try alloc.dupe(u8, "ls -la"));
    try aliases.put(try alloc.dupe(u8, "gs"), try alloc.dupe(u8, "git status"));

    const home = try std.fmt.allocPrint(alloc, "/tmp/zest-unalias-test-{d}-{d}", .{
        std.os.linux.getpid(),
        std.Io.Clock.now(.real, io).nanoseconds,
    });
    defer alloc.free(home);
    try shell_ctx.env_map.putExported("HOME", Value{ .text = home });

    var exec_ctx = ExecContext{
        .shell_ctx = &shell_ctx,
        .allocator = alloc,
        .input = .none,
        .output = .capture,
        .err = .none,
    };

    const cfg_path = try helpers.expandPathToAbs(&shell_ctx, alloc, DEFAULT_SHELL_CONFIG_PATH);
    defer alloc.free(cfg_path);
    try helpers.ensureDirPath(&shell_ctx, cfg_path);
    var file = try helpers.getFileFromPath(&shell_ctx, alloc, cfg_path, .{
        .write = true,
        .truncate = true,
        .pre_expanded = true,
    });
    defer file.close(shell_ctx.io.*);
    try helpers.fileWriteAll(shell_ctx.io.*, file,
        \\alias ll = ls -la
        \\alias gs = git status
        \\
    );

    var args = [_][]const u8{ "unalias", "ll" };
    const result = unalias_builtin(&exec_ctx, &args);
    try testing.expect(result == .boolean);
    try testing.expect(result.boolean);

    try testing.expect(aliases.get("ll") == null);
    try testing.expect(aliases.get("gs") != null);

    var updated_file = try helpers.getFileFromPath(&shell_ctx, alloc, cfg_path, .{
        .write = false,
        .truncate = false,
        .pre_expanded = true,
    });
    defer updated_file.close(shell_ctx.io.*);
    const updated = try helpers.fileReadAll(shell_ctx.io.*, alloc, updated_file);
    defer alloc.free(updated);

    try testing.expect(std.mem.indexOf(u8, updated, "alias ll") == null);
    try testing.expect(std.mem.indexOf(u8, updated, "alias gs") != null);
}

test "help command detail returns structured map in capture mode" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = try makeTestCtx(arena.allocator());

    var args = [_][]const u8{ "help", "where" };
    const result = help(&ctx, &args);
    try testing.expect(result == .map);
    const item = result.map;

    const name_value = item.get("name") orelse return error.TestExpectedEqual;
    try testing.expect(name_value == .text);
    try testing.expectEqualStrings("where", name_value.text);

    const transform_value = item.get("transform") orelse return error.TestExpectedEqual;
    try testing.expect(transform_value == .boolean);
    try testing.expect(transform_value.boolean);
}

test "builtins metadata includes at least one example per entry" {
    for (builtins_metadata) |meta| {
        try testing.expect(meta.examples.len > 0);
        for (meta.examples) |example| {
            const trimmed = std.mem.trim(u8, example, " \t\r\n");
            try testing.expect(trimmed.len > 0);
        }
    }
}

test "help --all returns list of builtin help entries" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = try makeTestCtx(arena.allocator());

    var args = [_][]const u8{ "help", "--all" };
    const result = help(&ctx, &args);

    try testing.expect(result == .list);
    try testing.expectEqual(builtins_metadata.len, result.list.items.len);
}

test "help command detail rejects command unavailable in engine mode" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = try makeTestCtx(arena.allocator());
    ctx.shell_ctx.exe_mode = .engine;

    var args = [_][]const u8{ "help", "history" };
    const result = help(&ctx, &args);
    try testing.expect(result == .err);
    try testing.expectEqual(ShellError.Unsupported, result.err);
}

test "help --all in engine mode excludes interactive-only commands and meta" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = try makeTestCtx(arena.allocator());
    ctx.shell_ctx.exe_mode = .engine;

    var args = [_][]const u8{ "help", "--all" };
    const result = help(&ctx, &args);
    try testing.expect(result == .list);

    for (result.list.items) |entry| {
        try testing.expect(entry == .map);
        const name = entry.map.get("name") orelse continue;
        if (name != .text) continue;
        try testing.expect(!std.mem.eql(u8, name.text, "history"));
        try testing.expect(!std.mem.eql(u8, name.text, "jobs"));
        try testing.expect(!std.mem.eql(u8, name.text, "step"));
        try testing.expect(!std.mem.eql(u8, name.text, "confirm"));
    }
}

test "help overview text includes help details meta commands and builtins" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = try makeTestCtx(arena.allocator());
    ctx.output = .capture;

    var args = [_][]const u8{"help"};
    const result = help(&ctx, &args);
    try testing.expect(result == .text);
    try testing.expect(std.mem.indexOf(u8, result.text, "help:") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "meta commands:") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "builtins:") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "help --summary") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "help --find <term> --summary") != null);
}

test "help overview in engine mode hides interactive-only entries" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = try makeTestCtx(arena.allocator());
    ctx.output = .capture;
    ctx.shell_ctx.exe_mode = .engine;

    var args = [_][]const u8{"help"};
    const result = help(&ctx, &args);
    try testing.expect(result == .text);
    try testing.expect(std.mem.indexOf(u8, result.text, "step") == null);
    try testing.expect(std.mem.indexOf(u8, result.text, "history") == null);
    try testing.expect(std.mem.indexOf(u8, result.text, "jobs") == null);
}

test "help --all can be filtered by where on name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = try makeTestCtx(arena.allocator());

    var help_args = [_][]const u8{ "help", "--all" };
    const help_value = help(&ctx, &help_args);
    try testing.expect(help_value == .list);

    ctx.input = .{ .value = help_value };
    var where_args = [_][]const u8{ "where", ".name", "==", "pwd" };
    const filtered = where(&ctx, &where_args);

    try testing.expect(filtered == .list);
    try testing.expectEqual(@as(usize, 1), filtered.list.items.len);
    try testing.expect(filtered.list.items[0] == .map);
    const name_value = filtered.list.items[0].map.get("name") orelse return error.TestExpectedEqual;
    try testing.expect(name_value == .text);
    try testing.expectEqualStrings("pwd", name_value.text);
}

test "help --find returns matching builtin entries" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = try makeTestCtx(arena.allocator());

    var args = [_][]const u8{ "help", "--find", "hist" };
    const result = help(&ctx, &args);

    try testing.expect(result == .list);
    const rows = result.list.items;
    try testing.expect(rows.len > 0);

    var found_history = false;
    for (rows) |row| {
        try testing.expect(row == .map);
        const name_value = row.map.get("name") orelse continue;
        if (name_value == .text and std.mem.eql(u8, name_value.text, "history")) {
            found_history = true;
        }
    }
    try testing.expect(found_history);
}

test "help --find without search term returns MissingArgument" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = try makeTestCtx(arena.allocator());

    var args = [_][]const u8{ "help", "--find" };
    const result = help(&ctx, &args);

    try testing.expect(result == .err);
    try testing.expectEqual(ShellError.MissingArgument, result.err);
}

// -- where --
test "where: missing predicate returns InvalidArgument" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ctx = try makeTestCtx(alloc);
    const list = makeTextList(alloc, &.{"hello"});
    ctx.input = .{ .value = Value{ .list = list } };

    // Pass no args beyond command name
    var args = [_][]const u8{"where"};
    const result = where(&ctx, &args);

    try testing.expect(result == .err);
    try testing.expectEqual(ShellError.InvalidArgument, result.err);
}

test "where filters generic list of maps by shared key and ignores missing key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ctx = try makeTestCtx(alloc);

    const input_list = try alloc.create(List);
    input_list.* = try List.initCapacity(alloc, 3);

    const row1 = try alloc.create(Map);
    row1.* = Map.init(alloc);
    try row1.put(try alloc.dupe(u8, "name"), Value{ .text = try alloc.dupe(u8, "pwd") });
    try row1.put(try alloc.dupe(u8, "usage"), Value{ .text = try alloc.dupe(u8, "pwd") });
    try input_list.append(alloc, Value{ .map = row1 });

    const row2 = try alloc.create(Map);
    row2.* = Map.init(alloc);
    try row2.put(try alloc.dupe(u8, "name"), Value{ .text = try alloc.dupe(u8, "help") });
    try input_list.append(alloc, Value{ .map = row2 });

    const row3 = try alloc.create(Map);
    row3.* = Map.init(alloc);
    try row3.put(try alloc.dupe(u8, "description"), Value{ .text = try alloc.dupe(u8, "no name key") });
    try input_list.append(alloc, Value{ .map = row3 });

    ctx.input = .{ .value = Value{ .list = input_list } };

    var args = [_][]const u8{ "where", ".name", "==", "pwd" };
    const result = where(&ctx, &args);

    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 1), result.list.items.len);
    try testing.expect(result.list.items[0] == .map);
    const name_value = result.list.items[0].map.get("name") orelse return error.TestExpectedEqual;
    try testing.expect(name_value == .text);
    try testing.expectEqualStrings("pwd", name_value.text);
}

test "select returns only requested fields from list maps" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ctx = try makeTestCtx(alloc);

    const input_list = try alloc.create(List);
    input_list.* = try List.initCapacity(alloc, 1);
    const row = try alloc.create(Map);
    row.* = Map.init(alloc);
    try row.put(try alloc.dupe(u8, "name"), Value{ .text = try alloc.dupe(u8, "pwd") });
    try row.put(try alloc.dupe(u8, "size"), Value{ .integer = 42 });
    try row.put(try alloc.dupe(u8, "extra"), Value{ .text = try alloc.dupe(u8, "x") });
    try input_list.append(alloc, Value{ .map = row });
    ctx.input = .{ .value = Value{ .list = input_list } };

    var args = [_][]const u8{ "select", ".name", ".size" };
    const result = select(&ctx, &args);

    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 1), result.list.items.len);
    const out_row = result.list.items[0].map;
    try testing.expect(out_row.contains("name"));
    try testing.expect(out_row.contains("size"));
    try testing.expect(!out_row.contains("extra"));
}

test "sort orders list of integers ascending" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ctx = try makeTestCtx(alloc);
    const input_list = try alloc.create(List);
    input_list.* = try List.initCapacity(alloc, 3);
    try input_list.append(alloc, Value{ .integer = 3 });
    try input_list.append(alloc, Value{ .integer = 1 });
    try input_list.append(alloc, Value{ .integer = 2 });
    ctx.input = .{ .value = Value{ .list = input_list } };

    var args = [_][]const u8{"sort"};
    const result = sort_builtin(&ctx, &args);

    try testing.expect(result == .list);
    try testing.expectEqual(@as(i64, 1), result.list.items[0].integer);
    try testing.expectEqual(@as(i64, 2), result.list.items[1].integer);
    try testing.expectEqual(@as(i64, 3), result.list.items[2].integer);
}

test "count returns integer length for list input" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ctx = try makeTestCtx(alloc);
    const input_list = try alloc.create(List);
    input_list.* = try List.initCapacity(alloc, 4);
    try input_list.append(alloc, Value{ .text = try alloc.dupe(u8, "a") });
    try input_list.append(alloc, Value{ .text = try alloc.dupe(u8, "b") });
    try input_list.append(alloc, Value{ .text = try alloc.dupe(u8, "c") });
    try input_list.append(alloc, Value{ .text = try alloc.dupe(u8, "d") });
    ctx.input = .{ .value = Value{ .list = input_list } };

    var args = [_][]const u8{"count"};
    const result = count(&ctx, &args);

    try testing.expect(result == .integer);
    try testing.expectEqual(@as(i64, 4), result.integer);
}

test "map builtin maps list integers with add expression" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ctx = try makeTestCtx(alloc);
    const input_list = try alloc.create(List);
    input_list.* = try List.initCapacity(alloc, 3);
    try input_list.append(alloc, Value{ .integer = 1 });
    try input_list.append(alloc, Value{ .integer = 2 });
    try input_list.append(alloc, Value{ .integer = 3 });
    ctx.input = .{ .value = Value{ .list = input_list } };

    var args = [_][]const u8{ "map", "add", "2" };
    const result = stream_transform_builtins.map_builtin(&ctx, &args);

    try testing.expect(result == .list);
    try testing.expectEqual(@as(i64, 3), result.list.items[0].integer);
    try testing.expectEqual(@as(i64, 4), result.list.items[1].integer);
    try testing.expectEqual(@as(i64, 5), result.list.items[2].integer);
}

test "where filters integers by comparator expression" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ctx = try makeTestCtx(alloc);
    const input_list = try alloc.create(List);
    input_list.* = try List.initCapacity(alloc, 4);
    try input_list.append(alloc, Value{ .integer = 1 });
    try input_list.append(alloc, Value{ .integer = 2 });
    try input_list.append(alloc, Value{ .integer = 3 });
    try input_list.append(alloc, Value{ .integer = 4 });
    ctx.input = .{ .value = Value{ .list = input_list } };

    var args = [_][]const u8{ "where", ">=", "3" };
    const result = where(&ctx, &args);

    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 2), result.list.items.len);
    try testing.expectEqual(@as(i64, 3), result.list.items[0].integer);
    try testing.expectEqual(@as(i64, 4), result.list.items[1].integer);
}

test "reduce builtin sums integer list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ctx = try makeTestCtx(alloc);
    const input_list = try alloc.create(List);
    input_list.* = try List.initCapacity(alloc, 3);
    try input_list.append(alloc, Value{ .integer = 2 });
    try input_list.append(alloc, Value{ .integer = 3 });
    try input_list.append(alloc, Value{ .integer = 5 });
    ctx.input = .{ .value = Value{ .list = input_list } };

    var args = [_][]const u8{ "reduce", "sum" };
    const result = stream_transform_builtins.reduce_builtin(&ctx, &args);

    try testing.expect(result == .integer);
    try testing.expectEqual(@as(i64, 10), result.integer);
}

test "lines builtin splits text input into line list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ctx = try makeTestCtx(alloc);
    ctx.input = .{ .value = Value{ .text = "a\nb\nc\n" } };

    var args = [_][]const u8{"lines"};
    const result = stream_transform_builtins.lines_builtin(&ctx, &args);

    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 3), result.list.items.len);
    try testing.expectEqualStrings("a", result.list.items[0].text);
    try testing.expectEqualStrings("b", result.list.items[1].text);
    try testing.expectEqualStrings("c", result.list.items[2].text);
}

test "split builtin splits by delimiter" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ctx = try makeTestCtx(alloc);
    ctx.input = .{ .value = Value{ .text = "a,b,c" } };

    var args = [_][]const u8{ "split", "," };
    const result = stream_transform_builtins.split_builtin(&ctx, &args);

    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 3), result.list.items.len);
    try testing.expectEqualStrings("a", result.list.items[0].text);
    try testing.expectEqualStrings("b", result.list.items[1].text);
    try testing.expectEqualStrings("c", result.list.items[2].text);
}

test "join builtin joins list values with delimiter" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ctx = try makeTestCtx(alloc);
    const input_list = makeTextList(alloc, &.{ "alpha", "beta", "gamma" });
    ctx.input = .{ .value = Value{ .list = input_list } };

    var args = [_][]const u8{ "join", "|" };
    const result = stream_transform_builtins.join_builtin(&ctx, &args);

    try testing.expect(result == .text);
    try testing.expectEqualStrings("alpha|beta|gamma", result.text);
}

// -- read_builtin --

test "read_builtin: pass - returns text from value input" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = try makeTestCtx(arena.allocator());
    ctx.input = .{ .value = Value{ .text = "hello" } };

    var args = [_][]const u8{"read"};
    const result = read_builtin(&ctx, &args);

    try testing.expect(result == .text);
    try testing.expectEqualStrings("hello", result.text);
}

// -- uppercase --

test "uppercase: pass - converts value input to uppercase" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = try makeTestCtx(arena.allocator());
    ctx.input = .{ .value = Value{ .text = "hello world" } };

    var args = [_][]const u8{"upper"};
    const result = uppercase(&ctx, &args);

    try testing.expect(result == .text);
    try testing.expectEqualStrings("HELLO WORLD", result.text);
}

test "uppercase: fail - missing file returns InvalidPath" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = try makeTestCtx(arena.allocator());
    ctx.input = .none;

    var args = [_][]const u8{ "upper", "nonexistent.txt" };
    const result = uppercase(&ctx, &args);

    try testing.expect(result == .err);
    try testing.expectEqual(ShellError.InvalidPath, result.err);
}

// -- b64 --

test "b64: pass - encodes plain text input" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = try makeTestCtx(arena.allocator());
    ctx.input = .{ .value = Value{ .text = "hello" } };

    var args = [_][]const u8{"b64"};
    const result = b64(&ctx, &args);

    try testing.expect(result == .text);
    try testing.expectEqualStrings("aGVsbG8=", result.text);
}

test "b64: pass - decodes base64 input" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = try makeTestCtx(arena.allocator());
    ctx.input = .{ .value = Value{ .text = "aGVsbG8=" } };

    var args = [_][]const u8{"b64"};
    const result = b64(&ctx, &args);

    try testing.expect(result == .text);
    try testing.expectEqualStrings("hello", result.text);
}

// -- exitcode --

test "exitcode: pass - returns last exit code as integer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = try makeTestCtx(arena.allocator());
    ctx.shell_ctx.last_exit_code = 0;

    var args = [_][]const u8{"exitcode"};
    const result = exitcode(&ctx, &args);

    try testing.expect(result == .integer);
    try testing.expectEqual(@as(i64, 0), result.integer);
}

test "exitcode: fail - non-zero exit code returned" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = try makeTestCtx(arena.allocator());
    ctx.shell_ctx.last_exit_code = 1;

    var args = [_][]const u8{"exitcode"};
    const result = exitcode(&ctx, &args);

    try testing.expect(result == .integer);
    try testing.expectEqual(@as(i64, 1), result.integer);
}

// -- test_builtin --

test "test_builtin: pass - string equality match" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = try makeTestCtx(arena.allocator());

    var args = [_][]const u8{ "test", "hello", "=", "hello" };
    const result = test_builtin(&ctx, &args);

    try testing.expect(result == .boolean);
    try testing.expectEqual(true, result.boolean);
}

test "test_builtin: fail - string equality no match" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = try makeTestCtx(arena.allocator());

    var args = [_][]const u8{ "test", "hello", "=", "world" };
    const result = test_builtin(&ctx, &args);

    try testing.expect(result == .boolean);
    try testing.expectEqual(false, result.boolean);
}

test "test_builtin: pass - numeric greater than true" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = try makeTestCtx(arena.allocator());

    var args = [_][]const u8{ "test", "10", "-gt", "5" };
    const result = test_builtin(&ctx, &args);

    try testing.expect(result == .boolean);
    try testing.expectEqual(true, result.boolean);
}

test "test_builtin: fail - too few args returns MissingArgument" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = try makeTestCtx(arena.allocator());

    var args = [_][]const u8{ "test", "-f" };
    const result = test_builtin(&ctx, &args);

    try testing.expect(result == .err);
    try testing.expectEqual(ShellError.MissingArgument, result.err);
}

// -- expr_builtin --

test "expr_builtin: pass - addition" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = try makeTestCtx(arena.allocator());

    var args = [_][]const u8{ "expr", "3", "+", "4" };
    const result = expr_builtin(&ctx, &args);

    try testing.expect(result == .integer);
    try testing.expectEqual(@as(i64, 7), result.integer);
}

test "expr_builtin: pass - division" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = try makeTestCtx(arena.allocator());

    var args = [_][]const u8{ "expr", "10", "/", "2" };
    const result = expr_builtin(&ctx, &args);

    try testing.expect(result == .integer);
    try testing.expectEqual(@as(i64, 5), result.integer);
}

test "expr_builtin: fail - division by zero" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = try makeTestCtx(arena.allocator());

    var args = [_][]const u8{ "expr", "10", "/", "0" };
    const result = expr_builtin(&ctx, &args);

    try testing.expect(result == .err);
    try testing.expectEqual(ShellError.DivisionByZero, result.err);
}

test "expr_builtin: fail - too few args returns MissingArgument" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = try makeTestCtx(arena.allocator());

    var args = [_][]const u8{ "expr", "1", "+" };
    const result = expr_builtin(&ctx, &args);

    try testing.expect(result == .err);
    try testing.expectEqual(ShellError.MissingArgument, result.err);
}
