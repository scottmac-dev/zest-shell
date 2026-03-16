const std = @import("std");
const core_ctx = @import("../../lib-core/core/context.zig");
const core_errors = @import("../../lib-core/core/errors.zig");
const core_types = @import("../../lib-core/core/types.zig");
const core_pipeline = @import("../../lib-core/core/pipeline.zig");
const history_mod = @import("history.zig");
const jobs_mod = @import("jobs.zig");

const Allocator = std.mem.Allocator;
const ShellCtx = core_ctx.ShellCtx;
const ShellError = core_errors.ShellError;
const InteractiveServices = core_ctx.InteractiveServices;
const List = core_types.List;
const Map = core_types.Map;
const Value = core_types.Value;
const CommandPipeline = core_pipeline.CommandPipeline;

pub const InteractiveAdapter = struct {
    history: *history_mod.HistoryManager,
    jobs: *jobs_mod.JobTable,
    hist_file: []const u8,
    env_file: []const u8,
    services: InteractiveServices,

    pub fn init(
        history: *history_mod.HistoryManager,
        jobs: *jobs_mod.JobTable,
        hist_file: []const u8,
        env_file: []const u8,
    ) InteractiveAdapter {
        var adapter = InteractiveAdapter{
            .history = history,
            .jobs = jobs,
            .hist_file = hist_file,
            .env_file = env_file,
            .services = undefined,
        };
        adapter.services = .{
            .userdata = @ptrCast(&adapter),
            .persist_session_fn = persistSession,
            .history_import_fn = historyImport,
            .history_write_fn = historyWrite,
            .history_text_fn = historyText,
            .history_list_fn = historyList,
            .history_size_fn = historySize,
            .history_at_fn = historyAt,
            .history_suggest_fn = historySuggest,
            .jobs_spawn_background_fn = spawnBackgroundPipeline,
            .jobs_poll_fn = pollBackgroundJobs,
            .jobs_clean_finished_fn = cleanFinishedJobs,
            .jobs_save_stopped_command_fn = saveStoppedCommand,
            .jobs_save_stopped_pipeline_fn = saveStoppedPipeline,
            .jobs_value_fn = jobsValue,
            .jobs_foreground_fn = foregroundJob,
            .jobs_background_fn = backgroundJob,
            .jobs_kill_fn = killJob,
        };
        return adapter;
    }

    pub fn servicesRef(self: *InteractiveAdapter) *const InteractiveServices {
        self.services.userdata = @ptrCast(self);
        return &self.services;
    }
};

fn selfFrom(userdata: *anyopaque) *InteractiveAdapter {
    return @ptrCast(@alignCast(userdata));
}

fn persistSession(userdata: *anyopaque, ctx: *ShellCtx) void {
    const self = selfFrom(userdata);
    self.history.exportHistory(ctx, self.hist_file, false) catch {};
    ctx.env_map.exportEnv(ctx, self.env_file) catch {};
}

fn historyImport(userdata: *anyopaque, ctx: *ShellCtx, path: []const u8) ShellError!void {
    const self = selfFrom(userdata);
    self.history.importHistory(ctx, path) catch return ShellError.FileNotFound;
}

fn historyWrite(userdata: *anyopaque, ctx: *ShellCtx, path: []const u8, truncate: bool) ShellError!void {
    const self = selfFrom(userdata);
    self.history.writeHistory(ctx, path, truncate) catch return ShellError.WriteFailed;
}

fn historyText(userdata: *anyopaque, allocator: Allocator, n: ?u32) ShellError![]const u8 {
    const self = selfFrom(userdata);
    var output = std.ArrayList(u8).initCapacity(allocator, 1024) catch return ShellError.AllocFailed;
    self.history.getHistoryText(allocator, &output, n) catch return ShellError.WriteFailed;
    return output.toOwnedSlice(allocator) catch return ShellError.AllocFailed;
}

fn historyList(userdata: *anyopaque, allocator: Allocator, n: ?u32) ShellError!*List {
    const self = selfFrom(userdata);
    const list = allocator.create(List) catch return ShellError.AllocFailed;
    list.* = List.initCapacity(allocator, n orelse 100) catch return ShellError.AllocFailed;
    self.history.getHistoryList(allocator, list, n) catch return ShellError.WriteFailed;
    return list;
}

fn historySize(userdata: *anyopaque) usize {
    const self = selfFrom(userdata);
    return self.history.size();
}

fn historyAt(userdata: *anyopaque, idx: usize) ?[]const u8 {
    const self = selfFrom(userdata);
    if (idx >= self.history.list.items.len) return null;
    return self.history.list.items[idx];
}

fn historySuggest(userdata: *anyopaque, prefix: []const u8) ?[]const u8 {
    const self = selfFrom(userdata);
    return self.history.findSuggestion(prefix);
}

fn spawnBackgroundPipeline(userdata: *anyopaque, ctx: *ShellCtx, pipeline_ptr: *const anyopaque, input: []const u8) ShellError!u32 {
    const self = selfFrom(userdata);
    const pipeline: *const CommandPipeline = @ptrCast(@alignCast(pipeline_ptr));
    return self.jobs.spawnBackgroundPipeline(ctx, pipeline.*, input) catch return ShellError.JobSpawnFailed;
}

fn pollBackgroundJobs(userdata: *anyopaque) void {
    const self = selfFrom(userdata);
    self.jobs.pollBackgroundJobs();
}

fn cleanFinishedJobs(userdata: *anyopaque, ctx: *ShellCtx, notify: bool) void {
    const self = selfFrom(userdata);
    self.jobs.cleanFinished(ctx, notify);
}

fn saveStoppedCommand(
    userdata: *anyopaque,
    ctx: *ShellCtx,
    args: []const []const u8,
    child_pid: std.posix.pid_t,
) ShellError!void {
    const self = selfFrom(userdata);
    self.jobs.saveStoppedCommand(ctx, @constCast(args), child_pid) catch return ShellError.JobSpawnFailed;
}

fn saveStoppedPipeline(
    userdata: *anyopaque,
    ctx: *ShellCtx,
    pipeline_ptr: *const anyopaque,
    pgid: std.posix.pid_t,
) ShellError!void {
    const self = selfFrom(userdata);
    const pipeline: *const CommandPipeline = @ptrCast(@alignCast(pipeline_ptr));
    self.jobs.saveStoppedPipeline(ctx, pipeline.*, pgid) catch return ShellError.JobSpawnFailed;
}

fn jobsValue(userdata: *anyopaque, allocator: Allocator) ShellError!Value {
    const self = selfFrom(userdata);
    const job_list = allocator.create(List) catch return ShellError.AllocFailed;
    job_list.* = List.initCapacity(allocator, 4) catch return ShellError.AllocFailed;

    for (self.jobs.jobs.items) |job| {
        const job_map = allocator.create(Map) catch return ShellError.AllocFailed;
        job_map.* = Map.init(allocator);

        const put = struct {
            fn call(map: *Map, alloc: Allocator, key: []const u8, val: Value) ShellError!void {
                map.put(alloc.dupe(u8, key) catch return ShellError.AllocFailed, val) catch return ShellError.AllocFailed;
            }
        }.call;

        try put(job_map, allocator, "id", .{ .integer = @intCast(job.id) });
        try put(job_map, allocator, "command", .{ .text = allocator.dupe(u8, job.command_line_input) catch return ShellError.AllocFailed });
        try put(job_map, allocator, "state", .{ .text = allocator.dupe(u8, @tagName(job.state)) catch return ShellError.AllocFailed });

        if (job.pgid) |pgid| {
            try put(job_map, allocator, "pgid", .{ .integer = @intCast(pgid) });
        }

        if (job.result) |result| {
            switch (result) {
                .success => try put(job_map, allocator, "exit_code", .{ .integer = 0 }),
                .exit_code => |code| try put(job_map, allocator, "exit_code", .{ .integer = @intCast(code) }),
                .err => |err| {
                    try put(job_map, allocator, "exit_code", .{ .integer = -1 });
                    try put(job_map, allocator, "error", .{ .text = allocator.dupe(u8, @errorName(err)) catch return ShellError.AllocFailed });
                },
            }
        }

        job_list.append(allocator, Value{ .map = job_map }) catch return ShellError.AllocFailed;
    }

    return Value{ .list = job_list };
}

fn foregroundJob(userdata: *anyopaque, ctx: *ShellCtx, job_id: u32) ShellError!void {
    const self = selfFrom(userdata);
    self.jobs.foregroundJob(ctx, job_id) catch return ShellError.JobSpawnFailed;
}

fn backgroundJob(userdata: *anyopaque, ctx: *ShellCtx, job_id: u32) ShellError!void {
    const self = selfFrom(userdata);
    self.jobs.backgroundJob(ctx, job_id) catch return ShellError.JobSpawnFailed;
}

fn killJob(userdata: *anyopaque, job_id: u32) ShellError!void {
    const self = selfFrom(userdata);
    self.jobs.killJob(job_id) catch return ShellError.JobNotFound;
}
