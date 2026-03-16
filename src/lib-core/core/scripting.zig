/// SCRIPT execution helpers and logic
const std = @import("std");
const command = @import("command.zig");
const execute = @import("execute.zig");
const helpers = @import("helpers.zig");
const lexer = @import("lexer.zig");
const parse = @import("parse.zig");
const types = @import("types.zig");
const Allocator = std.mem.Allocator;
const ShellCtx = @import("context.zig").ShellCtx;
const ShellError = @import("errors.zig").ShellError;
const Value = types.Value;

const MAX_WHILE_ITERATIONS: usize = 10;
const MAX_FUNCTION_CALL_DEPTH: usize = 32;

/// State machine approach for control flow
const ScriptState = enum {
    normal,
    // IF, ELIF, ELSE
    collecting_if_condition,
    collecting_if_body,
    collecting_elif_condition,
    collecting_elif_body,
    collecting_else_body,
    // FOR LOOPS
    collecting_for_header,
    collecting_for_body,
    // WHILE
    collecting_while_condition,
    collecting_while_body,
};

/// [param] for function call
const ParamType = enum {
    any,
    text,
    integer,
    float,
    boolean,
    list,
    map,
};

fn paramTypeName(param_type: ParamType) []const u8 {
    return switch (param_type) {
        .any => "any",
        .text => "text",
        .integer => "int",
        .float => "float",
        .boolean => "bool",
        .list => "list",
        .map => "map",
    };
}

fn parseParamType(raw_type: []const u8) ?ParamType {
    const name = std.mem.trim(u8, raw_type, &std.ascii.whitespace);
    if (name.len == 0) return null;

    if (std.ascii.eqlIgnoreCase(name, "any")) return .any;
    if (std.ascii.eqlIgnoreCase(name, "text") or
        std.ascii.eqlIgnoreCase(name, "string") or
        std.ascii.eqlIgnoreCase(name, "str"))
    {
        return .text;
    }
    if (std.ascii.eqlIgnoreCase(name, "int") or std.ascii.eqlIgnoreCase(name, "integer")) return .integer;
    if (std.ascii.eqlIgnoreCase(name, "float")) return .float;
    if (std.ascii.eqlIgnoreCase(name, "bool") or std.ascii.eqlIgnoreCase(name, "boolean")) return .boolean;
    if (std.ascii.eqlIgnoreCase(name, "list")) return .list;
    if (std.ascii.eqlIgnoreCase(name, "map") or
        std.ascii.eqlIgnoreCase(name, "record") or
        std.ascii.eqlIgnoreCase(name, "object"))
    {
        return .map;
    }
    return null;
}

const FunctionParam = struct {
    name: []const u8,
    optional: bool,
    param_type: ParamType = .any,

    fn deinit(self: *FunctionParam, allocator: Allocator) void {
        allocator.free(self.name);
    }
};

/// Enables def name [param, param2] { ... }
const ScriptFunction = struct {
    params: []FunctionParam,
    body: []const u8,

    fn deinit(self: *ScriptFunction, allocator: Allocator) void {
        for (self.params) |*param| param.deinit(allocator);
        allocator.free(self.params);
        allocator.free(self.body);
    }
};

/// Map name to fn
const ScriptFunctionMap = std.StringHashMap(ScriptFunction);

const SavedParamBinding = struct {
    had_value: bool = false,
    value: Value = .{ .void = {} },

    fn deinit(self: *SavedParamBinding, allocator: Allocator) void {
        if (self.had_value) {
            self.value.deinit(allocator);
            self.had_value = false;
            self.value = .{ .void = {} };
        }
    }
};

// Structure to hold each elif branch
const ElifBranch = struct {
    condition: []const u8,
    body: std.ArrayList(u8),

    fn deinit(self: *ElifBranch, allocator: Allocator) void {
        if (self.condition.len > 0) {
            allocator.free(self.condition);
        }
        self.body.deinit(allocator);
    }
};

const SwitchCase = struct {
    label: []const u8,
    body: std.ArrayList(u8),

    fn deinit(self: *SwitchCase, allocator: Allocator) void {
        allocator.free(self.label);
        self.body.deinit(allocator);
    }
};

const ControlBlock = struct {
    const Self = @This();
    block_type: BlockType,
    state: ScriptState,
    condition: []const u8,
    nesting_depth: usize = 0,

    // IF, ELIF, ELSE
    if_body: std.ArrayList(u8),
    elif_branches: std.ArrayList(ElifBranch),
    else_body: ?std.ArrayList(u8),
    // FOR
    loop_var: []const u8, // Variable name
    loop_items: [][]const u8, // List of values
    for_body: std.ArrayList(u8), // Body to execute
    // WHILE
    while_body: std.ArrayList(u8),
    start_line: usize = 0,

    const BlockType = enum { if_block, for_block, while_block };

    fn deinit(self: *Self, allocator: Allocator) void {
        switch (self.block_type) {
            .if_block => {
                if (self.condition.len > 0) allocator.free(self.condition);
                self.if_body.deinit(allocator);
                for (self.elif_branches.items) |*branch| branch.deinit(allocator);
                self.elif_branches.deinit(allocator);
                if (self.else_body) |*body| body.deinit(allocator);
            },
            .for_block => {
                if (self.loop_var.len > 0) allocator.free(self.loop_var);
                for (self.loop_items) |item| allocator.free(item);
                allocator.free(self.loop_items);
                self.for_body.deinit(allocator);
            },
            .while_block => {
                if (self.condition.len > 0) allocator.free(self.condition);
                self.while_body.deinit(allocator);
            },
        }
    }
};

pub const ScriptLintIssue = struct {
    line: usize,
    column: usize = 1,
    message: []const u8,
};

/// Parse for def fn
const FunctionHeader = struct {
    name: []const u8,
    params: []FunctionParam,
    opening_segment: ?[]const u8,
};

fn deinitScriptFunctionMap(allocator: Allocator, functions: *ScriptFunctionMap) void {
    var it = functions.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        entry.value_ptr.deinit(allocator);
    }
    functions.deinit();
}

fn isValidParamName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_') return false;
    for (name[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

fn parseParamToken(allocator: Allocator, raw_token: []const u8) !FunctionParam {
    const token_full = std.mem.trim(u8, raw_token, &std.ascii.whitespace);
    if (token_full.len == 0) return ShellError.InvalidSyntax;

    const before_default = if (std.mem.indexOfScalar(u8, token_full, '=')) |default_sep|
        std.mem.trim(u8, token_full[0..default_sep], &std.ascii.whitespace)
    else
        token_full;
    if (before_default.len == 0) return ShellError.InvalidSyntax;

    var token = before_default;
    var param_type: ParamType = .any;
    if (std.mem.indexOfScalar(u8, before_default, ':')) |type_sep| {
        token = std.mem.trim(u8, before_default[0..type_sep], &std.ascii.whitespace);
        const type_name = std.mem.trim(u8, before_default[type_sep + 1 ..], &std.ascii.whitespace);
        if (type_name.len == 0) return ShellError.InvalidSyntax;
        param_type = parseParamType(type_name) orelse return ShellError.InvalidSyntax;
    }

    var optional = false;
    if (std.mem.startsWith(u8, token, "$")) {
        token = token[1..];
    }
    if (std.mem.endsWith(u8, token, "?")) {
        optional = true;
        token = token[0 .. token.len - 1];
    }
    if (!isValidParamName(token)) return ShellError.InvalidSyntax;

    return .{
        .name = try allocator.dupe(u8, token),
        .optional = optional,
        .param_type = param_type,
    };
}

fn parseFunctionParams(allocator: Allocator, raw: []const u8) ![]FunctionParam {
    var raw_tokens = try std.ArrayList([]const u8).initCapacity(allocator, 8);
    defer raw_tokens.deinit(allocator);
    var raw_iter = std.mem.tokenizeAny(u8, raw, " \t\r\n,");
    while (raw_iter.next()) |tok| {
        try raw_tokens.append(allocator, tok);
    }

    var params = try std.ArrayList(FunctionParam).initCapacity(allocator, 4);
    errdefer {
        for (params.items) |*param| param.deinit(allocator);
        params.deinit(allocator);
    }

    var i: usize = 0;
    while (i < raw_tokens.items.len) {
        const token = raw_tokens.items[i];

        if (std.mem.endsWith(u8, token, ":")) {
            if (i + 1 >= raw_tokens.items.len) return ShellError.InvalidSyntax;
            const combined = try std.fmt.allocPrint(allocator, "{s}{s}", .{ token, raw_tokens.items[i + 1] });
            defer allocator.free(combined);
            const parsed = try parseParamToken(allocator, combined);
            try params.append(allocator, parsed);
            i += 2;
            continue;
        }

        if (i + 2 < raw_tokens.items.len and std.mem.eql(u8, raw_tokens.items[i + 1], ":")) {
            const combined = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ token, raw_tokens.items[i + 2] });
            defer allocator.free(combined);
            const parsed = try parseParamToken(allocator, combined);
            try params.append(allocator, parsed);
            i += 3;
            continue;
        }

        const parsed = try parseParamToken(allocator, token);
        try params.append(allocator, parsed);
        i += 1;
    }

    return params.toOwnedSlice(allocator);
}

fn parseJsonArgValue(allocator: Allocator, raw_arg: []const u8) !Value {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw_arg, .{}) catch
        return ShellError.TypeMismatch;
    defer parsed.deinit();
    return types.jsonToValue(allocator, parsed.value) catch ShellError.TypeMismatch;
}

fn inferAnyArgValue(allocator: Allocator, raw_arg: []const u8) !Value {
    if (std.mem.eql(u8, raw_arg, "true")) return .{ .boolean = true };
    if (std.mem.eql(u8, raw_arg, "false")) return .{ .boolean = false };

    if (std.fmt.parseInt(i64, raw_arg, 10) catch null) |n| return .{ .integer = n };
    if (std.fmt.parseFloat(f64, raw_arg) catch null) |f| return .{ .float = f };

    if (raw_arg.len > 0 and (raw_arg[0] == '[' or raw_arg[0] == '{')) {
        return parseJsonArgValue(allocator, raw_arg) catch .{ .text = try allocator.dupe(u8, raw_arg) };
    }

    return .{ .text = try allocator.dupe(u8, raw_arg) };
}

fn parseTypedArgValue(allocator: Allocator, param_type: ParamType, raw_arg: []const u8) !Value {
    return switch (param_type) {
        .any => try inferAnyArgValue(allocator, raw_arg),
        .text => .{ .text = try allocator.dupe(u8, raw_arg) },
        .integer => .{ .integer = std.fmt.parseInt(i64, raw_arg, 10) catch return ShellError.TypeMismatch },
        .float => .{ .float = std.fmt.parseFloat(f64, raw_arg) catch return ShellError.TypeMismatch },
        .boolean => if (std.mem.eql(u8, raw_arg, "true"))
            .{ .boolean = true }
        else if (std.mem.eql(u8, raw_arg, "false"))
            .{ .boolean = false }
        else
            ShellError.TypeMismatch,
        .list => blk: {
            const parsed = try parseJsonArgValue(allocator, raw_arg);
            if (parsed != .list) {
                parsed.deinit(allocator);
                return ShellError.TypeMismatch;
            }
            break :blk parsed;
        },
        .map => blk: {
            const parsed = try parseJsonArgValue(allocator, raw_arg);
            if (parsed != .map) {
                parsed.deinit(allocator);
                return ShellError.TypeMismatch;
            }
            break :blk parsed;
        },
    };
}

fn parseFunctionHeader(allocator: Allocator, trimmed: []const u8) !FunctionHeader {
    if (!std.mem.startsWith(u8, trimmed, "def ")) return ShellError.InvalidSyntax;

    const after_def = std.mem.trim(u8, trimmed[4..], &std.ascii.whitespace);
    if (after_def.len == 0) return ShellError.InvalidSyntax;

    const l_bracket = std.mem.indexOfScalar(u8, after_def, '[') orelse return ShellError.InvalidSyntax;
    const name = std.mem.trim(u8, after_def[0..l_bracket], &std.ascii.whitespace);
    if (name.len == 0) return ShellError.InvalidSyntax;

    const after_l = after_def[l_bracket + 1 ..];
    const r_bracket_rel = std.mem.indexOfScalar(u8, after_l, ']') orelse return ShellError.InvalidSyntax;
    const raw_params = after_l[0..r_bracket_rel];
    const params = try parseFunctionParams(allocator, raw_params);

    const after_sig = std.mem.trim(u8, after_l[r_bracket_rel + 1 ..], &std.ascii.whitespace);
    if (after_sig.len == 0) {
        return .{
            .name = name,
            .params = params,
            .opening_segment = null,
        };
    }

    const open_idx = std.mem.indexOfScalar(u8, after_sig, '{') orelse return ShellError.InvalidSyntax;
    const before_open = std.mem.trim(u8, after_sig[0..open_idx], &std.ascii.whitespace);
    if (before_open.len != 0) return ShellError.InvalidSyntax;

    return .{
        .name = name,
        .params = params,
        .opening_segment = after_sig[open_idx + 1 ..],
    };
}

fn appendFunctionBodySegment(
    allocator: Allocator,
    out: *std.ArrayList(u8),
    segment_raw: []const u8,
    brace_depth: *usize,
) !bool {
    const segment = std.mem.trim(u8, segment_raw, &std.ascii.whitespace);
    var start: usize = 0;
    var i: usize = 0;
    while (i < segment.len) : (i += 1) {
        const c = segment[i];
        if (c == '{') {
            if (i > start) try out.appendSlice(allocator, segment[start..i]);
            brace_depth.* += 1;
            start = i + 1;
            continue;
        }
        if (c == '}') {
            if (i > start) try out.appendSlice(allocator, segment[start..i]);
            if (brace_depth.* == 0) return ShellError.InvalidSyntax;
            brace_depth.* -= 1;
            if (brace_depth.* == 0) {
                const trailing = std.mem.trim(u8, segment[i + 1 ..], &std.ascii.whitespace);
                if (trailing.len != 0) return ShellError.InvalidSyntax;
                return true;
            }
            start = i + 1;
        }
    }

    if (start < segment.len) try out.appendSlice(allocator, segment[start..]);
    try out.append(allocator, '\n');
    return false;
}

fn upsertScriptFunction(
    allocator: Allocator,
    functions: *ScriptFunctionMap,
    name: []const u8,
    function: ScriptFunction,
) !void {
    if (functions.getPtr(name)) |existing| {
        existing.deinit(allocator);
        existing.* = function;
        return;
    }

    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    try functions.put(owned_name, function);
}

fn parseAndStoreFunctionDefinition(
    ctx: *ShellCtx,
    lines: anytype,
    line_num: *usize,
    trimmed: []const u8,
    functions: *ScriptFunctionMap,
) !void {
    const header = try parseFunctionHeader(ctx.allocator, trimmed);
    const params = header.params;
    errdefer {
        for (params) |*param| param.deinit(ctx.allocator);
        ctx.allocator.free(params);
    }

    var opening_segment_opt = header.opening_segment;
    if (opening_segment_opt == null) {
        while (lines.*.next()) |next_line| {
            line_num.* += 1;
            const next_trimmed = std.mem.trim(u8, next_line, &std.ascii.whitespace);
            if (next_trimmed.len == 0 or next_trimmed[0] == '#') continue;

            const open_idx = std.mem.indexOfScalar(u8, next_trimmed, '{') orelse return ShellError.InvalidSyntax;
            const before_open = std.mem.trim(u8, next_trimmed[0..open_idx], &std.ascii.whitespace);
            if (before_open.len != 0) return ShellError.InvalidSyntax;

            opening_segment_opt = next_trimmed[open_idx + 1 ..];
            break;
        }
    }
    if (opening_segment_opt == null) return ShellError.UnterminatedControlFlow;

    var body = try std.ArrayList(u8).initCapacity(ctx.allocator, 64);
    defer body.deinit(ctx.allocator);

    var brace_depth: usize = 1;
    var closed = try appendFunctionBodySegment(ctx.allocator, &body, opening_segment_opt.?, &brace_depth);
    while (!closed) {
        const next_line = lines.*.next() orelse return ShellError.UnterminatedControlFlow;
        line_num.* += 1;
        const next_trimmed = std.mem.trim(u8, next_line, &std.ascii.whitespace);
        if (next_trimmed.len == 0 or next_trimmed[0] == '#') {
            try body.append(ctx.allocator, '\n');
            continue;
        }
        closed = try appendFunctionBodySegment(ctx.allocator, &body, next_trimmed, &brace_depth);
    }

    const owned_body = try body.toOwnedSlice(ctx.allocator);
    errdefer ctx.allocator.free(owned_body);
    const function = ScriptFunction{
        .params = params,
        .body = owned_body,
    };
    try upsertScriptFunction(ctx.allocator, functions, header.name, function);
}

fn parseSimpleInvocationTokens(arena_alloc: Allocator, line: []const u8) !?[]lexer.Token {
    var token_list = try std.ArrayList(lexer.Token).initCapacity(arena_alloc, 8);
    var lex = lexer.Lexer.init(line);
    var expect_command = true;

    // Script function dispatch only intercepts single-command lines.
    // Sequences/pipes/redirections fall back to the normal parser/executor path.
    while (try lex.next(arena_alloc)) |raw_token| {
        var token = raw_token;
        switch (token.kind) {
            .Arg => {
                if (expect_command) {
                    token.kind = .Command;
                    expect_command = false;
                }
            },
            .Var, .Expr, .Command => {
                if (expect_command) {
                    token.kind = .Command;
                    expect_command = false;
                }
            },
            .Assignment, .Pipe, .Semicolon, .And, .Or, .Bg, .Redirect, .GroupStart, .GroupEnd, .Void => return null,
        }
        try token_list.append(arena_alloc, token);
    }

    if (token_list.items.len == 0) return null;
    if (token_list.items[0].kind != .Command) return null;
    return token_list.items;
}

fn requiredParamCount(params: []const FunctionParam) usize {
    var count: usize = 0;
    for (params) |param| {
        if (!param.optional) count += 1;
    }
    return count;
}

fn restoreParamBindings(
    ctx: *ShellCtx,
    fn_def: *const ScriptFunction,
    saved: []SavedParamBinding,
) !void {
    for (fn_def.params, 0..) |param, idx| {
        if (saved[idx].had_value) {
            try ctx.env_map.putShell(param.name, saved[idx].value);
            saved[idx].deinit(ctx.allocator);
        } else {
            ctx.env_map.remove(param.name);
        }
    }
}

fn executeScriptFunction(
    ctx: *ShellCtx,
    arena_alloc: Allocator,
    script_functions: *ScriptFunctionMap,
    function_call_depth: usize,
    fn_name: []const u8,
    fn_def: *const ScriptFunction,
    args: [][]const u8,
    script_name: []const u8,
) anyerror!u8 {
    if (function_call_depth >= MAX_FUNCTION_CALL_DEPTH) {
        ctx.print("{s}: function call depth exceeded for '{s}'\n", .{ script_name, fn_name });
        return ShellError.ResourceLimitReached;
    }

    const provided = if (args.len > 0) args.len - 1 else 0;
    const required = requiredParamCount(fn_def.params);
    if (provided < required or provided > fn_def.params.len) {
        ctx.print(
            "{s}: function '{s}' expected {d}..{d} args, got {d}\n",
            .{ script_name, fn_name, required, fn_def.params.len, provided },
        );
        return 1;
    }

    var saved = try std.ArrayList(SavedParamBinding).initCapacity(ctx.allocator, fn_def.params.len);
    defer {
        for (saved.items) |*entry| entry.deinit(ctx.allocator);
        saved.deinit(ctx.allocator);
    }

    for (fn_def.params, 0..) |param, idx| {
        var prior = SavedParamBinding{};
        if (ctx.env_map.get(param.name)) |existing| {
            prior.had_value = true;
            prior.value = try existing.clone(ctx.allocator);
        }
        try saved.append(ctx.allocator, prior);

        const arg_value = if (idx < provided) blk: {
            const parsed = parseTypedArgValue(ctx.allocator, param.param_type, args[idx + 1]) catch {
                ctx.print(
                    "{s}: function '{s}' arg '{s}' expected type {s}, got '{s}'\n",
                    .{ script_name, fn_name, param.name, paramTypeName(param.param_type), args[idx + 1] },
                );
                return 1;
            };
            break :blk parsed;
        } else Value{ .void = {} };
        defer arg_value.deinit(ctx.allocator);

        try ctx.env_map.putShell(param.name, arg_value);
    }

    const code = executeScriptWithExitCodeInternal(
        ctx,
        arena_alloc,
        fn_def.body,
        script_name,
        script_functions,
        function_call_depth + 1,
    ) catch |err| {
        try restoreParamBindings(ctx, fn_def, saved.items);
        return err;
    };
    try restoreParamBindings(ctx, fn_def, saved.items);
    return code;
}

fn tryExecuteFunctionInvocation(
    ctx: *ShellCtx,
    arena_alloc: Allocator,
    line: []const u8,
    script_name: []const u8,
    script_functions: *ScriptFunctionMap,
    function_call_depth: usize,
) !?u8 {
    const tokens = (try parseSimpleInvocationTokens(arena_alloc, line)) orelse return null;
    const invocation = command.Command{
        .args = tokens,
        .cmd_type = .external,
        .input_type = .text,
        .output_type = .text,
    };

    const expanded_args = try invocation.getExpandedArgs(ctx, arena_alloc);
    if (expanded_args.len == 0) return null;

    const fn_name = expanded_args[0];
    const fn_def = script_functions.get(fn_name) orelse return null;
    const code = try executeScriptFunction(
        ctx,
        arena_alloc,
        script_functions,
        function_call_depth,
        fn_name,
        &fn_def,
        expanded_args,
        script_name,
    );
    ctx.last_exit_code = code;
    return code;
}

fn executeScriptCommandLine(
    ctx: *ShellCtx,
    arena_alloc: Allocator,
    line: []const u8,
    script_name: []const u8,
    script_functions: *ScriptFunctionMap,
    function_call_depth: usize,
) anyerror!u8 {
    if (try tryExecuteFunctionInvocation(
        ctx,
        arena_alloc,
        line,
        script_name,
        script_functions,
        function_call_depth,
    )) |code| {
        return code;
    }
    try parse.parseAndExecute(ctx, arena_alloc, line);
    return ctx.last_exit_code;
}

fn handleLocalDeclaration(ctx: *ShellCtx, arena_alloc: Allocator, line: []const u8) anyerror!bool {
    if (!(std.mem.eql(u8, line, "local") or std.mem.startsWith(u8, line, "local "))) {
        return false;
    }

    // Minimal bash-compatible local handling:
    // - `local name` declares without changing value
    // - `local name=value` behaves like assignment
    // Scoping remains managed by function argument restore logic.
    const rest = if (line.len > 5)
        std.mem.trim(u8, line[5..], &std.ascii.whitespace)
    else
        "";
    if (rest.len == 0) return true;

    var iter = std.mem.tokenizeAny(u8, rest, &std.ascii.whitespace);
    while (iter.next()) |decl| {
        if (helpers.isAssignment(decl)) {
            try execute.executeAssignment(ctx, arena_alloc, decl);
        }
    }
    return true;
}

fn startsWithKeyword(line: []const u8, keyword: []const u8) bool {
    if (!std.mem.startsWith(u8, line, keyword)) return false;
    return line.len == keyword.len or std.ascii.isWhitespace(line[keyword.len]);
}

fn isKeywordWithOptionalSemicolon(line: []const u8, keyword: []const u8) bool {
    if (!std.mem.startsWith(u8, line, keyword)) return false;
    const rest = std.mem.trim(u8, line[keyword.len..], &std.ascii.whitespace);
    return rest.len == 0 or std.mem.eql(u8, rest, ";");
}

fn stripMatchingQuotes(text: []const u8) []const u8 {
    if (text.len < 2) return text;
    const first = text[0];
    const last = text[text.len - 1];
    if ((first == '"' and last == '"') or (first == '\'' and last == '\'')) {
        return text[1 .. text.len - 1];
    }
    return text;
}

fn parseScriptTransferCode(
    ctx: *ShellCtx,
    arena_alloc: Allocator,
    line: []const u8,
    keyword: []const u8,
    fallback: u8,
) u8 {
    const raw_arg = std.mem.trim(u8, line[keyword.len..], &std.ascii.whitespace);
    if (raw_arg.len == 0 or std.mem.eql(u8, raw_arg, ";")) return fallback;

    const expanded = helpers.expandVariables(ctx, arena_alloc, raw_arg) catch raw_arg;
    var parts = std.mem.tokenizeAny(u8, expanded, &std.ascii.whitespace);
    const first = parts.next() orelse return fallback;
    var candidate = stripMatchingQuotes(first);
    if (candidate.len > 0 and candidate[candidate.len - 1] == ';') {
        candidate = std.mem.trim(u8, candidate[0 .. candidate.len - 1], &std.ascii.whitespace);
    }
    if (candidate.len == 0) return fallback;
    return std.fmt.parseInt(u8, candidate, 10) catch 1;
}

fn appendScriptBodyLine(allocator: Allocator, body: *std.ArrayList(u8), line: []const u8) !void {
    try body.appendSlice(allocator, line);
    try body.append(allocator, '\n');
}

const SwitchHeader = struct {
    value_expr: []const u8,
    inline_opening_brace: bool,
};

fn parseSwitchHeader(line: []const u8) !SwitchHeader {
    if (!startsWithKeyword(line, "switch")) return ShellError.InvalidSyntax;

    const after_keyword = std.mem.trim(u8, line["switch".len..], &std.ascii.whitespace);
    if (after_keyword.len == 0 or after_keyword[0] != '[') return ShellError.InvalidSyntax;

    const close_bracket = std.mem.indexOfScalar(u8, after_keyword, ']') orelse return ShellError.InvalidSyntax;
    if (close_bracket <= 1) return ShellError.InvalidSyntax;

    const value_expr = std.mem.trim(u8, after_keyword[1..close_bracket], &std.ascii.whitespace);
    if (value_expr.len == 0) return ShellError.InvalidSyntax;

    const after_expr = std.mem.trim(u8, after_keyword[close_bracket + 1 ..], &std.ascii.whitespace);
    if (after_expr.len == 0) {
        return .{
            .value_expr = value_expr,
            .inline_opening_brace = false,
        };
    }

    if (after_expr[0] != '{') return ShellError.InvalidSyntax;
    if (std.mem.trim(u8, after_expr[1..], &std.ascii.whitespace).len != 0) return ShellError.InvalidSyntax;

    return .{
        .value_expr = value_expr,
        .inline_opening_brace = true,
    };
}

fn parseSwitchCaseLabel(line: []const u8) !?[]const u8 {
    if (!startsWithKeyword(line, "case")) return null;

    const after_case = std.mem.trim(u8, line["case".len..], &std.ascii.whitespace);
    if (after_case.len == 0) return ShellError.InvalidSyntax;

    const colon_idx = std.mem.indexOfScalar(u8, after_case, ':') orelse return ShellError.InvalidSyntax;
    const label = std.mem.trim(u8, after_case[0..colon_idx], &std.ascii.whitespace);
    const trailing = std.mem.trim(u8, after_case[colon_idx + 1 ..], &std.ascii.whitespace);
    if (label.len == 0 or trailing.len != 0) return ShellError.InvalidSyntax;
    return label;
}

fn isSwitchDefaultClause(line: []const u8) bool {
    if (!std.mem.startsWith(u8, line, "default")) return false;
    const rest = std.mem.trim(u8, line["default".len..], &std.ascii.whitespace);
    return std.mem.eql(u8, rest, ":");
}

fn isSwitchBlockClose(line: []const u8) bool {
    return std.mem.eql(u8, line, "}") or std.mem.eql(u8, line, "};");
}

fn resolveSwitchComparableToken(
    ctx: *ShellCtx,
    arena_alloc: Allocator,
    raw: []const u8,
) ![]const u8 {
    const expanded = try helpers.expandVariables(ctx, arena_alloc, raw);
    return stripMatchingQuotes(std.mem.trim(u8, expanded, &std.ascii.whitespace));
}

fn appendConditionFragment(allocator: Allocator, condition: *[]const u8, trimmed: []const u8) !void {
    if (trimmed.len == 0) return;
    if (condition.*.len == 0) {
        condition.* = try allocator.dupe(u8, trimmed);
        return;
    }

    const old = condition.*;
    condition.* = try std.fmt.allocPrint(allocator, "{s} {s}", .{ old, trimmed });
    allocator.free(old);
}

fn startElifBranch(ctx: *ShellCtx, block: *ControlBlock, trimmed: []const u8) !void {
    block.state = .collecting_elif_condition;

    var condition_text: []const u8 = "";
    var immediate_body = false;

    if (trimmed.len > 5) {
        const after_elif = std.mem.trim(u8, trimmed[5..], &std.ascii.whitespace);
        if (std.mem.indexOf(u8, after_elif, "then")) |then_pos| {
            const condition_part = std.mem.trim(u8, after_elif[0..then_pos], &std.ascii.whitespace);
            condition_text = if (std.mem.endsWith(u8, condition_part, ";"))
                std.mem.trim(u8, condition_part[0 .. condition_part.len - 1], &std.ascii.whitespace)
            else
                condition_part;
            immediate_body = true;
        } else {
            condition_text = after_elif;
        }
    }

    const branch = ElifBranch{
        .condition = try ctx.allocator.dupe(u8, condition_text),
        .body = try std.ArrayList(u8).initCapacity(ctx.allocator, 32),
    };
    try block.elif_branches.append(ctx.allocator, branch);
    if (immediate_body) block.state = .collecting_elif_body;
}

fn executeIfChain(
    ctx: *ShellCtx,
    arena_alloc: Allocator,
    block: *ControlBlock,
    script_name: []const u8,
    script_functions: *ScriptFunctionMap,
    function_call_depth: usize,
) anyerror!u8 {
    var code: u8 = ctx.last_exit_code;

    const if_result = try evaluateCondition(
        ctx,
        arena_alloc,
        block.condition,
        script_name,
        script_functions,
        function_call_depth,
    );
    if (if_result) {
        return executeScriptWithExitCodeInternal(
            ctx,
            arena_alloc,
            block.if_body.items,
            script_name,
            script_functions,
            function_call_depth,
        );
    }

    for (block.elif_branches.items) |*elif_branch| {
        const elif_result = try evaluateCondition(
            ctx,
            arena_alloc,
            elif_branch.condition,
            script_name,
            script_functions,
            function_call_depth,
        );
        if (!elif_result) continue;
        return executeScriptWithExitCodeInternal(
            ctx,
            arena_alloc,
            elif_branch.body.items,
            script_name,
            script_functions,
            function_call_depth,
        );
    }

    if (block.else_body) |else_body| {
        code = try executeScriptWithExitCodeInternal(
            ctx,
            arena_alloc,
            else_body.items,
            script_name,
            script_functions,
            function_call_depth,
        );
    }
    return code;
}

fn executeSwitchBlock(
    ctx: *ShellCtx,
    arena_alloc: Allocator,
    lines: anytype,
    line_num: *usize,
    switch_line: usize,
    header_line: []const u8,
    script_name: []const u8,
    script_functions: *ScriptFunctionMap,
    function_call_depth: usize,
) anyerror!u8 {
    const header = try parseSwitchHeader(header_line);

    if (!header.inline_opening_brace) {
        var opened = false;
        while (lines.*.next()) |next_line| {
            line_num.* += 1;
            const next_trimmed = std.mem.trim(u8, next_line, &std.ascii.whitespace);
            if (next_trimmed.len == 0 or next_trimmed[0] == '#') continue;
            if (!std.mem.eql(u8, next_trimmed, "{")) return ShellError.InvalidSyntax;
            opened = true;
            break;
        }
        if (!opened) return ShellError.UnterminatedControlFlow;
    }

    var cases = try std.ArrayList(SwitchCase).initCapacity(ctx.allocator, 4);
    defer {
        for (cases.items) |*branch| branch.deinit(ctx.allocator);
        cases.deinit(ctx.allocator);
    }

    var default_body: ?std.ArrayList(u8) = null;
    defer if (default_body) |*body| body.deinit(ctx.allocator);

    var active_case_idx: ?usize = null;
    var active_default = false;
    var nested_block_depth: usize = 0;
    var pending_nested_open: usize = 0;
    var closed = false;

    while (lines.*.next()) |raw_line| {
        line_num.* += 1;
        const trimmed = std.mem.trim(u8, raw_line, &std.ascii.whitespace);
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        if (std.mem.eql(u8, trimmed, "{") and pending_nested_open > 0) {
            pending_nested_open -= 1;
            nested_block_depth += 1;
            if (active_case_idx) |idx| {
                try appendScriptBodyLine(ctx.allocator, &cases.items[idx].body, trimmed);
            } else if (active_default and default_body != null) {
                try appendScriptBodyLine(ctx.allocator, &default_body.?, trimmed);
            } else {
                return ShellError.InvalidSyntax;
            }
            continue;
        }

        if (isSwitchBlockClose(trimmed)) {
            if (nested_block_depth > 0) {
                nested_block_depth -= 1;
                if (active_case_idx) |idx| {
                    try appendScriptBodyLine(ctx.allocator, &cases.items[idx].body, trimmed);
                } else if (active_default and default_body != null) {
                    try appendScriptBodyLine(ctx.allocator, &default_body.?, trimmed);
                } else {
                    return ShellError.InvalidSyntax;
                }
                continue;
            }

            closed = true;
            break;
        }

        if (nested_block_depth == 0) {
            if (try parseSwitchCaseLabel(trimmed)) |label| {
                var branch = SwitchCase{
                    .label = try ctx.allocator.dupe(u8, label),
                    .body = try std.ArrayList(u8).initCapacity(ctx.allocator, 32),
                };
                errdefer branch.deinit(ctx.allocator);
                try cases.append(ctx.allocator, branch);
                active_case_idx = cases.items.len - 1;
                active_default = false;
                continue;
            }

            if (std.mem.startsWith(u8, trimmed, "case")) return ShellError.InvalidSyntax;

            if (isSwitchDefaultClause(trimmed)) {
                if (default_body != null) return ShellError.InvalidSyntax;
                default_body = try std.ArrayList(u8).initCapacity(ctx.allocator, 32);
                active_case_idx = null;
                active_default = true;
                continue;
            }

            if (startsWithKeyword(trimmed, "default")) return ShellError.InvalidSyntax;
        }

        if (startsWithKeyword(trimmed, "switch")) {
            const nested_header = parseSwitchHeader(trimmed) catch return ShellError.InvalidSyntax;
            if (nested_header.inline_opening_brace) {
                nested_block_depth += 1;
            } else {
                pending_nested_open += 1;
            }
        } else if (std.mem.startsWith(u8, trimmed, "def ")) {
            if (std.mem.indexOfScalar(u8, trimmed, '{') != null) {
                nested_block_depth += 1;
            } else {
                pending_nested_open += 1;
            }
        }

        if (active_case_idx) |idx| {
            try appendScriptBodyLine(ctx.allocator, &cases.items[idx].body, trimmed);
        } else if (active_default and default_body != null) {
            try appendScriptBodyLine(ctx.allocator, &default_body.?, trimmed);
        } else {
            return ShellError.InvalidSyntax;
        }
    }

    if (!closed) return ShellError.UnterminatedControlFlow;

    const switch_value = try resolveSwitchComparableToken(ctx, arena_alloc, header.value_expr);
    var selected_body: ?[]const u8 = null;
    for (cases.items) |*branch| {
        const case_value = try resolveSwitchComparableToken(ctx, arena_alloc, branch.label);
        if (std.mem.eql(u8, switch_value, case_value)) {
            selected_body = branch.body.items;
            break;
        }
    }
    if (selected_body == null and default_body != null) {
        selected_body = default_body.?.items;
    }
    if (selected_body == null) {
        ctx.print(
            "{s}:{d}: switch value '{s}' matched no case and no default branch was provided\n",
            .{ script_name, switch_line, switch_value },
        );
        return ShellError.SwitchNoMatch;
    }

    const code = try executeScriptWithExitCodeInternal(
        ctx,
        arena_alloc,
        selected_body.?,
        script_name,
        script_functions,
        function_call_depth,
    );

    // `break` inside a switch exits the switch block itself and should not leak
    // as a surrounding loop break.
    if (ctx.loop_break) ctx.loop_break = false;
    return code;
}

/// Parse for loop header: "for VAR in ITEM1 ITEM2 ITEM3"
fn parseForHeader(
    arena_allocator: Allocator,
    header: []const u8,
) !struct { var_name: []const u8, items: [][]const u8 } {
    const trimmed = std.mem.trim(u8, header, &std.ascii.whitespace);
    if (!std.mem.startsWith(u8, trimmed, "for ")) return ShellError.InvalidForHeader;

    const for_condition = std.mem.trim(u8, trimmed[4..], &std.ascii.whitespace);

    var in_pos: usize = undefined;
    if (std.mem.indexOf(u8, for_condition, " in ")) |pos| {
        in_pos = pos;
    } else if (std.mem.endsWith(u8, for_condition, " in")) {
        in_pos = for_condition.len - 3;
    } else {
        return ShellError.MissingInKeyword;
    }

    const var_name = std.mem.trim(u8, for_condition[0..in_pos], &std.ascii.whitespace);
    if (var_name.len == 0) return ShellError.EmptyLoopVariable;

    const after_in = in_pos + 3;
    const items_str = if (after_in < for_condition.len)
        std.mem.trim(u8, for_condition[after_in..], &std.ascii.whitespace)
    else
        "";

    var items = try std.ArrayList([]const u8).initCapacity(arena_allocator, 4);
    if (items_str.len > 0) {
        var iter = std.mem.tokenizeAny(u8, items_str, &std.ascii.whitespace);
        while (iter.next()) |item| try items.append(arena_allocator, item);
    }

    return .{
        .var_name = var_name,
        .items = items.items,
    };
}

/// Evaluate condition result for control flow and loops
fn evaluateCondition(
    ctx: *ShellCtx,
    arena_alloc: Allocator,
    condition: []const u8,
    script_name: []const u8,
    script_functions: *ScriptFunctionMap,
    function_call_depth: usize,
) anyerror!bool {
    const saved_running_script = ctx.running_script;
    const saved_exit_code = ctx.last_exit_code;
    ctx.running_script = true;
    defer {
        ctx.running_script = saved_running_script;
        ctx.last_exit_code = saved_exit_code;
    }

    _ = executeScriptCommandLine(
        ctx,
        arena_alloc,
        condition,
        script_name,
        script_functions,
        function_call_depth,
    ) catch {};
    return ctx.last_exit_code == 0;
}

fn appendLintIssue(
    allocator: Allocator,
    issues: *std.ArrayList(ScriptLintIssue),
    line: usize,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const msg = std.fmt.allocPrint(allocator, fmt, args) catch return ShellError.AllocFailed;
    try issues.append(allocator, .{
        .line = line,
        .message = msg,
    });
}

fn lintConditionExpression(
    ctx: *ShellCtx,
    arena_alloc: Allocator,
    condition: []const u8,
    line_no: usize,
    issues: *std.ArrayList(ScriptLintIssue),
) !void {
    const trimmed = std.mem.trim(u8, condition, &std.ascii.whitespace);
    if (trimmed.len == 0) {
        try appendLintIssue(
            arena_alloc,
            issues,
            line_no,
            "expected condition before then/do",
            .{},
        );
        return;
    }
    _ = parse.parseCommandInput(ctx, arena_alloc, trimmed) catch |err| {
        try appendLintIssue(
            arena_alloc,
            issues,
            line_no,
            "expected condition expression; got '{s}' ({s})",
            .{ trimmed, @errorName(err) },
        );
        return;
    };
}

fn lintFunctionInvocationTypes(
    ctx: *ShellCtx,
    arena_alloc: Allocator,
    line: []const u8,
    line_no: usize,
    script_functions: *ScriptFunctionMap,
    issues: *std.ArrayList(ScriptLintIssue),
) !void {
    const tokens = (try parseSimpleInvocationTokens(arena_alloc, line)) orelse return;
    if (tokens.len == 0) return;

    const fn_name = tokens[0].text;
    const fn_def = script_functions.get(fn_name) orelse return;

    const provided = if (tokens.len > 0) tokens.len - 1 else 0;
    const required = requiredParamCount(fn_def.params);
    if (provided < required or provided > fn_def.params.len) {
        try appendLintIssue(
            arena_alloc,
            issues,
            line_no,
            "function '{s}' expected {d}..{d} args, got {d}",
            .{ fn_name, required, fn_def.params.len, provided },
        );
        return;
    }

    for (fn_def.params, 0..) |param, idx| {
        if (idx >= provided) break;
        const arg_tok = tokens[idx + 1];
        if (arg_tok.kind == .Var or arg_tok.kind == .Expr) continue;

        const parsed = parseTypedArgValue(ctx.allocator, param.param_type, arg_tok.text) catch {
            try appendLintIssue(
                arena_alloc,
                issues,
                line_no,
                "expected type {s}; got '{s}'",
                .{ paramTypeName(param.param_type), arg_tok.text },
            );
            continue;
        };
        parsed.deinit(ctx.allocator);
    }
}

fn lintCommandLine(
    ctx: *ShellCtx,
    arena_alloc: Allocator,
    line: []const u8,
    line_no: usize,
    script_functions: *ScriptFunctionMap,
    issues: *std.ArrayList(ScriptLintIssue),
) !void {
    _ = parse.parseCommandInput(ctx, arena_alloc, line) catch |err| {
        try appendLintIssue(
            arena_alloc,
            issues,
            line_no,
            "expected command syntax; got '{s}' ({s})",
            .{ line, @errorName(err) },
        );
        return;
    };
    try lintFunctionInvocationTypes(ctx, arena_alloc, line, line_no, script_functions, issues);
}

fn lintScriptWithIssuesInternal(
    ctx: *ShellCtx,
    arena_alloc: Allocator,
    content: []const u8,
    script_name: []const u8,
    script_functions: *ScriptFunctionMap,
    issues: *std.ArrayList(ScriptLintIssue),
    line_base: usize,
    lint_depth: usize,
) anyerror!void {
    if (lint_depth > MAX_FUNCTION_CALL_DEPTH * 2) {
        try appendLintIssue(arena_alloc, issues, line_base, "lint recursion depth exceeded", .{});
        return;
    }

    var line_num: usize = 1;
    var lines = std.mem.splitScalar(u8, content, '\n');

    var block_stack = try std.ArrayList(ControlBlock).initCapacity(ctx.allocator, 4);
    defer {
        for (block_stack.items) |*block| block.deinit(ctx.allocator);
        block_stack.deinit(ctx.allocator);
    }

    const getCurrentBlock = struct {
        fn get(stack: *std.ArrayList(ControlBlock)) ?*ControlBlock {
            if (stack.items.len == 0) return null;
            return &stack.items[stack.items.len - 1];
        }
    }.get;

    const getCurrentState = struct {
        fn get(stack: *std.ArrayList(ControlBlock)) ScriptState {
            if (stack.items.len == 0) return .normal;
            return stack.items[stack.items.len - 1].state;
        }
    }.get;

    while (lines.next()) |line| {
        const current_line = line_num;
        line_num += 1;
        const abs_line = line_base + current_line - 1;
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        const state = getCurrentState(&block_stack);

        switch (state) {
            .normal => {
                if (std.mem.startsWith(u8, trimmed, "def ")) {
                    const header = parseFunctionHeader(ctx.allocator, trimmed) catch |err| {
                        try appendLintIssue(
                            arena_alloc,
                            issues,
                            abs_line,
                            "expected 'def <name> [params] {{'; got '{s}' ({s})",
                            .{ trimmed, @errorName(err) },
                        );
                        continue;
                    };
                    defer {
                        for (header.params) |*param| param.deinit(ctx.allocator);
                        ctx.allocator.free(header.params);
                    }

                    parseAndStoreFunctionDefinition(
                        ctx,
                        &lines,
                        &line_num,
                        trimmed,
                        script_functions,
                    ) catch |err| {
                        try appendLintIssue(
                            arena_alloc,
                            issues,
                            abs_line,
                            "invalid function body near '{s}' ({s})",
                            .{ trimmed, @errorName(err) },
                        );
                        continue;
                    };

                    if (script_functions.get(header.name)) |fn_def| {
                        try lintScriptWithIssuesInternal(
                            ctx,
                            arena_alloc,
                            fn_def.body,
                            script_name,
                            script_functions,
                            issues,
                            abs_line,
                            lint_depth + 1,
                        );
                    }
                    continue;
                }

                if (std.mem.startsWith(u8, trimmed, "if ") or std.mem.eql(u8, trimmed, "if")) {
                    var new_block = ControlBlock{
                        .block_type = .if_block,
                        .state = .collecting_if_condition,
                        .condition = "",
                        .if_body = try std.ArrayList(u8).initCapacity(ctx.allocator, 32),
                        .elif_branches = try std.ArrayList(ElifBranch).initCapacity(ctx.allocator, 2),
                        .else_body = null,
                        .loop_var = "",
                        .loop_items = &[_][]const u8{},
                        .nesting_depth = 0,
                        .for_body = undefined,
                        .while_body = undefined,
                        .start_line = abs_line,
                    };

                    if (trimmed.len > 2) {
                        const after_if = std.mem.trim(u8, trimmed[2..], &std.ascii.whitespace);
                        if (std.mem.indexOf(u8, after_if, "then")) |then_pos| {
                            const condition_part = std.mem.trim(u8, after_if[0..then_pos], &std.ascii.whitespace);
                            const clean_condition = if (std.mem.endsWith(u8, condition_part, ";"))
                                std.mem.trim(u8, condition_part[0 .. condition_part.len - 1], &std.ascii.whitespace)
                            else
                                condition_part;
                            new_block.condition = try ctx.allocator.dupe(u8, clean_condition);
                            new_block.state = .collecting_if_body;
                        } else {
                            new_block.condition = try ctx.allocator.dupe(u8, after_if);
                        }
                    } else {
                        new_block.condition = try ctx.allocator.dupe(u8, "");
                    }

                    try block_stack.append(ctx.allocator, new_block);
                    continue;
                }

                if (std.mem.startsWith(u8, trimmed, "for ")) {
                    const parsed = parseForHeader(arena_alloc, trimmed) catch |err| {
                        try appendLintIssue(
                            arena_alloc,
                            issues,
                            abs_line,
                            "expected 'for <var> in <items>'; got '{s}' ({s})",
                            .{ trimmed, @errorName(err) },
                        );
                        continue;
                    };

                    var loop_items = try std.ArrayList([]const u8).initCapacity(ctx.allocator, parsed.items.len);
                    errdefer {
                        for (loop_items.items) |item| ctx.allocator.free(item);
                        loop_items.deinit(ctx.allocator);
                    }
                    for (parsed.items) |item| {
                        try loop_items.append(ctx.allocator, try ctx.allocator.dupe(u8, item));
                    }

                    const new_block = ControlBlock{
                        .block_type = .for_block,
                        .state = .collecting_for_header,
                        .condition = "",
                        .loop_var = try ctx.allocator.dupe(u8, parsed.var_name),
                        .loop_items = try loop_items.toOwnedSlice(ctx.allocator),
                        .for_body = try std.ArrayList(u8).initCapacity(ctx.allocator, 64),
                        .nesting_depth = 0,
                        .if_body = undefined,
                        .elif_branches = undefined,
                        .else_body = null,
                        .while_body = undefined,
                        .start_line = abs_line,
                    };
                    try block_stack.append(ctx.allocator, new_block);
                    continue;
                }

                if (std.mem.startsWith(u8, trimmed, "while ") or std.mem.eql(u8, trimmed, "while")) {
                    var new_block = ControlBlock{
                        .block_type = .while_block,
                        .state = .collecting_while_condition,
                        .condition = "",
                        .while_body = try std.ArrayList(u8).initCapacity(ctx.allocator, 32),
                        .nesting_depth = 0,
                        .if_body = undefined,
                        .elif_branches = undefined,
                        .else_body = null,
                        .loop_var = "",
                        .loop_items = &[_][]const u8{},
                        .for_body = undefined,
                        .start_line = abs_line,
                    };

                    if (trimmed.len > 6) {
                        const condition_part = std.mem.trim(u8, trimmed[6..], &std.ascii.whitespace);
                        new_block.condition = try ctx.allocator.dupe(u8, condition_part);
                    } else {
                        new_block.condition = try ctx.allocator.dupe(u8, "");
                    }

                    try block_stack.append(ctx.allocator, new_block);
                    continue;
                }

                if (startsWithKeyword(trimmed, "switch")) {
                    try lintSwitchBlock(
                        ctx,
                        arena_alloc,
                        &lines,
                        &line_num,
                        current_line,
                        trimmed,
                        script_name,
                        script_functions,
                        issues,
                        line_base,
                        lint_depth + 1,
                    );
                    continue;
                }

                if (isKeywordWithOptionalSemicolon(trimmed, "break") or isKeywordWithOptionalSemicolon(trimmed, "continue")) {
                    continue;
                }

                if (std.mem.eql(u8, trimmed, "do") or std.mem.eql(u8, trimmed, "done") or
                    std.mem.eql(u8, trimmed, "fi") or std.mem.eql(u8, trimmed, "else") or
                    std.mem.eql(u8, trimmed, "elif") or std.mem.eql(u8, trimmed, "then") or
                    startsWithKeyword(trimmed, "case") or startsWithKeyword(trimmed, "default"))
                {
                    try appendLintIssue(
                        arena_alloc,
                        issues,
                        abs_line,
                        "unexpected keyword '{s}'",
                        .{trimmed},
                    );
                    continue;
                }

                if (startsWithKeyword(trimmed, "exit") or startsWithKeyword(trimmed, "return") or
                    std.mem.eql(u8, trimmed, "set -e") or std.mem.eql(u8, trimmed, "set +e"))
                {
                    continue;
                }

                if (try handleLocalDeclaration(ctx, arena_alloc, trimmed)) continue;

                try lintCommandLine(ctx, arena_alloc, trimmed, abs_line, script_functions, issues);
            },

            .collecting_if_condition => {
                var block = getCurrentBlock(&block_stack).?;
                if (std.mem.eql(u8, trimmed, "then")) {
                    block.state = .collecting_if_body;
                    continue;
                }

                if (std.mem.indexOf(u8, trimmed, ";")) |semi_pos| {
                    const after_semi = std.mem.trim(u8, trimmed[semi_pos + 1 ..], &std.ascii.whitespace);
                    if (std.mem.eql(u8, after_semi, "then")) {
                        const condition_part = std.mem.trim(u8, trimmed[0..semi_pos], &std.ascii.whitespace);
                        try appendConditionFragment(ctx.allocator, &block.condition, condition_part);
                        block.state = .collecting_if_body;
                        continue;
                    }
                }

                try appendConditionFragment(ctx.allocator, &block.condition, trimmed);
            },

            .collecting_if_body => {
                var block = getCurrentBlock(&block_stack).?;
                if (std.mem.startsWith(u8, trimmed, "if ") or std.mem.eql(u8, trimmed, "if")) {
                    block.nesting_depth += 1;
                }

                if ((std.mem.startsWith(u8, trimmed, "elif ") or std.mem.eql(u8, trimmed, "elif")) and
                    block.nesting_depth == 0)
                {
                    try startElifBranch(ctx, block, trimmed);
                    continue;
                }

                if (std.mem.eql(u8, trimmed, "else") and block.nesting_depth == 0) {
                    block.state = .collecting_else_body;
                    block.else_body = try std.ArrayList(u8).initCapacity(ctx.allocator, 32);
                    continue;
                }

                if (std.mem.eql(u8, trimmed, "fi")) {
                    if (block.nesting_depth > 0) {
                        block.nesting_depth -= 1;
                    } else {
                        try lintConditionExpression(ctx, arena_alloc, block.condition, block.start_line, issues);
                        try lintScriptWithIssuesInternal(
                            ctx,
                            arena_alloc,
                            block.if_body.items,
                            script_name,
                            script_functions,
                            issues,
                            block.start_line + 1,
                            lint_depth + 1,
                        );
                        for (block.elif_branches.items) |*elif_branch| {
                            try lintConditionExpression(ctx, arena_alloc, elif_branch.condition, block.start_line, issues);
                            try lintScriptWithIssuesInternal(
                                ctx,
                                arena_alloc,
                                elif_branch.body.items,
                                script_name,
                                script_functions,
                                issues,
                                block.start_line + 1,
                                lint_depth + 1,
                            );
                        }
                        if (block.else_body) |else_body| {
                            try lintScriptWithIssuesInternal(
                                ctx,
                                arena_alloc,
                                else_body.items,
                                script_name,
                                script_functions,
                                issues,
                                block.start_line + 1,
                                lint_depth + 1,
                            );
                        }

                        var popped = block_stack.pop();
                        if (popped) |_| popped.?.deinit(ctx.allocator);
                        continue;
                    }
                }

                try block.if_body.appendSlice(ctx.allocator, trimmed);
                try block.if_body.append(ctx.allocator, '\n');
            },

            .collecting_else_body => {
                var block = getCurrentBlock(&block_stack).?;
                if (std.mem.startsWith(u8, trimmed, "if ") or std.mem.eql(u8, trimmed, "if")) {
                    block.nesting_depth += 1;
                }

                if (std.mem.eql(u8, trimmed, "fi")) {
                    if (block.nesting_depth > 0) {
                        block.nesting_depth -= 1;
                    } else {
                        try lintConditionExpression(ctx, arena_alloc, block.condition, block.start_line, issues);
                        try lintScriptWithIssuesInternal(
                            ctx,
                            arena_alloc,
                            block.if_body.items,
                            script_name,
                            script_functions,
                            issues,
                            block.start_line + 1,
                            lint_depth + 1,
                        );
                        for (block.elif_branches.items) |*elif_branch| {
                            try lintConditionExpression(ctx, arena_alloc, elif_branch.condition, block.start_line, issues);
                            try lintScriptWithIssuesInternal(
                                ctx,
                                arena_alloc,
                                elif_branch.body.items,
                                script_name,
                                script_functions,
                                issues,
                                block.start_line + 1,
                                lint_depth + 1,
                            );
                        }
                        try lintScriptWithIssuesInternal(
                            ctx,
                            arena_alloc,
                            block.else_body.?.items,
                            script_name,
                            script_functions,
                            issues,
                            block.start_line + 1,
                            lint_depth + 1,
                        );

                        var popped = block_stack.pop();
                        if (popped) |_| popped.?.deinit(ctx.allocator);
                        continue;
                    }
                }

                try block.else_body.?.appendSlice(ctx.allocator, trimmed);
                try block.else_body.?.append(ctx.allocator, '\n');
            },

            .collecting_elif_condition => {
                var block = getCurrentBlock(&block_stack).?;
                if (std.mem.eql(u8, trimmed, "then")) {
                    block.state = .collecting_elif_body;
                    continue;
                }

                if (std.mem.indexOf(u8, trimmed, ";")) |semi_pos| {
                    const after_semi = std.mem.trim(u8, trimmed[semi_pos + 1 ..], &std.ascii.whitespace);
                    if (std.mem.eql(u8, after_semi, "then")) {
                        var current_elif = &block.elif_branches.items[block.elif_branches.items.len - 1];
                        const condition_part = std.mem.trim(u8, trimmed[0..semi_pos], &std.ascii.whitespace);
                        try appendConditionFragment(ctx.allocator, &current_elif.condition, condition_part);
                        block.state = .collecting_elif_body;
                        continue;
                    }
                }

                var current_elif = &block.elif_branches.items[block.elif_branches.items.len - 1];
                try appendConditionFragment(ctx.allocator, &current_elif.condition, trimmed);
            },

            .collecting_elif_body => {
                var block = getCurrentBlock(&block_stack).?;
                if (std.mem.startsWith(u8, trimmed, "if ") or std.mem.eql(u8, trimmed, "if")) {
                    block.nesting_depth += 1;
                }

                if ((std.mem.startsWith(u8, trimmed, "elif ") or std.mem.eql(u8, trimmed, "elif")) and
                    block.nesting_depth == 0)
                {
                    try startElifBranch(ctx, block, trimmed);
                    continue;
                }

                if (std.mem.eql(u8, trimmed, "else") and block.nesting_depth == 0) {
                    block.state = .collecting_else_body;
                    block.else_body = try std.ArrayList(u8).initCapacity(ctx.allocator, 32);
                    continue;
                }

                if (std.mem.eql(u8, trimmed, "fi")) {
                    if (block.nesting_depth > 0) {
                        block.nesting_depth -= 1;
                    } else {
                        try lintConditionExpression(ctx, arena_alloc, block.condition, block.start_line, issues);
                        try lintScriptWithIssuesInternal(
                            ctx,
                            arena_alloc,
                            block.if_body.items,
                            script_name,
                            script_functions,
                            issues,
                            block.start_line + 1,
                            lint_depth + 1,
                        );
                        for (block.elif_branches.items) |*elif_branch| {
                            try lintConditionExpression(ctx, arena_alloc, elif_branch.condition, block.start_line, issues);
                            try lintScriptWithIssuesInternal(
                                ctx,
                                arena_alloc,
                                elif_branch.body.items,
                                script_name,
                                script_functions,
                                issues,
                                block.start_line + 1,
                                lint_depth + 1,
                            );
                        }
                        if (block.else_body) |else_body| {
                            try lintScriptWithIssuesInternal(
                                ctx,
                                arena_alloc,
                                else_body.items,
                                script_name,
                                script_functions,
                                issues,
                                block.start_line + 1,
                                lint_depth + 1,
                            );
                        }

                        var popped = block_stack.pop();
                        if (popped) |_| popped.?.deinit(ctx.allocator);
                        continue;
                    }
                }

                var current_elif = &block.elif_branches.items[block.elif_branches.items.len - 1];
                try current_elif.body.appendSlice(ctx.allocator, trimmed);
                try current_elif.body.append(ctx.allocator, '\n');
            },

            .collecting_for_header => {
                if (std.mem.eql(u8, trimmed, "do")) {
                    if (getCurrentBlock(&block_stack)) |block| block.state = .collecting_for_body;
                    continue;
                }
                try appendLintIssue(
                    arena_alloc,
                    issues,
                    abs_line,
                    "expected 'do'; got '{s}'",
                    .{trimmed},
                );
                var popped = block_stack.pop();
                if (popped) |_| popped.?.deinit(ctx.allocator);
            },

            .collecting_for_body => {
                var block = getCurrentBlock(&block_stack).?;
                if (std.mem.startsWith(u8, trimmed, "for ")) block.nesting_depth += 1;

                if (std.mem.eql(u8, trimmed, "done")) {
                    if (block.nesting_depth > 0) {
                        block.nesting_depth -= 1;
                    } else {
                        try lintScriptWithIssuesInternal(
                            ctx,
                            arena_alloc,
                            block.for_body.items,
                            script_name,
                            script_functions,
                            issues,
                            block.start_line + 1,
                            lint_depth + 1,
                        );
                        var popped = block_stack.pop();
                        if (popped) |_| popped.?.deinit(ctx.allocator);
                        continue;
                    }
                }

                try block.for_body.appendSlice(ctx.allocator, trimmed);
                try block.for_body.append(ctx.allocator, '\n');
            },

            .collecting_while_condition => {
                var block = getCurrentBlock(&block_stack).?;
                if (std.mem.eql(u8, trimmed, "do")) {
                    block.state = .collecting_while_body;
                    continue;
                }
                try appendConditionFragment(ctx.allocator, &block.condition, trimmed);
            },

            .collecting_while_body => {
                var block = getCurrentBlock(&block_stack).?;
                if (std.mem.startsWith(u8, trimmed, "while ")) block.nesting_depth += 1;

                if (std.mem.eql(u8, trimmed, "done")) {
                    if (block.nesting_depth > 0) {
                        block.nesting_depth -= 1;
                    } else {
                        try lintConditionExpression(ctx, arena_alloc, block.condition, block.start_line, issues);
                        try lintScriptWithIssuesInternal(
                            ctx,
                            arena_alloc,
                            block.while_body.items,
                            script_name,
                            script_functions,
                            issues,
                            block.start_line + 1,
                            lint_depth + 1,
                        );
                        var popped = block_stack.pop();
                        if (popped) |_| popped.?.deinit(ctx.allocator);
                        continue;
                    }
                }

                try block.while_body.appendSlice(ctx.allocator, trimmed);
                try block.while_body.append(ctx.allocator, '\n');
            },
        }
    }

    for (block_stack.items) |*block| {
        const err_name = switch (block.block_type) {
            .if_block => "unterminated if block (missing 'fi')",
            .for_block => "unterminated for loop (missing 'done')",
            .while_block => "unterminated while loop (missing 'done')",
        };
        try appendLintIssue(arena_alloc, issues, block.start_line, "{s}", .{err_name});
    }
}

fn lintSwitchBlock(
    ctx: *ShellCtx,
    arena_alloc: Allocator,
    lines: anytype,
    line_num: *usize,
    switch_line: usize,
    header_line: []const u8,
    script_name: []const u8,
    script_functions: *ScriptFunctionMap,
    issues: *std.ArrayList(ScriptLintIssue),
    line_base: usize,
    lint_depth: usize,
) anyerror!void {
    const abs_switch_line = line_base + switch_line - 1;
    const header = parseSwitchHeader(header_line) catch |err| {
        try appendLintIssue(
            arena_alloc,
            issues,
            abs_switch_line,
            "expected 'switch [value] {{'; got '{s}' ({s})",
            .{ header_line, @errorName(err) },
        );
        return;
    };

    if (!header.inline_opening_brace) {
        var opened = false;
        while (lines.*.next()) |next_line| {
            line_num.* += 1;
            const next_trimmed = std.mem.trim(u8, next_line, &std.ascii.whitespace);
            if (next_trimmed.len == 0 or next_trimmed[0] == '#') continue;
            if (!std.mem.eql(u8, next_trimmed, "{")) {
                try appendLintIssue(
                    arena_alloc,
                    issues,
                    line_base + line_num.* - 1,
                    "expected '{{'; got '{s}'",
                    .{next_trimmed},
                );
                return;
            }
            opened = true;
            break;
        }
        if (!opened) {
            try appendLintIssue(arena_alloc, issues, abs_switch_line, "unterminated switch block", .{});
            return;
        }
    }

    const LintSwitchCase = struct {
        label: []const u8,
        body: std.ArrayList(u8),
        line: usize,

        fn deinit(self: *@This(), allocator: Allocator) void {
            allocator.free(self.label);
            self.body.deinit(allocator);
        }
    };

    var cases = try std.ArrayList(LintSwitchCase).initCapacity(ctx.allocator, 4);
    defer {
        for (cases.items) |*branch| branch.deinit(ctx.allocator);
        cases.deinit(ctx.allocator);
    }

    var default_body: ?std.ArrayList(u8) = null;
    var default_line: usize = abs_switch_line;
    defer if (default_body) |*body| body.deinit(ctx.allocator);

    var active_case_idx: ?usize = null;
    var active_default = false;
    var nested_block_depth: usize = 0;
    var pending_nested_open: usize = 0;
    var closed = false;

    while (lines.*.next()) |raw_line| {
        line_num.* += 1;
        const abs_line = line_base + line_num.* - 1;
        const trimmed = std.mem.trim(u8, raw_line, &std.ascii.whitespace);
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        if (std.mem.eql(u8, trimmed, "{") and pending_nested_open > 0) {
            pending_nested_open -= 1;
            nested_block_depth += 1;
            if (active_case_idx) |idx| {
                try appendScriptBodyLine(ctx.allocator, &cases.items[idx].body, trimmed);
            } else if (active_default and default_body != null) {
                try appendScriptBodyLine(ctx.allocator, &default_body.?, trimmed);
            } else {
                try appendLintIssue(
                    arena_alloc,
                    issues,
                    abs_line,
                    "unexpected '{{' in switch body",
                    .{},
                );
            }
            continue;
        }

        if (isSwitchBlockClose(trimmed)) {
            if (nested_block_depth > 0) {
                nested_block_depth -= 1;
                if (active_case_idx) |idx| {
                    try appendScriptBodyLine(ctx.allocator, &cases.items[idx].body, trimmed);
                } else if (active_default and default_body != null) {
                    try appendScriptBodyLine(ctx.allocator, &default_body.?, trimmed);
                } else {
                    try appendLintIssue(
                        arena_alloc,
                        issues,
                        abs_line,
                        "unexpected '{s}'",
                        .{trimmed},
                    );
                }
                continue;
            }

            closed = true;
            break;
        }

        if (nested_block_depth == 0) {
            const maybe_label = parseSwitchCaseLabel(trimmed) catch |err| {
                try appendLintIssue(
                    arena_alloc,
                    issues,
                    abs_line,
                    "expected 'case <value>:'; got '{s}' ({s})",
                    .{ trimmed, @errorName(err) },
                );
                continue;
            };
            if (maybe_label) |label| {
                var branch = LintSwitchCase{
                    .label = try ctx.allocator.dupe(u8, label),
                    .body = try std.ArrayList(u8).initCapacity(ctx.allocator, 32),
                    .line = abs_line,
                };
                errdefer branch.deinit(ctx.allocator);
                try cases.append(ctx.allocator, branch);
                active_case_idx = cases.items.len - 1;
                active_default = false;
                continue;
            }

            if (isSwitchDefaultClause(trimmed)) {
                if (default_body != null) {
                    try appendLintIssue(
                        arena_alloc,
                        issues,
                        abs_line,
                        "duplicate 'default:' clause",
                        .{},
                    );
                    continue;
                }
                default_body = try std.ArrayList(u8).initCapacity(ctx.allocator, 32);
                default_line = abs_line;
                active_case_idx = null;
                active_default = true;
                continue;
            }

            if (startsWithKeyword(trimmed, "default")) {
                try appendLintIssue(
                    arena_alloc,
                    issues,
                    abs_line,
                    "expected 'default:'; got '{s}'",
                    .{trimmed},
                );
                continue;
            }
        }

        if (startsWithKeyword(trimmed, "switch")) {
            const nested_header = parseSwitchHeader(trimmed) catch |err| {
                try appendLintIssue(
                    arena_alloc,
                    issues,
                    abs_line,
                    "expected nested 'switch [value] {{'; got '{s}' ({s})",
                    .{ trimmed, @errorName(err) },
                );
                continue;
            };
            if (nested_header.inline_opening_brace) {
                nested_block_depth += 1;
            } else {
                pending_nested_open += 1;
            }
        } else if (std.mem.startsWith(u8, trimmed, "def ")) {
            if (std.mem.indexOfScalar(u8, trimmed, '{') != null) {
                nested_block_depth += 1;
            } else {
                pending_nested_open += 1;
            }
        }

        if (active_case_idx) |idx| {
            try appendScriptBodyLine(ctx.allocator, &cases.items[idx].body, trimmed);
        } else if (active_default and default_body != null) {
            try appendScriptBodyLine(ctx.allocator, &default_body.?, trimmed);
        } else {
            try appendLintIssue(
                arena_alloc,
                issues,
                abs_line,
                "expected case/default clause before '{s}'",
                .{trimmed},
            );
        }
    }

    if (!closed) {
        try appendLintIssue(arena_alloc, issues, abs_switch_line, "unterminated switch block", .{});
        return;
    }

    for (cases.items) |*branch| {
        try lintScriptWithIssuesInternal(
            ctx,
            arena_alloc,
            branch.body.items,
            script_name,
            script_functions,
            issues,
            branch.line + 1,
            lint_depth + 1,
        );
    }
    if (default_body) |body| {
        try lintScriptWithIssuesInternal(
            ctx,
            arena_alloc,
            body.items,
            script_name,
            script_functions,
            issues,
            default_line + 1,
            lint_depth + 1,
        );
    }

    if (default_body == null) {
        const switch_value = resolveSwitchComparableToken(ctx, arena_alloc, header.value_expr) catch "";
        var has_match = false;
        for (cases.items) |*branch| {
            const case_value = resolveSwitchComparableToken(ctx, arena_alloc, branch.label) catch continue;
            if (std.mem.eql(u8, switch_value, case_value)) {
                has_match = true;
                break;
            }
        }
        if (!has_match) {
            try appendLintIssue(
                arena_alloc,
                issues,
                abs_switch_line,
                "switch value '{s}' has no matching case and no default branch",
                .{switch_value},
            );
        }
    }
}

pub fn lintScript(
    ctx: *ShellCtx,
    arena_alloc: Allocator,
    content: []const u8,
    script_name: []const u8,
    issues: *std.ArrayList(ScriptLintIssue),
) anyerror!void {
    var script_functions = ScriptFunctionMap.init(ctx.allocator);
    defer deinitScriptFunctionMap(ctx.allocator, &script_functions);

    try lintScriptWithIssuesInternal(
        ctx,
        arena_alloc,
        content,
        script_name,
        &script_functions,
        issues,
        1,
        0,
    );
}

/// Main scripting fn call with state machine
pub fn executeScriptWithExitCode(
    ctx: *ShellCtx,
    arena_alloc: Allocator,
    content: []const u8,
    script_name: []const u8,
) anyerror!u8 {
    var script_functions = ScriptFunctionMap.init(ctx.allocator);
    defer deinitScriptFunctionMap(ctx.allocator, &script_functions);

    return executeScriptWithExitCodeInternal(
        ctx,
        arena_alloc,
        content,
        script_name,
        &script_functions,
        0,
    );
}

fn executeScriptWithExitCodeInternal(
    ctx: *ShellCtx,
    arena_alloc: Allocator,
    content: []const u8,
    script_name: []const u8,
    script_functions: *ScriptFunctionMap,
    function_call_depth: usize,
) anyerror!u8 {
    var line_num: usize = 1;
    var lines = std.mem.splitScalar(u8, content, '\n');

    var exit_on_error = false;
    var last_exit_code: u8 = 0;

    const previous_running_script = ctx.running_script;
    ctx.running_script = true;
    defer ctx.running_script = previous_running_script;

    var block_stack = try std.ArrayList(ControlBlock).initCapacity(ctx.allocator, 4);
    defer {
        for (block_stack.items) |*block| block.deinit(ctx.allocator);
        block_stack.deinit(ctx.allocator);
    }

    const getCurrentBlock = struct {
        fn get(stack: *std.ArrayList(ControlBlock)) ?*ControlBlock {
            if (stack.items.len == 0) return null;
            return &stack.items[stack.items.len - 1];
        }
    }.get;

    const getCurrentState = struct {
        fn get(stack: *std.ArrayList(ControlBlock)) ScriptState {
            if (stack.items.len == 0) return .normal;
            return stack.items[stack.items.len - 1].state;
        }
    }.get;

    while (lines.next()) |line| {
        const current_line = line_num;
        line_num += 1;
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        const state = getCurrentState(&block_stack);

        switch (state) {
            .normal => {
                if (std.mem.startsWith(u8, trimmed, "def ")) {
                    parseAndStoreFunctionDefinition(
                        ctx,
                        &lines,
                        &line_num,
                        trimmed,
                        script_functions,
                    ) catch |err| {
                        ctx.print("{s}:{d}: invalid function definition ({s})\n", .{
                            script_name,
                            current_line,
                            @errorName(err),
                        });
                        return err;
                    };
                    continue;
                }

                if (std.mem.startsWith(u8, trimmed, "if ") or std.mem.eql(u8, trimmed, "if")) {
                    var new_block = ControlBlock{
                        .block_type = .if_block,
                        .state = .collecting_if_condition,
                        .condition = "",
                        .if_body = try std.ArrayList(u8).initCapacity(ctx.allocator, 32),
                        .elif_branches = try std.ArrayList(ElifBranch).initCapacity(ctx.allocator, 2),
                        .else_body = null,
                        .loop_var = "",
                        .loop_items = &[_][]const u8{},
                        .nesting_depth = 0,
                        .for_body = undefined,
                        .while_body = undefined,
                    };

                    if (trimmed.len > 2) {
                        const after_if = std.mem.trim(u8, trimmed[2..], &std.ascii.whitespace);
                        if (std.mem.indexOf(u8, after_if, "then")) |then_pos| {
                            const condition_part = std.mem.trim(u8, after_if[0..then_pos], &std.ascii.whitespace);
                            const clean_condition = if (std.mem.endsWith(u8, condition_part, ";"))
                                std.mem.trim(u8, condition_part[0 .. condition_part.len - 1], &std.ascii.whitespace)
                            else
                                condition_part;
                            new_block.condition = try ctx.allocator.dupe(u8, clean_condition);
                            new_block.state = .collecting_if_body;
                        } else {
                            new_block.condition = try ctx.allocator.dupe(u8, after_if);
                        }
                    } else {
                        new_block.condition = try ctx.allocator.dupe(u8, "");
                    }

                    try block_stack.append(ctx.allocator, new_block);
                    continue;
                }

                if (std.mem.startsWith(u8, trimmed, "for ")) {
                    const expanded_header = try helpers.expandVariables(ctx, arena_alloc, trimmed);
                    const header_parts = parseForHeader(arena_alloc, expanded_header) catch |err| {
                        ctx.print("{s}:{d}: invalid for header: {s}\n", .{
                            script_name,
                            current_line,
                            @errorName(err),
                        });
                        return ShellError.InvalidForHeader;
                    };
                    const glob_expanded_items = try helpers.expandGlobList(ctx.io, ctx.allocator, header_parts.items);

                    const new_block = ControlBlock{
                        .block_type = .for_block,
                        .state = .collecting_for_header,
                        .condition = "",
                        .loop_var = try ctx.allocator.dupe(u8, header_parts.var_name),
                        .loop_items = glob_expanded_items,
                        .for_body = try std.ArrayList(u8).initCapacity(ctx.allocator, 64),
                        .nesting_depth = 0,
                        .if_body = undefined,
                        .elif_branches = undefined,
                        .else_body = null,
                        .while_body = undefined,
                    };
                    try block_stack.append(ctx.allocator, new_block);
                    continue;
                }

                if (std.mem.startsWith(u8, trimmed, "while ") or std.mem.eql(u8, trimmed, "while")) {
                    var new_block = ControlBlock{
                        .block_type = .while_block,
                        .state = .collecting_while_condition,
                        .condition = "",
                        .while_body = try std.ArrayList(u8).initCapacity(ctx.allocator, 32),
                        .nesting_depth = 0,
                        .if_body = undefined,
                        .elif_branches = undefined,
                        .else_body = null,
                        .loop_var = "",
                        .loop_items = &[_][]const u8{},
                        .for_body = undefined,
                    };

                    if (trimmed.len > 6) {
                        const condition_part = std.mem.trim(u8, trimmed[6..], &std.ascii.whitespace);
                        new_block.condition = try ctx.allocator.dupe(u8, condition_part);
                    } else {
                        new_block.condition = try ctx.allocator.dupe(u8, "");
                    }

                    try block_stack.append(ctx.allocator, new_block);
                    continue;
                }

                if (startsWithKeyword(trimmed, "switch")) {
                    const code = executeSwitchBlock(
                        ctx,
                        arena_alloc,
                        &lines,
                        &line_num,
                        current_line,
                        trimmed,
                        script_name,
                        script_functions,
                        function_call_depth,
                    ) catch |err| {
                        if (err != ShellError.SwitchNoMatch) {
                            ctx.print("{s}:{d}: invalid switch block ({s})\n", .{
                                script_name,
                                current_line,
                                @errorName(err),
                            });
                        }
                        return err;
                    };
                    last_exit_code = code;
                    ctx.last_exit_code = code;
                    if (ctx.loop_break or ctx.loop_continue) return last_exit_code;
                    if (exit_on_error and last_exit_code != 0) return last_exit_code;
                    continue;
                }

                if (isKeywordWithOptionalSemicolon(trimmed, "break")) {
                    ctx.loop_break = true;
                    return last_exit_code;
                }
                if (isKeywordWithOptionalSemicolon(trimmed, "continue")) {
                    ctx.loop_continue = true;
                    return last_exit_code;
                }

                if (std.mem.eql(u8, trimmed, "do") or std.mem.eql(u8, trimmed, "done") or
                    std.mem.eql(u8, trimmed, "fi") or std.mem.eql(u8, trimmed, "else") or
                    std.mem.eql(u8, trimmed, "elif") or std.mem.eql(u8, trimmed, "then") or
                    startsWithKeyword(trimmed, "case") or startsWithKeyword(trimmed, "default"))
                {
                    return ShellError.InvalidSyntax;
                }

                if (startsWithKeyword(trimmed, "exit")) {
                    return parseScriptTransferCode(ctx, arena_alloc, trimmed, "exit", last_exit_code);
                }
                if (startsWithKeyword(trimmed, "return")) {
                    return parseScriptTransferCode(ctx, arena_alloc, trimmed, "return", last_exit_code);
                }

                if (std.mem.eql(u8, trimmed, "set -e")) {
                    exit_on_error = true;
                    continue;
                }
                if (std.mem.eql(u8, trimmed, "set +e")) {
                    exit_on_error = false;
                    continue;
                }
                if (try handleLocalDeclaration(ctx, arena_alloc, trimmed)) {
                    last_exit_code = 0;
                    ctx.last_exit_code = 0;
                    continue;
                }

                const code = executeScriptCommandLine(
                    ctx,
                    arena_alloc,
                    trimmed,
                    script_name,
                    script_functions,
                    function_call_depth,
                ) catch {
                    last_exit_code = ctx.last_exit_code;
                    if (exit_on_error) return last_exit_code;
                    continue;
                };
                last_exit_code = code;
                ctx.last_exit_code = code;

                if (ctx.loop_break or ctx.loop_continue) return last_exit_code;
                if (exit_on_error and last_exit_code != 0) return last_exit_code;
            },

            .collecting_if_condition => {
                var block = getCurrentBlock(&block_stack).?;
                if (std.mem.eql(u8, trimmed, "then")) {
                    block.state = .collecting_if_body;
                    continue;
                }

                if (std.mem.indexOf(u8, trimmed, ";")) |semi_pos| {
                    const after_semi = std.mem.trim(u8, trimmed[semi_pos + 1 ..], &std.ascii.whitespace);
                    if (std.mem.eql(u8, after_semi, "then")) {
                        const condition_part = std.mem.trim(u8, trimmed[0..semi_pos], &std.ascii.whitespace);
                        try appendConditionFragment(ctx.allocator, &block.condition, condition_part);
                        block.state = .collecting_if_body;
                        continue;
                    }
                }

                try appendConditionFragment(ctx.allocator, &block.condition, trimmed);
            },

            .collecting_if_body => {
                var block = getCurrentBlock(&block_stack).?;
                if (std.mem.startsWith(u8, trimmed, "if ") or std.mem.eql(u8, trimmed, "if")) {
                    block.nesting_depth += 1;
                }

                if ((std.mem.startsWith(u8, trimmed, "elif ") or std.mem.eql(u8, trimmed, "elif")) and
                    block.nesting_depth == 0)
                {
                    try startElifBranch(ctx, block, trimmed);
                    continue;
                }

                if (std.mem.eql(u8, trimmed, "else") and block.nesting_depth == 0) {
                    block.state = .collecting_else_body;
                    block.else_body = try std.ArrayList(u8).initCapacity(ctx.allocator, 32);
                    continue;
                }

                if (std.mem.eql(u8, trimmed, "fi")) {
                    if (block.nesting_depth > 0) {
                        block.nesting_depth -= 1;
                    } else {
                        const code = try executeIfChain(
                            ctx,
                            arena_alloc,
                            block,
                            script_name,
                            script_functions,
                            function_call_depth,
                        );
                        last_exit_code = code;
                        ctx.last_exit_code = code;

                        var popped = block_stack.pop();
                        if (popped) |_| popped.?.deinit(ctx.allocator);
                        if (ctx.loop_break or ctx.loop_continue) return code;
                        continue;
                    }
                }

                try block.if_body.appendSlice(ctx.allocator, trimmed);
                try block.if_body.append(ctx.allocator, '\n');
            },

            .collecting_else_body => {
                var block = getCurrentBlock(&block_stack).?;
                if (std.mem.startsWith(u8, trimmed, "if ") or std.mem.eql(u8, trimmed, "if")) {
                    block.nesting_depth += 1;
                }

                if (std.mem.eql(u8, trimmed, "fi")) {
                    if (block.nesting_depth > 0) {
                        block.nesting_depth -= 1;
                    } else {
                        const code = try executeIfChain(
                            ctx,
                            arena_alloc,
                            block,
                            script_name,
                            script_functions,
                            function_call_depth,
                        );
                        last_exit_code = code;
                        ctx.last_exit_code = code;

                        var popped = block_stack.pop();
                        if (popped) |_| popped.?.deinit(ctx.allocator);
                        if (ctx.loop_break or ctx.loop_continue) return code;
                        continue;
                    }
                }

                try block.else_body.?.appendSlice(ctx.allocator, trimmed);
                try block.else_body.?.append(ctx.allocator, '\n');
            },

            .collecting_elif_condition => {
                var block = getCurrentBlock(&block_stack).?;
                if (std.mem.eql(u8, trimmed, "then")) {
                    block.state = .collecting_elif_body;
                    continue;
                }

                if (std.mem.indexOf(u8, trimmed, ";")) |semi_pos| {
                    const after_semi = std.mem.trim(u8, trimmed[semi_pos + 1 ..], &std.ascii.whitespace);
                    if (std.mem.eql(u8, after_semi, "then")) {
                        var current_elif = &block.elif_branches.items[block.elif_branches.items.len - 1];
                        const condition_part = std.mem.trim(u8, trimmed[0..semi_pos], &std.ascii.whitespace);
                        try appendConditionFragment(ctx.allocator, &current_elif.condition, condition_part);
                        block.state = .collecting_elif_body;
                        continue;
                    }
                }

                var current_elif = &block.elif_branches.items[block.elif_branches.items.len - 1];
                try appendConditionFragment(ctx.allocator, &current_elif.condition, trimmed);
            },

            .collecting_elif_body => {
                var block = getCurrentBlock(&block_stack).?;
                if (std.mem.startsWith(u8, trimmed, "if ") or std.mem.eql(u8, trimmed, "if")) {
                    block.nesting_depth += 1;
                }

                if ((std.mem.startsWith(u8, trimmed, "elif ") or std.mem.eql(u8, trimmed, "elif")) and
                    block.nesting_depth == 0)
                {
                    try startElifBranch(ctx, block, trimmed);
                    continue;
                }

                if (std.mem.eql(u8, trimmed, "else") and block.nesting_depth == 0) {
                    block.state = .collecting_else_body;
                    block.else_body = try std.ArrayList(u8).initCapacity(ctx.allocator, 32);
                    continue;
                }

                if (std.mem.eql(u8, trimmed, "fi")) {
                    if (block.nesting_depth > 0) {
                        block.nesting_depth -= 1;
                    } else {
                        const code = try executeIfChain(
                            ctx,
                            arena_alloc,
                            block,
                            script_name,
                            script_functions,
                            function_call_depth,
                        );
                        last_exit_code = code;
                        ctx.last_exit_code = code;

                        var popped = block_stack.pop();
                        if (popped) |_| popped.?.deinit(ctx.allocator);
                        if (ctx.loop_break or ctx.loop_continue) return code;
                        continue;
                    }
                }

                var current_elif = &block.elif_branches.items[block.elif_branches.items.len - 1];
                try current_elif.body.appendSlice(ctx.allocator, trimmed);
                try current_elif.body.append(ctx.allocator, '\n');
            },

            .collecting_for_header => {
                if (std.mem.eql(u8, trimmed, "do")) {
                    if (getCurrentBlock(&block_stack)) |block| block.state = .collecting_for_body;
                    continue;
                }
                return ShellError.InvalidForHeader;
            },

            .collecting_for_body => {
                var block = getCurrentBlock(&block_stack).?;
                if (std.mem.startsWith(u8, trimmed, "for ")) block.nesting_depth += 1;

                if (std.mem.eql(u8, trimmed, "done")) {
                    if (block.nesting_depth > 0) {
                        block.nesting_depth -= 1;
                    } else {
                        var original_binding = SavedParamBinding{};
                        defer original_binding.deinit(ctx.allocator);
                        if (ctx.env_map.get(block.loop_var)) |existing| {
                            original_binding.had_value = true;
                            original_binding.value = try existing.clone(ctx.allocator);
                        }

                        for (block.loop_items) |item| {
                            try ctx.env_map.putShell(block.loop_var, Value{ .text = item });

                            _ = try executeScriptWithExitCodeInternal(
                                ctx,
                                arena_alloc,
                                block.for_body.items,
                                script_name,
                                script_functions,
                                function_call_depth,
                            );

                            if (ctx.loop_break) {
                                ctx.loop_break = false;
                                break;
                            }
                            if (ctx.loop_continue) {
                                ctx.loop_continue = false;
                                continue;
                            }
                            if (exit_on_error and ctx.last_exit_code != 0) break;
                        }

                        if (original_binding.had_value) {
                            try ctx.env_map.putShell(block.loop_var, original_binding.value);
                            original_binding.deinit(ctx.allocator);
                        } else {
                            ctx.env_map.remove(block.loop_var);
                        }

                        var popped = block_stack.pop();
                        if (popped) |_| popped.?.deinit(ctx.allocator);
                        continue;
                    }
                }

                try block.for_body.appendSlice(ctx.allocator, trimmed);
                try block.for_body.append(ctx.allocator, '\n');
            },

            .collecting_while_condition => {
                var block = getCurrentBlock(&block_stack).?;
                if (std.mem.eql(u8, trimmed, "do")) {
                    block.state = .collecting_while_body;
                    continue;
                }
                try appendConditionFragment(ctx.allocator, &block.condition, trimmed);
            },

            .collecting_while_body => {
                var block = getCurrentBlock(&block_stack).?;
                if (std.mem.startsWith(u8, trimmed, "while ")) block.nesting_depth += 1;

                if (std.mem.eql(u8, trimmed, "done")) {
                    if (block.nesting_depth > 0) {
                        block.nesting_depth -= 1;
                    } else {
                        var iterations: usize = 0;
                        while (true) : (iterations += 1) {
                            if (iterations >= MAX_WHILE_ITERATIONS) {
                                ctx.print("{s}: infinite loop protection triggered\n", .{script_name});
                                return ShellError.InfiniteLoopDetected;
                            }

                            const should_continue = try evaluateCondition(
                                ctx,
                                arena_alloc,
                                block.condition,
                                script_name,
                                script_functions,
                                function_call_depth,
                            );
                            if (!should_continue) break;

                            _ = try executeScriptWithExitCodeInternal(
                                ctx,
                                arena_alloc,
                                block.while_body.items,
                                script_name,
                                script_functions,
                                function_call_depth,
                            );

                            if (ctx.loop_break) {
                                ctx.loop_break = false;
                                break;
                            }
                            if (ctx.loop_continue) {
                                ctx.loop_continue = false;
                                continue;
                            }
                            if (exit_on_error and ctx.last_exit_code != 0) break;
                        }

                        var popped = block_stack.pop();
                        if (popped) |_| popped.?.deinit(ctx.allocator);
                        continue;
                    }
                }

                try block.while_body.appendSlice(ctx.allocator, trimmed);
                try block.while_body.append(ctx.allocator, '\n');
            },
        }
    }

    if (block_stack.items.len != 0) {
        const unterminated = &block_stack.items[block_stack.items.len - 1];
        const error_type = switch (unterminated.block_type) {
            .if_block => ShellError.UnterminatedIfBlock,
            .for_block => ShellError.UnterminatedForLoop,
            .while_block => ShellError.UnterminatedWhileLoop,
        };
        ctx.print("{s}: unterminated {s} block\n", .{ script_name, @tagName(unterminated.block_type) });
        return error_type;
    }

    return last_exit_code;
}

//
// --- TESTS
//

test "script functions: def and call with positional args" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    var io = threaded.io();

    var env_map = try @import("env.zig").EnvMap.init(allocator);
    defer env_map.deinit();

    var ctx = try @import("context.zig").ShellCtx.initEngine(&io, allocator, env_map);
    defer ctx.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const script =
        \\def greet [name] {
        \\  GREETING=$name
        \\}
        \\greet zest
    ;

    const exit_code = try executeScriptWithExitCode(&ctx, arena.allocator(), script, "test_script");
    try std.testing.expectEqual(@as(u8, 0), exit_code);
    const greeting = env_map.get("GREETING") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("zest", greeting.text);
}

test "script functions: optional params and scope restoration" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    var io = threaded.io();

    var env_map = try @import("env.zig").EnvMap.init(allocator);
    defer env_map.deinit();

    var ctx = try @import("context.zig").ShellCtx.initEngine(&io, allocator, env_map);
    defer ctx.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const script =
        \\name=outer
        \\def set_name [name?] {
        \\  RESULT=$name
        \\}
        \\set_name inner
        \\AFTER_FIRST=$name
        \\set_name
        \\AFTER_SECOND=$name
    ;

    const exit_code = try executeScriptWithExitCode(&ctx, arena.allocator(), script, "test_script");
    try std.testing.expectEqual(@as(u8, 0), exit_code);

    const first = env_map.get("AFTER_FIRST") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("outer", first.text);

    const second = env_map.get("AFTER_SECOND") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("outer", second.text);

    const result = env_map.get("RESULT") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("", result.text);
}

test "script functions: callable in if conditions" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    var io = threaded.io();

    var env_map = try @import("env.zig").EnvMap.init(allocator);
    defer env_map.deinit();

    var ctx = try @import("context.zig").ShellCtx.initEngine(&io, allocator, env_map);
    defer ctx.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const script =
        \\def ok [] { true }
        \\if ok
        \\then
        \\  CHECK=passed
        \\fi
    ;

    const exit_code = try executeScriptWithExitCode(&ctx, arena.allocator(), script, "test_script");
    try std.testing.expectEqual(@as(u8, 0), exit_code);

    const check = env_map.get("CHECK") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("passed", check.text);
}

test "script functions: argument validation returns failure code" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    var io = threaded.io();

    var env_map = try @import("env.zig").EnvMap.init(allocator);
    defer env_map.deinit();

    var ctx = try @import("context.zig").ShellCtx.initEngine(&io, allocator, env_map);
    defer ctx.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const script =
        \\def pair [a b] {
        \\  OUT=$a
        \\}
        \\pair only_one
    ;

    const exit_code = try executeScriptWithExitCode(&ctx, arena.allocator(), script, "test_script");
    try std.testing.expectEqual(@as(u8, 1), exit_code);
    try std.testing.expect(env_map.get("OUT") == null);
}

test "script return supports quoted variable status" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    var io = threaded.io();

    var env_map = try @import("env.zig").EnvMap.init(allocator);
    defer env_map.deinit();

    var ctx = try @import("context.zig").ShellCtx.initEngine(&io, allocator, env_map);
    defer ctx.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const script =
        \\STATUS=0
        \\return "$STATUS"
    ;

    const exit_code = try executeScriptWithExitCode(&ctx, arena.allocator(), script, "test_script");
    try std.testing.expectEqual(@as(u8, 0), exit_code);
}

test "script functions: typed params support primitive and any inference" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    var io = threaded.io();

    var env_map = try @import("env.zig").EnvMap.init(allocator);
    defer env_map.deinit();

    var ctx = try @import("context.zig").ShellCtx.initEngine(&io, allocator, env_map);
    defer ctx.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const script =
        \\def typed [i: int f: float flag: bool name: text anyv] {
        \\  OUT_I=$i
        \\  OUT_F=$f
        \\  OUT_FLAG=$flag
        \\  OUT_NAME=$name
        \\  OUT_ANY=$anyv
        \\}
        \\typed 42 1.5 true zest +1
    ;

    const exit_code = try executeScriptWithExitCode(&ctx, arena.allocator(), script, "test_script");
    try std.testing.expectEqual(@as(u8, 0), exit_code);

    const out_i = env_map.get("OUT_I") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("42", out_i.text);

    const out_f = env_map.get("OUT_F") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("1.5", out_f.text);

    const out_flag = env_map.get("OUT_FLAG") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("true", out_flag.text);

    const out_name = env_map.get("OUT_NAME") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("zest", out_name.text);

    const out_any = env_map.get("OUT_ANY") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("1", out_any.text);
}

test "script functions: typed params reject mismatched arguments" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    var io = threaded.io();

    var env_map = try @import("env.zig").EnvMap.init(allocator);
    defer env_map.deinit();

    var ctx = try @import("context.zig").ShellCtx.initEngine(&io, allocator, env_map);
    defer ctx.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const script =
        \\def needs_int [x: int] {
        \\  OUT=$x
        \\}
        \\needs_int nope
    ;

    const exit_code = try executeScriptWithExitCode(&ctx, arena.allocator(), script, "test_script");
    try std.testing.expectEqual(@as(u8, 1), exit_code);
    try std.testing.expect(env_map.get("OUT") == null);
}

test "script switch executes matching case via direct equality" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    var io = threaded.io();

    var env_map = try @import("env.zig").EnvMap.init(allocator);
    defer env_map.deinit();

    var ctx = try @import("context.zig").ShellCtx.initEngine(&io, allocator, env_map);
    defer ctx.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const script =
        \\VAL=2
        \\switch [$VAL] {
        \\  case 1:
        \\    RESULT=one
        \\    break;
        \\  case 2:
        \\    RESULT=two
        \\    break;
        \\  default:
        \\    RESULT=defaulted
        \\}
    ;

    const exit_code = try executeScriptWithExitCode(&ctx, arena.allocator(), script, "test_script");
    try std.testing.expectEqual(@as(u8, 0), exit_code);
    const result = env_map.get("RESULT") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("two", result.text);
}

test "script switch executes default branch when no case matches" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    var io = threaded.io();

    var env_map = try @import("env.zig").EnvMap.init(allocator);
    defer env_map.deinit();

    var ctx = try @import("context.zig").ShellCtx.initEngine(&io, allocator, env_map);
    defer ctx.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const script =
        \\switch [404]
        \\{
        \\  case 200:
        \\    STATUS=ok
        \\    break
        \\  default:
        \\    STATUS=missing
        \\}
    ;

    const exit_code = try executeScriptWithExitCode(&ctx, arena.allocator(), script, "test_script");
    try std.testing.expectEqual(@as(u8, 0), exit_code);
    const status = env_map.get("STATUS") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("missing", status.text);
}

test "script switch reports explicit error when no case matches and no default" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    var io = threaded.io();

    var env_map = try @import("env.zig").EnvMap.init(allocator);
    defer env_map.deinit();

    var ctx = try @import("context.zig").ShellCtx.initEngine(&io, allocator, env_map);
    defer ctx.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const script =
        \\switch [2] {
        \\  case 1:
        \\    RESULT=one
        \\    break;
        \\}
    ;

    try std.testing.expectError(
        ShellError.SwitchNoMatch,
        executeScriptWithExitCode(&ctx, arena.allocator(), script, "test_script"),
    );
}

test "script switch break does not break outer loop" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    var io = threaded.io();

    var env_map = try @import("env.zig").EnvMap.init(allocator);
    defer env_map.deinit();

    var ctx = try @import("context.zig").ShellCtx.initEngine(&io, allocator, env_map);
    defer ctx.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const script =
        \\COUNT=0
        \\for item in a b
        \\do
        \\  switch [$item] {
        \\    case a:
        \\      break;
        \\    case b:
        \\      COUNT=1
        \\      break;
        \\  }
        \\done
    ;

    const exit_code = try executeScriptWithExitCode(&ctx, arena.allocator(), script, "test_script");
    try std.testing.expectEqual(@as(u8, 0), exit_code);
    const count = env_map.get("COUNT") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("1", count.text);
}

test "lintScript reports type mismatch and unterminated blocks" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    var io = threaded.io();

    var env_map = try @import("env.zig").EnvMap.init(allocator);
    defer env_map.deinit();

    var ctx = try @import("context.zig").ShellCtx.initEngine(&io, allocator, env_map);
    defer ctx.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const script =
        \\def needs_int [x:int] {
        \\  OUT=$x
        \\}
        \\needs_int hello
        \\if true
        \\  echo nope
    ;

    var issues = try std.ArrayList(ScriptLintIssue).initCapacity(allocator, 4);
    defer {
        for (issues.items) |issue| allocator.free(issue.message);
        issues.deinit(allocator);
    }

    try lintScript(&ctx, arena.allocator(), script, "lint_test", &issues);
    try std.testing.expect(issues.items.len >= 2);

    var saw_type: bool = false;
    var saw_unterminated: bool = false;
    for (issues.items) |issue| {
        if (std.mem.indexOf(u8, issue.message, "expects type int") != null) saw_type = true;
        if (std.mem.indexOf(u8, issue.message, "unterminated if block") != null) saw_unterminated = true;
    }
    try std.testing.expect(saw_type);
    try std.testing.expect(saw_unterminated);
}

test "lintScript passes valid script" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    var io = threaded.io();

    var env_map = try @import("env.zig").EnvMap.init(allocator);
    defer env_map.deinit();

    var ctx = try @import("context.zig").ShellCtx.initEngine(&io, allocator, env_map);
    defer ctx.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const script =
        \\def greet [name:text] {
        \\  GREETING=$name
        \\}
        \\greet zest
    ;

    var issues = try std.ArrayList(ScriptLintIssue).initCapacity(allocator, 2);
    defer {
        for (issues.items) |issue| allocator.free(issue.message);
        issues.deinit(allocator);
    }

    try lintScript(&ctx, arena.allocator(), script, "lint_test", &issues);
    try std.testing.expectEqual(@as(usize, 0), issues.items.len);
}
