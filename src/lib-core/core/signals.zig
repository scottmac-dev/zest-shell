// Keeps all repeated posix signals and helpers in a single file for clean code and simplicity
const std = @import("std");

// default action = allow posix signals to interupt
pub const dfl_act = std.posix.Sigaction{
    .handler = .{ .handler = std.posix.SIG.DFL },
    .mask = std.mem.zeroes(std.posix.sigset_t),
    .flags = 0,
};

// ignore action = shell ignores posix signals
pub const ign_act = std.posix.Sigaction{
    .handler = .{ .handler = std.posix.SIG.IGN },
    .mask = std.mem.zeroes(std.posix.sigset_t),
    .flags = 0,
};

/// Decode raw Linux waitpid status into a shell exit code
pub fn waitStatusToExitCode(status: u32) u8 {
    if (std.os.linux.W.IFEXITED(status)) {
        return @intCast(std.os.linux.W.EXITSTATUS(status));
    } else if (std.os.linux.W.IFSIGNALED(status)) {
        const sig = @intFromEnum(std.os.linux.W.TERMSIG(status));
        return 128 + @as(u8, @intCast(sig));
    } else if (std.os.linux.W.IFSTOPPED(status)) {
        return 148;
    }
    return 1;
}
