const std = @import("std");
const builtins = @import("builtins.zig");
const command = @import("command.zig");
const linux = std.os.linux;
const helpers = @import("helpers.zig");
const types = @import("types.zig");
const errors = @import("errors.zig");
const fork_exec = @import("fork_exec.zig");
const Allocator = std.mem.Allocator;
const BuiltinCommand = builtins.BuiltinCommand;
const Command = command.Command;
const CommandPipeline = @import("pipeline.zig").CommandPipeline;
const ExecContext = command.ExecContext;
const RedirConfig = command.RedirConfig;
const ShellCtx = @import("context.zig").ShellCtx;
const ShellError = @import("errors.zig").ShellError;
const Value = types.Value;
const List = types.List;
const Map = types.Map;

pub fn shouldRenderInteractiveExternalExit(exit_code: u8) bool {
    return exit_code >= 2 and exit_code < 128;
}

/// SINGLE command execution logic
/// Take a single command and route to the correct helper function
pub fn executeSingleCommand(ctx: *ShellCtx, arena_alloc: Allocator, cmd_pipeline: CommandPipeline) ShellError!u8 {
    const io = ctx.io.*;
    var stage = &cmd_pipeline.stages[0];

    const expanded_args = stage.getExpandedArgs(ctx, arena_alloc) catch return ShellError.CommandExpansionFailed;
    const cfg: ?RedirConfig = cmd_pipeline.redir_config;
    const has_in_redirect: bool = cfg != null and cfg.?.stdin_path != null;
    const has_out_redirect: bool = cfg != null and cfg.?.stdout_path != null;
    const has_err_redirect: bool = cfg != null and cfg.?.stderr_path != null;
    const merge_stderr_to_stdout: bool = cfg != null and cfg.?.merge_stderr_to_stdout;
    const has_any_redirect: bool = (has_in_redirect or has_out_redirect or has_err_redirect);

    const exit_code = switch (stage.cmd_type) {
        .assignment => blk: {
            executeAssignment(ctx, arena_alloc, expanded_args[0]) catch return ShellError.InvalidAssignment;
            break :blk 0;
        },

        .builtin => blk: {
            const builtin_fn = builtins.getBuiltinFunction(BuiltinCommand.fromString(expanded_args[0]));

            const stdin_file: ?std.Io.File = if (has_in_redirect) blk_in: {
                const f = helpers.getFileFromPath(ctx, arena_alloc, cfg.?.stdin_path.?, .{
                    .truncate = false,
                    .write = false,
                    .pre_expanded = false,
                }) catch |err| return errors.mapRedirectOpenError(err);
                break :blk_in f;
            } else null;
            defer if (stdin_file) |f| f.close(io);

            const stdout_file: ?std.Io.File = if (has_out_redirect) blk_in: {
                const f = helpers.getFileFromPath(ctx, arena_alloc, cfg.?.stdout_path.?, .{
                    .truncate = cfg.?.stdout_truncate,
                    .write = true,
                    .pre_expanded = false,
                }) catch |err| return errors.mapRedirectOpenError(err);
                break :blk_in f;
            } else null;
            defer if (stdout_file) |f| f.close(io);

            const stderr_file: ?std.Io.File = if (has_err_redirect and !merge_stderr_to_stdout) blk_in: {
                const f = helpers.getFileFromPath(ctx, arena_alloc, cfg.?.stderr_path.?, .{
                    .truncate = cfg.?.stderr_truncate,
                    .write = true,
                    .pre_expanded = false,
                }) catch |err| return errors.mapRedirectOpenError(err);
                break :blk_in f;
            } else null;
            defer if (stderr_file) |f| f.close(io);

            const append = blk_append: {
                if (!has_any_redirect) break :blk_append false;
                if (has_out_redirect) break :blk_append !cfg.?.stdout_truncate;
                if (has_err_redirect) break :blk_append !cfg.?.stderr_truncate;
                break :blk_append false;
            };

            executeTypedBuiltin(
                ctx,
                arena_alloc,
                builtin_fn,
                expanded_args,
                stdin_file,
                stdout_file,
                stderr_file,
                append,
                merge_stderr_to_stdout,
            ) catch |err| {
                if (ctx.exe_mode == .interactive and ctx.current_input_line != null) {
                    errors.reportInteractive(err, ctx.io.*, ctx.stdout, .{
                        .source_line = ctx.current_input_line.?,
                        .source_name = "interactive",
                        .line_no = 1,
                        .action = "execute builtin command",
                        .detail = expanded_args[0],
                        .command_word = expanded_args[0],
                    });
                } else {
                    errors.report(err, "execute builtin command", expanded_args[0]);
                }
                return err;
            };

            break :blk ctx.last_exit_code;
        },

        .external => blk: {
            switch (ctx.exe_mode) {
                .interactive => {
                    const exit_code = executeExternalInteractive(ctx, arena_alloc, expanded_args, cfg) catch |err| switch (err) {
                        ShellError.CommandNotFound => return ShellError.CommandNotFound,
                        ShellError.NotExecutable => return ShellError.NotExecutable,
                        ShellError.PermissionDenied => return ShellError.PermissionDenied,
                        else => return ShellError.ExecFailed,
                    };
                    if (ctx.current_input_line != null and shouldRenderInteractiveExternalExit(exit_code)) {
                        const detail = std.fmt.allocPrint(arena_alloc, "{s} exited with status {d}", .{ expanded_args[0], exit_code }) catch expanded_args[0];
                        errors.reportInteractive(ShellError.ExternalCommandFailed, ctx.io.*, ctx.stdout, .{
                            .source_line = ctx.current_input_line.?,
                            .source_name = "interactive",
                            .line_no = 1,
                            .action = "run external command",
                            .detail = detail,
                            .command_word = expanded_args[0],
                        });
                    }
                    break :blk exit_code;
                },
                .engine => break :blk executeExternalEngine(ctx, arena_alloc, expanded_args, cfg) catch return ShellError.ExecFailed,
            }
        },
    };

    return exit_code;
}

/// Executes a builtin and either captures and writes to terminal, or writes directly to an out file
pub fn executeTypedBuiltin(
    shell_ctx: *ShellCtx,
    allocator: Allocator,
    builtin_fn: builtins.BuiltinFn,
    args: [][]const u8,
    stdin_file: ?std.Io.File,
    stdout_file: ?std.Io.File,
    stderr_file: ?std.Io.File,
    append: bool,
    merge_stderr_to_stdout: bool,
) ShellError!void {

    // Capture builtin return values only when explicitly requested by engine JSON mode.
    const engine_capture = shell_ctx.exe_mode == .engine and shell_ctx.capture_engine_values and stdout_file == null;
    const output_target: command.ExecOutput = if (stdout_file) |f|
        .{ .stream = f }
    else if (engine_capture)
        .capture
    else
        .{ .stream = shell_ctx.stdout };
    const err_target: command.ExecErr = if (merge_stderr_to_stdout)
        switch (output_target) {
            .stream => |f| .{ .stream = f },
            .capture, .none => .{ .stream = shell_ctx.stdout },
        }
    else if (stderr_file) |f|
        .{ .stream = f }
    else
        .none;

    var exec_ctx = ExecContext{
        .shell_ctx = shell_ctx,
        .allocator = allocator,
        .input = if (stdin_file) |f| .{ .stream = f } else .none,
        .output = output_target,
        .err = err_target,
        .append = append,
    };

    //std.debug.print("exec_ctx: in -> {any} out -> {any}\n", .{ exec_ctx.input, exec_ctx.output });

    const value = builtin_fn(&exec_ctx, args);
    switch (value) {
        .err => |err| {
            shell_ctx.last_exit_code = 2;
            if (shell_ctx.exe_mode == .interactive and shell_ctx.current_input_line != null) {
                errors.reportInteractive(err, shell_ctx.io.*, shell_ctx.stdout, .{
                    .source_line = shell_ctx.current_input_line.?,
                    .source_name = "interactive",
                    .line_no = 1,
                    .action = "run builtin function",
                    .detail = args[0],
                    .command_word = args[0],
                });
            } else {
                errors.report(err, "run builtin function", args[0]);
            }
        },
        .boolean => |b| shell_ctx.last_exit_code = if (b) 0 else 1,
        else => shell_ctx.last_exit_code = 0,
    }

    // Store captured value for engine to format and emit
    if (engine_capture) {
        shell_ctx.captured_output = value;
    }
}

/// Execute a variable assignment (VAR=value)
pub fn executeAssignment(ctx: *ShellCtx, arena_alloc: Allocator, assignment_text: []const u8) ShellError!void {
    const parts = helpers.parseAssignment(assignment_text) orelse return ShellError.InvalidAssignment;

    // Expand variables in the value (allows Y=$X)
    const expanded_value = helpers.expandVariables(ctx, arena_alloc, parts.value) catch return ShellError.CommandExpansionFailed;

    // env_map will dupe and own the expanded value
    const value = types.Value{ .text = expanded_value };
    ctx.env_map.putShell(parts.name, value) catch return ShellError.InvalidAssignment;
}

/// Resolve command path in parent for interactive diagnostics and predictable failures.
pub fn resolveExternalCommandInteractive(ctx: *ShellCtx, arena_alloc: Allocator, cmd_name: []const u8) ShellError![]const u8 {
    if (helpers.isPath(cmd_name)) {
        const abs_path = helpers.expandPathToAbs(ctx, arena_alloc, cmd_name) catch return ShellError.InvalidPath;
        std.Io.Dir.accessAbsolute(ctx.io.*, abs_path, .{ .execute = true }) catch |err| return switch (err) {
            error.FileNotFound => ShellError.CommandNotFound,
            error.AccessDenied, error.PermissionDenied => ShellError.NotExecutable,
            else => ShellError.ExecFailed,
        };
        return abs_path;
    }

    const resolved = ctx.findExe(cmd_name) catch return ShellError.ExecFailed;
    return resolved orelse ShellError.CommandNotFound;
}

// --- INTERACTIVE
/// Run an external exe process and handle posix signals and redirects
pub fn executeExternalInteractive(
    ctx: *ShellCtx,
    arena_alloc: Allocator,
    args: [][]const u8,
    config: ?RedirConfig,
) ShellError!u8 {
    const cmd_path = try resolveExternalCommandInteractive(ctx, arena_alloc, args[0]);
    try preflightExternalRedirectWrites(ctx, arena_alloc, config);

    const child_pid = try fork_exec.forkProcess();

    if (child_pid == 0) {
        // ===== CHILD PROCESS =====
        fork_exec.setInteractiveChildSignalDefaults();
        if (!fork_exec.setChildProcessGroup(null)) linux.exit(1);
        if (!fork_exec.setupSingleExternalRedirectsInChild(ctx, arena_alloc, config)) {
            linux.exit(1);
        }
        fork_exec.execExternalResolvedOrExit(ctx, arena_alloc, cmd_path, args);
    }

    // ===== PARENT PROCESS =====
    _ = fork_exec.setParentProcessGroup(child_pid, null);
    fork_exec.setInteractiveParentSignalIgnore();
    fork_exec.giveTerminalTo(child_pid);

    var term_code: u8 = 0;
    while (true) {
        const waited = try fork_exec.waitPidChecked(child_pid, linux.W.UNTRACED);
        switch (waited) {
            .event => |status| {
                if (linux.W.IFSTOPPED(status)) {
                    ctx.print("\n[Job Suspended]\n", .{});
                    ctx.saveStoppedCommand(args, child_pid) catch return ShellError.JobSpawnFailed;
                    term_code = 148;
                    break;
                } else if (linux.W.IFEXITED(status)) {
                    term_code = @intCast(linux.W.EXITSTATUS(status));
                    break;
                } else if (linux.W.IFSIGNALED(status)) {
                    const sig = linux.W.TERMSIG(status);
                    if (sig == .INT) ctx.print("\n", .{});
                    term_code = 128 + @as(u8, @intCast(@intFromEnum(sig)));
                    break;
                }
            },
            .nohang => continue,
            .no_children => break,
        }
    }

    fork_exec.restoreTerminalToShell(ctx.shell_pgid.?);
    fork_exec.setInteractiveParentSignalIgnore();

    return term_code;
}

// ----- ENGINE (no signals, pid handling, job handling)
pub fn executeExternalEngine(
    ctx: *ShellCtx,
    arena_alloc: Allocator,
    args: [][]const u8,
    config: ?RedirConfig,
) ShellError!u8 {
    try preflightExternalRedirectWrites(ctx, arena_alloc, config);

    const child_pid = try fork_exec.forkProcess();

    if (child_pid == 0) {
        // ===== CHILD PROCESS =====
        // No setpgid, no signal reset — inherit defaults from engine process
        const cmd_path = resolveExternalCommandInteractive(ctx, arena_alloc, args[0]) catch |err| switch (err) {
            ShellError.CommandNotFound => {
                ctx.print("{s}: command not found\n", .{args[0]});
                linux.exit(127);
            },
            else => linux.exit(1),
        };

        if (!fork_exec.setupSingleExternalRedirectsInChild(ctx, arena_alloc, config)) {
            linux.exit(1);
        }
        fork_exec.execExternalResolvedOrExit(ctx, arena_alloc, cmd_path, args);
    }

    // ===== PARENT PROCESS =====
    while (true) {
        const waited = try fork_exec.waitPidChecked(child_pid, 0);
        switch (waited) {
            .event => |status| {
                if (linux.W.IFEXITED(status)) {
                    return @intCast(linux.W.EXITSTATUS(status));
                } else if (linux.W.IFSIGNALED(status)) {
                    return fork_exec.statusToExitCode(status);
                }
            },
            .no_children => return ShellError.ExecFailed,
            .nohang => continue,
        }
    }
}

fn preflightExternalRedirectWrites(
    ctx: *ShellCtx,
    arena_alloc: Allocator,
    config: ?RedirConfig,
) ShellError!void {
    const cfg = config orelse return;
    if (cfg.stdout_path) |path| {
        _ = helpers.expandPathToAbs(ctx, arena_alloc, path) catch return ShellError.InvalidPath;
    }
    if (cfg.stderr_path) |path| {
        _ = helpers.expandPathToAbs(ctx, arena_alloc, path) catch return ShellError.InvalidPath;
    }
}

/// Extract Value results from subshell execution output
fn parseCapturedSubshellValue(allocator: Allocator, captured: []const u8) !Value {
    const trimmed = std.mem.trim(u8, captured, " \n\r\t");
    if (trimmed.len == 0) return .{ .text = try allocator.dupe(u8, "") };

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch {
        return .{ .text = try allocator.dupe(u8, trimmed) };
    };
    defer parsed.deinit();
    return try types.jsonToValue(allocator, parsed.value);
}

/// Run a subshell process and capture stdout
pub fn captureSubshellForExpansion(ctx: *ShellCtx, allocator: Allocator, command_text: []const u8) !Value {
    // Subshell expansion runs a nested one-shot shell process (`zest -c ...`),
    // captures stdout, then parses JSON into a typed Value when possible.
    // This keeps execution concerns in execute.zig, while helpers only orchestrate expansion.
    var pipe_fds: [2]linux.fd_t = undefined;
    if (linux.pipe2(&pipe_fds, .{ .CLOEXEC = true }) != 0) {
        return error.BrokenPipe;
    }

    const pid = fork_exec.forkProcess() catch {
        _ = linux.close(pipe_fds[0]);
        _ = linux.close(pipe_fds[1]);
        return error.ExecFailed;
    };

    if (pid == 0) {
        _ = linux.close(pipe_fds[0]);
        if (linux.dup2(pipe_fds[1], linux.STDOUT_FILENO) < 0) linux.exit(1);
        _ = linux.close(pipe_fds[1]);

        var self_exe_buf: [std.fs.max_path_bytes]u8 = undefined;
        const self_exe_len = std.process.executablePath(ctx.io.*, &self_exe_buf) catch linux.exit(1);
        const self_exe = self_exe_buf[0..self_exe_len];
        const self_exe_z = allocator.dupeZ(u8, self_exe) catch linux.exit(1);
        const arg0 = allocator.dupeZ(u8, self_exe) catch linux.exit(1);
        const cmd_z = allocator.dupeZ(u8, command_text) catch linux.exit(1);

        const argv = allocator.allocSentinel(?[*:0]const u8, 3, null) catch linux.exit(1);
        argv[0] = arg0;
        argv[1] = "-c";
        argv[2] = cmd_z;

        const envp = ctx.env_map.createNullDelimitedEnvMap(allocator) catch linux.exit(1);
        _ = linux.execve(self_exe_z.ptr, @ptrCast(argv.ptr), @ptrCast(envp.ptr));
        linux.exit(127);
    }

    _ = linux.close(pipe_fds[1]);

    var captured = try std.ArrayList(u8).initCapacity(allocator, 256);
    defer captured.deinit(allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = std.posix.read(pipe_fds[0], buf[0..]) catch |err| {
            _ = linux.close(pipe_fds[0]);
            return err;
        };
        if (n == 0) break;
        try captured.appendSlice(allocator, buf[0..n]);
    }
    _ = linux.close(pipe_fds[0]);

    while (true) {
        const waited = fork_exec.waitPidChecked(pid, 0) catch break;
        switch (waited) {
            .event => break,
            .nohang => continue,
            .no_children => break,
        }
    }

    return parseCapturedSubshellValue(allocator, captured.items);
}

test "parseCapturedSubshellValue parses JSON object into map value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const value = try parseCapturedSubshellValue(allocator, "{\"name\":\"zest\",\"ok\":true}");
    defer value.deinit(allocator);

    try std.testing.expect(value == .map);
    const map = value.map;
    try std.testing.expect(map.contains("name"));
    try std.testing.expect(map.contains("ok"));
}

test "parseCapturedSubshellValue falls back to text for non-json output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const value = try parseCapturedSubshellValue(allocator, "plain output\n");
    defer value.deinit(allocator);

    try std.testing.expect(value == .text);
    try std.testing.expectEqualStrings("plain output", value.text);
}

test "shouldRenderInteractiveExternalExit only flags error-like statuses" {
    try std.testing.expect(!shouldRenderInteractiveExternalExit(0));
    try std.testing.expect(!shouldRenderInteractiveExternalExit(1));
    try std.testing.expect(shouldRenderInteractiveExternalExit(2));
    try std.testing.expect(shouldRenderInteractiveExternalExit(127));
    try std.testing.expect(!shouldRenderInteractiveExternalExit(130));
}
