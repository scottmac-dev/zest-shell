const std = @import("std");
const env = @import("env.zig");
const helpers = @import("helpers.zig");
const errors = @import("errors.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const ShellError = errors.ShellError;
const List = types.List;
const Value = types.Value;
pub const ShellExeMode = enum { interactive, engine }; // how the shell runs, REPL || one shot

/// Interface between core engine and interactive shell REPL
pub const InteractiveServices = struct {
    userdata: *anyopaque,
    persist_session_fn: *const fn (userdata: *anyopaque, ctx: *ShellCtx) void,
    history_import_fn: *const fn (userdata: *anyopaque, ctx: *ShellCtx, path: []const u8) ShellError!void,
    history_write_fn: *const fn (userdata: *anyopaque, ctx: *ShellCtx, path: []const u8, truncate: bool) ShellError!void,
    history_text_fn: *const fn (userdata: *anyopaque, allocator: Allocator, n: ?u32) ShellError![]const u8,
    history_list_fn: *const fn (userdata: *anyopaque, allocator: Allocator, n: ?u32) ShellError!*List,
    history_size_fn: *const fn (userdata: *anyopaque) usize,
    history_at_fn: *const fn (userdata: *anyopaque, idx: usize) ?[]const u8,
    // Non-owning pointer into in-memory history, optimized for realtime prompt UX.
    history_suggest_fn: *const fn (userdata: *anyopaque, prefix: []const u8) ?[]const u8,

    jobs_spawn_background_fn: *const fn (userdata: *anyopaque, ctx: *ShellCtx, pipeline_ptr: *const anyopaque, input: []const u8) ShellError!u32,
    jobs_poll_fn: *const fn (userdata: *anyopaque) void,
    jobs_clean_finished_fn: *const fn (userdata: *anyopaque, ctx: *ShellCtx, notify: bool) void,
    jobs_save_stopped_command_fn: *const fn (userdata: *anyopaque, ctx: *ShellCtx, args: []const []const u8, child_pid: std.posix.pid_t) ShellError!void,
    jobs_save_stopped_pipeline_fn: *const fn (userdata: *anyopaque, ctx: *ShellCtx, pipeline_ptr: *const anyopaque, pgid: std.posix.pid_t) ShellError!void,
    jobs_value_fn: *const fn (userdata: *anyopaque, allocator: Allocator) ShellError!Value,
    jobs_foreground_fn: *const fn (userdata: *anyopaque, ctx: *ShellCtx, job_id: u32) ShellError!void,
    jobs_background_fn: *const fn (userdata: *anyopaque, ctx: *ShellCtx, job_id: u32) ShellError!void,
    jobs_kill_fn: *const fn (userdata: *anyopaque, job_id: u32) ShellError!void,
};

/// Shell context holds pointers to history manager, env map, io, cache, process id, and allocator
pub const ShellCtx = struct {
    const Self = @This();
    pub const AliasMap = std.StringHashMap([]const u8);

    // -- SHARED
    exe_mode: ShellExeMode = .interactive,
    io: *std.Io,
    allocator: Allocator,
    env_map: *env.EnvMap,
    stdout: std.Io.File,
    last_exit_code: u8 = 0,
    shell_name: []const u8 = "zest",
    shell_version: []const u8 = "dev",

    // -- INTERACTIVE only
    interactive_services: ?*const InteractiveServices = null,
    exe_cache: ?*env.ExeCache = null,
    aliases: ?*AliasMap = null,
    shell_pgid: ?std.posix.pid_t = null,
    home_dir_cache: ?[]const u8 = null,
    display_user_cache: ?[]const u8 = null,
    prompt_template: ?[]const u8 = null,

    // -- ENGINE only
    captured_output: ?Value = null, // engine will need to capture and format output
    capture_engine_values: bool = false, // enable builtin return-value capture (used by JSON engine mode)
    // -- SCRIPTING
    running_script: bool = false,
    loop_break: bool = false,
    loop_continue: bool = false,
    current_input_line: ?[]const u8 = null,

    // Init for interactive REPL
    pub fn initShell(
        io: *std.Io,
        allocator: Allocator,
        env_map: *env.EnvMap,
        exe_cache: *env.ExeCache,
        aliases: *AliasMap,
        shell_name: []const u8,
        shell_version: []const u8,
        interactive_services: *const InteractiveServices,
    ) ShellCtx {
        const shell_pgid: std.posix.pid_t = @intCast(std.os.linux.getpid());

        return .{
            .io = io,
            .allocator = allocator,
            .env_map = env_map,
            .exe_cache = exe_cache,
            .aliases = aliases,
            .shell_pgid = shell_pgid,
            .stdout = std.Io.File.stdout(),
            .shell_name = shell_name,
            .shell_version = shell_version,
            .interactive_services = interactive_services,
        };
    }

    // Init for single shot engine
    pub fn initEngine(
        io: *std.Io,
        allocator: Allocator,
        env_map: *env.EnvMap,
    ) !ShellCtx {
        return .{
            .io = io,
            .allocator = allocator,
            .env_map = env_map,
            .exe_mode = ShellExeMode.engine,
            .stdout = std.Io.File.stdout(),
        };
    }

    // Mock ctx for testing
    pub fn initTest(allocator: Allocator) !ShellCtx {
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        var io = threaded.io();

        return .{
            .io = &io,
            .allocator = allocator,
            .env_map = try env.EnvMap.init(allocator),
            .stdout = std.Io.File.stdout(),
            .exe_mode = .interactive,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.home_dir_cache) |dir| {
            self.allocator.free(dir);
        }
        if (self.display_user_cache) |user| {
            self.allocator.free(user);
        }
        if (self.prompt_template) |template| {
            self.allocator.free(template);
        }
    }

    /// Return ~ HOME
    pub fn getHomeDirCache(self: *Self) ![]const u8 {
        switch (self.exe_mode) {
            .interactive => {
                // use cache
                if (self.home_dir_cache) |home| return home;
                const home_dir = self.env_map.get("HOME"); // should have been seeded from Environ
                if (home_dir) |home| {
                    self.home_dir_cache = switch (home) {
                        .text => |text| try self.allocator.dupe(u8, text),
                        else => try home.toString(self.allocator),
                    };
                    return self.home_dir_cache.?;
                } else {
                    return error.HomePathNotFound;
                }
            },
            .engine => {
                // lazy load from env map
                const home_dir = self.env_map.get("HOME"); // should have been seeded from Environ
                if (home_dir) |home| {
                    if (home == .text) return home.text;
                    if (self.home_dir_cache) |cached| return cached;
                    self.home_dir_cache = try home.toString(self.allocator);
                    return self.home_dir_cache.?;
                } else {
                    return error.HomePathNotFound;
                }
            },
        }
    }

    fn envUserCandidate(self: *Self, key: []const u8) !?[]const u8 {
        const value = self.env_map.get(key) orelse return null;
        return switch (value) {
            .text => |text| {
                if (text.len == 0) return null;
                return try self.allocator.dupe(u8, text);
            },
            else => {
                const text = try value.toString(self.allocator);
                if (text.len == 0) {
                    self.allocator.free(text);
                    return null;
                }
                return text;
            },
        };
    }

    /// Return a stable display username for prompt/banner rendering.
    /// Resolves from USER, then LOGNAME, with a non-hardcoded fallback.
    pub fn getDisplayUser(self: *Self) ![]const u8 {
        if (self.display_user_cache) |user| return user;

        const resolved =
            (try self.envUserCandidate("USER")) orelse
            (try self.envUserCandidate("LOGNAME")) orelse
            try self.allocator.dupe(u8, "user");

        self.display_user_cache = resolved;
        return resolved;
    }

    /// Get exe path from usr PATH
    pub fn findExe(self: *Self, exe_name: []const u8) !?[]const u8 {
        switch (self.exe_mode) {
            .interactive => {
                // use cache
                return try self.exe_cache.?.findExe(self.io, exe_name, self.env_map);
            },
            .engine => {
                // search env
                const path_val = self.env_map.get("PATH") orelse return null;
                var owned_path: ?[]const u8 = null;
                defer if (owned_path) |path| self.allocator.free(path);
                const path_env = switch (path_val) {
                    .text => |text| text,
                    else => blk: {
                        owned_path = try path_val.toString(self.allocator);
                        break :blk owned_path.?;
                    },
                };
                const sep: u8 = ':';

                var path_buf = try std.ArrayList(u8).initCapacity(self.allocator, 128);
                defer path_buf.deinit(self.allocator);
                var iter = std.mem.splitScalar(u8, path_env, sep);
                while (iter.next()) |dir| {
                    try helpers.appendPathJoin(&path_buf, self.allocator, dir, exe_name);
                    if (helpers.isExecutablePath(self.io, path_buf.items)) {
                        const path_cpy = try self.allocator.dupe(u8, path_buf.items);
                        return path_cpy;
                    }
                }
                return null;
            },
        }
    }

    pub fn resolveAlias(self: *const Self, name: []const u8) ?[]const u8 {
        if (self.exe_mode != .interactive) return null;
        const aliases = self.aliases orelse return null;
        return aliases.get(name);
    }

    /// Fmt print to stdout
    pub fn print(self: *Self, comptime fmt: []const u8, args: anytype) void {
        var o_buf: [1024]u8 = undefined;
        var writer = self.stdout.writer(self.io.*, &o_buf);
        const stdout = &writer.interface;
        stdout.print(fmt, args) catch |err| {
            errors.report(err, "write to stdout", "ShellCtx.print");
        };
        defer stdout.flush() catch |err| {
            errors.report(err, "flush stdout", "ShellCtx.print");
        };
    }

    pub fn persistSession(self: *Self) void {
        if (self.interactive_services) |svc| {
            svc.persist_session_fn(svc.userdata, self);
        }
    }

    // --- INTERACTIVE ONLY --

    pub fn historyImport(self: *Self, path: []const u8) ShellError!void {
        const svc = self.interactive_services orelse return ShellError.Unsupported;
        return svc.history_import_fn(svc.userdata, self, path);
    }

    pub fn historyWrite(self: *Self, path: []const u8, truncate: bool) ShellError!void {
        const svc = self.interactive_services orelse return ShellError.Unsupported;
        return svc.history_write_fn(svc.userdata, self, path, truncate);
    }

    pub fn historyText(self: *Self, allocator: Allocator, n: ?u32) ShellError![]const u8 {
        const svc = self.interactive_services orelse return ShellError.Unsupported;
        return svc.history_text_fn(svc.userdata, allocator, n);
    }

    pub fn historyList(self: *Self, allocator: Allocator, n: ?u32) ShellError!*List {
        const svc = self.interactive_services orelse return ShellError.Unsupported;
        return svc.history_list_fn(svc.userdata, allocator, n);
    }

    pub fn historySize(self: *Self) usize {
        const svc = self.interactive_services orelse return 0;
        return svc.history_size_fn(svc.userdata);
    }

    pub fn historyAt(self: *Self, idx: usize) ?[]const u8 {
        const svc = self.interactive_services orelse return null;
        return svc.history_at_fn(svc.userdata, idx);
    }

    pub fn historySuggest(self: *Self, prefix: []const u8) ?[]const u8 {
        const svc = self.interactive_services orelse return null;
        return svc.history_suggest_fn(svc.userdata, prefix);
    }

    pub fn spawnBackgroundPipeline(self: *Self, pipeline_ptr: *const anyopaque, input: []const u8) ShellError!u32 {
        const svc = self.interactive_services orelse return ShellError.Unsupported;
        return svc.jobs_spawn_background_fn(svc.userdata, self, pipeline_ptr, input);
    }

    pub fn pollBackgroundJobs(self: *Self) void {
        if (self.interactive_services) |svc| {
            svc.jobs_poll_fn(svc.userdata);
        }
    }

    pub fn cleanFinishedJobs(self: *Self, notify: bool) void {
        if (self.interactive_services) |svc| {
            svc.jobs_clean_finished_fn(svc.userdata, self, notify);
        }
    }

    pub fn saveStoppedCommand(self: *Self, args: []const []const u8, child_pid: std.posix.pid_t) ShellError!void {
        const svc = self.interactive_services orelse return ShellError.Unsupported;
        return svc.jobs_save_stopped_command_fn(svc.userdata, self, args, child_pid);
    }

    pub fn saveStoppedPipeline(self: *Self, pipeline_ptr: *const anyopaque, pgid: std.posix.pid_t) ShellError!void {
        const svc = self.interactive_services orelse return ShellError.Unsupported;
        return svc.jobs_save_stopped_pipeline_fn(svc.userdata, self, pipeline_ptr, pgid);
    }

    pub fn jobsValue(self: *Self, allocator: Allocator) ShellError!Value {
        const svc = self.interactive_services orelse return ShellError.Unsupported;
        return svc.jobs_value_fn(svc.userdata, allocator);
    }

    pub fn foregroundJob(self: *Self, job_id: u32) ShellError!void {
        const svc = self.interactive_services orelse return ShellError.Unsupported;
        return svc.jobs_foreground_fn(svc.userdata, self, job_id);
    }

    pub fn backgroundJob(self: *Self, job_id: u32) ShellError!void {
        const svc = self.interactive_services orelse return ShellError.Unsupported;
        return svc.jobs_background_fn(svc.userdata, self, job_id);
    }

    pub fn killJob(self: *Self, job_id: u32) ShellError!void {
        const svc = self.interactive_services orelse return ShellError.Unsupported;
        return svc.jobs_kill_fn(svc.userdata, job_id);
    }
};
