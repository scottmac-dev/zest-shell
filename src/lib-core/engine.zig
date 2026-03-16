// ============================================================================
// ENGINE BRANCH  core-core/engine.zig
// Responsibilities: take a command, execute it, return a result.
// No history, no job control, no terminal signals, no REPL.
// ============================================================================
const std = @import("std");
const linux = std.os.linux;
const helpers = @import("core/helpers.zig");
const parse = @import("core/parse.zig");
const pipeline = @import("core/pipeline.zig");
const scripting = @import("core/scripting.zig");
const env = @import("core/env.zig");
const errors = @import("core/errors.zig");
const json = @import("../lib-serialize/json.zig");
const types = @import("core/types.zig");
const ShellCtx = @import("core/context.zig").ShellCtx;
const ShellError = errors.ShellError;

pub const EngineConfig = struct {
    input: Input,
    output_format: OutputFormat = .text,
    profile: bool = false,
    plan_json: bool = false,
    env_file: ?[]const u8 = null,

    pub const OutputFormat = enum { text, json };
    pub const Input = union(enum) {
        command: []const u8,
        json_file: []const u8,
        script_file: []const u8,
    };
};

pub const ExecutionStage = struct {
    pipeline_index: usize,
    stage_index: usize,
    cmd: []const u8,
    args: []const []const u8,
};

pub const ExecutionError = struct {
    code: []const u8,
    category: []const u8,
    message: []const u8,
    hint: ?[]const u8 = null,
    action: ?[]const u8 = null,
    detail: ?[]const u8 = null,
};

pub const ExecutionResult = struct {
    status: []const u8,
    input_kind: []const u8,
    shell_version: []const u8,
    exit_code: u8,
    duration_ms: i64,
    stages: []const ExecutionStage,
    stdin: ?[]const u8,
    stdout: ?[]const u8,
    stderr: ?[]const u8,
    profile: ?ExecutionProfile = null,
    error_info: ?ExecutionError = null,
};

pub const ExecutionProfile = struct {
    prepare_ms: i64 = 0,
    execute_ms: i64 = 0,
    capture_ms: i64 = 0,
    total_ms: i64 = 0,
};

const PreparedPlan = struct {
    input_kind: []const u8,
    input_label: []const u8,
    sequence: ?pipeline.CommandSequence = null,
    script_path: ?[]const u8 = null,
    script_content: ?[]const u8 = null,
    measure_time: bool = false,
    retry_cfg: ?parse.RetryMetaConfig = null,
    plan_env: []const json.JsonEnvVar = &.{},
    stages: []ExecutionStage = &.{},
    redirects: RedirectSummary = .{},
};

const RedirectSummary = struct {
    stdin_path: ?[]const u8 = null,
    stdout_path: ?[]const u8 = null,
    stderr_path: ?[]const u8 = null,
    merge_stderr_to_stdout: bool = false,
};

const StreamCapture = struct {
    target_fd: linux.fd_t,
    saved_fd: linux.fd_t,
    path: []const u8,
};

pub fn run(cfg: EngineConfig, init: std.process.Init.Minimal) !u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env_map = try env.EnvMap.init(allocator);
    defer env_map.deinit();
    try env_map.seedFromEnviron(init.environ, allocator);

    var threaded: std.Io.Threaded = .init(allocator, .{
        .argv0 = .init(init.args),
        .environ = init.environ,
    });
    defer threaded.deinit();
    var io = threaded.io();

    var ctx = try ShellCtx.initEngine(&io, allocator, env_map);
    defer ctx.deinit();

    if (cfg.env_file) |path| {
        env_map.importEnv(&ctx, path) catch |err| {
            errors.report(err, "import engine environment", path);
        };
    }

    if (cfg.plan_json) return runPlanJson(cfg, allocator, &ctx);

    return switch (cfg.output_format) {
        .text => runText(cfg, allocator, &ctx),
        .json => runJson(cfg, allocator, &ctx),
    };
}

fn runText(cfg: EngineConfig, allocator: std.mem.Allocator, ctx: *ShellCtx) u8 {
    ctx.capture_engine_values = false;
    ctx.captured_output = null;
    var exec_error: ?anyerror = null;
    var exec_error_action: []const u8 = "execute engine input";
    var input_label: []const u8 = commandLineLabel(cfg.input);
    var exec_error_detail: ?[]const u8 = input_label;

    if (preparePlan(cfg, allocator, ctx)) |plan| {
        input_label = plan.input_label;
        exec_error_detail = input_label;
        executePreparedPlan(ctx, allocator, plan) catch |err| {
            exec_error = err;
            exec_error_action = "execute engine input";
            exec_error_detail = input_label;
        };
    } else |err| {
        exec_error = err;
        exec_error_action = "prepare execution plan";
        exec_error_detail = input_label;
    }

    if (ctx.captured_output) |value| {
        switch (value) {
            .boolean, .void => {},
            else => {
                const text = value.toPrettyString(allocator) catch "";
                if (text.len > 0) {
                    ctx.print("{s}", .{text});
                }
            },
        }
    }

    if (exec_error) |err| {
        errors.report(err, exec_error_action, exec_error_detail);
        return 1;
    }

    return ctx.last_exit_code;
}

fn runJson(cfg: EngineConfig, allocator: std.mem.Allocator, ctx: *ShellCtx) u8 {
    ctx.capture_engine_values = true;
    defer ctx.capture_engine_values = false;
    ctx.captured_output = null;
    var exec_error: ?anyerror = null;
    var exec_error_action: []const u8 = "execute engine input";
    var exec_error_detail: ?[]const u8 = null;
    var command_line = commandLineLabel(cfg.input);
    var result = ExecutionResult{
        .status = "ok",
        .input_kind = inferInputKind(cfg.input),
        .shell_version = ctx.shell_version,
        .exit_code = 0,
        .duration_ms = 0,
        .stages = &.{},
        .error_info = null,
        .stdin = null,
        .stdout = null,
        .stderr = null,
    };

    var stdout_capture: ?StreamCapture = null;
    var stderr_capture: ?StreamCapture = null;

    var profile = ExecutionProfile{};
    const start_time = std.Io.Clock.now(.awake, ctx.io.*);
    const prepare_start = std.Io.Clock.now(.awake, ctx.io.*);
    {
        if (preparePlan(cfg, allocator, ctx)) |plan| {
            result.input_kind = plan.input_kind;
            command_line = plan.input_label;
            exec_error_detail = command_line;
            result.stages = plan.stages;
            result.stdin = plan.redirects.stdin_path;
            result.stdout = plan.redirects.stdout_path;
            result.stderr = if (plan.redirects.stderr_path) |p|
                p
            else if (plan.redirects.merge_stderr_to_stdout and plan.redirects.stdout_path != null)
                plan.redirects.stdout_path
            else
                null;

            stdout_capture = beginStreamCapture(ctx, allocator, linux.STDOUT_FILENO, "stdout") catch |err| blk: {
                exec_error = err;
                exec_error_action = "begin stdout capture";
                break :blk null;
            };
            stderr_capture = beginStreamCapture(ctx, allocator, linux.STDERR_FILENO, "stderr") catch |err| blk: {
                exec_error = err;
                exec_error_action = "begin stderr capture";
                break :blk null;
            };

            const execute_start = std.Io.Clock.now(.awake, ctx.io.*);
            if (exec_error == null) {
                executePreparedPlan(ctx, allocator, plan) catch |err| {
                    exec_error = err;
                    exec_error_action = "execute engine input";
                };
            }
            profile.execute_ms = execute_start.durationTo(std.Io.Clock.now(.awake, ctx.io.*)).toMilliseconds();
        } else |err| {
            exec_error = err;
            exec_error_action = "prepare execution plan";
            exec_error_detail = command_line;
        }
    }
    profile.prepare_ms = prepare_start.durationTo(std.Io.Clock.now(.awake, ctx.io.*)).toMilliseconds();

    const capture_start = std.Io.Clock.now(.awake, ctx.io.*);
    var captured_stdout: ?[]const u8 = null;
    var captured_stderr: ?[]const u8 = null;
    if (stdout_capture) |cap| {
        captured_stdout = finishStreamCapture(ctx, allocator, cap) catch |err| blk: {
            if (exec_error == null) {
                exec_error = err;
                exec_error_action = "finish stdout capture";
                exec_error_detail = cap.path;
            }
            break :blk "";
        };
    }
    if (stderr_capture) |cap| {
        captured_stderr = finishStreamCapture(ctx, allocator, cap) catch |err| blk: {
            if (exec_error == null) {
                exec_error = err;
                exec_error_action = "finish stderr capture";
                exec_error_detail = cap.path;
            }
            break :blk "";
        };
    }
    if (result.stdout == null) result.stdout = captured_stdout orelse "";
    if (result.stderr == null) result.stderr = captured_stderr orelse "";
    profile.capture_ms = capture_start.durationTo(std.Io.Clock.now(.awake, ctx.io.*)).toMilliseconds();

    const end_time = std.Io.Clock.now(.awake, ctx.io.*);
    const duration = start_time.durationTo(end_time);
    const elapsed_ms = duration.toMilliseconds();
    profile.total_ms = elapsed_ms;

    // In engine mode some builtins return captured values instead of writing streams.
    // Use captured_output as a fallback only when stream capture is empty.
    if (ctx.captured_output) |value| {
        const stdout_redirected = result.stdout != null;
        const stderr_redirected = result.stderr != null;
        switch (value) {
            .boolean, .void => {},
            .err => |e| {
                if (!stderr_redirected or (result.stderr != null and result.stderr.?.len == 0)) {
                    result.stderr = @errorName(e);
                }
            },
            else => {
                if (!stdout_redirected or (result.stdout != null and result.stdout.?.len == 0)) {
                    const text = value.toString(allocator) catch "";
                    result.stdout = text;
                }
            },
        }
    }

    result.duration_ms = elapsed_ms;
    if (cfg.profile) result.profile = profile;
    result.exit_code = if (exec_error == null) ctx.last_exit_code else 1;

    if (exec_error) |err| {
        const diag = errors.toStructured(err, allocator) catch errors.StructuredError{
            .error_code = err,
            .code = "UnknownError",
            .category = "internal",
            .message = "Unknown execution error",
            .hint = null,
        };
        result.status = "error";
        result.error_info = .{
            .code = diag.code,
            .category = diag.category,
            .message = diag.message,
            .hint = diag.hint,
            .action = exec_error_action,
            .detail = exec_error_detail,
        };
    }

    const out = std.json.Stringify.valueAlloc(allocator, result, .{ .whitespace = .indent_2 }) catch {
        errors.report(ShellError.AllocFailed, "serialize execution result", null);
        return 1;
    };
    ctx.print("{s}\n", .{out});
    return result.exit_code;
}

fn runPlanJson(cfg: EngineConfig, allocator: std.mem.Allocator, ctx: *ShellCtx) u8 {
    const plan = preparePlan(cfg, allocator, ctx) catch |err| {
        errors.report(err, "prepare execution plan", commandLineLabel(cfg.input));
        return 1;
    };

    const seq = plan.sequence orelse {
        errors.report(ShellError.Unsupported, "generate plan-json output", "only command and .json inputs are supported");
        return 1;
    };
    if (plan.retry_cfg != null) {
        errors.report(ShellError.Unsupported, "generate plan-json output", "retry meta cannot be represented in pipeline plan JSON");
        return 1;
    }
    const plan_json = json.serializeCommandSequencePlan(
        allocator,
        seq,
        plan.measure_time,
        plan.plan_env,
    ) catch |err| {
        errors.report(err, "serialize command sequence plan", commandLineLabel(cfg.input));
        return 1;
    };
    ctx.print("{s}\n", .{plan_json});
    return 0;
}

fn executePreparedPlan(ctx: *ShellCtx, allocator: std.mem.Allocator, plan: PreparedPlan) anyerror!void {
    if (plan.sequence) |seq| {
        return parse.executeCommandSequenceWithMeta(
            ctx,
            allocator,
            seq,
            plan.input_label,
            plan.measure_time,
            plan.retry_cfg,
            false,
        );
    }

    if (plan.script_content) |content| {
        const script_name = plan.script_path orelse plan.input_label;
        const exit_code = try scripting.executeScriptWithExitCode(ctx, allocator, content, script_name);
        ctx.last_exit_code = exit_code;
        return;
    }

    return ShellError.Unsupported;
}

fn inferInputKind(input: EngineConfig.Input) []const u8 {
    return switch (input) {
        .command => "command",
        .json_file => "json",
        .script_file => "script",
    };
}

fn commandLineLabel(input: EngineConfig.Input) []const u8 {
    return switch (input) {
        .command => |cmd| cmd,
        .json_file => |path| path,
        .script_file => |path| path,
    };
}

fn applyPlanEnv(ctx: *ShellCtx, env_entries: []const json.JsonEnvVar) void {
    for (env_entries) |entry| {
        const val = types.Value{ .text = entry.value };
        if (entry.exported) {
            _ = ctx.env_map.putExported(entry.name, val) catch {};
        } else {
            _ = ctx.env_map.putShell(entry.name, val) catch {};
        }
    }
}

fn preparePlan(cfg: EngineConfig, allocator: std.mem.Allocator, ctx: *ShellCtx) ShellError!PreparedPlan {
    switch (cfg.input) {
        .command => |cmd| {
            const parsed = try parse.parseCommandInput(ctx, allocator, cmd);
            return .{
                .input_kind = "command",
                .input_label = parsed.command_input,
                .sequence = parsed.sequence,
                .measure_time = parsed.measure_time,
                .retry_cfg = parsed.retry,
                .plan_env = &.{},
                .stages = try buildStageMetadata(allocator, parsed.sequence),
                .redirects = summarizeRedirects(parsed.sequence),
            };
        },
        .json_file => |path| {
            const raw = try readEngineInputFile(ctx, allocator, path, false);
            const plan = try json.parseCommandSequenceJson(allocator, raw);
            if (!cfg.plan_json) applyPlanEnv(ctx, plan.env);

            return .{
                .input_kind = "json",
                .input_label = path,
                .sequence = plan.sequence,
                .measure_time = plan.measure_time,
                .retry_cfg = null,
                .plan_env = plan.env,
                .stages = try buildStageMetadata(allocator, plan.sequence),
                .redirects = summarizeRedirects(plan.sequence),
            };
        },
        .script_file => {
            return try prepareScriptPlan(cfg, allocator, ctx);
        },
    }
}

fn prepareScriptPlan(cfg: EngineConfig, allocator: std.mem.Allocator, ctx: *ShellCtx) ShellError!PreparedPlan {
    const path = switch (cfg.input) {
        .script_file => |p| p,
        else => return ShellError.InvalidArgument,
    };

    const raw = try readEngineInputFile(ctx, allocator, path, false);
    return .{
        .input_kind = "script",
        .input_label = path,
        .sequence = null,
        .script_path = path,
        .script_content = raw,
        .measure_time = false,
        .retry_cfg = null,
        .plan_env = &.{},
        .stages = &.{},
        .redirects = .{},
    };
}

fn summarizeRedirects(sequence: pipeline.CommandSequence) RedirectSummary {
    var summary = RedirectSummary{};
    for (sequence.pipelines) |pipe| {
        if (pipe.redir_config) |cfg| {
            if (cfg.stdin_path) |path| summary.stdin_path = path;
            if (cfg.stdout_path) |path| summary.stdout_path = path;
            if (cfg.stderr_path) |path| summary.stderr_path = path;
            if (cfg.merge_stderr_to_stdout) summary.merge_stderr_to_stdout = true;
        }
    }
    return summary;
}

fn readEngineInputFile(
    ctx: *ShellCtx,
    allocator: std.mem.Allocator,
    path: []const u8,
    pre_expanded: bool,
) ShellError![]u8 {
    return helpers.readFileFromPath(ctx, allocator, path, pre_expanded) catch |err| errors.mapPolicyReadError(err);
}

fn beginStreamCapture(
    ctx: *ShellCtx,
    allocator: std.mem.Allocator,
    target_fd: linux.fd_t,
    name: []const u8,
) ShellError!StreamCapture {
    const pid = linux.getpid();
    const stamp = std.Io.Clock.now(.real, ctx.io.*).nanoseconds;
    const path = std.fmt.allocPrint(allocator, "/tmp/zest-{s}-{d}-{d}-{x}.tmp", .{
        name,
        pid,
        stamp,
        @intFromPtr(ctx),
    }) catch return ShellError.AllocFailed;
    errdefer allocator.free(path);

    var file = helpers.getFileFromPath(ctx, allocator, path, .{
        .write = true,
        .truncate = true,
        .pre_expanded = true,
    }) catch |err| return errors.mapPathOpenError(err);
    defer file.close(ctx.io.*);

    const saved = linux.dup(target_fd);
    if (saved > std.math.maxInt(i32)) return ShellError.ExecFailed;
    if (linux.dup2(file.handle, target_fd) < 0) {
        _ = linux.close(@intCast(saved));
        return ShellError.ExecFailed;
    }

    return .{
        .target_fd = target_fd,
        .saved_fd = @intCast(saved),
        .path = path,
    };
}

fn finishStreamCapture(
    ctx: *ShellCtx,
    allocator: std.mem.Allocator,
    capture: StreamCapture,
) ShellError![]const u8 {
    errdefer allocator.free(capture.path);
    if (linux.dup2(capture.saved_fd, capture.target_fd) < 0) return ShellError.ExecFailed;
    _ = linux.close(capture.saved_fd);

    const text = try readEngineInputFile(ctx, allocator, capture.path, true);

    const path_z = allocator.dupeZ(u8, capture.path) catch return ShellError.AllocFailed;
    defer allocator.free(path_z);
    _ = linux.unlink(path_z.ptr);
    allocator.free(capture.path);

    return text;
}

fn buildStageMetadata(
    allocator: std.mem.Allocator,
    sequence: pipeline.CommandSequence,
) ShellError![]ExecutionStage {
    var total_stages: usize = 0;
    for (sequence.pipelines) |pipe| {
        total_stages += pipe.stages.len;
    }

    var stages = try std.ArrayList(ExecutionStage).initCapacity(allocator, total_stages);
    for (sequence.pipelines, 0..) |pipe, p_idx| {
        for (pipe.stages, 0..) |stage, s_idx| {
            const cmd_name = if (stage.args.len > 0) stage.args[0].text else "";
            var arg_list = try std.ArrayList([]const u8).initCapacity(allocator, if (stage.args.len > 1) stage.args.len - 1 else 0);
            if (stage.args.len > 1) {
                for (stage.args[1..]) |arg| {
                    try arg_list.append(allocator, arg.text);
                }
            }
            try stages.append(allocator, .{
                .pipeline_index = p_idx,
                .stage_index = s_idx,
                .cmd = cmd_name,
                .args = arg_list.items,
            });
        }
    }
    return stages.items;
}
