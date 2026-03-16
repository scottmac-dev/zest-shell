const std = @import("std");
const types = @import("types.zig");
const helpers = @import("helpers.zig");
const Allocator = std.mem.Allocator;
const ShellCtx = @import("context.zig").ShellCtx;
const Map = types.Map;
const Value = types.Value;
const INIT_CAPACITY = 8; // default ArrayList capacity

/// Represents a map entry in EnvMap, contains exported flag to enable single map for both
/// local and global persistent variables.
pub const VarEntry = struct {
    value: Value,
    exported: bool,
    persistent: bool,

    pub fn deinit(self: *VarEntry, allocator: Allocator) void {
        self.value.deinit(allocator);
    }
};

/// A string map for shell and environment variables
pub const EnvMap = struct {
    const Self = @This();

    allocator: Allocator,
    vars: std.StringHashMap(VarEntry),
    loaded: bool,

    pub fn init(allocator: Allocator) !*Self {
        const evm = try allocator.create(Self);
        evm.* = Self{
            .allocator = allocator,
            .vars = std.StringHashMap(VarEntry).init(allocator),
            .loaded = false,
        };
        return evm;
    }

    pub fn deinit(self: *Self) void {
        var it = self.vars.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(self.allocator);
        }
        self.vars.deinit();
        self.allocator.destroy(self);
    }

    /// Seed from process environ at startup. Seeded vars are exported to child
    /// processes but are not written to the persisted env file unless they are
    /// explicitly exported during a shell session.
    pub fn seedFromEnviron(self: *Self, environ: std.process.Environ, allocator: Allocator) !void {
        var map = try environ.createMap(allocator);
        defer map.deinit();
        const reserve: u32 = @intCast(@min(map.count(), std.math.maxInt(u32)));
        try self.vars.ensureUnusedCapacity(reserve);

        var it = map.iterator();
        while (it.next()) |entry| {
            try self.putEntry(entry.key_ptr.*, Value{ .text = entry.value_ptr.* }, true, false);
        }
    }

    /// Internal: put a key/value with explicit exported flag, handles owned memory correctly
    fn putEntry(self: *Self, key: []const u8, value: Value, exported: bool, persistent: bool) !void {
        const owned_value = try value.clone(self.allocator);
        errdefer owned_value.deinit(self.allocator);
        if (self.vars.getPtr(key)) |old_entry| {
            old_entry.value.deinit(self.allocator);
            old_entry.value = owned_value;
            old_entry.exported = exported;
            old_entry.persistent = persistent;
        } else {
            const owned_key = try self.allocator.dupe(u8, key);
            try self.vars.put(owned_key, VarEntry{
                .value = owned_value,
                .exported = exported,
                .persistent = persistent,
            });
        }
    }

    /// Put a shell-local variable (not passed to child processes)
    pub fn putShell(self: *Self, key: []const u8, value: Value) !void {
        try self.putEntry(key, value, false, false);
    }

    /// Put an exported environment variable (passed to child processes)
    pub fn putExported(self: *Self, key: []const u8, value: Value) !void {
        try self.putEntry(key, value, true, true);
    }

    /// Get a variable value regardless of export status
    pub fn get(self: *Self, key: []const u8) ?Value {
        if (self.vars.get(key)) |entry| return entry.value;
        return null;
    }

    /// Mark an existing shell variable as exported. Returns false if key not found.
    pub fn exportVar(self: *Self, key: []const u8) !bool {
        if (self.vars.getPtr(key)) |entry| {
            entry.exported = true;
            entry.persistent = true;
            return true;
        }
        return false;
    }

    /// Remove a variable, freeing its memory
    pub fn remove(self: *Self, key: []const u8) void {
        if (self.vars.fetchRemove(key)) |kv| {
            self.allocator.free(kv.key);
            kv.value.value.deinit(self.allocator);
        }
    }

    /// Remove a variable but keep the key alive (key owned by another structure)
    pub fn removeKeepKey(self: *Self, key: []const u8) void {
        if (self.vars.fetchRemove(key)) |kv| {
            kv.value.value.deinit(self.allocator);
        }
    }

    /// Print all variables, showing export status
    pub fn printAll(self: *Self, ctx: *ShellCtx) void {
        var it = self.vars.iterator();
        while (it.next()) |entry| {
            const prefix: []const u8 = if (entry.value_ptr.exported) "export " else "";
            const val_text = entry.value_ptr.value.toString(self.allocator) catch {
                ctx.print("{s}{s}=<err>\n", .{ prefix, entry.key_ptr.* });
                continue;
            };
            defer self.allocator.free(val_text);
            ctx.print("{s}{s}={s}\n", .{ prefix, entry.key_ptr.*, val_text });
        }
    }

    /// Read from file and populate vars. Expects KEY=VALUE format, splits on first = only.
    /// Imported vars are exported and persistent because they came from a
    /// previous interactive session's explicit exports.
    pub fn importEnv(self: *Self, ctx: *ShellCtx, file_path: []const u8) !void {
        if (self.loaded) return;
        self.loaded = true;

        var file = helpers.getFileFromPath(ctx, ctx.allocator, file_path, .{
            .truncate = false,
            .pre_expanded = false,
            .write = false,
        }) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer file.close(ctx.io.*);

        const content = try helpers.fileReadAll(ctx.io.*, ctx.allocator, file);
        defer ctx.allocator.free(content);

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \n\r\t");
            if (trimmed.len == 0) continue;
            if (std.mem.indexOfScalar(u8, trimmed, '=')) |idx| {
                const key = trimmed[0..idx];
                const value = trimmed[idx + 1 ..];
                if (key.len == 0) continue;
                try self.putEntry(key, Value{ .text = value }, true, true);
            }
        }
    }

    /// Write persistent exported vars to disk in KEY=VALUE format
    pub fn exportEnv(self: *Self, ctx: *ShellCtx, file_path: []const u8) !void {
        if (ctx.exe_mode != .interactive) return;

        const expanded_path = try helpers.expandPathToAbs(ctx, ctx.allocator, file_path);
        defer ctx.allocator.free(expanded_path);

        try helpers.ensureDirPath(ctx, expanded_path);

        var file = try helpers.getFileFromPath(ctx, ctx.allocator, expanded_path, .{
            .write = true,
            .truncate = true,
            .pre_expanded = true,
        });
        defer file.close(ctx.io.*);

        const output = try self.asOwnedMapString(ctx.allocator);
        defer ctx.allocator.free(output);

        try helpers.fileWriteAll(ctx.io.*, file, output);
    }

    /// Serialize persistent exported vars to KEY=VALUE\n string
    pub fn asOwnedMapString(self: *Self, arena: Allocator) ![]const u8 {
        var output = try std.ArrayList(u8).initCapacity(arena, 256);

        var iter = self.vars.iterator();
        while (iter.next()) |entry| {
            if (!entry.value_ptr.exported or !entry.value_ptr.persistent) continue;
            const value_str = try entry.value_ptr.value.toString(arena);
            defer arena.free(value_str);
            const line = try std.fmt.allocPrint(arena, "{s}={s}\n", .{ entry.key_ptr.*, value_str });
            defer arena.free(line);
            try output.appendSlice(arena, line);
        }

        return output.toOwnedSlice(arena);
    }

    /// Build null-terminated envp array for execve, exported vars only
    pub fn createNullDelimitedEnvMap(self: *Self, arena: Allocator) ![:null]?[*:0]u8 {
        // Count exported vars first
        var exported_count: usize = 0;
        var count_it = self.vars.iterator();
        while (count_it.next()) |pair| {
            if (pair.value_ptr.exported) exported_count += 1;
        }

        const envp_buf = try arena.allocSentinel(?[*:0]u8, exported_count, null);

        var it = self.vars.iterator();
        var i: usize = 0;
        while (it.next()) |pair| {
            if (!pair.value_ptr.exported) continue;
            const val_str = try pair.value_ptr.value.toString(arena);
            const env_buf = try arena.allocSentinel(u8, pair.key_ptr.len + val_str.len + 1, 0);
            @memcpy(env_buf[0..pair.key_ptr.len], pair.key_ptr.*);
            env_buf[pair.key_ptr.len] = '=';
            @memcpy(env_buf[pair.key_ptr.len + 1 ..], val_str);
            envp_buf[i] = env_buf.ptr;
            i += 1;
        }
        std.debug.assert(i == exported_count);

        return envp_buf;
    }

    /// Return Map of Value objects, stripping away the exported flag data
    pub fn getExportedMap(self: *Self, allocator: Allocator) !Map {
        var result = Map.init(allocator);
        errdefer {
            var cleanup = result.iterator();
            while (cleanup.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                entry.value_ptr.*.deinit(allocator);
            }
            result.deinit();
        }

        var it = self.vars.iterator();
        while (it.next()) |entry| {
            if (!entry.value_ptr.exported) continue;
            const key_copy = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(key_copy);
            const value_copy = try entry.value_ptr.value.clone(allocator);
            errdefer value_copy.deinit(allocator);
            try result.put(key_copy, value_copy);
        }
        return result;
    }
};

/// Cache for executable lookups to avoid repeated PATH scanning
/// only used in interactive mode, not worth overhead for one shots
pub const ExeCache = struct {
    const Self = @This();

    allocator: Allocator,
    exe_map: std.StringHashMap([]const u8), // map exe name -> path
    path_dirs: std.ArrayList([]const u8), // all cached directories
    cached_path: []const u8, // last path with known changes

    pub fn init(allocator: Allocator) !Self {
        return .{
            .allocator = allocator,
            .exe_map = std.StringHashMap([]const u8).init(allocator),
            .path_dirs = try std.ArrayList([]const u8).initCapacity(allocator, INIT_CAPACITY),
            .cached_path = &.{},
        };
    }

    pub fn deinit(self: *Self) void {
        // free values and keys
        var it = self.exe_map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.exe_map.deinit();

        // Free path directories
        for (self.path_dirs.items) |dir| {
            self.allocator.free(dir);
        }
        self.path_dirs.deinit(self.allocator);

        if (self.cached_path.len > 0) {
            self.allocator.free(self.cached_path);
        }
    }

    /// Now takes environ instead of calling std.posix.getenv directly
    pub fn updatePathCache(self: *Self, env_map: *EnvMap) !void {
        const path_val = env_map.get("PATH") orelse return;
        const path_env = switch (path_val) {
            .text => |text| text,
            else => return,
        };
        if (std.mem.eql(u8, self.cached_path, path_env)) return;

        for (self.path_dirs.items) |dir| self.allocator.free(dir);
        self.path_dirs.clearRetainingCapacity();

        if (self.cached_path.len > 0) self.allocator.free(self.cached_path);

        self.cached_path = try self.allocator.dupe(u8, path_env);

        const sep: u8 = ':';

        var iter = std.mem.splitScalar(u8, path_env, sep);
        while (iter.next()) |dir| {
            if (dir.len == 0) continue;
            try self.path_dirs.append(self.allocator, try self.allocator.dupe(u8, dir));
        }
    }

    /// findExe and isPathExe now thread environ through
    pub fn findExe(self: *Self, io: *std.Io, exe_name: []const u8, env_map: *EnvMap) !?[]const u8 {
        try self.updatePathCache(env_map);

        if (self.exe_map.get(exe_name)) |cached_path| {
            if (self.isExe(io, cached_path)) {
                return cached_path;
            } else {
                const entry = self.exe_map.fetchRemove(exe_name).?;
                self.allocator.free(entry.key);
                self.allocator.free(entry.value);
            }
        }

        var path_buf = try std.ArrayList(u8).initCapacity(self.allocator, 128);
        defer path_buf.deinit(self.allocator);
        for (self.path_dirs.items) |dir| {
            try helpers.appendPathJoin(&path_buf, self.allocator, dir, exe_name);
            if (self.isExe(io, path_buf.items)) {
                const name_cpy = try self.allocator.dupe(u8, exe_name);
                const path_cpy = try self.allocator.dupe(u8, path_buf.items);
                try self.exe_map.put(name_cpy, path_cpy);
                return path_cpy;
            }
        }

        return null;
    }

    pub fn isPathExe(self: *Self, io: *std.Io, cmd: []const u8, env_map: *EnvMap) !bool {
        return (try self.findExe(io, cmd, env_map)) != null;
    }

    // Quick check absolute path for executable permissions assumes all cached paths are expanded to abs paths
    pub fn isExe(self: *Self, io: *std.Io, absolute_path: []const u8) bool {
        _ = self;
        return helpers.isExecutablePath(io, absolute_path);
    }
};

fn deinitOwnedValueMap(allocator: Allocator, map: *Map) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        entry.value_ptr.*.deinit(allocator);
    }
    map.deinit();
}

test "getExportedMap returns fully owned clones" {
    var env_map = try EnvMap.init(std.testing.allocator);
    defer env_map.deinit();

    try env_map.putExported("TOKEN", .{ .text = "abc123" });
    try env_map.putShell("LOCAL_ONLY", .{ .text = "x" });

    const original = env_map.get("TOKEN") orelse return error.TestExpectedEqual;
    try std.testing.expect(original == .text);

    var exported = try env_map.getExportedMap(std.testing.allocator);
    defer deinitOwnedValueMap(std.testing.allocator, &exported);

    try std.testing.expect(exported.get("LOCAL_ONLY") == null);

    const cloned = exported.get("TOKEN") orelse return error.TestExpectedEqual;
    try std.testing.expect(cloned == .text);
    try std.testing.expectEqualStrings("abc123", cloned.text);
    try std.testing.expect(original.text.ptr != cloned.text.ptr);

    env_map.remove("TOKEN");
    const still_owned = exported.get("TOKEN") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("abc123", still_owned.text);
}

test "seeded env stays exported but is not persisted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var env_map = try EnvMap.init(std.testing.allocator);
    defer env_map.deinit();

    try env_map.putEntry("PATH", .{ .text = "/bin:/usr/bin" }, true, false);
    try env_map.putExported("ZEST_SESSION", .{ .text = "1" });

    const serialized = try env_map.asOwnedMapString(std.testing.allocator);
    defer std.testing.allocator.free(serialized);

    try std.testing.expect(std.mem.indexOf(u8, serialized, "PATH=/bin:/usr/bin") == null);
    try std.testing.expect(std.mem.indexOf(u8, serialized, "ZEST_SESSION=1") != null);

    const envp = try env_map.createNullDelimitedEnvMap(arena.allocator());
    try std.testing.expectEqual(@as(usize, 2), envp.len);
}
