const std = @import("std");
const env = @import("../../lib-core/core/env.zig");
const helpers = @import("../../lib-core/core/helpers.zig");
const config = @import("config.zig");
const ShellCtx = @import("../../lib-core/core/context.zig").ShellCtx;

const Allocator = std.mem.Allocator;

pub const PromptRenderCache = struct {
    visible_len: usize,
    lines_before_input: usize,
    rendered: []const u8,
};

pub const PromptData = struct {
    user: []const u8,
    cwd: []const u8,
    cwd_tilde: []const u8,
    cwd_base: []const u8,
    git: []const u8,
    status: []const u8,
    prompt_char: []const u8,
    shell: []const u8,
};

pub fn buildPromptRenderCache(ctx: *ShellCtx, allocator: Allocator, status_suffix: []const u8) !PromptRenderCache {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_n = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_end = std.mem.indexOfScalar(u8, &cwd_buf, 0) orelse cwd_n;
    const cwd = cwd_buf[0..cwd_end];
    const cwd_base = std.fs.path.basename(cwd);
    const user = ctx.getDisplayUser() catch "user";
    const cwd_tilde = formatCwdTilde(ctx, allocator, cwd) catch cwd;
    defer if (cwd_tilde.ptr != cwd.ptr) allocator.free(cwd_tilde);

    const git_segment = try resolveGitPromptSegment(ctx, allocator, cwd);
    defer if (git_segment) |segment| allocator.free(segment);

    return renderTemplate(allocator, ctx.prompt_template orelse config.DEFAULT_PROMPT_TEMPLATE, .{
        .user = user,
        .cwd = cwd,
        .cwd_tilde = cwd_tilde,
        .cwd_base = cwd_base,
        .git = git_segment orelse "",
        .status = status_suffix,
        .prompt_char = if (std.mem.eql(u8, user, "root")) "#" else "$",
        .shell = ctx.shell_name,
    });
}

pub fn renderTemplate(allocator: Allocator, template: []const u8, data: PromptData) !PromptRenderCache {
    var out = std.ArrayList(u8).initCapacity(allocator, template.len + data.cwd.len + data.git.len + 32) catch unreachable;
    defer out.deinit(allocator);

    var visible_len: usize = 0;
    var lines_before_input: usize = 0;
    var cursor: usize = 0;
    while (cursor < template.len) {
        if (template[cursor] == '$' and cursor + 1 < template.len and template[cursor + 1] == '{') {
            const close_idx = std.mem.indexOfScalarPos(u8, template, cursor + 2, '}');
            if (close_idx) |end| {
                const key = template[cursor + 2 .. end];
                if (try appendPlaceholder(allocator, &out, &visible_len, &lines_before_input, key, data)) {
                    cursor = end + 1;
                    continue;
                }
            }
        }

        out.append(allocator, template[cursor]) catch return error.OutOfMemory;
        if (template[cursor] == '\n') {
            lines_before_input += 1;
            visible_len = 0;
        } else {
            visible_len += 1;
        }
        cursor += 1;
    }

    return .{
        .visible_len = visible_len,
        .lines_before_input = lines_before_input,
        .rendered = try out.toOwnedSlice(allocator),
    };
}

fn appendPlaceholder(
    allocator: Allocator,
    out: *std.ArrayList(u8),
    visible_len: *usize,
    lines_before_input: *usize,
    key: []const u8,
    data: PromptData,
) !bool {
    if (std.mem.eql(u8, key, "user")) {
        try appendColored(out, allocator, config.UserHandleColor, data.user);
        visible_len.* += data.user.len;
        return true;
    }
    if (std.mem.eql(u8, key, "cwd")) {
        try appendColored(out, allocator, config.CwdHandleColor, data.cwd);
        visible_len.* += data.cwd.len;
        return true;
    }
    if (std.mem.eql(u8, key, "cwd_tilde")) {
        try appendColored(out, allocator, config.CwdHandleColor, data.cwd_tilde);
        visible_len.* += data.cwd_tilde.len;
        return true;
    }
    if (std.mem.eql(u8, key, "cwd_base")) {
        try appendColored(out, allocator, config.CwdHandleColor, data.cwd_base);
        visible_len.* += data.cwd_base.len;
        return true;
    }
    if (std.mem.eql(u8, key, "git")) {
        if (data.git.len > 0) {
            try appendColored(out, allocator, config.GitBranchColor, data.git);
            visible_len.* += data.git.len;
        }
        return true;
    }
    if (std.mem.eql(u8, key, "status")) {
        try out.appendSlice(allocator, data.status);
        visible_len.* += data.status.len;
        return true;
    }
    if (std.mem.eql(u8, key, "prompt_char")) {
        try out.appendSlice(allocator, data.prompt_char);
        visible_len.* += data.prompt_char.len;
        return true;
    }
    if (std.mem.eql(u8, key, "shell")) {
        try out.appendSlice(allocator, data.shell);
        visible_len.* += data.shell.len;
        return true;
    }
    if (std.mem.eql(u8, key, "nl")) {
        try out.append(allocator, '\n');
        lines_before_input.* += 1;
        visible_len.* = 0;
        return true;
    }
    return false;
}

fn appendColored(
    out: *std.ArrayList(u8),
    allocator: Allocator,
    color: config.Color,
    text: []const u8,
) !void {
    if (text.len == 0) return;
    const rendered = try std.fmt.allocPrint(allocator, "\x1b[{s}m{s}\x1b[0m", .{
        config.getAnsiColorStr(color),
        text,
    });
    defer allocator.free(rendered);
    try out.appendSlice(allocator, rendered);
}

fn formatCwdTilde(ctx: *ShellCtx, allocator: Allocator, cwd: []const u8) ![]const u8 {
    const home = ctx.getHomeDirCache() catch return allocator.dupe(u8, cwd);
    if (!std.mem.startsWith(u8, cwd, home)) return allocator.dupe(u8, cwd);

    if (cwd.len == home.len) return allocator.dupe(u8, "~");
    if (cwd.len > home.len and cwd[home.len] == '/') {
        return std.fmt.allocPrint(allocator, "~{s}", .{cwd[home.len..]});
    }
    return allocator.dupe(u8, cwd);
}

fn resolveGitPromptSegment(ctx: *ShellCtx, allocator: Allocator, cwd: []const u8) !?[]const u8 {
    const branch = try resolveGitBranchNameForCwd(ctx, allocator, cwd);
    if (branch == null) return null;
    defer allocator.free(branch.?);
    return try std.fmt.allocPrint(allocator, " ({s})", .{branch.?});
}

pub fn resolveGitBranchNameForCwd(ctx: *ShellCtx, allocator: Allocator, cwd: []const u8) !?[]const u8 {
    const git_dir = try resolveGitDirForCwd(ctx, allocator, cwd);
    if (git_dir == null) return null;
    defer allocator.free(git_dir.?);

    const head_path = try joinAbsolutePath(allocator, git_dir.?, "HEAD");
    defer allocator.free(head_path);

    const head = readTextFile(ctx, allocator, head_path) catch return null;
    defer allocator.free(head);

    return parseGitHeadText(allocator, head);
}

pub fn resolveGitDirForCwd(ctx: *ShellCtx, allocator: Allocator, cwd: []const u8) !?[]const u8 {
    return findGitDir(ctx, allocator, cwd);
}

fn findGitDir(ctx: *ShellCtx, allocator: Allocator, start_dir: []const u8) !?[]const u8 {
    var current = try allocator.dupe(u8, start_dir);
    defer allocator.free(current);

    while (true) {
        const dot_git = try joinAbsolutePath(allocator, current, ".git");
        defer allocator.free(dot_git);

        if (isGitDir(ctx, dot_git)) {
            const git_dir = try allocator.dupe(u8, dot_git);
            return git_dir;
        }

        if (try resolveGitDirFile(ctx, allocator, current, dot_git)) |git_dir| {
            return git_dir;
        }

        if (std.mem.eql(u8, current, "/")) return null;
        const parent = std.fs.path.dirname(current) orelse return null;
        if (parent.len == 0 or parent.len == current.len) return null;

        const next = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = next;
    }
}

fn isGitDir(ctx: *ShellCtx, dot_git: []const u8) bool {
    var dir = std.Io.Dir.openDirAbsolute(ctx.io.*, dot_git, .{}) catch return false;
    dir.close(ctx.io.*);
    return true;
}

fn resolveGitDirFile(ctx: *ShellCtx, allocator: Allocator, base_dir: []const u8, dot_git_path: []const u8) !?[]const u8 {
    const dot_git = readTextFile(ctx, allocator, dot_git_path) catch return null;
    defer allocator.free(dot_git);

    const trimmed = std.mem.trim(u8, dot_git, " \t\r\n");
    const prefix = "gitdir:";
    if (!std.mem.startsWith(u8, trimmed, prefix)) return null;

    const raw_git_dir = std.mem.trim(u8, trimmed[prefix.len..], " \t");
    if (raw_git_dir.len == 0) return null;

    const resolved = if (std.fs.path.isAbsolute(raw_git_dir))
        try allocator.dupe(u8, raw_git_dir)
    else
        try joinAbsolutePath(allocator, base_dir, raw_git_dir);

    if (!isGitDir(ctx, resolved)) {
        allocator.free(resolved);
        return null;
    }
    return resolved;
}

fn readTextFile(ctx: *ShellCtx, allocator: Allocator, abs_path: []const u8) ![]const u8 {
    var file = try std.Io.Dir.openFileAbsolute(ctx.io.*, abs_path, .{ .mode = .read_only });
    defer file.close(ctx.io.*);
    return helpers.fileReadAll(ctx.io.*, allocator, file);
}

fn joinAbsolutePath(allocator: Allocator, base: []const u8, child: []const u8) ![]const u8 {
    if (base.len == 0 or base[0] != '/') return error.InvalidPath;
    if (std.mem.eql(u8, base, "/")) {
        return std.fmt.allocPrint(allocator, "/{s}", .{child});
    }
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, child });
}

fn parseGitHeadText(allocator: Allocator, raw: []const u8) !?[]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    const ref_prefix = "ref: ";
    if (!std.mem.startsWith(u8, trimmed, ref_prefix)) {
        const short_len = @min(trimmed.len, 7);
        return try std.fmt.allocPrint(allocator, "detached@{s}", .{trimmed[0..short_len]});
    }

    const ref_name = trimmed[ref_prefix.len..];
    const heads_prefix = "refs/heads/";
    if (std.mem.startsWith(u8, ref_name, heads_prefix)) {
        const branch = try allocator.dupe(u8, ref_name[heads_prefix.len..]);
        return branch;
    }
    const ref = try allocator.dupe(u8, ref_name);
    return ref;
}

test "renderTemplate expands known placeholders and preserves visible length" {
    const rendered = try renderTemplate(std.testing.allocator, "${user}:${cwd}${git}${status}${prompt_char} ", .{
        .user = "alice",
        .cwd = "/tmp/demo",
        .cwd_tilde = "/tmp/demo",
        .cwd_base = "demo",
        .git = " (main)",
        .status = " [SBX]",
        .prompt_char = "$",
        .shell = "zest",
    });
    defer std.testing.allocator.free(rendered.rendered);

    try std.testing.expectEqual(@as(usize, "alice:/tmp/demo (main) [SBX]$ ".len), rendered.visible_len);
    try std.testing.expectEqual(@as(usize, 0), rendered.lines_before_input);
    try std.testing.expect(std.mem.indexOf(u8, rendered.rendered, "alice") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.rendered, "/tmp/demo") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.rendered, " (main)") != null);
}

test "renderTemplate leaves unknown placeholders untouched" {
    const rendered = try renderTemplate(std.testing.allocator, "x${unknown}y", .{
        .user = "alice",
        .cwd = "/tmp",
        .cwd_tilde = "/tmp",
        .cwd_base = "tmp",
        .git = "",
        .status = "",
        .prompt_char = "$",
        .shell = "zest",
    });
    defer std.testing.allocator.free(rendered.rendered);

    try std.testing.expectEqualStrings("x${unknown}y", rendered.rendered);
    try std.testing.expectEqual(@as(usize, 12), rendered.visible_len);
    try std.testing.expectEqual(@as(usize, 0), rendered.lines_before_input);
}

test "parseGitHeadText resolves branch and detached head formats" {
    const branch = (try parseGitHeadText(std.testing.allocator, "ref: refs/heads/feature/demo\n")).?;
    defer std.testing.allocator.free(branch);
    try std.testing.expectEqualStrings("feature/demo", branch);

    const detached = (try parseGitHeadText(std.testing.allocator, "0123456789abcdef\n")).?;
    defer std.testing.allocator.free(detached);
    try std.testing.expectEqualStrings("detached@0123456", detached);
}

test "findGitDir returns null for absolute non-git paths" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    var io = threaded.io();

    var env_map = try env.EnvMap.init(allocator);
    defer env_map.deinit();

    var ctx = try ShellCtx.initEngine(&io, allocator, env_map);
    defer ctx.deinit();
    ctx.exe_mode = .interactive;

    const git_dir = try findGitDir(&ctx, allocator, "/tmp");
    defer if (git_dir) |path| allocator.free(path);
    try std.testing.expect(git_dir == null);
}

test "renderTemplate tracks multi-line prompt metrics" {
    const rendered = try renderTemplate(std.testing.allocator, "${user} ${cwd_base}${git}${nl}> ", .{
        .user = "alice",
        .cwd = "/tmp/demo",
        .cwd_tilde = "/tmp/demo",
        .cwd_base = "demo",
        .git = " (main)",
        .status = "",
        .prompt_char = "$",
        .shell = "zest",
    });
    defer std.testing.allocator.free(rendered.rendered);

    try std.testing.expectEqualStrings("\x1b[36malice\x1b[0m \x1b[32mdemo\x1b[0m\x1b[35m (main)\x1b[0m\n> ", rendered.rendered);
    try std.testing.expectEqual(@as(usize, 2), rendered.visible_len);
    try std.testing.expectEqual(@as(usize, 1), rendered.lines_before_input);
}
