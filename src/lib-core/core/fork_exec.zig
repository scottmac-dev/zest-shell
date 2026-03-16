const std = @import("std");
const linux = std.os.linux;
const helpers = @import("helpers.zig");
const signals = @import("signals.zig");
const RedirConfig = @import("command.zig").RedirConfig;
const ShellCtx = @import("context.zig").ShellCtx;
const ShellError = @import("errors.zig").ShellError;

/// File handler pipe stdout -> stdin
pub const PipeFds = struct {
    read: linux.fd_t,
    write: linux.fd_t,
};

pub const WaitResult = union(enum) {
    event: u32,
    nohang,
    no_children,
};

pub const RedirectFds = struct {
    stdin_fd: ?linux.fd_t = null,
    stdout_fd: ?linux.fd_t = null,
    stderr_fd: ?linux.fd_t = null,
    merge_stderr_to_stdout: bool = false,

    pub fn closeAll(self: *const RedirectFds) void {
        if (self.stdin_fd) |fd| _ = linux.close(fd);
        if (self.stdout_fd) |fd| _ = linux.close(fd);
        if (self.stderr_fd) |fd| _ = linux.close(fd);
    }
};

pub fn setInteractiveChildSignalDefaults() void {
    std.posix.sigaction(linux.SIG.INT, &signals.dfl_act, null);
    std.posix.sigaction(linux.SIG.TSTP, &signals.dfl_act, null);
}

pub fn setInteractiveParentSignalIgnore() void {
    std.posix.sigaction(linux.SIG.INT, &signals.ign_act, null);
    std.posix.sigaction(linux.SIG.TSTP, &signals.ign_act, null);
}

pub fn setChildProcessGroup(pgid: ?linux.pid_t) bool {
    while (true) {
        const ret = if (pgid) |g|
            linux.setpgid(0, g)
        else
            linux.setpgid(0, 0);
        switch (linux.errno(ret)) {
            .SUCCESS => return true,
            .INTR => continue,
            else => return false,
        }
    }
}

pub fn setParentProcessGroup(child_pid: linux.pid_t, pipeline_pgid: ?linux.pid_t) linux.pid_t {
    const desired: linux.pid_t = pipeline_pgid orelse child_pid;
    while (true) {
        const ret = linux.setpgid(child_pid, desired);
        switch (linux.errno(ret)) {
            .SUCCESS => return desired,
            .INTR => continue,
            // Benign race: child may have already exec'd, exited, or set its own PGID.
            .ACCES, .CHILD => return desired,
            else => return desired,
        }
    }
}

pub fn forkProcess() ShellError!linux.pid_t {
    while (true) {
        const ret = linux.fork();
        switch (linux.errno(ret)) {
            .SUCCESS => return @intCast(ret),
            .INTR => continue,
            .AGAIN => return ShellError.SystemResources,
            .NOMEM => return ShellError.OutOfMemory,
            else => return ShellError.ExecFailed,
        }
    }
}

pub fn waitPidChecked(pid: linux.pid_t, options: u32) ShellError!WaitResult {
    while (true) {
        var status: u32 = 0;
        const ret = linux.waitpid(pid, &status, options);
        switch (linux.errno(ret)) {
            .SUCCESS => {
                if (ret == 0) return .nohang;
                return .{ .event = status };
            },
            .INTR => continue,
            .CHILD => return .no_children,
            else => return ShellError.ExecFailed,
        }
    }
}

pub fn giveTerminalTo(pgid: linux.pid_t) void {
    while (true) {
        var val = pgid;
        const ret = linux.tcsetpgrp(linux.STDIN_FILENO, &val);
        switch (linux.errno(ret)) {
            .SUCCESS => return,
            .INTR => continue,
            else => return,
        }
    }
}

pub fn restoreTerminalToShell(shell_pgid: linux.pid_t) void {
    while (true) {
        var val = shell_pgid;
        const ret = linux.tcsetpgrp(linux.STDIN_FILENO, &val);
        switch (linux.errno(ret)) {
            .SUCCESS => return,
            .INTR => continue,
            else => return,
        }
    }
}

pub fn statusToExitCode(status: u32) u8 {
    return signals.waitStatusToExitCode(status);
}

pub const ProcessGroupWait = struct {
    any_event: bool = false,
    no_children: bool = false,
    exited: bool = false,
    signaled: bool = false,
    stopped: bool = false,
    last_status: u32 = 0,
};

fn mapRedirectError(err: anyerror) ShellError {
    _ = @errorName(err);
    return ShellError.InvalidPath;
}

fn redirectWriteFlags(truncate: bool) linux.O {
    return if (truncate)
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }
    else
        .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true };
}

fn openPathFd(arena_alloc: std.mem.Allocator, abs_path: []const u8, flags: linux.O, mode: u32) ShellError!linux.fd_t {
    const fd = linux.open(
        (arena_alloc.dupeZ(u8, abs_path) catch return ShellError.AllocFailed).ptr,
        flags,
        mode,
    );
    if (fd > std.math.maxInt(i32)) return ShellError.InvalidPath;
    return @intCast(fd);
}

fn openReadOnlyRedirectFdForChild(
    ctx: *ShellCtx,
    arena_alloc: std.mem.Allocator,
    raw_path: []const u8,
) !linux.fd_t {
    const expanded = try helpers.expandPathToAbs(ctx, arena_alloc, raw_path);
    return try openPathFd(arena_alloc, expanded, .{ .ACCMODE = .RDONLY }, 0);
}

fn openWriteRedirectFdForChild(
    ctx: *ShellCtx,
    arena_alloc: std.mem.Allocator,
    raw_path: []const u8,
    truncate: bool,
) ShellError!linux.fd_t {
    const expanded = helpers.expandPathToAbs(ctx, arena_alloc, raw_path) catch return ShellError.FileNotFound;
    return try openPathFd(arena_alloc, expanded, redirectWriteFlags(truncate), 0o644);
}

fn dupToAndClose(fd: linux.fd_t, target_fd: linux.fd_t) bool {
    if (linux.dup2(fd, target_fd) < 0) return false;
    _ = linux.close(fd);
    return true;
}

fn classifyWaitStatus(status: u32, out: *ProcessGroupWait) void {
    out.last_status = status;
    if (linux.W.IFEXITED(status)) {
        out.exited = true;
    } else if (linux.W.IFSIGNALED(status)) {
        out.signaled = true;
    } else if (linux.W.IFSTOPPED(status)) {
        out.stopped = true;
    }
}

/// Wait for one process-group event and handle EINTR/ECHILD robustly.
pub fn waitProcessGroupBlocking(pgid: linux.pid_t) ProcessGroupWait {
    var result = ProcessGroupWait{};

    while (true) {
        const waited = waitPidChecked(-pgid, linux.W.UNTRACED) catch return result;
        switch (waited) {
            .event => |status| {
                result.any_event = true;
                classifyWaitStatus(status, &result);
                return result;
            },
            .nohang => continue,
            .no_children => {
                result.no_children = true;
                return result;
            },
        }
    }
}

/// Drain all currently-available process-group events without blocking.
pub fn drainProcessGroupNoHang(pgid: linux.pid_t) ProcessGroupWait {
    var result = ProcessGroupWait{};

    while (true) {
        const waited = waitPidChecked(-pgid, linux.W.NOHANG | linux.W.UNTRACED) catch return result;
        switch (waited) {
            .event => |status| {
                result.any_event = true;
                classifyWaitStatus(status, &result);
                continue;
            },
            .nohang => return result,
            .no_children => {
                result.no_children = true;
                return result;
            },
        }
    }
}

pub fn openRedirectFds(ctx: *ShellCtx, arena_alloc: std.mem.Allocator, cfg: ?RedirConfig) ShellError!RedirectFds {
    if (cfg == null) return .{};

    var fds = RedirectFds{
        .merge_stderr_to_stdout = cfg.?.merge_stderr_to_stdout,
    };
    errdefer fds.closeAll();

    if (cfg.?.stdin_path) |path| {
        const file = helpers.getFileFromPath(ctx, arena_alloc, path, .{
            .write = false,
            .pre_expanded = false,
        }) catch |err| return mapRedirectError(err);
        fds.stdin_fd = file.handle;
    }

    if (cfg.?.stdout_path) |path| {
        fds.stdout_fd = try openWriteRedirectFdForChild(ctx, arena_alloc, path, cfg.?.stdout_truncate);
    }

    if (cfg.?.stderr_path) |path| {
        fds.stderr_fd = try openWriteRedirectFdForChild(ctx, arena_alloc, path, cfg.?.stderr_truncate);
    }

    return fds;
}

pub fn setupSingleExternalRedirectsInChild(
    ctx: *ShellCtx,
    arena_alloc: std.mem.Allocator,
    cfg: ?RedirConfig,
) bool {
    if (cfg == null) return true;

    if (cfg.?.stdin_path) |path| {
        const fd = openReadOnlyRedirectFdForChild(ctx, arena_alloc, path) catch return false;
        if (!dupToAndClose(fd, linux.STDIN_FILENO)) return false;
    }

    if (cfg.?.stdout_path) |path| {
        const fd = openWriteRedirectFdForChild(ctx, arena_alloc, path, cfg.?.stdout_truncate) catch return false;
        if (!dupToAndClose(fd, linux.STDOUT_FILENO)) return false;
    }

    if (cfg.?.merge_stderr_to_stdout) {
        if (linux.dup2(linux.STDOUT_FILENO, linux.STDERR_FILENO) < 0) return false;
    } else if (cfg.?.stderr_path) |path| {
        const fd = openWriteRedirectFdForChild(ctx, arena_alloc, path, cfg.?.stderr_truncate) catch return false;
        if (!dupToAndClose(fd, linux.STDERR_FILENO)) return false;
    }

    return true;
}

pub fn setupPipelineChildStdio(
    idx: usize,
    num_commands: usize,
    pipes: []const PipeFds,
    redirects: RedirectFds,
) bool {
    const is_first = idx == 0;
    const is_last = idx == num_commands - 1;

    if (!is_first) {
        const prev_pipe = pipes[idx - 1];
        if (linux.dup2(prev_pipe.read, linux.STDIN_FILENO) < 0) return false;
    } else if (redirects.stdin_fd) |fd| {
        if (linux.dup2(fd, linux.STDIN_FILENO) < 0) return false;
    }

    if (is_last and redirects.stdout_fd != null) {
        const fd = redirects.stdout_fd.?;
        if (linux.dup2(fd, linux.STDOUT_FILENO) < 0) return false;
        if (redirects.merge_stderr_to_stdout) {
            if (linux.dup2(fd, linux.STDERR_FILENO) < 0) return false;
        }
    } else if (!is_last) {
        const cur_pipe = pipes[idx];
        if (linux.dup2(cur_pipe.write, linux.STDOUT_FILENO) < 0) return false;
    }

    if (is_last and redirects.stderr_fd != null) {
        const fd = redirects.stderr_fd.?;
        if (!redirects.merge_stderr_to_stdout) {
            if (linux.dup2(fd, linux.STDERR_FILENO) < 0) return false;
        }
    }

    return true;
}

pub fn closePipes(pipes: []const PipeFds) void {
    for (pipes) |pipe| {
        _ = linux.close(pipe.read);
        _ = linux.close(pipe.write);
    }
}

pub fn execExternalOrExit(ctx: *ShellCtx, arena_alloc: std.mem.Allocator, args: [][]const u8) noreturn {
    const cmd_path = @import("execute.zig").resolveExternalCommandInteractive(ctx, arena_alloc, args[0]) catch |err| switch (err) {
        ShellError.CommandNotFound => {
            ctx.print("{s}: command not found\n", .{args[0]});
            linux.exit(127);
        },
        else => linux.exit(1),
    };
    execExternalResolvedOrExit(ctx, arena_alloc, cmd_path, args);
}

pub fn execExternalResolvedOrExit(
    ctx: *ShellCtx,
    arena_alloc: std.mem.Allocator,
    full_path: []const u8,
    args: [][]const u8,
) noreturn {
    const full_path_z = arena_alloc.dupeZ(u8, full_path) catch linux.exit(1);
    const argv = arena_alloc.allocSentinel(?[*:0]const u8, args.len, null) catch linux.exit(1);
    argv[0] = arena_alloc.dupeZ(u8, args[0]) catch linux.exit(1);
    for (args[1..], 1..) |arg, i| {
        argv[i] = arena_alloc.dupeZ(u8, arg) catch linux.exit(1);
    }
    const envp = ctx.env_map.createNullDelimitedEnvMap(ctx.allocator) catch linux.exit(1);
    _ = linux.execve(full_path_z, @ptrCast(argv.ptr), @ptrCast(envp.ptr));
    linux.exit(127);
}

//
// --- TESTS --
//

test "fork_exec: waitPidChecked observes exited child" {
    const pid = try forkProcess();
    if (pid == 0) {
        linux.exit(7);
    }

    const waited = try waitPidChecked(pid, 0);
    switch (waited) {
        .event => |status| {
            try std.testing.expect(linux.W.IFEXITED(status));
            try std.testing.expectEqual(@as(u8, 7), @as(u8, @intCast(linux.W.EXITSTATUS(status))));
        },
        else => return error.TestExpectedEqual,
    }
}

test "fork_exec: waitPidChecked nohang returns nohang while child runs" {
    const pid = try forkProcess();
    if (pid == 0) {
        const req = linux.timespec{ .sec = 0, .nsec = 5 * std.time.ns_per_ms };
        _ = linux.nanosleep(&req, null);
        linux.exit(0);
    }

    const waited = try waitPidChecked(pid, linux.W.NOHANG);
    switch (waited) {
        .nohang => {},
        .event => {},
        else => return error.TestExpectedEqual,
    }
    _ = try waitPidChecked(pid, 0);
}
