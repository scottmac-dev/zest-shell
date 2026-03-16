// ============================================================================
// INTERACTIVE SHELL BRANCH  shell/shell.zig
// Responsibilities: REPL loop, prompt rendering, history, job control,
// terminal signal management, user-facing UX.
//
// This branch delegates all actual command execution down to shared parse/
// execute infrastructure. It owns only the session layer above that.
// ============================================================================
const std = @import("std");
const config = @import("interactive/config.zig");
const env = @import("../lib-core/core/env.zig");
const parse = @import("../lib-core/core/parse.zig");
const helpers = @import("../lib-core/core/helpers.zig");
const errors = @import("../lib-core/core/errors.zig");
const signals = @import("../lib-core/core/signals.zig");
const ShellError = @import("../lib-core/core/errors.zig").ShellError;
const history = @import("interactive/history.zig");
const session_config = @import("interactive/session_config.zig");
const jobs = @import("interactive/jobs.zig");
const adapters = @import("interactive/adapters.zig");
const input_handler = @import("interactive/input_raw.zig");
const Allocator = std.mem.Allocator;
const ShellCtx = @import("../lib-core/core/context.zig").ShellCtx;
const linux = std.os.linux;

/// Full config for the interactive shell branch.
/// Carries everything needed for a long-lived REPL session.
pub const InteractiveConfig = struct {
    /// Path to history file for persistence across sessions.
    hist_file: []const u8 = config.HIST_FILE,

    /// Path to env persistence file.
    env_file: []const u8 = config.ENV_FILE,

    /// Path to interactive shell config (aliases and session defaults).
    config_file: []const u8 = config.CONFIG_FILE,
};

/// Set up terminal processes and signal handling
fn setupTerminal() void {
    const shell_pid: std.posix.pid_t = @intCast(std.os.linux.getpid());
    _ = std.os.linux.setpgid(shell_pid, shell_pid);

    std.posix.sigaction(std.posix.SIG.INT, &signals.ign_act, null);
    std.posix.sigaction(std.posix.SIG.TSTP, &signals.ign_act, null);
    std.posix.sigaction(std.posix.SIG.TTOU, &signals.ign_act, null);
    std.posix.sigaction(std.posix.SIG.TTIN, &signals.ign_act, null);

    const tty_fd = std.posix.STDIN_FILENO;
    std.posix.tcsetpgrp(tty_fd, shell_pid) catch {};
}

fn monotonicNowNs() i128 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return (@as(i128, ts.sec) * std.time.ns_per_s) + @as(i128, ts.nsec);
}

fn formatRelativeLastLaunch(allocator: Allocator, epoch_secs: i64) ![]const u8 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    const now: i64 = @intCast(ts.sec);
    const delta = if (now > epoch_secs) now - epoch_secs else 0;

    if (delta < 45) return std.fmt.allocPrint(allocator, "just now", .{});
    if (delta < 90) return std.fmt.allocPrint(allocator, "1 min ago", .{});
    if (delta < 60 * 60) return std.fmt.allocPrint(allocator, "{d} mins ago", .{@divTrunc(delta, 60)});
    if (delta < 2 * 60 * 60) return std.fmt.allocPrint(allocator, "1 hour ago", .{});
    if (delta < 24 * 60 * 60) return std.fmt.allocPrint(allocator, "{d} hours ago", .{@divTrunc(delta, 60 * 60)});
    if (delta < 2 * 24 * 60 * 60) return std.fmt.allocPrint(allocator, "1 day ago", .{});
    if (delta < 7 * 24 * 60 * 60) return std.fmt.allocPrint(allocator, "{d} days ago", .{@divTrunc(delta, 24 * 60 * 60)});
    if (delta < 2 * 7 * 24 * 60 * 60) return std.fmt.allocPrint(allocator, "1 week ago", .{});
    if (delta < 30 * 24 * 60 * 60) return std.fmt.allocPrint(allocator, "{d} weeks ago", .{@divTrunc(delta, 7 * 24 * 60 * 60)});
    if (delta < 2 * 30 * 24 * 60 * 60) return std.fmt.allocPrint(allocator, "1 month ago", .{});
    if (delta < 365 * 24 * 60 * 60) return std.fmt.allocPrint(allocator, "{d} months ago", .{@divTrunc(delta, 30 * 24 * 60 * 60)});
    if (delta < 2 * 365 * 24 * 60 * 60) return std.fmt.allocPrint(allocator, "1 year ago", .{});
    return std.fmt.allocPrint(allocator, "{d} years ago", .{@divTrunc(delta, 365 * 24 * 60 * 60)});
}

fn readLastLaunchEpoch(ctx: *ShellCtx, allocator: Allocator) ?i64 {
    const expanded = helpers.expandPathToAbs(ctx, allocator, config.LAST_LAUNCH_FILE) catch return null;
    defer allocator.free(expanded);

    const raw = helpers.readFileFromPath(ctx, allocator, expanded, true) catch return null;
    defer allocator.free(raw);

    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    return std.fmt.parseInt(i64, trimmed, 10) catch null;
}

fn writeLastLaunchEpoch(ctx: *ShellCtx, allocator: Allocator, epoch_secs: i64) void {
    const expanded = helpers.expandPathToAbs(ctx, allocator, config.LAST_LAUNCH_FILE) catch return;
    defer allocator.free(expanded);

    helpers.ensureDirPath(ctx, expanded) catch return;

    var file = helpers.getFileFromPath(ctx, allocator, expanded, .{
        .write = true,
        .truncate = true,
        .pre_expanded = true,
    }) catch return;
    defer file.close(ctx.io.*);

    var buf: [48]u8 = undefined;
    const payload = std.fmt.bufPrint(&buf, "{d}\n", .{epoch_secs}) catch return;
    helpers.fileWriteAll(ctx.io.*, file, payload) catch {};
}

fn printBannerLine(ctx: *ShellCtx, color: config.Color, line: []const u8) void {
    ctx.print("\x1b[{s}m{s}\x1b[0m\n", .{
        config.getAnsiColorStr(color),
        line,
    });
}

fn printBannerArt(ctx: *ShellCtx) void {
    printBannerLine(ctx, .cyan, "   ____  _____ ____ _____");
    printBannerLine(ctx, .blue, "  /_  / | ____/ ___|_   _|");
    printBannerLine(ctx, .magenta, "   / /  |  _| \\___ \\ | |");
    printBannerLine(ctx, .yellow, "  / /_  | |___ ___) || |");
    printBannerLine(ctx, .green, " /____| |_____|____/ |_|");
}

fn printStartupBanner(ctx: *ShellCtx, allocator: Allocator, loaded_cfg: session_config.LoadedConfig, startup_ms: i64) void {
    const last_epoch = readLastLaunchEpoch(ctx, allocator);
    const last_text = if (last_epoch) |secs| formatRelativeLastLaunch(allocator, secs) catch null else null;
    defer if (last_text) |text| allocator.free(text);

    const user = ctx.getDisplayUser() catch "user";

    ctx.print("\n", .{});
    printBannerArt(ctx);
    ctx.print("  v{s}       | user={s}\n", .{
        config.VERSION,
        user,
    });
    ctx.print("  \x1b[{s}mstartup\x1b[0m={d}ms | \x1b[{s}maliases\x1b[0m={d}\n", .{
        config.getAnsiColorStr(.yellow),
        startup_ms,
        config.getAnsiColorStr(.magenta),
        loaded_cfg.alias_count,
    });
    if (last_text) |text| {
        ctx.print("  \x1b[{s}mlast_launch\x1b[0m={s}\n\n", .{
            config.getAnsiColorStr(.cyan),
            text,
        });
    } else {
        ctx.print("  \x1b[{s}mlast_launch\x1b[0m=first run\n\n", .{
            config.getAnsiColorStr(.cyan),
        });
    }
}

const HeredocCapture = struct {
    display_input: []const u8,
    parse_input: []const u8,
    temp_paths: []const []const u8,
};

const HeredocMatch = struct {
    operator_start: usize,
    operator_end: usize,
    delimiter: []const u8,
    expand_body: bool,
};

fn isWordTerminator(c: u8) bool {
    return std.ascii.isWhitespace(c) or c == '|' or c == '&' or c == ';' or c == '<' or c == '>';
}

fn hasTrailingLineContinuation(line: []const u8) bool {
    if (line.len == 0 or line[line.len - 1] != '\\') return false;

    var slash_count: usize = 0;
    var i = line.len;
    while (i > 0 and line[i - 1] == '\\') : (i -= 1) {
        slash_count += 1;
    }
    return slash_count % 2 == 1;
}

fn readCookedLineWithPrompt(ctx: *ShellCtx, arena_alloc: Allocator, prompt: []const u8) !struct { line: []const u8, eof: bool } {
    ctx.print("{s}", .{prompt});

    var i_buf: [512]u8 = undefined;
    const stdin_file = std.Io.File.stdin();
    var stdin_reader = stdin_file.reader(ctx.io.*, &i_buf);
    const stdin = &stdin_reader.interface;

    var line = try std.ArrayList(u8).initCapacity(arena_alloc, 64);

    while (true) {
        const ch = stdin.takeByte() catch |err| switch (err) {
            error.EndOfStream => return .{ .line = line.items, .eof = true },
            else => return err,
        };
        if (ch == '\n') return .{ .line = line.items, .eof = false };
        if (ch == '\r') continue;
        try line.append(arena_alloc, ch);
    }
}

fn collectContinuationLines(ctx: *ShellCtx, arena_alloc: Allocator, first_line: []const u8) ![]const u8 {
    var logical = try std.ArrayList(u8).initCapacity(arena_alloc, first_line.len + 32);
    try logical.appendSlice(arena_alloc, first_line);

    while (hasTrailingLineContinuation(logical.items)) {
        _ = logical.pop();
        const continuation = try readCookedLineWithPrompt(ctx, arena_alloc, "> ");
        if (continuation.eof) return ShellError.UnexpectedEof;
        try logical.appendSlice(arena_alloc, continuation.line);
    }

    return logical.items;
}

fn nextHeredocMatch(input: []const u8, start_idx: usize) ShellError!?HeredocMatch {
    var in_single = false;
    var in_double = false;
    var escaped = false;

    var i = start_idx;
    while (i < input.len) : (i += 1) {
        const ch = input[i];

        if (escaped) {
            escaped = false;
            continue;
        }
        if (ch == '\\' and !in_single) {
            escaped = true;
            continue;
        }
        if (ch == '\'' and !in_double) {
            in_single = !in_single;
            continue;
        }
        if (ch == '"' and !in_single) {
            in_double = !in_double;
            continue;
        }

        if (in_single or in_double) continue;
        if (ch != '<' or i + 1 >= input.len or input[i + 1] != '<') continue;

        var j = i + 2;
        while (j < input.len and std.ascii.isWhitespace(input[j])) : (j += 1) {}
        if (j >= input.len) return ShellError.InvalidSyntax;

        if (input[j] == '\'' or input[j] == '"') {
            const quote = input[j];
            const delim_start = j + 1;
            var delim_end = delim_start;
            while (delim_end < input.len and input[delim_end] != quote) : (delim_end += 1) {}
            if (delim_end >= input.len) return ShellError.InvalidSyntax;
            if (delim_end == delim_start) return ShellError.InvalidSyntax;
            return HeredocMatch{
                .operator_start = i,
                .operator_end = delim_end + 1,
                .delimiter = input[delim_start..delim_end],
                .expand_body = false,
            };
        }

        const delim_start = j;
        var delim_end = delim_start;
        while (delim_end < input.len and !isWordTerminator(input[delim_end])) : (delim_end += 1) {}
        if (delim_end == delim_start) return ShellError.InvalidSyntax;
        return HeredocMatch{
            .operator_start = i,
            .operator_end = delim_end,
            .delimiter = input[delim_start..delim_end],
            .expand_body = true,
        };
    }

    return null;
}

fn readHeredocBody(
    ctx: *ShellCtx,
    arena_alloc: Allocator,
    delimiter: []const u8,
    expand_body: bool,
) ![]const u8 {
    var body = try std.ArrayList(u8).initCapacity(arena_alloc, 128);

    while (true) {
        const next = try readCookedLineWithPrompt(ctx, arena_alloc, "> ");
        if (next.eof) return ShellError.UnexpectedEof;
        if (std.mem.eql(u8, next.line, delimiter)) break;
        const rendered_line = if (expand_body)
            helpers.expandVariables(ctx, arena_alloc, next.line) catch next.line
        else
            next.line;
        try body.appendSlice(arena_alloc, rendered_line);
        try body.append(arena_alloc, '\n');
    }

    return body.items;
}

fn createHeredocTempFile(
    ctx: *ShellCtx,
    arena_alloc: Allocator,
    body: []const u8,
    temp_counter: *u64,
) ![]const u8 {
    temp_counter.* += 1;
    const path = try std.fmt.allocPrint(arena_alloc, "/tmp/zest-heredoc-{d}-{d}.tmp", .{
        linux.getpid(),
        temp_counter.*,
    });

    var file = try std.Io.Dir.createFileAbsolute(ctx.io.*, path, .{ .truncate = true });
    defer file.close(ctx.io.*);
    try helpers.fileWriteAll(ctx.io.*, file, body);
    return path;
}

fn preprocessInteractiveInput(
    ctx: *ShellCtx,
    arena_alloc: Allocator,
    first_line: []const u8,
    temp_counter: *u64,
) !HeredocCapture {
    const display_input = try collectContinuationLines(ctx, arena_alloc, first_line);

    var parse_output = try std.ArrayList(u8).initCapacity(arena_alloc, display_input.len + 64);
    var temp_paths = try std.ArrayList([]const u8).initCapacity(arena_alloc, 2);

    var cursor: usize = 0;
    var changed = false;
    while (try nextHeredocMatch(display_input, cursor)) |match| {
        changed = true;
        try parse_output.appendSlice(arena_alloc, display_input[cursor..match.operator_start]);

        const body = try readHeredocBody(ctx, arena_alloc, match.delimiter, match.expand_body);
        const path = try createHeredocTempFile(ctx, arena_alloc, body, temp_counter);
        try temp_paths.append(arena_alloc, path);

        try parse_output.appendSlice(arena_alloc, "< ");
        try parse_output.appendSlice(arena_alloc, path);
        cursor = match.operator_end;
    }

    if (!changed) {
        return .{
            .display_input = display_input,
            .parse_input = display_input,
            .temp_paths = temp_paths.items,
        };
    }

    try parse_output.appendSlice(arena_alloc, display_input[cursor..]);
    return .{
        .display_input = display_input,
        .parse_input = parse_output.items,
        .temp_paths = temp_paths.items,
    };
}

fn cleanupHeredocTempFiles(ctx: *ShellCtx, temp_paths: []const []const u8) void {
    for (temp_paths) |path| {
        std.Io.Dir.deleteFileAbsolute(ctx.io.*, path) catch {};
    }
}

/// REPL loop
pub fn run(cfg: InteractiveConfig, init: std.process.Init.Minimal) !u8 {
    const startup_begin_ns = monotonicNowNs();

    // GPA gives us leak detection during development. In a release build
    // you'd swap this for page_allocator or a custom allocator.
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .enable_memory_limit = true,
        .stack_trace_frames = 16,
    }){};
    defer {
        if (gpa.deinit() == .leak) @panic("Memory leak detected!");
    }
    const allocator = gpa.allocator();

    setupTerminal();

    // Initialize session-level services
    var history_manager = try history.HistoryManager.init(allocator);
    defer history_manager.deinit();

    var env_map = try env.EnvMap.init(allocator);
    defer env_map.deinit();
    try env_map.seedFromEnviron(init.environ, allocator);

    var jobs_table = try jobs.JobTable.init(allocator);
    defer jobs_table.deinit();

    var exe_cache = try env.ExeCache.init(allocator);
    defer exe_cache.deinit();

    var alias_map = ShellCtx.AliasMap.init(allocator);
    defer {
        var iter = alias_map.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        alias_map.deinit();
    }

    var interactive_adapter = adapters.InteractiveAdapter.init(
        history_manager,
        jobs_table,
        cfg.hist_file,
        cfg.env_file,
    );

    var threaded: std.Io.Threaded = .init(allocator, .{
        .argv0 = .init(init.args),
        .environ = init.environ,
    });
    defer threaded.deinit();
    var io = threaded.io();

    var ctx = ShellCtx.initShell(
        &io,
        allocator,
        env_map,
        &exe_cache,
        &alias_map,
        config.SHELL_NAME,
        config.VERSION,
        interactive_adapter.servicesRef(),
    );
    defer ctx.deinit();
    var loaded_cfg = session_config.load(&ctx, allocator, cfg.config_file, &alias_map) catch |err| {
        errors.report(err, "load interactive config", cfg.config_file);
        return 2;
    };
    defer session_config.freeLoadedConfig(allocator, &loaded_cfg);
    if (loaded_cfg.prompt_template) |template| {
        ctx.prompt_template = allocator.dupe(u8, template) catch null;
    }

    // Load persistent session state
    env_map.importEnv(&ctx, cfg.env_file) catch |err| {
        errors.report(err, "import shell environment", cfg.env_file);
    };
    // Persist session state on exit
    defer history_manager.exportHistory(&ctx, cfg.hist_file, false) catch |err| {
        errors.report(err, "export command history", cfg.hist_file);
    };
    defer env_map.exportEnv(&ctx, cfg.env_file) catch |err| {
        errors.report(err, "export shell environment", cfg.env_file);
    };

    const startup_end_ns = monotonicNowNs();
    const startup_delta_ns = startup_end_ns - startup_begin_ns;
    const startup_ms: i64 = if (startup_delta_ns <= 0)
        0
    else
        @intCast(@divFloor(startup_delta_ns, std.time.ns_per_ms));

    // Startup banner (not shown to agents)
    printStartupBanner(&ctx, allocator, loaded_cfg, startup_ms);

    const now_real = std.Io.Clock.now(.real, ctx.io.*);
    const now_epoch_secs: i64 = @intCast(@divFloor(now_real.nanoseconds, std.time.ns_per_s));
    writeLastLaunchEpoch(&ctx, allocator, now_epoch_secs);

    // -----------------------------------------------------------------------
    // REPL loop
    // -----------------------------------------------------------------------
    var heredoc_temp_counter: u64 = 0;
    var history_loaded = false;

    while (true) {
        // Per-command arena: parse, execute, free. No state leaks between
        // commands. Long-lived state (history, env) lives in the GPA above.
        var arena = std.heap.ArenaAllocator.init(allocator);
        const arena_alloc = arena.allocator();
        defer arena.deinit();

        // Keep background job state fresh even while idle at the prompt.
        ctx.pollBackgroundJobs();
        ctx.cleanFinishedJobs(true);

        // Defer history disk I/O until after the first prompt renders.
        if (!history_loaded) {
            history_loaded = true;
            history_manager.importHistory(&ctx, cfg.hist_file) catch |err| {
                errors.report(err, "import command history", cfg.hist_file);
            };
        }

        const input = try input_handler.read(&ctx, arena_alloc);
        if (input.len == 0) continue;

        const capture = preprocessInteractiveInput(&ctx, arena_alloc, input, &heredoc_temp_counter) catch |err| {
            errors.reportInteractive(err, ctx.io.*, ctx.stdout, .{
                .source_line = input,
                .source_name = "interactive",
                .line_no = 1,
                .action = "collect multiline/heredoc input",
                .detail = input,
                .command_word = null,
            });
            ctx.last_exit_code = 1;
            continue;
        };
        defer cleanupHeredocTempFiles(&ctx, capture.temp_paths);
        if (capture.display_input.len == 0) continue;

        // Persist command in history using the GPA (outlives the arena)
        const cmd = try allocator.dupe(u8, capture.display_input);
        history_manager.push(cmd) catch allocator.free(cmd);

        // Execute — soft error handling; REPL continues on failure
        ctx.current_input_line = cmd;
        var head_iter = std.mem.tokenizeAny(u8, cmd, &std.ascii.whitespace);
        const command_word = head_iter.next();
        parse.parseAndExecute(&ctx, arena_alloc, capture.parse_input) catch |err| {
            errors.reportInteractive(err, ctx.io.*, ctx.stdout, .{
                .source_line = cmd,
                .source_name = "interactive",
                .line_no = 1,
                .action = "parse and execute REPL command",
                .detail = cmd,
                .command_word = command_word,
            });
            ctx.last_exit_code = 1;
            ctx.current_input_line = null;
            continue;
        };
        ctx.current_input_line = null;
    }
}

test "hasTrailingLineContinuation detects odd trailing slash runs" {
    try std.testing.expect(hasTrailingLineContinuation("echo hello\\"));
    try std.testing.expect(!hasTrailingLineContinuation("echo hello\\\\"));
    try std.testing.expect(!hasTrailingLineContinuation("echo hello"));
}

test "nextHeredocMatch finds bare and quoted delimiters" {
    const simple = try nextHeredocMatch("cat <<EOF", 0);
    try std.testing.expect(simple != null);
    try std.testing.expectEqualStrings("EOF", simple.?.delimiter);
    try std.testing.expect(simple.?.expand_body);

    const quoted = try nextHeredocMatch("cat <<'DONE' | wc", 0);
    try std.testing.expect(quoted != null);
    try std.testing.expectEqualStrings("DONE", quoted.?.delimiter);
    try std.testing.expect(!quoted.?.expand_body);

    const none = try nextHeredocMatch("echo \"<<EOF\"", 0);
    try std.testing.expect(none == null);
}
