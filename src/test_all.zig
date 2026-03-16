comptime {
    _ = @import("lib-core/core/builtins.zig");
    _ = @import("lib-core/core/helpers.zig");
    _ = @import("lib-core/core/lexer.zig");
    _ = @import("lib-core/core/types.zig");
    _ = @import("lib-core/engine.zig");
    _ = @import("main.zig");
    _ = @import("lib-serialize/base64.zig");
    _ = @import("lib-serialize/json.zig");
    _ = @import("shell/interactive/autocomplete.zig");
    _ = @import("shell/interactive/history.zig");
    _ = @import("shell/interactive/input_raw.zig");
    _ = @import("shell/interactive/prompt.zig");
    _ = @import("shell/interactive/session_config.zig");
}
