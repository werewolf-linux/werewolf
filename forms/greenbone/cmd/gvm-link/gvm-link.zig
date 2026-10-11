//! gvm-link carries gvmd's socket to gsad. The two images do not share a
//! directory, and gsad speaks to the manager only over a Unix socket.
//!
//!     gvm-link
//!
//! /etc/werewolf/gvm-link names the two sockets, on the host:
//!
//!     listen /run/svc/gsad/run/manager.sock
//!     dial /run/svc/gvmd/run/gvmd.sock
//!
//! runit starts it as root (forms/greenbone/rootfs/etc/sv/gvm-link/run).
//! It binds the listen socket, drops to _glink, and from then on only
//! accepts, connects and copies bytes. gvmd's socket is mode 0666 so
//! _glink can open it; GMP still wants the administrator password.

const std = @import("std");
const sandbox = @import("sandbox");
const Io = std.Io;
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

const config_path = "/etc/werewolf/gvm-link";
const drop_user = "_glink";

const Config = struct { listen: []const u8, dial: []const u8 };

const SockaddrUn = extern struct {
    family: u16,
    path: [108]u8,
};

pub fn main(init: std.process.Init) void {
    const io = init.io;
    run(io, init.arena.allocator()) catch |err| {
        say(io, "{{\"event\":\"down\",\"why\":\"{s}\"}}", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn run(io: Io, gpa: Allocator) !void {
    const cfg = try parse(try readFile(io, gpa, config_path, 512));
    const me = try account(io, gpa, drop_user);
    const listen_fd = try bindListen(cfg.listen);
    say(io, "{{\"event\":\"start\",\"listen\":\"{s}\",\"dial\":\"{s}\"}}", .{ cfg.listen, cfg.dial });
    try sandbox.dropTo(me.uid, null);
    var filter: sandbox.Filter = .{};
    inline for ([_][]const u8{
        "accept",   "accept4", "socket", "connect", "read",     "write",
        "close",    "poll",    "ppoll",  "exit",    "exit_group", "futex",
        "mmap",     "mprotect", "munmap", "brk",    "clone",    "clone3",
        "rt_sigaction", "rt_sigreturn", "clock_gettime", "gettid",
        "set_robust_list", "rseq", "madvise", "getrandom",
    }) |name| filter.allow(name);
    try filter.install();
    while (true) {
        const got = linux.accept4(listen_fd, null, null, linux.SOCK.CLOEXEC);
        if (linux.errno(got) == .INTR) continue;
        if (linux.errno(got) != .SUCCESS) linux.exit_group(1);
        const client: i32 = @intCast(got);
        const dial = cfg.dial;
        const thread = std.Thread.spawn(.{}, shuttle, .{ client, dial }) catch {
            _ = linux.close(client);
            continue;
        };
        thread.detach();
    }
}

fn shuttle(client: i32, dial: []const u8) void {
    const up = connectTo(dial) catch {
        _ = linux.close(client);
        return;
    };
    var buf: [8192]u8 = undefined;
    var fds = [2]linux.pollfd{
        .{ .fd = client, .events = linux.POLL.IN, .revents = 0 },
        .{ .fd = up, .events = linux.POLL.IN, .revents = 0 },
    };
    while (true) {
        fds[0].revents = 0;
        fds[1].revents = 0;
        const n = linux.poll(&fds, 2, -1);
        if (linux.errno(n) == .INTR) continue;
        if (linux.errno(n) != .SUCCESS) break;
        if (fds[0].revents & (linux.POLL.IN | linux.POLL.HUP | linux.POLL.ERR) != 0) {
            if (!copySome(client, up, &buf)) break;
        }
        if (fds[1].revents & (linux.POLL.IN | linux.POLL.HUP | linux.POLL.ERR) != 0) {
            if (!copySome(up, client, &buf)) break;
        }
    }
    _ = linux.close(client);
    _ = linux.close(up);
}

fn copySome(from: i32, to: i32, buf: []u8) bool {
    const n = linux.read(from, buf.ptr, buf.len);
    if (linux.errno(n) == .INTR) return true;
    if (linux.errno(n) != .SUCCESS or n == 0) return false;
    var off: usize = 0;
    while (off < n) {
        const w = linux.write(to, buf[off..n].ptr, n - off);
        if (linux.errno(w) == .INTR) continue;
        if (linux.errno(w) != .SUCCESS or w == 0) return false;
        off += w;
    }
    return true;
}

fn bindListen(path: []const u8) !i32 {
    if (std.fs.path.dirname(path)) |dir| {
        var i: u8 = 0;
        while (i < 60) : (i += 1) {
            var dz: [129]u8 = undefined;
            const rc = linux.access(try z(dir, &dz), linux.X_OK);
            if (linux.errno(rc) == .SUCCESS) break;
            _ = linux.nanosleep(&.{ .sec = 1, .nsec = 0 }, null);
        }
    }
    var pz: [129]u8 = undefined;
    const pathz = try z(path, &pz);
    _ = linux.unlink(pathz);
    _ = linux.syscall1(.umask, 0o111);
    const rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) return error.Socket;
    const fd: i32 = @intCast(rc);
    var addr: SockaddrUn = .{ .family = linux.AF.UNIX, .path = @splat(0) };
    if (path.len + 1 > addr.path.len) return error.BadConfig;
    @memcpy(addr.path[0..path.len], path);
    const len: linux.socklen_t = @intCast(2 + path.len + 1);
    if (linux.errno(linux.bind(fd, @ptrCast(&addr), len)) != .SUCCESS) return error.Bind;
    if (linux.errno(linux.fchmod(fd, 0o666)) != .SUCCESS) return error.Mode;
    if (linux.errno(linux.listen(fd, 16)) != .SUCCESS) return error.Listen;
    return fd;
}

fn connectTo(path: []const u8) !i32 {
    const rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) return error.Socket;
    const fd: i32 = @intCast(rc);
    var addr: SockaddrUn = .{ .family = linux.AF.UNIX, .path = @splat(0) };
    if (path.len + 1 > addr.path.len) return error.BadConfig;
    @memcpy(addr.path[0..path.len], path);
    const len: linux.socklen_t = @intCast(2 + path.len + 1);
    if (linux.errno(linux.connect(fd, @ptrCast(&addr), len)) != .SUCCESS) {
        _ = linux.close(fd);
        return error.Connect;
    }
    return fd;
}

fn parse(text: []const u8) !Config {
    var listen_at: ?[]const u8 = null;
    var dial: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse return error.BadConfig;
        const key = line[0..sp];
        const value = std.mem.trim(u8, line[sp + 1 ..], " \t");
        if (value.len == 0 or value[0] != '/' or value.len > 108) return error.BadConfig;
        if (std.mem.eql(u8, key, "listen")) {
            if (listen_at != null) return error.BadConfig;
            listen_at = value;
        } else if (std.mem.eql(u8, key, "dial")) {
            if (dial != null) return error.BadConfig;
            dial = value;
        } else return error.BadConfig;
    }
    return .{
        .listen = listen_at orelse return error.BadConfig,
        .dial = dial orelse return error.BadConfig,
    };
}

const Account = struct { uid: u32, gid: u32 };

fn account(io: Io, gpa: Allocator, name: []const u8) !Account {
    const text = try readFile(io, gpa, "/etc/passwd", 1 << 20);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var f = std.mem.splitScalar(u8, line, ':');
        const user = f.next() orelse continue;
        if (!std.mem.eql(u8, user, name)) continue;
        _ = f.next();
        const uid = f.next() orelse return error.NoUser;
        const gid = f.next() orelse return error.NoUser;
        return .{
            .uid = std.fmt.parseInt(u32, uid, 10) catch return error.NoUser,
            .gid = std.fmt.parseInt(u32, gid, 10) catch return error.NoUser,
        };
    }
    return error.NoUser;
}

fn readFile(io: Io, gpa: Allocator, path: []const u8, limit: usize) ![]const u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(limit));
}

fn z(s: []const u8, buf: []u8) ![*:0]u8 {
    if (s.len + 1 > buf.len) return error.BadConfig;
    @memcpy(buf[0..s.len], s);
    buf[s.len] = 0;
    return buf[0..s.len :0];
}

fn say(io: Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const line = std.mem.print(&buf, "gvm-link: " ++ fmt ++ "\n", args) catch return;
    Io.File.stdout().writeStreamingAll(io, line) catch {};
}

test "parse reads the two sockets" {
    const cfg = try parse(
        \\# both on the host
        \\listen /run/svc/gsad/run/manager.sock
        \\dial /run/svc/gvmd/run/gvmd.sock
    );
    try std.testing.expectEqualStrings("/run/svc/gsad/run/manager.sock", cfg.listen);
    try std.testing.expectEqualStrings("/run/svc/gvmd/run/gvmd.sock", cfg.dial);
}

test "parse refuses a relative path and a second listen" {
    try std.testing.expectError(error.BadConfig, parse("listen relative\n"));
    try std.testing.expectError(error.BadConfig, parse("listen /a\nlisten /b\ndial /c\n"));
}
