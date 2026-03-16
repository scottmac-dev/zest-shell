// GLOBAL CONFIG CONSTANTS
const PathType = @import("../../lib-core/core/types.zig").PathType;

/// Terminal UI colours, basic colors only
pub const Color = enum { reset, red, green, yellow, blue, magenta, cyan, white };

// FORMATTED WITH COLOR = "\x1b[{s}m{s}\x1b[0m",.{ ansi, text },
pub fn getAnsiColorStr(
    color: Color,
) []const u8 {
    switch (color) {
        .red => return "31",
        .green => return "32",
        .yellow => return "33",
        .blue => return "34",
        .magenta => return "35",
        .cyan => return "36",
        .white => return "37",
        else => return "0",
    }
}

pub const CONFIG_DIR = "~/.config/zest";
pub const HIST_FILE = "~/.config/zest/history.txt";
pub const HIST_FILE_PATH_TYPE = PathType.home;
pub const ENV_FILE = "~/.config/zest/env.txt";
pub const ENV_FILE_PATH_TYPE = PathType.home;
pub const CONFIG_FILE = "~/.config/zest/config.txt";
pub const CONFIG_FILE_PATH_TYPE = PathType.home;
pub const LAST_LAUNCH_FILE = "~/.config/zest/last_launch.txt";
pub const VERSION = "0.0.1";
pub const SHELL_NAME = "ZEST";
pub const UserHandleColor = Color.cyan;
pub const CwdHandleColor = Color.green;
pub const GitBranchColor = Color.magenta;
pub const BuiltinCommandColor = Color.cyan;
pub const CommandColor = Color.yellow;
pub const SeparatorColor = Color.magenta;
pub const DEFAULT_PROMPT_TEMPLATE = "${user}:${cwd}${git}${status}${prompt_char} ";
