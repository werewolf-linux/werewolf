//! paperless-init makes Paperless's directories, then waits until Valkey's
//! socket answers. migrate runs after this, and it will not start a
//! database Valkey cannot queue for.

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const linux = std.os.linux;

const data = "/data/svc/paperless";
const sock = "/run/svc/valkey/valkey.sock";

const dirs = [_][]const u8{
    data ++ "/media/documents/originals",
    data ++ "/media/documents/archive",
    data ++ "/media/documents/thumbnails",
    data ++ "/media/documents/share_link_bundles",
    data ++ "/index",
    data ++ "/log",
    data ++ "/consume",
    data ++ "/llm_index",
    "/run/svc/paperless/tmp",
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    run(io) catch |err| {
        say(io, "{s}", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn run(io: Io) !void {
    for (dirs) |path| try ensure(io, path);
    var i: u32 = 0;
    while (i < 60) : (i += 1) {
        if (valkeyUp()) {
            say(io, "valkey is up", .{});
            return;
        }
        var req: linux.timespec = .{ .sec = 1, .nsec = 0 };
        _ = linux.nanosleep(&req, null);
    }
    say(io, "valkey is not listening", .{});
    return error.NoValkey;
}

fn ensure(io: Io, path: []const u8) !void {
    Dir.cwd().createDirPath(io, path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

fn valkeyUp() bool {
    const fd = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(fd) != .SUCCESS) return false;
    defer _ = linux.close(@intCast(fd));
    var addr: linux.sockaddr.un = .{ .family = linux.AF.UNIX, .path = @splat(0) };
    @memcpy(addr.path[0..sock.len], sock);
    return linux.errno(linux.connect(
        @intCast(fd),
        @ptrCast(&addr),
        @sizeOf(linux.sockaddr.un),
    )) == .SUCCESS;
}

fn say(io: Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const line = std.mem.print(&buf, "paperless-init: " ++ fmt ++ "\n", args) catch return;
    Io.File.stdout().writeStreamingAll(io, line) catch {};
}

test "the directories are the library, the queue's scratch, and the consume folder" {
    try std.testing.expectEqual(9, dirs.len);
    try std.testing.expectEqualStrings(data ++ "/consume", dirs[6]);
    try std.testing.expectEqualStrings("/run/svc/paperless/tmp", dirs[8]);
}
