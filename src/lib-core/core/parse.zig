const std = @import("std");
const builtins = @import("builtins.zig");
const command = @import("command.zig");
const execute = @import("execute.zig");
const errors = @import("errors.zig");
const helpers = @import("helpers.zig");
const lexer = @import("lexer.zig");
const pipeline = @import("pipeline.zig");
const types = @import("types.zig");
const Allocator = std.mem.Allocator;
const ShellCtx = @import("context.zig").ShellCtx;
const ShellError = @import("errors.zig").ShellError;

const RetryBackoff = enum { fixed, exp };

pub const RetryMetaConfig = struct {
    max_attempts: ?u32 = null,
    max_duration_ns: ?u64 = null,
    delay_ns: u64 = 200 * std.time.ns_per_ms,
    backoff: RetryBackoff = .fixed,
    max_delay_ns: ?u64 = null,
    jitter: bool = false,
    on_exit: [256]bool = [_]bool{false} ** 256,
    has_on_exit: bool = false,
    except_exit: [256]bool = [_]bool{false} ** 256,
    has_except_exit: bool = false,
    quiet: bool = false,
    summary: bool = false,
};

const RetryDecision = enum {
    retry,
    no_retry_success,
    no_retry_fail_fast,
    no_retry_not_in_on_exit,
    no_retry_in_except_exit,
};

pub const ParsedMetaInput = struct {
    command_input: []const u8,
    measure_time: bool = false,
    retry: ?RetryMetaConfig = null,
    step_mode: bool = false,
};

pub const ParsedCommandInput = struct {
    command_input: []const u8,
    sequence: pipeline.CommandSequence,
    measure_time: bool = false,
    retry: ?RetryMetaConfig = null,
    step_mode: bool = false,
};

const ParsedRetryMetaRaw = struct {
    command_input: []const u8,
    cfg: RetryMetaConfig,
};

const RetryLoopTermination = enum {
    success,
    max_attempts_reached,
    max_duration_reached,
    fail_fast_or_filtered,
};

/// Core parse input, tokenize, construct, execute handler
pub fn parseAndExecute(ctx: *ShellCtx, arena_alloc: Allocator, input: []const u8) ShellError!void {
    const parsed = parseCommandInput(ctx, arena_alloc, input) catch |err| switch (err) {
        ShellError.EmptyCommand => return,
        else => return err,
    };
    const cmd_sequence = parsed.sequence;
    const measure_time = parsed.measure_time;
    const retry_cfg = parsed.retry;
    const step_mode = parsed.step_mode;
    try executeCommandSequenceWithRetry(ctx, arena_alloc, cmd_sequence, input, measure_time, retry_cfg, step_mode);
}

/// Parse command input into a normalized executable sequence.
/// This is shared across interactive REPL and engine `-c` input so command
/// entry semantics stay aligned.
pub fn parseCommandInput(ctx: *ShellCtx, arena_alloc: Allocator, input: []const u8) ShellError!ParsedCommandInput {
    const trimmed = std.mem.trim(u8, input, &std.ascii.whitespace);
    if (trimmed.len == 0) return ShellError.EmptyCommand;

    const meta = try parseMetaInputPrefix(arena_alloc, input);
    if (meta.step_mode and ctx.exe_mode != .interactive) return ShellError.Unsupported;
    const actual_input = meta.command_input;
    if (actual_input.len == 0) return ShellError.EmptyCommand;

    const tokens = try tokenizeWithCommandKinds(arena_alloc, actual_input);
    if (tokens.len == 0) return ShellError.EmptyCommand;

    const expanded_tokens = try expandInteractiveAliases(ctx, arena_alloc, tokens);
    const normalized_tokens = try pipeline.expandGroupedSequenceRedirects(arena_alloc, expanded_tokens);
    try lexer.validateTokenSequence(normalized_tokens);

    return .{
        .command_input = actual_input,
        .sequence = try pipeline.generateCommandSequence(arena_alloc, normalized_tokens),
        .measure_time = meta.measure_time,
        .retry = meta.retry,
        .step_mode = meta.step_mode,
    };
}

fn tokenizeWithCommandKinds(arena_alloc: Allocator, input: []const u8) ![]lexer.Token {
    var token_list = try std.ArrayList(lexer.Token).initCapacity(arena_alloc, 8);
    var lexer_instance = lexer.Lexer.init(input);
    var expect_command = true;
    var current_command: ?[]const u8 = null;

    while (try lexer_instance.next(arena_alloc)) |raw_token| {
        var token = raw_token;

        // The lexer intentionally stays syntax-focused. This pass adds the
        // command/arg distinction that depends on surrounding shell structure.
        if (token.kind == .Arg) {
            if (expect_command) {
                token.kind = .Command;
                expect_command = false;
                current_command = token.text;
            }
        } else if (token.kind == .Assignment) {
            // Assignment can be a standalone command or a command prefix (X=1 cmd).
            // Once a real command is already active, treat NAME=value as a normal
            // argument unless the builtin explicitly expects assignment syntax.
            if (!expect_command and (current_command == null or !std.mem.eql(u8, current_command.?, "export"))) {
                token.kind = .Arg;
            }
        } else if (token.kind == .Var or token.kind == .Expr) {
            if (expect_command) {
                expect_command = false;
                current_command = null;
            }
        } else {
            switch (token.kind) {
                .Pipe, .Semicolon, .And, .Or, .Bg => {
                    expect_command = true;
                    current_command = null;
                },
                .GroupStart => {
                    expect_command = true;
                    current_command = null;
                },
                .GroupEnd => {
                    expect_command = false;
                    current_command = null;
                },
                else => {},
            }
        }

        try token_list.append(arena_alloc, token);
    }

    return token_list.items;
}

pub fn parseMetaInputPrefix(arena_alloc: Allocator, input: []const u8) ShellError!ParsedMetaInput {
    var remaining = std.mem.trim(u8, input, &std.ascii.whitespace);
    var parsed = ParsedMetaInput{
        .command_input = remaining,
    };

    // Meta prefixes compose left-to-right before normal parsing. Keeping them
    // in one place avoids the REPL and engine developing different entry rules.
    while (remaining.len > 0) {
        if (startsWithWord(remaining, "profile")) {
            if (parsed.step_mode) return ShellError.InvalidArgument;
            if (parsed.measure_time) return ShellError.InvalidArgument;
            parsed.measure_time = true;
            remaining = std.mem.trimStart(u8, remaining["profile".len..], &std.ascii.whitespace);
            continue;
        }

        if (startsWithWord(remaining, "retry")) {
            if (parsed.step_mode) return ShellError.InvalidArgument;
            if (parsed.retry != null) return ShellError.InvalidArgument;
            const retry_parsed = try parseRetryMetaPrefixRaw(arena_alloc, remaining);
            parsed.retry = retry_parsed.cfg;
            remaining = retry_parsed.command_input;
            continue;
        }

        if (startsWithWord(remaining, "step")) {
            if (parsed.measure_time or parsed.retry != null or parsed.step_mode) return ShellError.InvalidArgument;
            parsed.step_mode = true;
            remaining = std.mem.trimStart(u8, remaining[4..], &std.ascii.whitespace);
            continue;
        }

        break;
    }

    parsed.command_input = remaining;
    return parsed;
}

fn startsWithWord(input: []const u8, word: []const u8) bool {
    if (!std.mem.startsWith(u8, input, word)) return false;
    if (input.len == word.len) return true;
    return std.ascii.isWhitespace(input[word.len]);
}

fn skipLeadingWhitespaceIndex(input: []const u8, from: usize) usize {
    var idx = from;
    while (idx < input.len and std.ascii.isWhitespace(input[idx])) : (idx += 1) {}
    return idx;
}

const TokenWithStart = struct {
    token: lexer.Token,
    start_idx: usize,
};

fn nextTokenWithStart(arena_alloc: Allocator, lx: *lexer.Lexer, input: []const u8) ShellError!?TokenWithStart {
    const start_idx = skipLeadingWhitespaceIndex(input, lx.pos);
    const tok = (lx.next(arena_alloc) catch return ShellError.InvalidSyntax) orelse return null;
    return .{
        .token = tok,
        .start_idx = start_idx,
    };
}

fn parseRetryMetaPrefixRaw(arena_alloc: Allocator, input: []const u8) ShellError!ParsedRetryMetaRaw {
    var lx = lexer.Lexer.init(input);
    const first = (try nextTokenWithStart(arena_alloc, &lx, input)) orelse return ShellError.MissingCommand;
    if (!std.mem.eql(u8, first.token.text, "retry")) return ShellError.InvalidArgument;

    var cfg = RetryMetaConfig{};
    var command_start_idx: ?usize = null;

    const budget_scan = (try nextTokenWithStart(arena_alloc, &lx, input)) orelse return ShellError.MissingArgument;
    if (std.mem.eql(u8, budget_scan.token.text, "for")) {
        const dur_scan = (try nextTokenWithStart(arena_alloc, &lx, input)) orelse return ShellError.MissingArgument;
        cfg.max_duration_ns = parseDurationToNs(dur_scan.token.text) orelse return ShellError.InvalidArgument;
    } else {
        const parsed_count = std.fmt.parseInt(u32, budget_scan.token.text, 10) catch return ShellError.InvalidArgument;
        if (parsed_count == 0) return ShellError.InvalidArgument;
        cfg.max_attempts = parsed_count;
    }

    while (command_start_idx == null) {
        const scan = (try nextTokenWithStart(arena_alloc, &lx, input)) orelse break;
        const arg = scan.token.text;

        if (std.mem.eql(u8, arg, "--delay")) {
            const value_scan = (try nextTokenWithStart(arena_alloc, &lx, input)) orelse return ShellError.MissingArgument;
            cfg.delay_ns = parseDurationToNs(value_scan.token.text) orelse return ShellError.InvalidArgument;
            continue;
        }

        if (std.mem.eql(u8, arg, "--backoff")) {
            const mode_scan = (try nextTokenWithStart(arena_alloc, &lx, input)) orelse return ShellError.MissingArgument;
            if (std.mem.eql(u8, mode_scan.token.text, "fixed")) {
                cfg.backoff = .fixed;
            } else if (std.mem.eql(u8, mode_scan.token.text, "exp")) {
                cfg.backoff = .exp;
            } else {
                return ShellError.InvalidArgument;
            }
            continue;
        }

        if (std.mem.eql(u8, arg, "--max-delay")) {
            const value_scan = (try nextTokenWithStart(arena_alloc, &lx, input)) orelse return ShellError.MissingArgument;
            cfg.max_delay_ns = parseDurationToNs(value_scan.token.text) orelse return ShellError.InvalidArgument;
            continue;
        }

        if (std.mem.eql(u8, arg, "--jitter")) {
            cfg.jitter = true;
            continue;
        }

        if (std.mem.eql(u8, arg, "--on-exit")) {
            const value_scan = (try nextTokenWithStart(arena_alloc, &lx, input)) orelse return ShellError.MissingArgument;
            try parseExitCodeMask(value_scan.token.text, &cfg.on_exit);
            cfg.has_on_exit = true;
            continue;
        }

        if (std.mem.eql(u8, arg, "--except-exit")) {
            const value_scan = (try nextTokenWithStart(arena_alloc, &lx, input)) orelse return ShellError.MissingArgument;
            try parseExitCodeMask(value_scan.token.text, &cfg.except_exit);
            cfg.has_except_exit = true;
            continue;
        }

        if (std.mem.eql(u8, arg, "--quiet")) {
            cfg.quiet = true;
            continue;
        }

        if (std.mem.eql(u8, arg, "--summary")) {
            cfg.summary = true;
            continue;
        }

        if (std.mem.startsWith(u8, arg, "--")) return ShellError.InvalidArgument;
        command_start_idx = scan.start_idx;
    }

    const cmd_start = command_start_idx orelse return ShellError.MissingCommand;
    const command_input = std.mem.trim(u8, input[cmd_start..], &std.ascii.whitespace);
    if (command_input.len == 0) return ShellError.MissingCommand;
    if (command_input[0] == '{') return ShellError.InvalidArgument;

    if (cfg.max_delay_ns) |max_delay| {
        if (max_delay < cfg.delay_ns) cfg.delay_ns = max_delay;
    }

    return .{
        .command_input = command_input,
        .cfg = cfg,
    };
}

fn parseDurationToNs(raw: []const u8) ?u64 {
    if (raw.len == 0) return null;
    var number_part = raw;
    var factor: u64 = std.time.ns_per_ms; // default to ms for plain integers

    if (std.mem.endsWith(u8, raw, "ms")) {
        number_part = raw[0 .. raw.len - 2];
        factor = std.time.ns_per_ms;
    } else if (std.mem.endsWith(u8, raw, "s")) {
        number_part = raw[0 .. raw.len - 1];
        factor = std.time.ns_per_s;
    } else if (std.mem.endsWith(u8, raw, "m")) {
        number_part = raw[0 .. raw.len - 1];
        factor = 60 * std.time.ns_per_s;
    } else if (std.mem.endsWith(u8, raw, "h")) {
        number_part = raw[0 .. raw.len - 1];
        factor = 60 * 60 * std.time.ns_per_s;
    }

    if (number_part.len == 0) return null;
    const value = std.fmt.parseInt(u64, number_part, 10) catch return null;
    if (value == 0) return null;
    return std.math.mul(u64, value, factor) catch null;
}

fn parseExitCodeMask(raw: []const u8, mask: *[256]bool) ShellError!void {
    mask.* = [_]bool{false} ** 256;

    var any = false;
    var parts = std.mem.splitScalar(u8, raw, ',');
    while (parts.next()) |part_raw| {
        const part = std.mem.trim(u8, part_raw, &std.ascii.whitespace);
        if (part.len == 0) return ShellError.InvalidArgument;
        const code = std.fmt.parseInt(u16, part, 10) catch return ShellError.InvalidArgument;
        if (code > 255) return ShellError.InvalidArgument;
        mask[@intCast(code)] = true;
        any = true;
    }
    if (!any) return ShellError.InvalidArgument;
}

fn expandInteractiveAliases(ctx: *ShellCtx, arena_alloc: Allocator, tokens: []lexer.Token) ![]lexer.Token {
    if (ctx.exe_mode != .interactive) return tokens;
    const aliases = ctx.aliases orelse return tokens;
    if (aliases.count() == 0) return tokens;

    var out = try std.ArrayList(lexer.Token).initCapacity(arena_alloc, tokens.len);
    var any_expanded = false;

    for (tokens) |token| {
        if (token.kind == .Command and !token.single_quoted) {
            if (ctx.resolveAlias(token.text)) |alias_body| {
                const alias_tokens = try tokenizeWithCommandKinds(arena_alloc, alias_body);
                if (alias_tokens.len == 0) return ShellError.InvalidSyntax;
                try out.appendSlice(arena_alloc, alias_tokens);
                any_expanded = true;
                continue;
            }
        }
        try out.append(arena_alloc, token);
    }

    if (!any_expanded) return tokens;
    return out.items;
}

fn parseStepDecision(raw: []const u8) ?bool {
    const trimmed = std.mem.trim(u8, raw, &std.ascii.whitespace);
    if (trimmed.len == 0) return false;

    var parts = std.mem.tokenizeAny(u8, trimmed, &std.ascii.whitespace);
    const token = parts.next() orelse return false;

    if (std.ascii.eqlIgnoreCase(token, "y") or std.ascii.eqlIgnoreCase(token, "yes")) return true;
    if (std.ascii.eqlIgnoreCase(token, "n") or std.ascii.eqlIgnoreCase(token, "no")) return false;
    return null;
}

fn promptStepContinue(ctx: *ShellCtx, arena_alloc: Allocator, message: []const u8) ShellError!bool {
    var i_buf: [256]u8 = undefined;
    const stdin_file = std.Io.File.stdin();
    var stdin_reader = stdin_file.reader(ctx.io.*, &i_buf);
    const stdin = &stdin_reader.interface;

    var attempts: usize = 0;
    while (attempts < 3) : (attempts += 1) {
        ctx.print("{s} [y/N]: ", .{message});

        var line = std.ArrayList(u8).initCapacity(arena_alloc, 32) catch return ShellError.AllocFailed;
        while (true) {
            const ch = stdin.takeByte() catch |err| switch (err) {
                error.EndOfStream => return false,
                else => return ShellError.ReadFailed,
            };
            if (ch == '\n') break;
            if (ch == '\r') continue;
            line.append(arena_alloc, ch) catch return ShellError.AllocFailed;
        }

        const decision = parseStepDecision(line.items);
        if (decision != null) return decision.?;
        ctx.print("step: please answer y/yes or n/no\n", .{});
    }

    return false;
}

fn makeStepTempOutputPath(ctx: *ShellCtx, arena_alloc: Allocator, stage_idx: usize) ![]const u8 {
    const now_ns = std.Io.Clock.now(.real, ctx.io.*).nanoseconds;
    return std.fmt.allocPrint(arena_alloc, "/tmp/zest-step-{d}-{d}-{d}.out", .{
        std.os.linux.getpid(),
        now_ns,
        stage_idx,
    });
}

fn stagePipeContents(stage: command.Command) pipeline.Contents {
    return if (stage.cmd_type == .builtin) .builtins_only else .externals_mixed;
}

fn promptStepStage(
    ctx: *ShellCtx,
    arena_alloc: Allocator,
    stage_idx: usize,
    total_stages: usize,
    stage_desc: []const u8,
) ShellError!bool {
    const prompt = std.fmt.allocPrint(
        arena_alloc,
        "step: run stage {d}/{d}: {s}",
        .{ stage_idx + 1, total_stages, stage_desc },
    ) catch return ShellError.AllocFailed;
    const proceed = try promptStepContinue(ctx, arena_alloc, prompt);
    if (!proceed) {
        ctx.print("step: aborted at stage {d}\n", .{stage_idx + 1});
    }
    return proceed;
}

fn cleanupStepTempFiles(paths: []const []const u8) void {
    for (paths) |path| {
        var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
        const z_path = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch continue;
        _ = std.os.linux.unlink(z_path);
    }
}

fn readStepOutputFromPath(ctx: *ShellCtx, arena_alloc: Allocator, path: []const u8) ShellError![]const u8 {
    var file = helpers.getFileFromPath(ctx, arena_alloc, path, .{
        .write = false,
        .truncate = false,
        .pre_expanded = true,
    }) catch |open_err| {
        const mapped = errors.mapPathOpenError(open_err);
        return switch (mapped) {
            ShellError.FileNotFound, ShellError.PathNotFound => try arena_alloc.dupe(u8, ""),
            else => mapped,
        };
    };
    defer file.close(ctx.io.*);
    return helpers.fileReadAll(ctx.io.*, arena_alloc, file) catch |read_err| errors.mapPolicyReadError(read_err);
}

fn formatStepStageCommand(ctx: *ShellCtx, arena_alloc: Allocator, stage: *const command.Command) ShellError![]const u8 {
    const expanded = stage.getExpandedArgs(ctx, arena_alloc) catch return ShellError.CommandExpansionFailed;
    if (expanded.len == 0) return try arena_alloc.dupe(u8, "<empty>");
    return std.mem.join(arena_alloc, " ", expanded) catch ShellError.AllocFailed;
}

fn printStepPreviousStdout(ctx: *ShellCtx, stage_idx: usize, total_stages: usize, data: []const u8) void {
    ctx.print("step: stdout before stage {d}/{d}:\n", .{ stage_idx + 1, total_stages });
    if (data.len == 0) {
        ctx.print("(empty)\n", .{});
    } else {
        ctx.print("{s}\n", .{data});
    }
}

fn reportStepBuiltinStageError(ctx: *ShellCtx, err: ShellError, command_word: []const u8) void {
    if (ctx.exe_mode == .interactive and ctx.current_input_line != null) {
        errors.reportInteractive(err, ctx.io.*, ctx.stdout, .{
            .source_line = ctx.current_input_line.?,
            .source_name = "interactive",
            .line_no = 1,
            .action = "step execute builtin stage",
            .detail = command_word,
            .command_word = command_word,
        });
    } else {
        errors.report(err, "step execute builtin stage", command_word);
    }
}

fn executePipelineStepBuiltins(
    ctx: *ShellCtx,
    arena_alloc: Allocator,
    pipe_l: pipeline.CommandPipeline,
) ShellError!u8 {
    var previous_value: ?types.Value = null;
    var final_exit_code: u8 = 0;
    var last_output: ?[]const u8 = null;

    for (pipe_l.stages, 0..) |*stage, idx| {
        const stage_desc = try formatStepStageCommand(ctx, arena_alloc, stage);
        if (idx > 0 and previous_value != null) {
            const rendered = previous_value.?.toString(arena_alloc) catch return ShellError.AllocFailed;
            printStepPreviousStdout(ctx, idx, pipe_l.stages.len, rendered);
        }

        if (!(try promptStepStage(ctx, arena_alloc, idx, pipe_l.stages.len, stage_desc))) return 1;

        const expanded_args = stage.getExpandedArgs(ctx, arena_alloc) catch return ShellError.CommandExpansionFailed;
        const builtin_fn = builtins.getBuiltinFunction(builtins.BuiltinCommand.fromString(expanded_args[0]));
        var exec_ctx = command.ExecContext{
            .shell_ctx = ctx,
            .allocator = arena_alloc,
            .input = if (idx == 0)
                .none
            else
                .{ .value = previous_value.? },
            .output = .capture,
            .err = .{ .stream = ctx.stdout },
        };

        const output_value = builtin_fn(&exec_ctx, expanded_args);
        if (output_value == .err) {
            reportStepBuiltinStageError(ctx, output_value.err, expanded_args[0]);
            return 1;
        }
        final_exit_code = switch (output_value) {
            .boolean => |b| if (b) 0 else 1,
            else => 0,
        };

        previous_value = output_value;
        last_output = output_value.toString(arena_alloc) catch null;
    }

    if (last_output) |out| {
        if (out.len > 0) ctx.print("{s}\n", .{out});
    }
    return final_exit_code;
}

fn executePipelineStepMixed(
    ctx: *ShellCtx,
    arena_alloc: Allocator,
    pipe_l: pipeline.CommandPipeline,
    input_label: []const u8,
) ShellError!u8 {
    var output_paths = std.ArrayList([]const u8).initCapacity(arena_alloc, pipe_l.stages.len) catch return ShellError.AllocFailed;
    defer cleanupStepTempFiles(output_paths.items);

    var first_failure: ?u8 = null;
    var last_exit_code: u8 = 0;

    for (pipe_l.stages, 0..) |stage, idx| {
        if (idx > 0) {
            const previous_stdout = try readStepOutputFromPath(ctx, arena_alloc, output_paths.items[idx - 1]);
            printStepPreviousStdout(ctx, idx, pipe_l.stages.len, previous_stdout);
        }

        const stage_desc = try formatStepStageCommand(ctx, arena_alloc, &stage);
        if (!(try promptStepStage(ctx, arena_alloc, idx, pipe_l.stages.len, stage_desc))) return 1;

        const out_path = try makeStepTempOutputPath(ctx, arena_alloc, idx);
        output_paths.append(arena_alloc, out_path) catch return ShellError.AllocFailed;

        var stage_redir = command.RedirConfig{};
        if (idx > 0) {
            stage_redir.stdin = .pipe;
            stage_redir.stdin_path = output_paths.items[idx - 1];
        }
        stage_redir.stdout = .pipe;
        stage_redir.stdout_path = out_path;
        stage_redir.stdout_truncate = true;

        var stage_arr = [_]command.Command{stage};
        const one_stage_pipe = pipeline.CommandPipeline{
            .stages = stage_arr[0..],
            .mode = .interactive,
            .contents = stagePipeContents(stage),
            .redir_config = stage_redir,
        };

        const maybe_exit_code = try executePipelineOnce(ctx, arena_alloc, one_stage_pipe, input_label);
        const exit_code = maybe_exit_code orelse return ShellError.InvalidArgument;
        last_exit_code = exit_code;
        if (idx < pipe_l.stages.len - 1 and exit_code != 0 and first_failure == null) {
            first_failure = exit_code;
        }
    }

    if (output_paths.items.len > 0) {
        const final_output = try readStepOutputFromPath(ctx, arena_alloc, output_paths.items[output_paths.items.len - 1]);
        if (final_output.len > 0) ctx.print("{s}", .{final_output});
    }

    return first_failure orelse last_exit_code;
}

fn executePipelineStepMode(
    ctx: *ShellCtx,
    arena_alloc: Allocator,
    pipe_l: pipeline.CommandPipeline,
    input_label: []const u8,
) ShellError!u8 {
    if (ctx.exe_mode != .interactive) return ShellError.Unsupported;
    if (pipe_l.mode == .background) return ShellError.InvalidArgument;
    if (pipe_l.redir_config != null) return ShellError.InvalidArgument;
    if (pipe_l.stages.len < 2) return ShellError.InvalidArgument;

    return switch (pipe_l.contents) {
        .builtins_only => executePipelineStepBuiltins(ctx, arena_alloc, pipe_l),
        .externals_mixed => executePipelineStepMixed(ctx, arena_alloc, pipe_l, input_label),
    };
}

pub fn executeCommandSequence(
    ctx: *ShellCtx,
    arena_alloc: Allocator,
    cmd_sequence: pipeline.CommandSequence,
    input_label: []const u8,
    measure_time: bool,
) ShellError!void {
    return executeCommandSequenceWithRetry(ctx, arena_alloc, cmd_sequence, input_label, measure_time, null, false);
}

pub fn executeCommandSequenceWithMeta(
    ctx: *ShellCtx,
    arena_alloc: Allocator,
    cmd_sequence: pipeline.CommandSequence,
    input_label: []const u8,
    measure_time: bool,
    retry_cfg: ?RetryMetaConfig,
    step_mode: bool,
) ShellError!void {
    return executeCommandSequenceWithRetry(ctx, arena_alloc, cmd_sequence, input_label, measure_time, retry_cfg, step_mode);
}

fn executeCommandSequenceWithRetry(
    ctx: *ShellCtx,
    arena_alloc: Allocator,
    cmd_sequence: pipeline.CommandSequence,
    input_label: []const u8,
    measure_time: bool,
    retry_cfg: ?RetryMetaConfig,
    step_mode: bool,
) ShellError!void {
    // Execution
    const start_time = if (measure_time) std.Io.Clock.now(.awake, ctx.io.*) else undefined;
    const start_rusage = if (measure_time) std.posix.getrusage(std.posix.rusage.SELF) else undefined;

    if (step_mode) {
        if (ctx.exe_mode != .interactive) return ShellError.Unsupported;
        if (retry_cfg != null or measure_time) return ShellError.InvalidArgument;
        if (cmd_sequence.pipelines.len != 1 or cmd_sequence.operators.len != 0) return ShellError.InvalidArgument;
        const pipe_l = cmd_sequence.pipelines[0];
        const exit_code = try executePipelineStepMode(ctx, arena_alloc, pipe_l, input_label);
        ctx.last_exit_code = exit_code;
    } else if (retry_cfg) |cfg| {
        if (cmd_sequence.pipelines.len != 1 or cmd_sequence.operators.len != 0) return ShellError.InvalidArgument;
        const pipe_l = cmd_sequence.pipelines[0];
        if (pipe_l.mode == .background) return ShellError.InvalidArgument;
        const exit_code = try executePipelineWithRetry(ctx, arena_alloc, pipe_l, input_label, cfg);
        ctx.last_exit_code = exit_code;
    } else {
        // Execute in semicolon-delimited groups, handling &&/|| within each group
        // This ensures &&/|| short-circuiting never crosses a semicolon boundary
        var group_start: usize = 0;
        while (group_start < cmd_sequence.pipelines.len) {

            // Find the end of this semicolon group
            var group_end = group_start;
            while (group_end < cmd_sequence.operators.len and
                cmd_sequence.operators[group_end] != .semicolon) : (group_end += 1)
            {}
            // group_end is now the index of the last pipeline in this group

            // Execute &&/|| chain within this group
            var j = group_start;
            while (j <= group_end) : (j += 1) {
                const pipe_l = cmd_sequence.pipelines[j];
                const maybe_exit_code = try executePipelineOnce(ctx, arena_alloc, pipe_l, input_label);
                if (maybe_exit_code == null) continue;

                const exit_code = maybe_exit_code.?;
                ctx.last_exit_code = exit_code;

                // Check &&/|| within group - cannot cross semicolon boundary
                if (j < group_end) {
                    const should_continue = switch (cmd_sequence.operators[j]) {
                        .and_op => exit_code == 0,
                        .or_op => exit_code != 0,
                        .semicolon, .none => true,
                    };
                    if (!should_continue) {
                        // Find next || in this group and resume from there
                        var skip = j + 1;
                        while (skip < group_end) : (skip += 1) {
                            if (cmd_sequence.operators[skip] == .or_op) {
                                j = skip;
                                break;
                            }
                        } else break; // no || found, exit group
                    }
                }
            }

            group_start = group_end + 1;
        }
    }

    if (measure_time) {
        const end_time = std.Io.Clock.now(.awake, ctx.io.*);
        const duration = start_time.durationTo(end_time);
        const elapsed_ns = duration.toNanoseconds();
        const end_rusage = std.posix.getrusage(std.posix.rusage.SELF);
        const profile = helpers.buildTimingProfile(
            start_rusage,
            end_rusage,
            elapsed_ns,
            ctx.last_exit_code,
        );
        helpers.printTimingProfile(ctx, arena_alloc, profile);
    }

    if (ctx.exe_mode == .interactive) {
        // Poll background jobs for state changes, then clean up finished ones
        ctx.pollBackgroundJobs();
        ctx.cleanFinishedJobs(true); // true = notify user of completions
    }
}

fn executePipelineOnce(
    ctx: *ShellCtx,
    arena_alloc: Allocator,
    pipe_l: pipeline.CommandPipeline,
    input_label: []const u8,
) ShellError!?u8 {
    const is_background = pipe_l.mode == .background;
    if (pipe_l.stages.len == 0) return ShellError.EmptyPipeline;

    if (is_background and ctx.exe_mode == .interactive) {
        const input_cpy = ctx.allocator.dupe(u8, input_label) catch return ShellError.AllocFailed;
        defer ctx.allocator.free(input_cpy);
        const job_id = ctx.spawnBackgroundPipeline(@ptrCast(&pipe_l), input_cpy) catch
            return ShellError.JobSpawnFailed;
        ctx.print("[{d}] started\n", .{job_id});
        return null;
    }

    const exit_code: u8 = if (pipe_l.stages.len == 1) blk: {
        break :blk execute.executeSingleCommand(ctx, arena_alloc, pipe_l) catch |err| switch (err) {
            ShellError.CommandNotFound => blk_not_found: {
                if (ctx.exe_mode == .interactive) {
                    const command_word: ?[]const u8 = if (pipe_l.stages.len > 0 and pipe_l.stages[0].args.len > 0)
                        pipe_l.stages[0].args[0].text
                    else
                        null;
                    const detail = if (command_word) |word|
                        commandNotFoundDetail(ctx, arena_alloc, word)
                    else
                        null;
                    errors.reportInteractive(err, ctx.io.*, ctx.stdout, .{
                        .source_line = input_label,
                        .source_name = "interactive",
                        .line_no = 1,
                        .action = "resolve external command",
                        .detail = detail,
                        .command_word = command_word,
                    });
                }
                break :blk_not_found 127;
            },
            ShellError.NotExecutable, ShellError.PermissionDenied => blk_not_exec: {
                if (ctx.exe_mode == .interactive) {
                    const command_word: ?[]const u8 = if (pipe_l.stages.len > 0 and pipe_l.stages[0].args.len > 0)
                        pipe_l.stages[0].args[0].text
                    else
                        null;
                    errors.reportInteractive(err, ctx.io.*, ctx.stdout, .{
                        .source_line = input_label,
                        .source_name = "interactive",
                        .line_no = 1,
                        .action = "prepare external command",
                        .detail = command_word,
                        .command_word = command_word,
                    });
                }
                break :blk_not_exec 126;
            },
            ShellError.ExecFailed => 1,
            else => return err,
        };
    } else pipeline.executePipeline(ctx, arena_alloc, pipe_l, null);

    return exit_code;
}

fn absDiffUsize(a: usize, b: usize) usize {
    return if (a >= b) a - b else b - a;
}

fn levenshteinDistanceWithin(a: []const u8, b: []const u8, max_distance: usize) ?usize {
    if (a.len == 0) return if (b.len <= max_distance) b.len else null;
    if (b.len == 0) return if (a.len <= max_distance) a.len else null;
    if (absDiffUsize(a.len, b.len) > max_distance) return null;
    if (a.len > 64 or b.len > 64) return null;

    var prev: [65]u8 = undefined;
    var curr: [65]u8 = undefined;

    var j: usize = 0;
    while (j <= b.len) : (j += 1) {
        prev[j] = @intCast(j);
    }

    var i: usize = 1;
    while (i <= a.len) : (i += 1) {
        curr[0] = @intCast(i);
        var row_min: usize = curr[0];
        j = 1;
        while (j <= b.len) : (j += 1) {
            const replace_cost: usize = if (a[i - 1] == b[j - 1]) 0 else 1;
            const del = @as(usize, prev[j]) + 1;
            const ins = @as(usize, curr[j - 1]) + 1;
            const rep = @as(usize, prev[j - 1]) + replace_cost;
            const best = @min(del, @min(ins, rep));
            curr[j] = @intCast(best);
            if (best < row_min) row_min = best;
        }
        if (row_min > max_distance) return null;
        j = 0;
        while (j <= b.len) : (j += 1) {
            prev[j] = curr[j];
        }
    }

    const dist: usize = prev[b.len];
    if (dist > max_distance) return null;
    return dist;
}

fn candidateSuggestionScore(input: []const u8, candidate: []const u8) ?usize {
    if (std.mem.eql(u8, input, candidate)) return null;
    if (std.mem.startsWith(u8, candidate, input)) {
        return absDiffUsize(candidate.len, input.len);
    }
    const dist = levenshteinDistanceWithin(input, candidate, 2) orelse return null;
    return 100 + (dist * 10) + absDiffUsize(candidate.len, input.len);
}

fn findBestCommandSuggestion(ctx: *ShellCtx, input: []const u8) ?[]const u8 {
    if (input.len == 0) return null;

    var best_candidate: ?[]const u8 = null;
    var best_score: usize = std.math.maxInt(usize);

    for (builtins.builtins) |candidate| {
        const score = candidateSuggestionScore(input, candidate) orelse continue;
        if (score < best_score) {
            best_score = score;
            best_candidate = candidate;
        }
    }

    if (ctx.aliases) |aliases| {
        var iter = aliases.iterator();
        while (iter.next()) |entry| {
            const candidate = entry.key_ptr.*;
            const score = candidateSuggestionScore(input, candidate) orelse continue;
            if (score < best_score) {
                best_score = score;
                best_candidate = candidate;
            }
        }
    }

    return best_candidate;
}

fn commandNotFoundDetail(ctx: *ShellCtx, allocator: Allocator, command_word: []const u8) []const u8 {
    if (findBestCommandSuggestion(ctx, command_word)) |candidate| {
        return std.fmt.allocPrint(allocator, "{s} (did you mean '{s}'?)", .{ command_word, candidate }) catch command_word;
    }
    return command_word;
}

fn executePipelineWithRetry(
    ctx: *ShellCtx,
    arena_alloc: Allocator,
    pipe_l: pipeline.CommandPipeline,
    input_label: []const u8,
    cfg: RetryMetaConfig,
) ShellError!u8 {
    var attempt: u32 = 1;
    const started_at = std.Io.Clock.now(.awake, ctx.io.*);

    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    const now_ns: i128 = (@as(i128, ts.sec) * std.time.ns_per_s) + @as(i128, ts.nsec);
    const pid: u64 = @intCast(std.os.linux.getpid());
    const seed: u64 = @intCast(now_ns & std.math.maxInt(u64));
    var prng = std.Random.DefaultPrng.init(seed ^ pid);
    const random = prng.random();

    var termination: RetryLoopTermination = .fail_fast_or_filtered;

    while (true) {
        const maybe_exit_code = try executePipelineOnce(ctx, arena_alloc, pipe_l, input_label);
        if (maybe_exit_code == null) return ShellError.InvalidArgument;

        const exit_code = maybe_exit_code.?;
        ctx.last_exit_code = exit_code;

        const decision = decideRetry(cfg, exit_code);
        if (decision == .no_retry_success) {
            termination = .success;
            break;
        }
        if (decision != .retry) {
            termination = .fail_fast_or_filtered;
            break;
        }

        const next_attempt = attempt + 1;
        if (cfg.max_attempts) |max_attempts| {
            if (next_attempt > max_attempts) {
                termination = .max_attempts_reached;
                break;
            }
        }

        if (cfg.max_duration_ns) |max_duration_ns| {
            const elapsed = started_at.durationTo(std.Io.Clock.now(.awake, ctx.io.*));
            const elapsed_ns_i = elapsed.toNanoseconds();
            const elapsed_ns: u64 = if (elapsed_ns_i <= 0) 0 else @intCast(@min(elapsed_ns_i, std.math.maxInt(u64)));
            if (elapsed_ns >= max_duration_ns) {
                termination = .max_duration_reached;
                break;
            }
        }

        const delay_ns = computeRetryDelayNs(cfg, attempt, random);
        if (!cfg.quiet) {
            ctx.print(
                "retry: attempt {d} failed (exit {d}), policy={s}, next_attempt={d}, sleep={d}ms\n",
                .{
                    attempt,
                    exit_code,
                    @tagName(cfg.backoff),
                    next_attempt,
                    @divFloor(delay_ns, std.time.ns_per_ms),
                },
            );
        }

        if (delay_ns > 0) {
            std.Io.sleep(ctx.io.*, .{ .nanoseconds = delay_ns }, .real) catch {};
        }

        attempt = next_attempt;
    }

    if (cfg.summary) {
        const success_text = if (ctx.last_exit_code == 0) "true" else "false";
        const reason_text = switch (termination) {
            .success => "success",
            .max_attempts_reached => "max-attempts-reached",
            .max_duration_reached => "max-duration-reached",
            .fail_fast_or_filtered => "non-retriable-failure",
        };
        ctx.print(
            "retry summary: attempts={d} final_exit={d} success={s} reason={s}\n",
            .{ attempt, ctx.last_exit_code, success_text, reason_text },
        );
    }

    return ctx.last_exit_code;
}

fn computeRetryDelayNs(cfg: RetryMetaConfig, failed_attempt_index: u32, random: std.Random) u64 {
    var delay = cfg.delay_ns;

    if (cfg.backoff == .exp and failed_attempt_index > 1) {
        var i: u32 = 1;
        while (i < failed_attempt_index) : (i += 1) {
            delay = std.math.mul(u64, delay, 2) catch std.math.maxInt(u64);
        }
    }

    if (cfg.max_delay_ns) |max_delay_ns| {
        if (delay > max_delay_ns) delay = max_delay_ns;
    }

    if (cfg.jitter and delay > 1) {
        const jitter_cap = @max(@divFloor(delay, 4), @as(u64, 1));
        const extra = random.uintLessThan(u64, jitter_cap + 1);
        delay = std.math.add(u64, delay, extra) catch std.math.maxInt(u64);
    }

    if (cfg.max_delay_ns) |max_delay_ns| {
        if (delay > max_delay_ns) delay = max_delay_ns;
    }

    return delay;
}

fn decideRetry(cfg: RetryMetaConfig, exit_code: u8) RetryDecision {
    if (exit_code == 0) return .no_retry_success;
    if (exit_code == 126 or exit_code == 127) return .no_retry_fail_fast;
    if (cfg.has_on_exit and !cfg.on_exit[exit_code]) return .no_retry_not_in_on_exit;
    if (cfg.has_except_exit and cfg.except_exit[exit_code]) return .no_retry_in_except_exit;
    return .retry;
}

fn freeAliasMap(allocator: Allocator, aliases: *ShellCtx.AliasMap) void {
    var iter = aliases.iterator();
    while (iter.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    aliases.deinit();
}

test "parseCommandInput normalizes profile meta prefix for command mode" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer {
        _ = gpa.deinit();
    }

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    var io = threaded.io();

    var env_map = try @import("env.zig").EnvMap.init(allocator);
    defer env_map.deinit();

    var ctx = try ShellCtx.initEngine(&io, allocator, &env_map);
    defer ctx.deinit();

    const parsed = try parseCommandInput(&ctx, allocator, "profile retry 2 --delay 1ms echo hi");
    const retry_cfg = parsed.retry orelse return error.TestExpectedEqual;

    try std.testing.expect(parsed.measure_time);
    try std.testing.expectEqual(@as(?u32, 2), retry_cfg.max_attempts);
    try std.testing.expectEqualStrings("echo hi", parsed.command_input);
    try std.testing.expectEqual(@as(usize, 1), parsed.sequence.pipelines.len);
    try std.testing.expectEqual(@as(usize, 1), parsed.sequence.pipelines[0].stages.len);
    try std.testing.expectEqualStrings("echo", parsed.sequence.pipelines[0].stages[0].args[0].text);
}

test "parseMetaInputPrefix parses inline retry count with command tail" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try parseMetaInputPrefix(allocator, "retry 3 echo hello");

    try std.testing.expect(parsed.retry != null);
    const cfg = parsed.retry.?;
    try std.testing.expectEqual(@as(?u32, 3), cfg.max_attempts);
    try std.testing.expectEqual(@as(?u64, null), cfg.max_duration_ns);
    try std.testing.expectEqualStrings("echo hello", parsed.command_input);
}

test "parseMetaInputPrefix parses retry options" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try parseMetaInputPrefix(
        allocator,
        "retry for 2s --delay 100ms --backoff exp --max-delay 1s --jitter --on-exit 1,2 --except-exit 2 --summary echo hi",
    );
    const cfg = parsed.retry orelse return error.TestExpectedEqual;

    try std.testing.expectEqual(@as(?u32, null), cfg.max_attempts);
    try std.testing.expectEqual(@as(?u64, 2 * std.time.ns_per_s), cfg.max_duration_ns);
    try std.testing.expectEqual(@as(u64, 100 * std.time.ns_per_ms), cfg.delay_ns);
    try std.testing.expectEqual(RetryBackoff.exp, cfg.backoff);
    try std.testing.expectEqual(@as(?u64, std.time.ns_per_s), cfg.max_delay_ns);
    try std.testing.expect(cfg.jitter);
    try std.testing.expect(cfg.has_on_exit);
    try std.testing.expect(cfg.on_exit[1]);
    try std.testing.expect(cfg.on_exit[2]);
    try std.testing.expect(cfg.has_except_exit);
    try std.testing.expect(cfg.except_exit[2]);
    try std.testing.expect(cfg.summary);
    try std.testing.expectEqualStrings("echo hi", parsed.command_input);
}

test "parseMetaInputPrefix parses retry for-budget with quiet flag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try parseMetaInputPrefix(
        allocator,
        "retry for 1s --quiet echo ok",
    );
    const cfg = parsed.retry orelse return error.TestExpectedEqual;

    try std.testing.expectEqual(@as(?u32, null), cfg.max_attempts);
    try std.testing.expectEqual(@as(?u64, std.time.ns_per_s), cfg.max_duration_ns);
    try std.testing.expect(cfg.quiet);
    try std.testing.expectEqualStrings("echo ok", parsed.command_input);
}

test "parseMetaInputPrefix parses step meta command" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try parseMetaInputPrefix(allocator, "step echo hello | upper | read");
    try std.testing.expect(parsed.step_mode);
    try std.testing.expectEqualStrings("echo hello | upper | read", parsed.command_input);
    try std.testing.expect(!parsed.measure_time);
    try std.testing.expect(parsed.retry == null);
}

test "parseMetaInputPrefix rejects step combined with other meta prefixes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectError(ShellError.InvalidArgument, parseMetaInputPrefix(allocator, "profile step echo hi | upper"));
    try std.testing.expectError(ShellError.InvalidArgument, parseMetaInputPrefix(allocator, "step retry 2 echo hi | upper"));
}

test "parseMetaInputPrefix rejects removed retry flags" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectError(ShellError.InvalidArgument, parseMetaInputPrefix(allocator, "retry --for 2s echo hi"));
    try std.testing.expectError(ShellError.InvalidArgument, parseMetaInputPrefix(allocator, "retry 2 --verbose echo hi"));
}

test "parseMetaInputPrefix rejects optional retry command wrappers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectError(ShellError.InvalidArgument, parseMetaInputPrefix(allocator, "retry 2 -- false"));
    try std.testing.expectError(ShellError.InvalidArgument, parseMetaInputPrefix(allocator, "retry 2 { echo hi | upper }"));
}

test "parseMetaInputPrefix requires command body for retry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectError(ShellError.MissingCommand, parseMetaInputPrefix(allocator, "retry 2"));
}

test "decideRetry honors fail-fast and exit filters" {
    var cfg = RetryMetaConfig{ .max_attempts = 3 };
    try std.testing.expectEqual(RetryDecision.no_retry_success, decideRetry(cfg, 0));
    try std.testing.expectEqual(RetryDecision.no_retry_fail_fast, decideRetry(cfg, 127));
    try std.testing.expectEqual(RetryDecision.retry, decideRetry(cfg, 1));

    cfg.has_on_exit = true;
    cfg.on_exit[28] = true;
    try std.testing.expectEqual(RetryDecision.retry, decideRetry(cfg, 28));
    try std.testing.expectEqual(RetryDecision.no_retry_not_in_on_exit, decideRetry(cfg, 1));

    cfg.has_except_exit = true;
    cfg.except_exit[28] = true;
    try std.testing.expectEqual(RetryDecision.no_retry_in_except_exit, decideRetry(cfg, 28));
}

test "tokenizeWithCommandKinds keeps command slot open after assignment prefix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const tokens = try tokenizeWithCommandKinds(allocator, "X=inline env | grep '^X=inline$'");
    try std.testing.expectEqual(@as(usize, 6), tokens.len);
    try std.testing.expectEqual(lexer.TokenKind.Assignment, tokens[0].kind);
    try std.testing.expectEqual(lexer.TokenKind.Command, tokens[1].kind);
    try std.testing.expectEqualStrings("env", tokens[1].text);
    try std.testing.expectEqual(lexer.TokenKind.Pipe, tokens[2].kind);
    try std.testing.expectEqual(lexer.TokenKind.Command, tokens[3].kind);
}

test "tokenizeWithCommandKinds treats inline key=value after command as plain args" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const tokens = try tokenizeWithCommandKinds(allocator, "python3 cli.py x=10 dx=3");
    try std.testing.expectEqual(@as(usize, 4), tokens.len);
    try std.testing.expectEqual(lexer.TokenKind.Command, tokens[0].kind);
    try std.testing.expectEqual(lexer.TokenKind.Arg, tokens[1].kind);
    try std.testing.expectEqual(lexer.TokenKind.Arg, tokens[2].kind);
    try std.testing.expectEqual(lexer.TokenKind.Arg, tokens[3].kind);
}

test "tokenizeWithCommandKinds preserves export assignment syntax" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const tokens = try tokenizeWithCommandKinds(allocator, "export X=10");
    try std.testing.expectEqual(@as(usize, 2), tokens.len);
    try std.testing.expectEqual(lexer.TokenKind.Command, tokens[0].kind);
    try std.testing.expectEqual(lexer.TokenKind.Assignment, tokens[1].kind);
}

test "expandInteractiveAliases expands first command token" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer {
        _ = gpa.deinit();
    }

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    var io = threaded.io();

    var env_map = try @import("env.zig").EnvMap.init(allocator);
    defer env_map.deinit();

    var ctx = try ShellCtx.initEngine(&io, allocator, &env_map);
    defer ctx.deinit();
    ctx.exe_mode = .interactive;

    var aliases = ShellCtx.AliasMap.init(allocator);
    defer freeAliasMap(allocator, &aliases);
    try aliases.put(try allocator.dupe(u8, "gp"), try allocator.dupe(u8, "git pull"));
    ctx.aliases = &aliases;

    const tokens = try tokenizeWithCommandKinds(allocator, "gp origin main");
    const expanded = try expandInteractiveAliases(&ctx, allocator, tokens);

    try std.testing.expectEqual(@as(usize, 4), expanded.len);
    try std.testing.expectEqual(lexer.TokenKind.Command, expanded[0].kind);
    try std.testing.expectEqualStrings("git", expanded[0].text);
    try std.testing.expectEqualStrings("pull", expanded[1].text);
    try std.testing.expectEqualStrings("origin", expanded[2].text);
    try std.testing.expectEqualStrings("main", expanded[3].text);
}

test "expandInteractiveAliases does not expand quoted command token" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer {
        _ = gpa.deinit();
    }

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    var io = threaded.io();

    var env_map = try @import("env.zig").EnvMap.init(allocator);
    defer env_map.deinit();

    var ctx = try ShellCtx.initEngine(&io, allocator, &env_map);
    defer ctx.deinit();
    ctx.exe_mode = .interactive;

    var aliases = ShellCtx.AliasMap.init(allocator);
    defer freeAliasMap(allocator, &aliases);
    try aliases.put(try allocator.dupe(u8, "gp"), try allocator.dupe(u8, "git pull"));
    ctx.aliases = &aliases;

    const tokens = try tokenizeWithCommandKinds(allocator, "'gp' origin");
    const expanded = try expandInteractiveAliases(&ctx, allocator, tokens);

    try std.testing.expectEqual(@as(usize, 2), expanded.len);
    try std.testing.expectEqual(lexer.TokenKind.Command, expanded[0].kind);
    try std.testing.expectEqualStrings("gp", expanded[0].text);
    try std.testing.expect(expanded[0].single_quoted);
}

test "findBestCommandSuggestion suggests nearest builtin name" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer {
        _ = gpa.deinit();
    }

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    var io = threaded.io();

    var env_map = try @import("env.zig").EnvMap.init(allocator);
    defer env_map.deinit();

    var ctx = try ShellCtx.initEngine(&io, allocator, &env_map);
    defer ctx.deinit();

    const suggestion = findBestCommandSuggestion(&ctx, "hepl") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("help", suggestion);
}

test "findBestCommandSuggestion includes interactive aliases" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer {
        _ = gpa.deinit();
    }

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    var io = threaded.io();

    var env_map = try @import("env.zig").EnvMap.init(allocator);
    defer env_map.deinit();

    var ctx = try ShellCtx.initEngine(&io, allocator, &env_map);
    defer ctx.deinit();
    ctx.exe_mode = .interactive;

    var aliases = ShellCtx.AliasMap.init(allocator);
    defer freeAliasMap(allocator, &aliases);
    try aliases.put(try allocator.dupe(u8, "gst"), try allocator.dupe(u8, "git status"));
    ctx.aliases = &aliases;

    const suggestion = findBestCommandSuggestion(&ctx, "gts") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("gst", suggestion);
}

test "step meta command is rejected during parse in engine mode" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer {
        _ = gpa.deinit();
    }

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    var io = threaded.io();

    var env_map = try @import("env.zig").EnvMap.init(allocator);
    defer env_map.deinit();

    var ctx = try ShellCtx.initEngine(&io, allocator, &env_map);
    defer ctx.deinit();

    try std.testing.expectError(ShellError.Unsupported, parseCommandInput(&ctx, allocator, "step echo hi | upper"));
}
