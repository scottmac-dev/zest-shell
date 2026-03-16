const std = @import("std");
const linux = std.os.linux;
const builtins = @import("builtins.zig");
const command = @import("command.zig");
const execute = @import("execute.zig");
const errors = @import("errors.zig");
const fork_exec = @import("fork_exec.zig");
const helpers = @import("helpers.zig");
const types = @import("types.zig");
const Allocator = std.mem.Allocator;
const BuiltinCommand = builtins.BuiltinCommand;
const Command = command.Command;
const RedirConfig = command.RedirConfig;
const ShellCtx = @import("context.zig").ShellCtx;
const ShellError = @import("errors.zig").ShellError;
const Token = @import("lexer.zig").Token;
const TokenKind = @import("lexer.zig").TokenKind;
const TypeTag = types.TypeTag;
const Value = types.Value;
const INIT_CAPACITY = 4;

fn reportPipelineError(
    ctx: *ShellCtx,
    err: anyerror,
    action: []const u8,
    detail: ?[]const u8,
    command_word: ?[]const u8,
) void {
    if (ctx.exe_mode == .interactive and ctx.current_input_line != null) {
        errors.reportInteractive(err, ctx.io.*, ctx.stdout, .{
            .source_line = ctx.current_input_line.?,
            .source_name = "interactive",
            .line_no = 1,
            .action = action,
            .detail = detail,
            .command_word = command_word,
        });
        return;
    }
    errors.report(err, action, detail);
}

pub const Mode = enum { interactive, background, agent };
pub const Contents = enum { builtins_only, externals_mixed };

pub const SequenceOperator = enum {
    none, // No operator (single command/pipeline)
    semicolon, // ; - always run next
    and_op, // && - run next if success
    or_op, // || - run next if failure
};

pub const CommandSequence = struct {
    pipelines: []CommandPipeline,
    operators: []SequenceOperator, // operators[i] connects pipelines[i] to pipelines[i+1]

    pub fn deinit(self: *CommandSequence, allocator: Allocator) void {
        for (self.pipelines) |*pipeline| {
            pipeline.*.deinit(allocator);
        }
        allocator.free(self.pipelines);
        allocator.free(self.operators);
    }
};

pub const CommandPipeline = struct {
    const Self = @This();
    stages: []Command,
    mode: Mode = .interactive,
    contents: Contents = .externals_mixed,
    redir_config: ?RedirConfig = null,
    measure_time: bool = false,

    /// Ensures special builtins not in pipelines to prevent undefined behaviour
    pub fn validate(self: *Self) ShellError!void {
        if (self.stages.len == 0) return ShellError.EmptyPipeline;
        if (self.stages.len == 1) return; // single command
        for (self.stages) |stage| {
            if (stage.cmd_type == .assignment) return ShellError.AssignmentMidPipeline;
            if (stage.cmd_type == .builtin) {
                const tag = BuiltinCommand.fromString(stage.args[0].text);
                if (BuiltinCommand.isNonForkable(tag)) {
                    return ShellError.StateChangeBuiltinInPipeline;
                }
            }
        }
        try self.validateTypeFlow();
    }

    fn validateTypeFlow(self: *Self) ShellError!void {
        if (self.stages.len < 2) return;

        var i: usize = 0;
        while (i + 1 < self.stages.len) : (i += 1) {
            const lhs = self.stages[i];
            const rhs = self.stages[i + 1];
            if (rhs.cmd_type != .builtin) continue;

            const rhs_name = rhs.args[0].text;
            const rhs_tag = BuiltinCommand.fromString(rhs_name);
            const rhs_sig = builtins.getTypeSignature(rhs_tag);
            const expected = rhs_sig.input_type orelse continue;
            const actual = lhs.output_type;

            const compatible = actual == expected;
            if (compatible) continue;

            if (rhs_sig.strict_input) {
                return ShellError.TypeMismatch;
            }

            std.log.warn(
                "pipeline type warning: '{s}' outputs {s}, but '{s}' expects {s}",
                .{ lhs.args[0].text, typeTagName(actual), rhs_name, typeTagName(expected) },
            );
        }
    }
};

const GroupRedirect = struct {
    symbol: ?Token = null,
    target: ?Token = null,
    next_index: usize,
};

inline fn isSequenceSeparator(kind: TokenKind) bool {
    return kind == .Semicolon or kind == .And or kind == .Or;
}

fn findGroupEnd(tokens: []Token, start_idx: usize) ShellError!usize {
    var idx = start_idx;
    while (idx < tokens.len) : (idx += 1) {
        switch (tokens[idx].kind) {
            // Keep grouping intentionally simple and predictable.
            .GroupStart => return ShellError.InvalidSyntax,
            .GroupEnd => return idx,
            else => {},
        }
    }
    return ShellError.InvalidSyntax;
}

fn parseGroupRedirect(tokens: []Token, start_idx: usize) ShellError!GroupRedirect {
    if (start_idx >= tokens.len or tokens[start_idx].kind != .Redirect) {
        return .{ .next_index = start_idx };
    }

    const symbol = tokens[start_idx];
    if (std.mem.eql(u8, symbol.text, "2>&1")) {
        return .{
            .symbol = symbol,
            .next_index = start_idx + 1,
        };
    }

    if (start_idx + 1 >= tokens.len) return ShellError.InvalidSyntax;
    const target = tokens[start_idx + 1];
    if (target.kind != .Arg and target.kind != .Var and target.kind != .Expr) {
        return ShellError.InvalidSyntax;
    }

    return .{
        .symbol = symbol,
        .target = target,
        .next_index = start_idx + 2,
    };
}

fn appendExpandedGroupTokens(
    arena_alloc: std.mem.Allocator,
    out: *std.ArrayList(Token),
    inner_tokens: []Token,
    redirect_symbol: ?Token,
    redirect_target: ?Token,
) ShellError!void {
    if (inner_tokens.len == 0) return ShellError.InvalidSyntax;

    var segment_start: usize = 0;
    var idx: usize = 0;
    while (idx <= inner_tokens.len) : (idx += 1) {
        const at_end = idx == inner_tokens.len;
        const is_separator = !at_end and isSequenceSeparator(inner_tokens[idx].kind);
        if (!at_end and (inner_tokens[idx].kind == .GroupStart or inner_tokens[idx].kind == .GroupEnd)) {
            return ShellError.InvalidSyntax;
        }
        if (!at_end and !is_separator) continue;

        const segment = inner_tokens[segment_start..idx];
        if (segment.len == 0) return ShellError.InvalidSyntax;

        for (segment) |token| {
            out.append(arena_alloc, token) catch return ShellError.AllocFailed;
        }

        if (redirect_symbol) |symbol| {
            out.append(arena_alloc, symbol) catch return ShellError.AllocFailed;
            if (redirect_target) |target| {
                out.append(arena_alloc, target) catch return ShellError.AllocFailed;
            }
        }

        if (is_separator) {
            out.append(arena_alloc, inner_tokens[idx]) catch return ShellError.AllocFailed;
        }
        segment_start = idx + 1;
    }
}

/// Expand grouped command syntax `{...} [redirect]` into a flat token stream.
/// Redirects after the group are applied to each sequence segment inside the group.
pub fn expandGroupedSequenceRedirects(arena_alloc: std.mem.Allocator, tokens: []Token) ShellError![]Token {
    var out = std.ArrayList(Token).initCapacity(arena_alloc, tokens.len) catch return ShellError.AllocFailed;
    var changed = false;

    var i: usize = 0;
    while (i < tokens.len) {
        const token = tokens[i];
        switch (token.kind) {
            .GroupStart => {
                changed = true;

                const group_end = try findGroupEnd(tokens, i + 1);
                const redirect = try parseGroupRedirect(tokens, group_end + 1);
                try appendExpandedGroupTokens(arena_alloc, &out, tokens[i + 1 .. group_end], redirect.symbol, redirect.target);
                i = redirect.next_index;
            },
            .GroupEnd => return ShellError.InvalidSyntax,
            else => {
                out.append(arena_alloc, token) catch return ShellError.AllocFailed;
                i += 1;
            },
        }
    }

    if (!changed) return tokens;
    return out.items;
}

fn typeTagName(tag: TypeTag) []const u8 {
    return switch (tag) {
        .void => "void",
        .text => "text",
        .integer => "integer",
        .float => "float",
        .boolean => "boolean",
        .list => "list",
        .map => "map",
        .err => "err",
    };
}

fn isMergeRedirect(text: []const u8) bool {
    return std.mem.eql(u8, text, "2>&1") or
        std.mem.eql(u8, text, "&>") or
        std.mem.eql(u8, text, "&>>");
}

fn inferBuiltinOutputType(cmd_tag: BuiltinCommand, args: []Token, fallback: ?TypeTag) TypeTag {
    switch (cmd_tag) {
        .cmd_help => {
            var has_all = false;
            var has_find = false;
            var has_summary = false;
            var has_positional = false;
            for (args[1..]) |arg| {
                if (arg.kind != .Arg and arg.kind != .Var and arg.kind != .Expr) continue;
                if (std.mem.eql(u8, arg.text, "--all")) has_all = true;
                if (std.mem.eql(u8, arg.text, "--find")) has_find = true;
                if (std.mem.eql(u8, arg.text, "--summary")) has_summary = true;
                if (!std.mem.startsWith(u8, arg.text, "-")) has_positional = true;
            }
            if (has_summary) return .map;
            if (has_all or has_find) return .list;
            if (has_positional) return .map;
        },
        else => {},
    }
    return fallback orelse TypeTag.text;
}

/// Command sequence is a more generic and flexible version of a pipeline
/// it allows for non-piped, sequential commands to be specified, instead of
/// piping everything by default
pub fn generateCommandSequence(arena_alloc: std.mem.Allocator, tokens: []Token) ShellError!CommandSequence {
    // Split tokens by sequence operators (;, &&, ||)
    // Each group becomes a separate pipeline
    var pipeline_groups = std.ArrayList([]Token).initCapacity(arena_alloc, INIT_CAPACITY) catch return ShellError.AllocFailed;
    var operators = std.ArrayList(SequenceOperator).initCapacity(arena_alloc, INIT_CAPACITY) catch return ShellError.AllocFailed;

    var start: usize = 0;
    for (tokens, 0..) |token, i| {
        // Check for sequence operators (not pipe | which stays within pipeline)
        if (token.kind == .Semicolon or token.kind == .And or token.kind == .Or) {
            // Save the tokens for this pipeline (from start to current position)
            pipeline_groups.append(arena_alloc, tokens[start..i]) catch return ShellError.AllocFailed;

            // Save the operator that connects this pipeline to the next
            const op = switch (token.kind) {
                .Semicolon => SequenceOperator.semicolon,
                .And => SequenceOperator.and_op,
                .Or => SequenceOperator.or_op,
                else => unreachable,
            };

            // Dont add trailing semicolons
            if (i != tokens.len - 1) {
                operators.append(arena_alloc, op) catch return ShellError.AllocFailed;
            }

            // Next pipeline starts after this operator
            start = i + 1;
        }
    }

    // Add final pipeline (everything after last operator, or all tokens if no operators)
    if (start < tokens.len) {
        pipeline_groups.append(arena_alloc, tokens[start..]) catch return ShellError.AllocFailed;
    }

    // If no tokens at all, error
    if (pipeline_groups.items.len == 0) {
        return ShellError.EmptyCommandSequence;
    }

    // Generate CommandPipeline for each group using your existing function
    // This handles all the redirect, background, builtin/exe logic automatically
    var pipelines = std.ArrayList(CommandPipeline).initCapacity(arena_alloc, INIT_CAPACITY) catch return ShellError.AllocFailed;
    //std.debug.print("pipeline groups: {d}\n", .{pipeline_groups.items.len});

    for (pipeline_groups.items) |group_tokens| {
        // Existing generateCommandPipeline handles:
        // - Commands and args
        // - Pipes (|) within the group
        // - Redirects (>, >>)
        // - Background (&)
        // - Builtin vs exe detection
        var pipeline = try generateCommandPipeline(arena_alloc, group_tokens);
        try pipeline.validate();
        pipelines.append(arena_alloc, pipeline) catch return ShellError.AllocFailed;
    }

    // Note: memory freed by arena and not deinit here so .items should be fine
    return CommandSequence{
        .pipelines = pipelines.items,
        .operators = operators.items,
    };
}

fn appendAssignmentStage(
    stages: *std.ArrayList(Command),
    arena_alloc: std.mem.Allocator,
    token: Token,
) ShellError!void {
    const args = arena_alloc.alloc(Token, 1) catch return ShellError.AllocFailed;
    args[0] = token;
    stages.append(arena_alloc, .{
        .args = args,
        .cmd_type = .assignment,
        .input_type = TypeTag.void,
        .output_type = TypeTag.void,
    }) catch return ShellError.AllocFailed;
}

// generate a CommandPipeline from an array of semantic Tokens
pub fn generateCommandPipeline(arena_alloc: std.mem.Allocator, tokens: []Token) ShellError!CommandPipeline {
    var stages = std.ArrayList(Command).initCapacity(arena_alloc, INIT_CAPACITY) catch return ShellError.AllocFailed;

    var mode: Mode = .interactive;

    var redir_config: ?RedirConfig = null;
    var pending_redir: ?[]const u8 = null; // last seen redirect symbol awaiting its path

    var contains_builtin: bool = false;
    var contains_external: bool = false;

    var i: usize = 0;
    while (i < tokens.len) {
        var leading_assignments: []const Token = &.{};
        if (tokens[i].kind == .Assignment) {
            const assign_start = i;
            while (i < tokens.len and tokens[i].kind == .Assignment) : (i += 1) {}

            // Prefix assignment form: X=1 cmd ...
            if (i < tokens.len and tokens[i].kind == .Command) {
                leading_assignments = tokens[assign_start..i];
            } else {
                // Standalone assignment form: X=1 ; Y=2
                for (tokens[assign_start..i]) |assignment_token| {
                    try appendAssignmentStage(&stages, arena_alloc, assignment_token);
                    contains_builtin = true;
                }
                continue;
            }
        }

        const token = tokens[i];
        const is_last: bool = i == tokens.len - 1;

        switch (token.kind) {
            .Command => {
                var arg_tokens = std.ArrayList(Token).initCapacity(arena_alloc, tokens.len) catch return ShellError.AllocFailed;

                // Add the command itself as first arg
                arg_tokens.append(arena_alloc, token) catch return ShellError.AllocFailed;

                // collect args
                if (!is_last) {
                    i += 1;
                    for (tokens[i..]) |*next_token| {
                        switch (next_token.kind) {
                            .Arg, .Var, .Expr => {
                                // Could be a redirect path or a real arg
                                if (pending_redir) |sym| {
                                    // This arg is the path for the pending redirect
                                    if (redir_config == null) redir_config = RedirConfig{};
                                    const cfg = &redir_config.?;
                                    cfg.applySymbol(sym);
                                    // Assign path to correct slot
                                    if (std.mem.eql(u8, sym, "<")) {
                                        cfg.stdin_path = next_token.text;
                                    } else if (std.mem.eql(u8, sym, "2>") or std.mem.eql(u8, sym, "2>>")) {
                                        cfg.stderr_path = next_token.text;
                                    } else {
                                        cfg.stdout_path = next_token.text;
                                    }
                                    pending_redir = null;
                                } else {
                                    arg_tokens.append(arena_alloc, next_token.*) catch return ShellError.AllocFailed;
                                }
                            },
                            .Redirect => {
                                const current_cmd: BuiltinCommand = if (arg_tokens.items.len > 0)
                                    BuiltinCommand.fromString(arg_tokens.items[0].text)
                                else
                                    .external;

                                // For builtins that allow angle bracket args, check if predicate is already complete
                                // args[0] = cmd, args[1] = field, args[2] = op, args[3] = value -> 4 tokens = predicate done
                                const predicate_complete = arg_tokens.items.len >= 4;

                                const treat_as_redirect = blk: {
                                    if (!BuiltinCommand.allowAngleBracketArgs(current_cmd)) break :blk true;
                                    if (predicate_complete) break :blk true;
                                    // Only treat as arg if it's actually a comparison operator
                                    const is_comparison = std.mem.eql(u8, next_token.text, ">") or
                                        std.mem.eql(u8, next_token.text, "<") or
                                        std.mem.eql(u8, next_token.text, ">=") or
                                        std.mem.eql(u8, next_token.text, "<=");
                                    break :blk !is_comparison;
                                };

                                if (treat_as_redirect) {
                                    if (isMergeRedirect(next_token.text)) {
                                        if (redir_config == null) redir_config = RedirConfig{};
                                        redir_config.?.applySymbol(next_token.text);
                                        if (!std.mem.eql(u8, next_token.text, "2>&1")) {
                                            pending_redir = next_token.text;
                                        }
                                    } else {
                                        pending_redir = next_token.text;
                                    }
                                } else {
                                    next_token.*.kind = .Arg;
                                    arg_tokens.append(arena_alloc, next_token.*) catch return ShellError.AllocFailed;
                                }
                            },
                            .Bg => {
                                mode = .background;
                                break;
                            },
                            .Assignment => {
                                // only valid after command export
                                if (arg_tokens.items.len == 1 and std.mem.eql(u8, arg_tokens.items[0].text, "export")) {
                                    arg_tokens.append(arena_alloc, next_token.*) catch return ShellError.AllocFailed;
                                } else {
                                    return ShellError.InvalidTokenSequence;
                                }
                            },
                            .Pipe => break,
                            .Command, .And, .Or, .Semicolon, .GroupStart, .GroupEnd => {
                                // These should have been filtered by generateCommandSequence
                                return ShellError.InvalidTokenSequence;
                            },
                            .Void => {
                                return ShellError.InvalidToken;
                            },
                        }
                        i += 1;
                    }
                }

                var normalized_args = arg_tokens.items;
                var force_external = false;
                if (leading_assignments.len > 0) {
                    const original_cmd = arg_tokens.items[0].text;
                    const allow_prefix = !builtins.isBuiltinCmd(original_cmd) or std.mem.eql(u8, original_cmd, "env");
                    if (!allow_prefix) return ShellError.InvalidTokenSequence;

                    // Lower-risk compatibility path:
                    // rewrite `X=1 cmd ...` as `env X=1 cmd ...` for external execution.
                    var prefixed_args = std.ArrayList(Token).initCapacity(
                        arena_alloc,
                        arg_tokens.items.len + leading_assignments.len + 1,
                    ) catch return ShellError.AllocFailed;

                    prefixed_args.append(arena_alloc, .{
                        .kind = .Command,
                        .text = "env",
                    }) catch return ShellError.AllocFailed;
                    for (leading_assignments) |assignment_token| {
                        var as_arg = assignment_token;
                        as_arg.kind = .Arg;
                        prefixed_args.append(arena_alloc, as_arg) catch return ShellError.AllocFailed;
                    }
                    if (std.mem.eql(u8, original_cmd, "env")) {
                        if (arg_tokens.items.len > 1) {
                            prefixed_args.appendSlice(arena_alloc, arg_tokens.items[1..]) catch return ShellError.AllocFailed;
                        }
                    } else {
                        prefixed_args.appendSlice(arena_alloc, arg_tokens.items) catch return ShellError.AllocFailed;
                    }
                    normalized_args = prefixed_args.items;
                    force_external = true;
                }

                // Use command name for lookup
                const lookup_name = normalized_args[0].text;
                const cmd_type: command.CmdType = if (force_external)
                    .external
                else if (builtins.isBuiltinCmd(lookup_name))
                    .builtin
                else
                    .external;

                switch (cmd_type) {
                    .external => {
                        contains_external = true;

                        // external commands use fallback text as expected types
                        stages.append(arena_alloc, .{
                            .args = normalized_args,
                            .cmd_type = cmd_type,
                            .input_type = TypeTag.text,
                            .output_type = TypeTag.text,
                        }) catch return ShellError.AllocFailed;
                    },
                    .builtin, .assignment => {
                        contains_builtin = true;
                        const cmd_tag = BuiltinCommand.fromString(lookup_name);
                        const sig = builtins.getTypeSignature(cmd_tag);
                        stages.append(arena_alloc, .{
                            .args = normalized_args,
                            .cmd_type = cmd_type,
                            .input_type = sig.input_type orelse TypeTag.text,
                            .output_type = inferBuiltinOutputType(cmd_tag, normalized_args, sig.output_type),
                        }) catch return ShellError.AllocFailed;
                    },
                }
            },
            .Assignment => {
                contains_builtin = true;
                try appendAssignmentStage(&stages, arena_alloc, token);
            },
            .Bg => {
                mode = .background;
            },
            .Arg => {
                // Redirect path at pipeline level (after a pipe stage)
                if (pending_redir) |sym| {
                    if (redir_config == null) redir_config = RedirConfig{};
                    const cfg = &redir_config.?;
                    cfg.applySymbol(sym);
                    if (std.mem.eql(u8, sym, "<")) {
                        cfg.stdin_path = token.text;
                    } else if (std.mem.eql(u8, sym, "2>") or std.mem.eql(u8, sym, "2>>")) {
                        cfg.stderr_path = token.text;
                    } else {
                        cfg.stdout_path = token.text;
                    }
                    pending_redir = null;
                }
            },
            .Redirect => {
                if (isMergeRedirect(token.text)) {
                    if (redir_config == null) redir_config = RedirConfig{};
                    redir_config.?.applySymbol(token.text);
                    if (!std.mem.eql(u8, token.text, "2>&1")) {
                        pending_redir = token.text;
                    }
                } else {
                    pending_redir = token.text;
                }
            },

            .Pipe => {},
            .Var, .Expr => {
                // Variables/expressions outside command context shouldn't happen
                return ShellError.UnexpectedToken;
            },
            .And, .Or, .Semicolon, .GroupStart, .GroupEnd => {
                // These should have been handled by generateCommandSequence
                return ShellError.InvalidTokenSequence;
            },
            .Void => {
                return ShellError.InvalidToken;
            },
        }
        i += 1;
    }
    var contents: Contents = .externals_mixed;
    if (contains_builtin and !contains_external)
        contents = .builtins_only;

    return CommandPipeline{
        .stages = stages.items,
        .contents = contents,
        .mode = mode,
        .redir_config = redir_config,
    };
}

/// PIPELINE excution logic
/// Delegates execution logic based on contents
pub fn executePipeline(ctx: *ShellCtx, arena_alloc: Allocator, pipeline: CommandPipeline, bg_pgid_out: ?*linux.pid_t) u8 {
    switch (pipeline.contents) {
        .builtins_only => {
            // Run pipeline in main process and pipe native zig Values directly
            // Much more performant with no syscalls but harder for job control and signals
            return executePipelineBuiltins(ctx, arena_alloc, pipeline) catch |err| {
                reportPipelineError(ctx, err, "execute builtin-only pipeline", null, null);
                return 1;
            };
        },
        .externals_mixed => {
            // Manually handle fork and exec between builtins and externals
            // handles job control and posix signals natively and outsources IO to kernel pipes
            switch (ctx.exe_mode) {
                .interactive => return executePipelineForkedInteractive(ctx, arena_alloc, pipeline, bg_pgid_out) catch |err| {
                    reportPipelineError(ctx, err, "execute interactive mixed pipeline", null, null);
                    return 1;
                },
                .engine => return executePipelineForkedEngine(ctx, arena_alloc, pipeline) catch |err| {
                    errors.report(err, "execute engine mixed pipeline", null);
                    return 1;
                },
            }
        },
    }
}

const BuiltinPipelineOutput = struct {
    target: command.ExecOutput,
    owns_file: bool,
};

fn openBuiltinPipelineFinalOutput(ctx: *ShellCtx, arena_alloc: Allocator, cfg: ?RedirConfig) ShellError!BuiltinPipelineOutput {
    if (cfg) |c| {
        if (c.stdout_path) |path| {
            const f = helpers.getFileFromPath(ctx, arena_alloc, path, .{
                .write = true,
                .pre_expanded = false,
                .truncate = c.stdout_truncate,
            }) catch |err| return errors.mapRedirectOpenError(err);
            return .{
                .target = .{ .stream = f },
                .owns_file = true,
            };
        }
    }
    return .{
        .target = .{ .stream = ctx.stdout },
        .owns_file = false,
    };
}

fn openBuiltinPipelineInitialInput(ctx: *ShellCtx, arena_alloc: Allocator, cfg: ?RedirConfig) ShellError!command.ExecInput {
    if (cfg) |c| {
        if (c.stdin_path) |path| {
            const f = helpers.getFileFromPath(ctx, arena_alloc, path, .{
                .pre_expanded = false,
                .write = false,
                .truncate = false,
            }) catch |err| return errors.mapRedirectOpenError(err);
            return .{ .stream = f };
        }
    }
    return .none;
}

fn closeExecInputIfStream(ctx: *ShellCtx, input: command.ExecInput) void {
    switch (input) {
        .stream => |f| f.close(ctx.io.*),
        else => {},
    }
}

fn builtinPipelineExitCode(
    ctx: *ShellCtx,
    output_value: Value,
    command_word: []const u8,
) u8 {
    return switch (output_value) {
        .err => |e| blk: {
            reportPipelineError(ctx, e, "execute builtin in pipeline", command_word, command_word);
            break :blk 1;
        },
        .boolean => |b| if (b) 0 else 1,
        else => 0,
    };
}

fn printBuiltinPipelineScalarFallback(
    ctx: *ShellCtx,
    arena_alloc: Allocator,
    output_value: Value,
) ShellError!void {
    switch (output_value) {
        .void, .boolean, .err, .list, .map => {},
        else => {
            const text = output_value.toString(arena_alloc) catch return ShellError.AllocFailed;
            if (text.len > 0) ctx.print("{s}", .{text});
        },
    }
}

/// Builtins only pipeline passes typed Value
pub fn executePipelineBuiltins(ctx: *ShellCtx, arena_alloc: Allocator, pipeline: CommandPipeline) ShellError!u8 {
    const num_commands = pipeline.stages.len;
    var builtin_outputs = std.ArrayList(Value).initCapacity(arena_alloc, num_commands) catch return ShellError.AllocFailed;

    const cfg: ?RedirConfig = pipeline.redir_config;
    const final_output = try openBuiltinPipelineFinalOutput(ctx, arena_alloc, cfg);
    defer if (final_output.owns_file) final_output.target.stream.close(ctx.io.*);

    var final_exit_code: u8 = 0;

    for (pipeline.stages, 0..) |*cmd, idx| {
        const is_first = idx == 0;
        const is_last = idx == num_commands - 1;

        const expanded_args = cmd.getExpandedArgs(ctx, arena_alloc) catch return ShellError.CommandExpansionFailed;
        const builtin_fn = builtins.getBuiltinFunction(BuiltinCommand.fromString(expanded_args[0]));

        const stage_input: command.ExecInput = if (is_first)
            try openBuiltinPipelineInitialInput(ctx, arena_alloc, cfg)
        else
            .{ .value = builtin_outputs.items[idx - 1] };
        defer if (is_first) closeExecInputIfStream(ctx, stage_input);

        var exec_ctx = command.ExecContext{
            .shell_ctx = ctx,
            .allocator = arena_alloc,
            .input = stage_input,
            .output = if (is_last) final_output.target else .capture,
            .append = if (cfg) |c| !c.stdout_truncate else false,
        };

        const output_value = builtin_fn(&exec_ctx, expanded_args);

        if (is_last) {
            final_exit_code = builtinPipelineExitCode(ctx, output_value, expanded_args[0]);
            try printBuiltinPipelineScalarFallback(ctx, arena_alloc, output_value);
        } else {
            builtin_outputs.appendAssumeCapacity(output_value);
        }
    }
    return final_exit_code;
}

/// Execute a builtin command in a forked child process
/// This function runs in the child and communicates via stdin/stdout file descriptors
fn executeBuiltinInChild(ctx: *ShellCtx, arena_alloc: Allocator, args: [][]const u8, is_first: bool) !u8 {
    const cmd_name = args[0];
    const builtin_cmd = BuiltinCommand.fromString(cmd_name);
    const builtin_fn = builtins.getBuiltinFunction(builtin_cmd);

    // Create File handles from the actual stdin/stdout FDs
    // After dup2, STDIN_FILENO and STDOUT_FILENO point to the pipes
    const stdin_file = std.Io.File.stdin();
    const stdout_file = std.Io.File.stdout();

    // Setup execution context with file descriptors
    var exec_ctx = command.ExecContext{
        .shell_ctx = ctx,
        .allocator = arena_alloc,
        .input = if (is_first) .none else .{ .stream = stdin_file },
        .output = .{ .stream = stdout_file },
        .is_pipe = true,
    };

    const result = builtin_fn(&exec_ctx, args);

    return switch (result) {
        .err => 1,
        .boolean => |b| if (b) 0 else 1,
        else => 0,
    };
}

fn createPipelinePipes(
    arena_alloc: Allocator,
    num_commands: usize,
    pipes: *std.ArrayList(fork_exec.PipeFds),
) ShellError!void {
    for (0..num_commands - 1) |_| {
        var pipe_fds: [2]linux.fd_t = undefined;
        const rc = linux.pipe2(&pipe_fds, .{ .CLOEXEC = true });
        if (rc != 0) return ShellError.BrokenPipe;
        pipes.append(arena_alloc, .{
            .read = pipe_fds[0],
            .write = pipe_fds[1],
        }) catch return ShellError.AllocFailed;
    }
}

fn preflightExternalPipelineStage(ctx: *ShellCtx, expanded_args: [][]const u8) ShellError!void {
    _ = ctx;
    _ = expanded_args;
}

/// Handler for mixed builtin/external pipelines, fork and exec with fd stream wiring
/// Handles user input signals and tty control in interactive mode.
fn executePipelineForkedInteractive(ctx: *ShellCtx, arena_alloc: Allocator, pipeline: CommandPipeline, bg_pgid_out: ?*linux.pid_t) ShellError!u8 {
    const num_commands = pipeline.stages.len;

    const ProcessInfo = struct {
        pid: linux.pid_t,
        is_builtin: bool,
        command_word: ?[]const u8,
    };

    var final_exit_code: u8 = 0;
    var final_failure_command: ?[]const u8 = null;
    var final_failure_external = false;

    var processes = std.ArrayList(ProcessInfo).initCapacity(arena_alloc, num_commands) catch return ShellError.AllocFailed;
    var pipeline_pgid: ?linux.pid_t = null;
    var pipes = std.ArrayList(fork_exec.PipeFds).initCapacity(arena_alloc, num_commands) catch return ShellError.AllocFailed;
    errdefer fork_exec.closePipes(pipes.items);

    // Create all pipes upfront.
    try createPipelinePipes(arena_alloc, num_commands, &pipes);

    const cfg: ?RedirConfig = pipeline.redir_config;
    var redirects = try fork_exec.openRedirectFds(ctx, arena_alloc, cfg);
    errdefer redirects.closeAll();

    // Spawn each command
    for (pipeline.stages, 0..) |*cmd, idx| {
        const expanded_args = cmd.getExpandedArgs(ctx, arena_alloc) catch return ShellError.CommandExpansionFailed;
        if (cmd.cmd_type == .external) {
            try preflightExternalPipelineStage(ctx, expanded_args);
        }
        const resolved_external_path: ?[]const u8 = if (cmd.cmd_type == .external)
            try execute.resolveExternalCommandInteractive(ctx, arena_alloc, expanded_args[0])
        else
            null;

        const pid = try fork_exec.forkProcess();

        if (pid == 0) {
            // ===== CHILD PROCESS =====
            fork_exec.setInteractiveChildSignalDefaults();
            if (!fork_exec.setChildProcessGroup(pipeline_pgid)) linux.exit(1);

            if (!fork_exec.setupPipelineChildStdio(idx, num_commands, pipes.items, redirects)) {
                linux.exit(1);
            }
            fork_exec.closePipes(pipes.items);
            redirects.closeAll();

            // Execute
            if (cmd.cmd_type == .builtin) {
                const exit_code = executeBuiltinInChild(ctx, arena_alloc, expanded_args, idx == 0) catch 1;
                linux.exit(exit_code);
            } else {
                fork_exec.execExternalResolvedOrExit(ctx, arena_alloc, resolved_external_path.?, expanded_args);
            }
        }

        // ===== PARENT PROCESS =====

        // Set process group - both parent and child attempt setpgid to avoid race
        if (pipeline_pgid == null) {
            pipeline_pgid = fork_exec.setParentProcessGroup(@intCast(pid), null);
            if (bg_pgid_out) |out| out.* = @intCast(pid);
        } else {
            _ = fork_exec.setParentProcessGroup(@intCast(pid), pipeline_pgid.?);
        }

        processes.append(arena_alloc, .{
            .pid = @intCast(pid),
            .is_builtin = (cmd.cmd_type == .builtin),
            .command_word = if (expanded_args.len > 0) expanded_args[0] else null,
        }) catch return ShellError.AllocFailed;
    }

    // Close pipe ends in parent - children have their copies
    fork_exec.closePipes(pipes.items);
    redirects.closeAll();

    // Restore signal ignoring in parent
    fork_exec.setInteractiveParentSignalIgnore();

    // Give terminal control to pipeline (foreground and interactive only)
    if (bg_pgid_out == null) {
        if (pipeline_pgid) |pgid| {
            fork_exec.giveTerminalTo(pgid);
        }
    }

    // Wait for all children on foreground pipelines
    if (bg_pgid_out == null) {
        var any_stopped = false;
        var saved_job = false;
        var first_failure: ?u8 = null;
        var first_failure_command: ?[]const u8 = null;
        var first_failure_external = false;

        for (processes.items, 0..) |proc_info, idx| {
            const is_last_proc = idx == processes.items.len - 1;

            // If an earlier process in the pipeline was stopped,
            // stop remaining processes and reap them with WNOHANG
            if (any_stopped) {
                if (pipeline_pgid) |pgid| {
                    _ = linux.kill(-pgid, linux.SIG.STOP);
                }
                // Drain remaining pids non-blocking so we don't leak them
                _ = fork_exec.waitPidChecked(proc_info.pid, linux.W.UNTRACED | linux.W.NOHANG) catch {};
                continue;
            }

            while (true) {
                const waited = try fork_exec.waitPidChecked(proc_info.pid, linux.W.UNTRACED);
                switch (waited) {
                    .event => |status| {
                        if (linux.W.IFSTOPPED(status)) {
                            any_stopped = true;
                            if (!saved_job) {
                                saved_job = true;
                                final_exit_code = 148;
                                if (pipeline_pgid != null) {
                                    ctx.print("\n[Job Suspended]\n", .{});
                                    ctx.saveStoppedPipeline(@ptrCast(&pipeline), pipeline_pgid.?) catch return ShellError.JobSpawnFailed;
                                }
                            }
                            break;
                        } else if (linux.W.IFEXITED(status)) {
                            const exit_code: u8 = @intCast(linux.W.EXITSTATUS(status));
                            if (exit_code != 0 and !is_last_proc) {
                                first_failure = exit_code;
                                first_failure_command = proc_info.command_word;
                                first_failure_external = !proc_info.is_builtin;
                                if (pipeline_pgid) |pgid| {
                                    _ = linux.kill(-pgid, .TERM);
                                }
                            }
                            if (is_last_proc) {
                                final_exit_code = first_failure orelse exit_code;
                                final_failure_command = first_failure_command orelse proc_info.command_word;
                                final_failure_external = first_failure_external or !proc_info.is_builtin;
                            }
                            break;
                        } else if (linux.W.IFSIGNALED(status)) {
                            const sig = linux.W.TERMSIG(status);
                            if (sig == .INT and is_last_proc) ctx.print("\n", .{});
                            const exit_code: u8 = 128 + @as(u8, @intCast(@intFromEnum(sig)));
                            if (is_last_proc) {
                                final_exit_code = first_failure orelse exit_code;
                                final_failure_command = first_failure_command orelse proc_info.command_word;
                                final_failure_external = first_failure_external or !proc_info.is_builtin;
                            }
                            break;
                        }
                    },
                    .nohang => continue,
                    .no_children => break,
                }
            }
        }
    }

    // Return terminal control to shell
    if (bg_pgid_out == null) {
        fork_exec.restoreTerminalToShell(ctx.shell_pgid.?);
        if (final_failure_external and
            execute.shouldRenderInteractiveExternalExit(final_exit_code) and
            ctx.current_input_line != null)
        {
            const command_word = final_failure_command;
            const detail = if (command_word) |cmd|
                std.fmt.allocPrint(arena_alloc, "{s} exited with status {d}", .{ cmd, final_exit_code }) catch cmd
            else
                std.fmt.allocPrint(arena_alloc, "pipeline exited with status {d}", .{final_exit_code}) catch "pipeline failed";
            reportPipelineError(
                ctx,
                ShellError.ExternalCommandFailed,
                "run interactive pipeline",
                detail,
                command_word,
            );
        }
    }

    return final_exit_code;
}

// Core fork/exec pipeline without signal or tty control for headless mode.
fn executePipelineForkedEngine(ctx: *ShellCtx, arena_alloc: Allocator, pipeline: CommandPipeline) ShellError!u8 {
    const num_commands = pipeline.stages.len;

    const ProcessInfo = struct {
        pid: linux.pid_t,
        is_builtin: bool,
    };

    var final_exit_code: u8 = 0;

    var processes = std.ArrayList(ProcessInfo).initCapacity(arena_alloc, num_commands) catch return ShellError.AllocFailed;
    var pipes = std.ArrayList(fork_exec.PipeFds).initCapacity(arena_alloc, num_commands) catch return ShellError.AllocFailed;
    errdefer fork_exec.closePipes(pipes.items);

    // Create all pipes upfront.
    try createPipelinePipes(arena_alloc, num_commands, &pipes);

    var redirects = try fork_exec.openRedirectFds(ctx, arena_alloc, pipeline.redir_config);
    errdefer redirects.closeAll();

    // Spawn each command
    for (pipeline.stages, 0..) |*cmd, idx| {
        const expanded_args = cmd.getExpandedArgs(ctx, arena_alloc) catch return ShellError.CommandExpansionFailed;
        if (cmd.cmd_type == .external) {
            try preflightExternalPipelineStage(ctx, expanded_args);
        }

        const pid = try fork_exec.forkProcess();

        if (pid == 0) {
            // ===== CHILD PROCESS =====
            // No setpgid, no signal reset — inherit engine defaults
            var cmd_path: ?[]const u8 = null;
            if (cmd.cmd_type == .external) {
                cmd_path = execute.resolveExternalCommandInteractive(ctx, arena_alloc, expanded_args[0]) catch |err| switch (err) {
                    errors.ShellError.CommandNotFound => {
                        ctx.print("{s}: command not found\n", .{expanded_args[0]});
                        linux.exit(127);
                    },
                    else => linux.exit(1),
                };
            }

            if (!fork_exec.setupPipelineChildStdio(idx, num_commands, pipes.items, redirects)) {
                linux.exit(1);
            }
            fork_exec.closePipes(pipes.items);
            redirects.closeAll();

            // Execute
            if (cmd.cmd_type == .builtin) {
                const exit_code = executeBuiltinInChild(ctx, arena_alloc, expanded_args, idx == 0) catch 1;
                linux.exit(exit_code);
            } else {
                fork_exec.execExternalResolvedOrExit(ctx, arena_alloc, cmd_path.?, expanded_args);
            }
        }

        // ===== PARENT PROCESS =====
        processes.append(arena_alloc, .{
            .pid = @intCast(pid),
            .is_builtin = (cmd.cmd_type == .builtin),
        }) catch return ShellError.AllocFailed;
    }

    // Close pipe ends in parent - children have their copies
    fork_exec.closePipes(pipes.items);
    redirects.closeAll();

    // Wait for all children — no UNTRACED, no job control
    var first_failure: ?u8 = null;
    for (processes.items, 0..) |proc, idx| {
        const is_last = idx == processes.items.len - 1;
        while (true) {
            const waited = try fork_exec.waitPidChecked(proc.pid, 0);
            switch (waited) {
                .event => |status| {
                    if (linux.W.IFEXITED(status)) {
                        const code: u8 = @intCast(linux.W.EXITSTATUS(status));
                        if (code != 0 and !is_last) first_failure = code;
                        if (is_last) final_exit_code = first_failure orelse code;
                        break;
                    } else if (linux.W.IFSIGNALED(status)) {
                        const code: u8 = 128 + @as(u8, @intCast(@intFromEnum(linux.W.TERMSIG(status))));
                        if (is_last) final_exit_code = first_failure orelse code;
                        break;
                    }
                },
                .no_children => return ShellError.ExecFailed,
                .nohang => continue,
            }
        }
    }

    return final_exit_code;
}

//
// --- TESTS
//

test "pipeline type validation hard-fails scalar input into where" {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tokens = [_]Token{
        .{ .kind = .Command, .text = "echo" },
        .{ .kind = .Arg, .text = "hi" },
        .{ .kind = .Pipe, .text = "|" },
        .{ .kind = .Command, .text = "where" },
        .{ .kind = .Arg, .text = ".name" },
        .{ .kind = .Arg, .text = "==" },
        .{ .kind = .Arg, .text = "hi" },
    };

    try std.testing.expectError(ShellError.TypeMismatch, generateCommandSequence(allocator, tokens[0..]));
}

test "pipeline type validation allows help all into where" {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tokens = [_]Token{
        .{ .kind = .Command, .text = "help" },
        .{ .kind = .Arg, .text = "--all" },
        .{ .kind = .Pipe, .text = "|" },
        .{ .kind = .Command, .text = "where" },
        .{ .kind = .Arg, .text = ".name" },
        .{ .kind = .Arg, .text = "==" },
        .{ .kind = .Arg, .text = "pwd" },
    };

    const sequence = try generateCommandSequence(allocator, tokens[0..]);
    try std.testing.expectEqual(@as(usize, 1), sequence.pipelines.len);
}

test "group redirect append applies to every sequence segment" {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tokens = [_]Token{
        .{ .kind = .GroupStart, .text = "{" },
        .{ .kind = .Command, .text = "ls" },
        .{ .kind = .Semicolon, .text = ";" },
        .{ .kind = .Command, .text = "ls" },
        .{ .kind = .GroupEnd, .text = "}" },
        .{ .kind = .Redirect, .text = ">>" },
        .{ .kind = .Arg, .text = "out" },
    };

    const expanded = try expandGroupedSequenceRedirects(allocator, tokens[0..]);
    try std.testing.expectEqual(@as(usize, 7), expanded.len);
    try std.testing.expectEqualStrings(">>", expanded[1].text);
    try std.testing.expectEqualStrings("out", expanded[2].text);
    try std.testing.expectEqual(TokenKind.Semicolon, expanded[3].kind);
    try std.testing.expectEqualStrings(">>", expanded[5].text);
    try std.testing.expectEqualStrings("out", expanded[6].text);

    const sequence = try generateCommandSequence(allocator, expanded);
    try std.testing.expectEqual(@as(usize, 2), sequence.pipelines.len);
    try std.testing.expectEqual(@as(usize, 1), sequence.operators.len);
    try std.testing.expectEqual(SequenceOperator.semicolon, sequence.operators[0]);

    for (sequence.pipelines) |pipe_l| {
        try std.testing.expect(pipe_l.redir_config != null);
        const cfg = pipe_l.redir_config.?;
        try std.testing.expect(cfg.stdout_path != null);
        try std.testing.expectEqualStrings("out", cfg.stdout_path.?);
        try std.testing.expect(!cfg.stdout_truncate);
    }
}

test "group redirect overwrite preserves operator chain" {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tokens = [_]Token{
        .{ .kind = .GroupStart, .text = "{" },
        .{ .kind = .Command, .text = "a" },
        .{ .kind = .And, .text = "&&" },
        .{ .kind = .Command, .text = "b" },
        .{ .kind = .Or, .text = "||" },
        .{ .kind = .Command, .text = "c" },
        .{ .kind = .GroupEnd, .text = "}" },
        .{ .kind = .Redirect, .text = ">" },
        .{ .kind = .Arg, .text = "out" },
    };

    const expanded = try expandGroupedSequenceRedirects(allocator, tokens[0..]);
    const sequence = try generateCommandSequence(allocator, expanded);

    try std.testing.expectEqual(@as(usize, 3), sequence.pipelines.len);
    try std.testing.expectEqual(@as(usize, 2), sequence.operators.len);
    try std.testing.expectEqual(SequenceOperator.and_op, sequence.operators[0]);
    try std.testing.expectEqual(SequenceOperator.or_op, sequence.operators[1]);

    for (sequence.pipelines) |pipe_l| {
        try std.testing.expect(pipe_l.redir_config != null);
        const cfg = pipe_l.redir_config.?;
        try std.testing.expect(cfg.stdout_path != null);
        try std.testing.expectEqualStrings("out", cfg.stdout_path.?);
        try std.testing.expect(cfg.stdout_truncate);
    }
}

test "group redirect rejects nested groups" {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tokens = [_]Token{
        .{ .kind = .GroupStart, .text = "{" },
        .{ .kind = .Command, .text = "ls" },
        .{ .kind = .Semicolon, .text = ";" },
        .{ .kind = .GroupStart, .text = "{" },
        .{ .kind = .Command, .text = "pwd" },
        .{ .kind = .GroupEnd, .text = "}" },
        .{ .kind = .GroupEnd, .text = "}" },
        .{ .kind = .Redirect, .text = ">" },
        .{ .kind = .Arg, .text = "out" },
    };

    try std.testing.expectError(ShellError.InvalidSyntax, expandGroupedSequenceRedirects(allocator, tokens[0..]));
}

test "generateCommandPipeline rewrites assignment-prefixed external command to env form" {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tokens = [_]Token{
        .{ .kind = .Assignment, .text = "X=inline" },
        .{ .kind = .Command, .text = "env" },
        .{ .kind = .Pipe, .text = "|" },
        .{ .kind = .Command, .text = "grep" },
        .{ .kind = .Arg, .text = "^X=inline$" },
    };

    const pipe_l = try generateCommandPipeline(allocator, tokens[0..]);
    try std.testing.expectEqual(@as(usize, 2), pipe_l.stages.len);
    try std.testing.expectEqual(command.CmdType.external, pipe_l.stages[0].cmd_type);
    try std.testing.expectEqualStrings("env", pipe_l.stages[0].args[0].text);
    try std.testing.expectEqualStrings("X=inline", pipe_l.stages[0].args[1].text);
}

test "generateCommandPipeline rejects assignment prefix before non-env builtin" {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tokens = [_]Token{
        .{ .kind = .Assignment, .text = "X=inline" },
        .{ .kind = .Command, .text = "cd" },
        .{ .kind = .Arg, .text = "/tmp" },
    };

    try std.testing.expectError(ShellError.InvalidTokenSequence, generateCommandPipeline(allocator, tokens[0..]));
}
