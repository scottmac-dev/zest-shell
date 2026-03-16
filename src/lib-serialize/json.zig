// ----- SERIALIZATION HELPERS
const std = @import("std");
const errors = @import("../lib-core/core/errors.zig");
const command = @import("../lib-core/core/command.zig");
const lexer = @import("../lib-core/core/lexer.zig");
const pipeline = @import("../lib-core/core/pipeline.zig");
const types = @import("../lib-core/core/types.zig");
const Allocator = std.mem.Allocator;
const ShellError = errors.ShellError;
const Token = lexer.Token;
const TokenKind = lexer.TokenKind;
const Value = types.Value;
const RedirConfig = command.RedirConfig;

pub const JsonEnvVar = struct {
    name: []const u8,
    value: []const u8,
    exported: bool = true,
};

pub const JsonExecutionPlan = struct {
    tokens: []Token,
    sequence: pipeline.CommandSequence,
    env: []JsonEnvVar,
    measure_time: bool = false,
};

/// Converts zig structs into a JSON string
pub fn serializeJson(allocator: Allocator, value: anytype) ![]u8 {
    return try std.json.Stringify.valueAlloc(allocator, value, .{});
}

/// Converts JSON string into a zig struct
pub fn paresJson(comptime T: anytype, allocator: Allocator, data: []const u8) !std.json.Parsed(T) {
    return try std.json.parseFromSlice(T, allocator, data, .{});
}

const JsonInput = struct {
    version: u8 = 1,
    settings: ?Settings = null,
    env: ?[]EnvVar = null,
    sequence: []SeqEntry,

    const Settings = struct {
        measure_time: bool = false,
    };

    const EnvVar = struct {
        name: []const u8,
        value: []const u8,
        exported: bool = true,
    };

    const SeqEntry = struct {
        pipeline: []CmdEntry,
        redirects: ?Redirects = null,
        background: bool = false,
        operator: ?[]const u8 = null,
    };

    const CmdEntry = struct {
        cmd: []const u8,
        args: ?[]const []const u8 = null,
        @"substitute-cmd": ?SubstituteCmd = null,
    };

    const SubstituteCmd = struct {
        cmd: []const u8,
        args: ?[]const []const u8 = null,
    };

    const Redirects = struct {
        stdin: ?[]const u8 = null,
        stdout: ?[]const u8 = null,
        stderr: ?[]const u8 = null,
        stdout_append: bool = false,
        stderr_append: bool = false,
        merge_stderr_to_stdout: bool = false,
    };
};

fn appendToken(tokens: *std.ArrayList(Token), allocator: Allocator, kind: TokenKind, text: []const u8) ShellError!void {
    const owned = allocator.dupe(u8, text) catch return ShellError.AllocFailed;
    tokens.append(allocator, .{
        .kind = kind,
        .text = owned,
    }) catch return ShellError.AllocFailed;
}

fn parseSequenceOperator(text: []const u8) ?TokenKind {
    if (std.mem.eql(u8, text, "semicolon") or std.mem.eql(u8, text, ";")) return .Semicolon;
    if (std.mem.eql(u8, text, "and") or std.mem.eql(u8, text, "&&")) return .And;
    if (std.mem.eql(u8, text, "or") or std.mem.eql(u8, text, "||")) return .Or;
    if (std.mem.eql(u8, text, "none")) return null;
    return null;
}

fn isSafeShellArg(arg: []const u8) bool {
    if (arg.len == 0) return false;
    for (arg) |c| {
        if (std.ascii.isAlphanumeric(c)) continue;
        if (c == '_' or c == '-' or c == '.' or c == '/' or c == ':') continue;
        return false;
    }
    return true;
}

fn appendShellQuotedArg(buf: *std.ArrayList(u8), allocator: Allocator, arg: []const u8) !void {
    if (isSafeShellArg(arg)) {
        try buf.appendSlice(allocator, arg);
        return;
    }

    try buf.append(allocator, '\'');
    for (arg) |c| {
        if (c == '\'') {
            try buf.appendSlice(allocator, "'\\''");
        } else {
            try buf.append(allocator, c);
        }
    }
    try buf.append(allocator, '\'');
}

fn buildSubstituteCommandText(allocator: Allocator, sub: JsonInput.SubstituteCmd) ![]const u8 {
    var inner = try std.ArrayList(u8).initCapacity(allocator, 32);
    errdefer inner.deinit(allocator);

    try appendShellQuotedArg(&inner, allocator, sub.cmd);
    if (sub.args) |args| {
        for (args) |arg| {
            try inner.append(allocator, ' ');
            try appendShellQuotedArg(&inner, allocator, arg);
        }
    }

    var wrapped = try std.ArrayList(u8).initCapacity(allocator, inner.items.len + 3);
    errdefer wrapped.deinit(allocator);
    try wrapped.appendSlice(allocator, "$(");
    try wrapped.appendSlice(allocator, inner.items);
    try wrapped.append(allocator, ')');
    return wrapped.toOwnedSlice(allocator);
}

fn validateJsonInput(root: JsonInput) ShellError!void {
    if (root.version != 1) return ShellError.Unsupported;
    if (root.sequence.len == 0) return ShellError.EmptyCommandSequence;

    for (root.sequence, 0..) |entry, idx| {
        if (entry.pipeline.len == 0) return ShellError.EmptyPipeline;
        for (entry.pipeline) |cmd| {
            if (cmd.cmd.len == 0) return ShellError.MissingCommand;
        }

        if (entry.redirects) |r| {
            if (r.merge_stderr_to_stdout and r.stderr != null and r.stdout != null) {
                return ShellError.InvalidArgument;
            }
            if (r.stdout_append and r.stdout == null) return ShellError.InvalidArgument;
            if (r.stderr_append and r.stderr == null) return ShellError.InvalidArgument;
        }

        if (idx == root.sequence.len - 1) {
            if (entry.operator) |op| {
                if (!std.mem.eql(u8, op, "none")) return ShellError.InvalidCommandSequence;
            }
        } else if (entry.operator) |op| {
            if (parseSequenceOperator(op) == null and !std.mem.eql(u8, op, "none")) {
                return ShellError.InvalidCommandSequence;
            }
        }
    }
}

pub fn parseCommandSequenceJson(allocator: Allocator, data: []const u8) ShellError!JsonExecutionPlan {
    const parsed = paresJson(JsonInput, allocator, data) catch return ShellError.InvalidSyntax;
    const root = parsed.value;

    try validateJsonInput(root);

    var tokens = std.ArrayList(Token).initCapacity(allocator, 32) catch return ShellError.AllocFailed;

    for (root.sequence, 0..) |entry, seq_idx| {
        for (entry.pipeline, 0..) |cmd, cmd_idx| {
            try appendToken(&tokens, allocator, .Command, cmd.cmd);

            if (cmd.args) |args| {
                for (args) |arg| {
                    try appendToken(&tokens, allocator, .Arg, arg);
                }
            }

            if (cmd.@"substitute-cmd") |sub| {
                const subs_text = buildSubstituteCommandText(allocator, sub) catch return ShellError.AllocFailed;
                try appendToken(&tokens, allocator, .Arg, subs_text);
            }

            if (cmd_idx < entry.pipeline.len - 1) {
                try appendToken(&tokens, allocator, .Pipe, "|");
            }
        }

        if (entry.redirects) |redir| {
            if (redir.stdin) |path| {
                try appendToken(&tokens, allocator, .Redirect, "<");
                try appendToken(&tokens, allocator, .Arg, path);
            }

            if (redir.stdout) |path| {
                if (redir.merge_stderr_to_stdout) {
                    try appendToken(&tokens, allocator, .Redirect, if (redir.stdout_append) "&>>" else "&>");
                    try appendToken(&tokens, allocator, .Arg, path);
                } else {
                    try appendToken(&tokens, allocator, .Redirect, if (redir.stdout_append) ">>" else ">");
                    try appendToken(&tokens, allocator, .Arg, path);
                }
            }

            if (redir.stderr) |path| {
                try appendToken(&tokens, allocator, .Redirect, if (redir.stderr_append) "2>>" else "2>");
                try appendToken(&tokens, allocator, .Arg, path);
            } else if (redir.merge_stderr_to_stdout and redir.stdout == null) {
                try appendToken(&tokens, allocator, .Redirect, "2>&1");
            }
        }

        if (entry.background) {
            try appendToken(&tokens, allocator, .Bg, "&");
        }

        if (seq_idx < root.sequence.len - 1) {
            const op_text = entry.operator orelse "semicolon";
            const op_kind = parseSequenceOperator(op_text) orelse return ShellError.InvalidCommandSequence;
            try appendToken(&tokens, allocator, op_kind, op_text);
        }
    }

    lexer.validateTokenSequence(tokens.items) catch return ShellError.InvalidTokenSequence;
    const cmd_sequence = pipeline.generateCommandSequence(allocator, tokens.items) catch |err| switch (err) {
        ShellError.InvalidTokenSequence => return ShellError.InvalidTokenSequence,
        else => return ShellError.FailedPipelineGeneration,
    };

    const env_cap: usize = if (root.env) |vars| vars.len else 0;
    var env_vars = std.ArrayList(JsonEnvVar).initCapacity(allocator, env_cap) catch return ShellError.AllocFailed;
    if (root.env) |vars| {
        for (vars) |v| {
            const name = allocator.dupe(u8, v.name) catch return ShellError.AllocFailed;
            const value = allocator.dupe(u8, v.value) catch return ShellError.AllocFailed;
            env_vars.append(allocator, .{
                .name = name,
                .value = value,
                .exported = v.exported,
            }) catch return ShellError.AllocFailed;
        }
    }

    return .{
        .tokens = tokens.items,
        .sequence = cmd_sequence,
        .env = env_vars.items,
        .measure_time = if (root.settings) |s| s.measure_time else false,
    };
}

const JsonPlanOutput = struct {
    version: u8 = 1,
    settings: Settings,
    env: ?[]const JsonEnvVar = null,
    sequence: []SeqEntry,

    const Settings = struct {
        measure_time: bool = false,
    };

    const SeqEntry = struct {
        pipeline: []CmdEntry,
        redirects: ?Redirects = null,
        background: bool = false,
        operator: []const u8 = "none",
    };

    const CmdEntry = struct {
        cmd: []const u8,
        args: ?[]const []const u8 = null,
    };

    const Redirects = struct {
        stdin: ?[]const u8 = null,
        stdout: ?[]const u8 = null,
        stderr: ?[]const u8 = null,
        stdout_append: bool = false,
        stderr_append: bool = false,
        merge_stderr_to_stdout: bool = false,
    };
};

fn sequenceOperatorToText(op: pipeline.SequenceOperator) []const u8 {
    return switch (op) {
        .semicolon => "semicolon",
        .and_op => "and",
        .or_op => "or",
        .none => "none",
    };
}

fn buildPlanRedirects(redir: ?RedirConfig) ?JsonPlanOutput.Redirects {
    const cfg = redir orelse return null;
    if (cfg.stdin_path == null and cfg.stdout_path == null and cfg.stderr_path == null and !cfg.merge_stderr_to_stdout) {
        return null;
    }
    return .{
        .stdin = cfg.stdin_path,
        .stdout = cfg.stdout_path,
        .stderr = cfg.stderr_path,
        .stdout_append = cfg.stdout_path != null and !cfg.stdout_truncate,
        .stderr_append = cfg.stderr_path != null and !cfg.stderr_truncate,
        .merge_stderr_to_stdout = cfg.merge_stderr_to_stdout,
    };
}

/// Serialize a command sequence into JSON pipeline-input format.
pub fn serializeCommandSequencePlan(
    allocator: Allocator,
    sequence: pipeline.CommandSequence,
    measure_time: bool,
    env_entries: []const JsonEnvVar,
) ![]const u8 {
    var entries = try std.ArrayList(JsonPlanOutput.SeqEntry).initCapacity(allocator, sequence.pipelines.len);

    for (sequence.pipelines, 0..) |pipe, pipeline_idx| {
        var cmds = try std.ArrayList(JsonPlanOutput.CmdEntry).initCapacity(allocator, pipe.stages.len);
        for (pipe.stages) |stage| {
            if (stage.args.len == 0) return ShellError.MissingCommand;
            const cmd_name = stage.args[0].text;

            var cmd_args: ?[]const []const u8 = null;
            if (stage.args.len > 1) {
                var args_list = try std.ArrayList([]const u8).initCapacity(allocator, stage.args.len - 1);
                for (stage.args[1..]) |arg| {
                    try args_list.append(allocator, arg.text);
                }
                cmd_args = try args_list.toOwnedSlice(allocator);
            }

            try cmds.append(allocator, .{
                .cmd = cmd_name,
                .args = cmd_args,
            });
        }

        const op_text = if (pipeline_idx < sequence.operators.len)
            sequenceOperatorToText(sequence.operators[pipeline_idx])
        else
            "none";
        try entries.append(allocator, .{
            .pipeline = try cmds.toOwnedSlice(allocator),
            .redirects = buildPlanRedirects(pipe.redir_config),
            .background = pipe.mode == .background,
            .operator = op_text,
        });
    }

    const root = JsonPlanOutput{
        .settings = .{ .measure_time = measure_time },
        .env = if (env_entries.len == 0) null else env_entries,
        .sequence = try entries.toOwnedSlice(allocator),
    };
    return std.json.Stringify.valueAlloc(allocator, root, .{ .whitespace = .indent_2 });
}

/// Pretty-printed JSON with configurable indent.
/// Complements Value.toJson (compact) in core/types.zig.
/// Caller owns the returned slice.
pub fn toJsonPretty(value: Value, allocator: Allocator, indent: u8) ![]const u8 {
    var builder = try std.ArrayList(u8).initCapacity(allocator, 512);
    errdefer builder.deinit(allocator);
    try writeJsonPretty(value, allocator, &builder, indent, 0);
    return builder.toOwnedSlice(allocator);
}

/// Recursive writer. depth tracks current nesting level for indentation.
fn writeJsonPretty(
    value: Value,
    allocator: Allocator,
    builder: *std.ArrayList(u8),
    indent: u8,
    depth: usize,
) !void {
    switch (value) {
        .void => try builder.appendSlice(allocator, "null"),
        .boolean => |b| try builder.appendSlice(allocator, if (b) "true" else "false"),
        .integer => |i| try builder.appendSlice(allocator, try std.fmt.allocPrint(allocator, "{d}", .{i})),
        .float => |f| try builder.appendSlice(allocator, try std.fmt.allocPrint(allocator, "{d}", .{f})),
        .err => |e| {
            const diag = try errors.toStructured(e, allocator);
            const payload = try serializeJson(allocator, .{
                .code = diag.code,
                .category = diag.category,
                .message = diag.message,
                .hint = diag.hint,
            });
            try builder.appendSlice(allocator, payload);
        },
        .text => |t| {
            // Escape string content
            const escaped = try serializeJson(allocator, t);
            try builder.appendSlice(allocator, escaped);
        },
        .list => |l| {
            if (l.items.len == 0) {
                try builder.appendSlice(allocator, "[]");
                return;
            }
            try builder.appendSlice(allocator, "[\n");
            for (l.items, 0..) |item, idx| {
                try writeIndent(allocator, builder, indent, depth + 1);
                try writeJsonPretty(item, allocator, builder, indent, depth + 1);
                if (idx < l.items.len - 1) try builder.append(allocator, ',');
                try builder.append(allocator, '\n');
            }
            try writeIndent(allocator, builder, indent, depth);
            try builder.append(allocator, ']');
        },
        .map => |m| {
            if (m.count() == 0) {
                try builder.appendSlice(allocator, "{}");
                return;
            }
            try builder.appendSlice(allocator, "{\n");
            var iter = m.iterator();
            var idx: usize = 0;
            while (iter.next()) |entry| {
                try writeIndent(allocator, builder, indent, depth + 1);
                // Key
                const key_json = try serializeJson(allocator, entry.key_ptr.*);
                try builder.appendSlice(allocator, key_json);
                try builder.appendSlice(allocator, ": ");
                // Value
                try writeJsonPretty(entry.value_ptr.*, allocator, builder, indent, depth + 1);
                if (idx < m.count() - 1) try builder.append(allocator, ',');
                try builder.append(allocator, '\n');
                idx += 1;
            }
            try writeIndent(allocator, builder, indent, depth);
            try builder.append(allocator, '}');
        },
    }
}

inline fn writeIndent(allocator: Allocator, builder: *std.ArrayList(u8), indent: u8, depth: usize) !void {
    const total = indent * depth;
    try builder.appendNTimes(allocator, ' ', total);
}

/// Bridge between zig std lib json Value and shell typed Value
pub fn jsonNodeToValue(allocator: std.mem.Allocator, node: std.json.Value) !Value {
    return switch (node) {
        .null => .{ .void = {} },
        .bool => |b| .{ .boolean = b },
        .integer => |i| .{ .integer = i },
        .float => |f| .{ .float = f },
        .number_string => |ns| blk: {
            if (std.fmt.parseInt(i64, ns, 10) catch null) |n| break :blk .{ .integer = n };
            if (std.fmt.parseFloat(f64, ns) catch null) |f2| break :blk .{ .float = f2 };
            break :blk .{ .text = try allocator.dupe(u8, ns) };
        },
        .string => |s| .{ .text = try allocator.dupe(u8, s) },
        .array => |arr| blk: {
            const list = try allocator.create(types.List);
            list.* = try types.List.initCapacity(allocator, arr.items.len);
            for (arr.items) |item| {
                try list.append(allocator, try jsonNodeToValue(allocator, item));
            }
            break :blk .{ .list = list };
        },
        .object => |obj| blk: {
            const map = try allocator.create(types.Map);
            map.* = types.Map.init(allocator);
            var iter = obj.iterator();
            while (iter.next()) |entry| {
                try map.put(
                    try allocator.dupe(u8, entry.key_ptr.*),
                    try jsonNodeToValue(allocator, entry.value_ptr.*),
                );
            }
            break :blk .{ .map = map };
        },
    };
}

test "parseCommandSequenceJson parses valid pipeline schema" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const raw =
        \\{
        \\  "version": 1,
        \\  "settings": { "measure_time": true },
        \\  "env": [
        \\    { "name": "FOO", "value": "bar", "exported": true }
        \\  ],
        \\  "sequence": [
        \\    {
        \\      "pipeline": [
        \\        { "cmd": "echo", "args": ["hello"] },
        \\        { "cmd": "count" }
        \\      ],
        \\      "operator": "semicolon"
        \\    },
        \\    {
        \\      "pipeline": [
        \\        { "cmd": "true" }
        \\      ],
        \\      "operator": "none"
        \\    }
        \\  ]
        \\}
    ;

    const plan = try parseCommandSequenceJson(allocator, raw);
    try std.testing.expect(plan.measure_time);
    try std.testing.expectEqual(@as(usize, 1), plan.env.len);
    try std.testing.expectEqual(@as(usize, 2), plan.sequence.pipelines.len);
    try std.testing.expectEqual(@as(usize, 1), plan.sequence.operators.len);
    try std.testing.expect(plan.tokens.len > 0);
}

test "parseCommandSequenceJson rejects invalid operator placement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const raw =
        \\{
        \\  "version": 1,
        \\  "sequence": [
        \\    {
        \\      "pipeline": [
        \\        { "cmd": "echo", "args": ["a"] }
        \\      ],
        \\      "operator": "none"
        \\    },
        \\    {
        \\      "pipeline": [
        \\        { "cmd": "echo", "args": ["b"] }
        \\      ]
        \\    }
        \\  ]
        \\}
    ;

    try std.testing.expectError(ShellError.InvalidCommandSequence, parseCommandSequenceJson(allocator, raw));
}

test "parseCommandSequenceJson supports substitute-cmd argument" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const raw =
        \\{
        \\  "version": 1,
        \\  "sequence": [
        \\    {
        \\      "pipeline": [
        \\        {
        \\          "cmd": "echo",
        \\          "substitute-cmd": { "cmd": "echo", "args": ["hello world"] }
        \\        }
        \\      ],
        \\      "operator": "none"
        \\    }
        \\  ]
        \\}
    ;

    const plan = try parseCommandSequenceJson(allocator, raw);

    var found_sub = false;
    for (plan.tokens) |tok| {
        if (tok.kind == .Arg and std.mem.startsWith(u8, tok.text, "$(")) {
            found_sub = true;
            try std.testing.expect(std.mem.indexOf(u8, tok.text, "echo") != null);
            try std.testing.expect(std.mem.indexOf(u8, tok.text, "hello world") != null);
            break;
        }
    }
    try std.testing.expect(found_sub);
}

test "serializeCommandSequencePlan produces JSON compatible with parseCommandSequenceJson" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const raw =
        \\{
        \\  "version": 1,
        \\  "settings": { "measure_time": false },
        \\  "sequence": [
        \\    {
        \\      "pipeline": [
        \\        { "cmd": "echo", "args": ["hello"] },
        \\        { "cmd": "count" }
        \\      ],
        \\      "operator": "none"
        \\    }
        \\  ]
        \\}
    ;

    const parsed = try parseCommandSequenceJson(allocator, raw);
    const out = try serializeCommandSequencePlan(allocator, parsed.sequence, true, parsed.env);
    const reparsed = try parseCommandSequenceJson(allocator, out);

    try std.testing.expect(reparsed.measure_time);
    try std.testing.expectEqual(parsed.sequence.pipelines.len, reparsed.sequence.pipelines.len);
    try std.testing.expectEqual(parsed.sequence.pipelines[0].stages.len, reparsed.sequence.pipelines[0].stages.len);
}
