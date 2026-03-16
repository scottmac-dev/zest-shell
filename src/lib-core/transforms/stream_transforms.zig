const std = @import("std");
const command = @import("../core/command.zig");
const helpers = @import("../core/helpers.zig");
const transforms = @import("transforms.zig");
const stream_ops = @import("../transforms/stream_ops.zig");
const types = @import("../core/types.zig");
const ShellError = @import("../core/errors.zig").ShellError;
const ExecContext = command.ExecContext;
const Value = types.Value;
const List = types.List;

pub fn map_builtin(exec_ctx: *ExecContext, args: [][]const u8) Value {
    const input = getInputList(exec_ctx) catch return Value{ .err = ShellError.TypeMismatch };
    const spec = stream_ops.parseMapSpec(args[1..]) catch |err| return Value{ .err = err };
    const out = stream_ops.mapValues(exec_ctx.allocator, input, spec) catch |err| return Value{ .err = err };
    return returnList(exec_ctx, out);
}

pub fn reduce_builtin(exec_ctx: *ExecContext, args: [][]const u8) Value {
    if (args.len < 2) return Value{ .err = ShellError.MissingArgument };
    const input = getInputList(exec_ctx) catch return Value{ .err = ShellError.TypeMismatch };
    const op = args[1];
    const delim: ?[]const u8 = if (args.len > 2) args[2] else null;
    const reduced = stream_ops.reduceValues(exec_ctx.allocator, input, op, delim) catch |err| return Value{ .err = err };
    return returnValue(exec_ctx, reduced);
}

pub fn lines_builtin(exec_ctx: *ExecContext, args: [][]const u8) Value {
    _ = args;
    const text = getInputText(exec_ctx) catch return Value{ .err = ShellError.MissingInput };
    const out = stream_ops.linesOfText(exec_ctx.allocator, text) catch |err| return Value{ .err = err };
    return returnList(exec_ctx, out);
}

pub fn split_builtin(exec_ctx: *ExecContext, args: [][]const u8) Value {
    const text = getInputText(exec_ctx) catch return Value{ .err = ShellError.MissingInput };
    const delim = if (args.len > 1) args[1] else null;
    const out = stream_ops.splitText(exec_ctx.allocator, text, delim) catch |err| return Value{ .err = err };
    return returnList(exec_ctx, out);
}

pub fn join_builtin(exec_ctx: *ExecContext, args: [][]const u8) Value {
    const input = getInputList(exec_ctx) catch return Value{ .err = ShellError.TypeMismatch };
    const delim = if (args.len > 1) args[1] else "";
    const joined = stream_ops.joinValues(exec_ctx.allocator, input, delim) catch |err| return Value{ .err = err };
    return returnValue(exec_ctx, Value{ .text = joined });
}

fn getInputList(exec_ctx: *ExecContext) !*List {
    return switch (exec_ctx.input) {
        .value => |v| switch (v) {
            .list => |l| l,
            else => ShellError.TypeMismatch,
        },
        else => ShellError.TypeMismatch,
    };
}

fn getInputText(exec_ctx: *ExecContext) ![]const u8 {
    return switch (exec_ctx.input) {
        .value => |v| try v.toString(exec_ctx.allocator),
        .stream => |stdin| if (exec_ctx.is_pipe)
            helpers.pipeReadAll(exec_ctx.shell_ctx.io.*, exec_ctx.allocator, stdin)
        else
            helpers.fileReadAll(exec_ctx.shell_ctx.io.*, exec_ctx.allocator, stdin),
        .none => ShellError.MissingInput,
    };
}

fn returnList(exec_ctx: *ExecContext, list: *List) Value {
    return switch (exec_ctx.output) {
        .stream => {
            const rendered = transforms.renderValue(exec_ctx, .{ .list = list });
            if (rendered == .err) return rendered;
            return Value{ .void = {} };
        },
        .capture => Value{ .list = list },
        .none => Value{ .void = {} },
    };
}

fn returnValue(exec_ctx: *ExecContext, value: Value) Value {
    return switch (exec_ctx.output) {
        .stream => {
            const rendered = transforms.renderValue(exec_ctx, value);
            if (rendered == .err) return rendered;
            return Value{ .void = {} };
        },
        .capture => value,
        .none => Value{ .void = {} },
    };
}
