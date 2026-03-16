/// JOBS represent background threads not executed in interactive mode
const std = @import("std");
const signals = @import("../../lib-core/core/signals.zig");
const errors = @import("../../lib-core/core/errors.zig");
const Allocator = std.mem.Allocator;
const core_pipeline = @import("../../lib-core/core/pipeline.zig");
const CommandPipeline = core_pipeline.CommandPipeline;
const ShellCtx = @import("../../lib-core/core/context.zig").ShellCtx;
const fork_exec = @import("../../lib-core/core/fork_exec.zig");
const INIT_CAPACITY = 4;

pub const JobState = enum {
    running,
    finished,
    stopped,
    failed,
    killed,
};

pub const JobResult = union(enum) {
    success,
    exit_code: u8,
    err: anyerror,
};

pub const Job = struct {
    id: u32,
    handle: std.Thread,
    has_thread: bool,
    state: JobState,
    result: ?JobResult = null,
    pgid: ?std.posix.pid_t = null, // process group ID for kill support
    command_line_input: []const u8, // original cmd
    arena: *std.heap.ArenaAllocator,
    // Set to true when fg claims ownership of waitpid from the background thread
    claimed: std.atomic.Value(bool) = .init(false),
};

pub const JobTable = struct {
    const Self = @This();

    allocator: Allocator,
    jobs: std.ArrayList(*Job),
    next_id: u32 = 1,

    pub fn init(allocator: Allocator) !*Self {
        const table = try allocator.create(Self);
        table.* = .{
            .allocator = allocator,
            .jobs = try std.ArrayList(*Job).initCapacity(
                allocator,
                INIT_CAPACITY,
            ),
        };
        return table;
    }

    pub fn deinit(self: *Self) void {
        for (self.jobs.items) |job| {
            if (job.has_thread) {
                job.handle.join();
            }
            job.arena.deinit();
            self.allocator.destroy(job.arena);
            self.allocator.free(job.command_line_input);
            self.allocator.destroy(job);
        }
        self.jobs.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Clean finished jobs, free memory, and optionally notify about completions
    pub fn cleanFinished(self: *Self, ctx: *ShellCtx, notify: bool) void {
        var i: usize = 0;
        while (i < self.jobs.items.len) {
            const job = self.jobs.items[i];

            // Only clean up jobs that are truly finished, NOT stopped jobs
            const should_clean = switch (job.state) {
                .finished, .failed, .killed => true,
                .running, .stopped => false,
            };

            if (should_clean) {
                // Notify user about job completion before cleaning
                if (notify) {
                    const state_str = switch (job.state) {
                        .finished => "Done",
                        .failed => "Failed",
                        .killed => "Killed",
                        .stopped => unreachable, // Won't happen due to should_clean check
                        .running => unreachable,
                    };

                    const result_info = if (job.result) |res| switch (res) {
                        .success => blk: {
                            var buf: [32]u8 = undefined;
                            const str = std.fmt.bufPrint(&buf, " (success)", .{}) catch "";
                            break :blk str;
                        },
                        .exit_code => |code| blk: {
                            var buf: [32]u8 = undefined;
                            const str = std.fmt.bufPrint(&buf, " (exit {d})", .{code}) catch "";
                            break :blk str;
                        },
                        .err => |e| blk: {
                            var buf: [128]u8 = undefined;
                            const diag = errors.toStructured(e, self.allocator) catch null;
                            break :blk std.fmt.bufPrint(&buf, " (error: {s}: {s})", .{ diag.code, diag.message }) catch "";
                        },
                    } else "";

                    ctx.print("[{d}] {s}{s} {s}\n", .{
                        job.id,
                        state_str,
                        result_info,
                        job.command_line_input,
                    });
                }

                // Clean up the job
                if (job.has_thread) {
                    job.handle.join();
                }
                job.arena.deinit();
                self.allocator.destroy(job.arena);
                self.allocator.free(job.command_line_input);
                self.allocator.destroy(job);
                _ = self.jobs.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// Poll all background jobs with WNOHANG to check for state changes.
    /// Call this just before printing the prompt in the main REPL loop.
    pub fn pollBackgroundJobs(self: *Self) void {
        for (self.jobs.items) |job| {
            if (job.state != .running) continue;
            const pgid = job.pgid orelse continue;
            if (job.has_thread) continue;

            const drained = fork_exec.drainProcessGroupNoHang(pgid);
            if (!drained.any_event and !drained.no_children) continue;

            if (drained.stopped) {
                job.state = .stopped;
                continue;
            }

            if (drained.exited or drained.signaled) {
                applyTerminalStatus(job, drained.last_status);
            }

            if (drained.no_children and job.state == .running) {
                // The entire group has been reaped, but we may not have observed a
                // terminal status in this poll cycle (e.g. another waiter raced).
                job.state = .finished;
            }
        }
    }

    /// Kills job by job id, used for kill <id> or Ctrl C
    pub fn killJob(self: *Self, job_id: u32) !void {
        for (self.jobs.items) |job| {
            if (job.id == job_id) {
                if (job.pgid) |pgid| {
                    const rc = std.os.linux.kill(-pgid, .TERM);
                    if (rc != 0) return error.KillFailed;
                    job.state = .killed;
                    job.result = .{ .exit_code = 143 };
                }
                return;
            }
        }
        return error.JobNotFound;
    }

    /// Stops job by id, used for Ctrl Z
    pub fn stopJob(self: *Self, ctx: *ShellCtx, job_id: u32) !void {
        const job = self.findJob(job_id) orelse return error.JobNotFound;
        if (job.state != .running) return error.JobNotRunning;
        const pgid = job.pgid orelse return error.NoPGID;

        const rc = std.os.linux.kill(-pgid, .STOP);
        if (rc != 0) return error.KillFailed;

        // Poll until pollBackgroundJobs observes WIFSTOPPED and updates state
        var waited: u32 = 0;
        while (job.state == .running and waited < 500) {
            std.Io.sleep(ctx.io.*, .{ .nanoseconds = 10 * std.time.ns_per_ms }, .real) catch {};
            waited += 10;
        }
        if (job.state != .stopped) return error.JobStopFailed;
    }

    /// Find a job by ID
    pub fn findJob(self: *Self, job_id: u32) ?*Job {
        for (self.jobs.items) |job| {
            if (job.id == job_id) return job;
        }
        return null;
    }

    /// Wait for a specific job to complete
    pub fn waitForJob(self: *Self, job_id: u32) !void {
        for (self.jobs.items) |job| {
            if (job.id == job_id) {
                if (job.has_thread) {
                    job.handle.join();
                    job.has_thread = false;
                }
                return;
            }
        }
        return error.JobNotFound;
    }

    /// Spawn a pipeline as a background job
    pub fn spawnBackgroundPipeline(
        self: *Self,
        ctx: *ShellCtx,
        cmd_pipeline: CommandPipeline,
        command_line_input: []const u8,
    ) !u32 {
        const job_id = self.next_id;
        self.next_id += 1;

        const arena = try self.allocator.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(self.allocator);

        const job = try self.allocator.create(Job);
        job.* = .{
            .id = job_id,
            .handle = undefined,
            .has_thread = false,
            .state = .running,
            .command_line_input = try self.allocator.dupe(u8, command_line_input),
            .arena = arena,
        };

        var bg_pgid: std.os.linux.pid_t = 0;
        const bg_exit = core_pipeline.executePipeline(ctx, arena.allocator(), cmd_pipeline, &bg_pgid);
        if (bg_pgid != 0) {
            job.pgid = bg_pgid;
            job.state = .running;
        } else {
            // Failed before creating a background process group.
            job.state = .failed;
            job.result = .{ .exit_code = bg_exit };
        }

        try self.jobs.append(self.allocator, job);
        return job_id;
    }

    /// Transfer waitpid ownership from a background thread to the foreground.
    /// Sends SIGSTOP to flush the thread out of its waitpid, marks the job as
    /// claimed, joins the thread, then marks has_thread = false so foregroundJob
    /// can safely own the wait loop.
    pub fn reclaimThreadedJob(self: *Self, job_id: u32) !void {
        const job = self.findJob(job_id) orelse return error.JobNotFound;

        if (!job.has_thread) return; // Already a non-threaded job, nothing to do
        if (job.state != .running) return; // Only need to reclaim running threaded jobs

        const pgid = job.pgid orelse return error.NoPGID;

        // Mark as claimed BEFORE sending SIGSTOP so the thread sees it
        // when waitpid returns with WIFSTOPPED
        job.claimed.store(true, .release);

        // Send SIGSTOP to force the thread's waitpid to return
        std.posix.kill(-pgid, std.posix.SIG.STOP) catch |err| switch (err) {
            error.ProcessNotFound => {
                // Job already exited between claim and signal; just join and continue.
            },
            else => {
                job.claimed.store(false, .release); // Roll back on failure
                return error.KillFailed;
            },
        };

        // Join the thread - it will exit cleanly once it sees claimed == true
        // and its waitpid returns with WIFSTOPPED
        job.handle.join();
        job.has_thread = false;

        // Only force stopped if thread did not report a terminal state.
        if (job.state == .running) {
            job.state = .stopped;
        }
    }

    /// Save a stopped foreground pipeline to the job table
    pub fn saveStoppedPipeline(
        self: *Self,
        ctx: *ShellCtx,
        pipeline: CommandPipeline,
        pgid: std.posix.pid_t,
    ) !void {
        const job_id = self.next_id;
        self.*.next_id += 1;

        // Create arena for this job
        const arena = try self.allocator.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(self.allocator);

        // Reconstruct command line from pipeline
        const command_line = try reconstructCommandLine(self.allocator, pipeline);

        const job = try self.allocator.create(Job);
        job.* = .{
            .id = job_id,
            .handle = undefined, // Not applicable for stopped foreground jobs
            .has_thread = false,
            .state = .stopped,
            .command_line_input = command_line,
            .arena = arena,
            .pgid = pgid,
            .result = null,
        };

        try self.jobs.append(self.allocator, job);
        ctx.print("[{d}] Stopped\n", .{job_id});
    }

    /// Save a stopped single command to the job table
    pub fn saveStoppedCommand(
        self: *Self,
        ctx: *ShellCtx,
        args: [][]const u8,
        pgid: std.posix.pid_t,
    ) !void {
        const job_id = self.next_id;
        self.*.next_id += 1;

        // Create arena for this job
        const arena = try self.allocator.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(self.allocator);

        // Reconstruct command line from args
        const command_line = try reconstructCommandLineFromArgs(self.allocator, args);

        const job = try self.allocator.create(Job);
        job.* = .{
            .id = job_id,
            .handle = undefined,
            .has_thread = false, // Not a threaded background job
            .state = .stopped,
            .command_line_input = command_line,
            .arena = arena,
            .pgid = pgid,
            .result = null,
        };

        try self.jobs.append(self.allocator, job);
        ctx.print("[{d}] Stopped\n", .{job_id});
    }

    /// Resume a background job in the tty foreground
    pub fn foregroundJob(self: *Self, ctx: *ShellCtx, job_id: u32) !void {
        const job = self.findJob(job_id) orelse return error.JobNotFound;

        if (job.state != .stopped and job.state != .running) {
            return error.JobNotStopped;
        }

        // If this is a running threaded job (&-launched), we must transfer
        // waitpid ownership from the background thread before we can wait on it
        if (job.has_thread and job.state == .running) {
            try self.reclaimThreadedJob(job_id);
            // job.state is now .stopped, fall through to normal fg resume path
        }

        const pgid = job.pgid orelse return error.NoPGID;
        const tty_fd = std.posix.STDIN_FILENO;

        ctx.print("[{d}] Continuing: {s}\n", .{ job_id, job.command_line_input });

        // Give terminal control to the job's process group BEFORE sending SIGCONT
        // If we send SIGCONT first and the process tries to read stdin, it gets SIGTTIN
        std.posix.tcsetpgrp(tty_fd, pgid) catch {};

        // Shell ignores INT and TSTP while waiting for foreground job
        std.posix.sigaction(std.os.linux.SIG.INT, &signals.ign_act, null);
        std.posix.sigaction(std.os.linux.SIG.TSTP, &signals.ign_act, null);

        // Send SIGCONT to the entire process group
        // This is safe even if the job is already running (it's a no-op for running processes)
        std.posix.kill(-pgid, std.posix.SIG.CONT) catch |err| {
            // Restore terminal and signals before returning error
            std.posix.tcsetpgrp(tty_fd, ctx.shell_pgid.?) catch {};
            std.posix.sigaction(std.os.linux.SIG.INT, &signals.ign_act, null);
            std.posix.sigaction(std.os.linux.SIG.TSTP, &signals.ign_act, null);
            return err;
        };

        job.state = .running;

        // Wait loop - reap the whole process group to avoid child zombies.
        var last_terminal_status: ?u32 = null;
        while (true) {
            const ev = fork_exec.waitProcessGroupBlocking(pgid);
            if (ev.no_children) {
                if (last_terminal_status) |status| {
                    applyTerminalStatus(job, status);
                    switch (job.state) {
                        .finished => ctx.print("[{d}] Done\t{s}\n", .{ job_id, job.command_line_input }),
                        .killed => ctx.print("[{d}] Killed\t{s}\n", .{ job_id, job.command_line_input }),
                        else => {},
                    }
                } else if (job.state == .running) {
                    job.state = .finished;
                    ctx.print("[{d}] Done\t{s}\n", .{ job_id, job.command_line_input });
                }
                break;
            }

            if (!ev.any_event) continue;

            if (ev.stopped) {
                job.state = .stopped;
                // Clear claimed so the job could theoretically be bg'd and re-fg'd
                job.claimed.store(false, .release);
                // Don't clean up - job stays in table as stopped
                ctx.print("\n[{d}] Stopped\t{s}\n", .{ job_id, job.command_line_input });
                break;
            }

            if (ev.exited or ev.signaled) {
                last_terminal_status = ev.last_status;
                const drained = fork_exec.drainProcessGroupNoHang(pgid);
                if (drained.exited or drained.signaled) {
                    last_terminal_status = drained.last_status;
                }
                if (drained.no_children) {
                    const status = last_terminal_status orelse drained.last_status;
                    applyTerminalStatus(job, status);
                    if (job.state == .killed and std.os.linux.W.IFSIGNALED(status) and std.os.linux.W.TERMSIG(status) == .INT) {
                        ctx.print("\n", .{});
                    }
                    switch (job.state) {
                        .finished => ctx.print("[{d}] Done\t{s}\n", .{ job_id, job.command_line_input }),
                        .killed => ctx.print("[{d}] Killed\t{s}\n", .{ job_id, job.command_line_input }),
                        else => {},
                    }
                    break;
                }
            }
        }

        // Return terminal control to shell
        std.posix.tcsetpgrp(tty_fd, ctx.shell_pgid.?) catch {};

        // Restore shell signal handlers
        std.posix.sigaction(std.os.linux.SIG.INT, &signals.ign_act, null);
        std.posix.sigaction(std.os.linux.SIG.TSTP, &signals.ign_act, null);
    }

    /// Resume a stopped job in the background
    pub fn backgroundJob(self: *Self, ctx: *ShellCtx, job_id: u32) !void {
        const job = self.findJob(job_id) orelse return error.JobNotFound;
        if (job.state != .stopped) return error.JobNotStopped;
        const pgid = job.pgid orelse return error.NoPGID;

        // Send SIGCONT to resume without giving terminal control
        std.posix.kill(-pgid, std.posix.SIG.CONT) catch |err| switch (err) {
            error.ProcessNotFound => return error.JobNotFound, // process already gone
            else => return err,
        };

        job.state = .running;
        ctx.print("[{d}] Running in background: {s}\n", .{ job_id, job.command_line_input });
    }
};

fn applyTerminalStatus(job: *Job, status: u32) void {
    if (std.os.linux.W.IFSIGNALED(status)) {
        const sig = std.os.linux.W.TERMSIG(status);
        job.state = .killed;
        job.result = .{ .exit_code = 128 + @as(u8, @intCast(@intFromEnum(sig))) };
    } else if (std.os.linux.W.IFEXITED(status)) {
        job.state = .finished;
        job.result = .{ .exit_code = @intCast(std.os.linux.W.EXITSTATUS(status)) };
    }
}

/// Reconstruct the command line string from a pipeline
fn reconstructCommandLine(allocator: Allocator, pipeline: CommandPipeline) ![]const u8 {
    var parts = try std.ArrayList(u8).initCapacity(allocator, 32);
    defer parts.deinit(allocator);

    for (pipeline.stages, 0..) |stage, idx| {
        if (idx > 0) try parts.appendSlice(allocator, " | ");
        for (stage.args, 0..) |arg, arg_idx| {
            if (arg_idx > 0) try parts.append(allocator, ' ');
            try parts.appendSlice(allocator, arg.text);
        }
    }

    if (pipeline.redir_config) |config| {
        // Stdin redirect
        if (config.stdin_path) |in_path| {
            try parts.appendSlice(allocator, " < ");
            try parts.appendSlice(allocator, in_path);
        }

        // Stdout redirect — handle merge shorthand vs separate redirects
        if (config.stdout_path) |out_path| {
            if (config.merge_stderr_to_stdout) {
                // &> or &>>
                const op: []const u8 = if (config.stdout_truncate) " &> " else " &>> ";
                try parts.appendSlice(allocator, op);
            } else if (config.stdout == .pipe) {
                // > or >>
                const op: []const u8 = if (config.stdout_truncate) " > " else " >> ";
                try parts.appendSlice(allocator, op);
            }
            try parts.appendSlice(allocator, out_path);
        }

        // Separate stderr redirect (2> or 2>>)
        if (config.stderr_path) |err_path| {
            const op: []const u8 = if (config.stderr_truncate) " 2> " else " 2>> ";
            try parts.appendSlice(allocator, op);
            try parts.appendSlice(allocator, err_path);
        }

        // 2>&1 without a file (merge to stdout stream, no path)
        if (config.merge_stderr_to_stdout and config.stdout_path == null) {
            try parts.appendSlice(allocator, " 2>&1");
        }
    }

    return try parts.toOwnedSlice(allocator);
}

/// Reconstruct command line from args array
fn reconstructCommandLineFromArgs(allocator: Allocator, args: [][]const u8) ![]const u8 {
    var parts = try std.ArrayList(u8).initCapacity(allocator, 32);
    defer parts.deinit(allocator);

    for (args, 0..) |arg, idx| {
        if (idx > 0) {
            try parts.append(allocator, ' ');
        }
        try parts.appendSlice(allocator, arg);
    }

    return try parts.toOwnedSlice(allocator);
}
