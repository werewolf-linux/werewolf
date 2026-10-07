//! seal-watch: answer for the machine seal what its promises do not allow.
//!
//! The seal (cmd/init), on PID 1, allows the system calls of the machine's
//! promises and hands the rest to this program through a seccomp listener
//! (SECCOMP_RET_USER_NOTIF), passed over a socket on stdin at boot. Each
//! service holds itself to its own pledge with a filter of its own that
//! refuses with ENOSYS (leash, after dropping CAP_SYS_ADMIN, cannot make a
//! listener), so what reaches here is what a program running under the
//! machine seal alone, werewolf's own, makes outside the machine's
//! promises. It answers each:
//!
//!     enforce   refused as if the kernel had no such call (ENOSYS); said
//!               once, with the promise that would allow it, and counted in
//!               /run/werewolf/seal/refused, which `seal` shows:
//!               seal-watch: {"event":"refused","call":"keyctl","promise":"never","pid":97}
//!     learn     allowed, and said once, with the program that made it, so
//!               make seal-learn can read what each form needs. A learning
//!               machine installs no per-service filters either, so every
//!               call reaches here:
//!               seal-watch:
//! {"event":"learned","call":"memfd_create","promise":"memfd","exe":"/usr/bin/node"}
//!
//! What no promise brings (lib/seal.zig, never) is refused either way.
//! init decides to learn: only on a DEV=1 build, never released, booted
//! with werewolf.seal=learn.
//!
//! init starts it before the seal, so it is not under it. Enforcing, it
//! becomes nobody with no capabilities, under no_new_privs and a filter of
//! its own that allows the calls of its loop and nothing else. Learning, it
//! stays root, to read each caller's /proc/PID/exe.

const std = @import("std");
const builtin = @import("builtin");
const seal = @import("seal");
const linux = std.os.linux;

const nobody = 65534;

pub fn main() void {
    var mode_buf: [8]u8 = undefined;
    const got = receiveListener(&mode_buf) orelse {
        say("no listener from init; unlisted calls are refused unsaid", .{});
        linux.exit_group(1);
    };
    _ = linux.close(0);
    const fd = got.fd;
    const learn = got.mode.len > 0 and got.mode[0] == 'l';
    // runit's stage 3 asks every process to stop; refusals still come until
    // the machine is down, so this one ignores the signals and waits for the
    // KILL that follows.
    const ignore: linux.Sigaction = .{
        .handler = .{ .handler = linux.SIG.IGN },
        .mask = linux.sigemptyset(),
        .flags = 0,
    };
    for ([_]linux.SIG{ .TERM, .HUP, .INT, .PIPE }) |sig| _ = linux.sigaction(sig, &ignore, null);
    const table = linux.open(
        seal.refused_path,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true, .NOFOLLOW = true },
        0o644,
    );
    if (linux.errno(table) != .SUCCESS)
        say("cannot write {s}: {s}", .{ seal.refused_path, @tagName(linux.errno(table)) });
    if (!learn) confine() catch |err| {
        say("cannot confine itself: {s}; unlisted calls are refused unsaid", .{@errorName(err)});
        linux.exit_group(1);
    };
    say("{{\"event\":\"start\",\"mode\":\"{s}\"}}", .{if (learn) "learn" else "enforce"});
    serve(fd, learn, if (linux.errno(table) == .SUCCESS) @intCast(table) else -1);
}

const Received = struct { fd: i32, mode: []const u8 };

/// The listener, sent by init over the socket on stdin (SCM_RIGHTS), with
/// one byte: l to learn, e to enforce.
fn receiveListener(mode_buf: *[8]u8) ?Received {
    var iov = [_]std.posix.iovec{.{ .base = mode_buf, .len = mode_buf.len }};
    var control: [cmsg_space]u8 align(8) = @splat(0);
    var msg: linux.msghdr = .{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = 1,
        .control = &control,
        .controllen = control.len,
        .flags = 0,
    };
    const n = linux.recvmsg(0, &msg, linux.MSG.CMSG_CLOEXEC);
    if (linux.errno(n) != .SUCCESS or n == 0) return null;
    const e = builtin.cpu.arch.endian();
    if (msg.controllen < 20 or
        std.mem.readInt(i32, control[8..12], e) != linux.SOL.SOCKET or
        std.mem.readInt(i32, control[12..16], e) != scm_rights) return null;
    return .{ .fd = std.mem.readInt(i32, control[16..20], e), .mode = mode_buf[0..n] };
}

const scm_rights = 1;
/// struct cmsghdr (a size_t and two ints) and one int, aligned.
const cmsg_space = 24;

/// nobody, no capabilities, no_new_privs, and a filter allowing only what
/// serve calls.
fn confine() !void {
    if (linux.errno(linux.setgroups(0, &[_]linux.gid_t{})) != .SUCCESS) return error.Groups;
    if (linux.errno(linux.setresgid(nobody, nobody, nobody)) != .SUCCESS) return error.Gid;
    if (linux.errno(linux.setresuid(nobody, nobody, nobody)) != .SUCCESS) return error.Uid;
    if (linux.errno(linux.prctl(@backingInt(linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0)) != .SUCCESS)
        return error.NoNewPrivs;
    const prog = extern struct { len: u16, filter: [*]const Filter }{
        .len = own_filter.len,
        .filter = &own_filter,
    };
    if (linux.errno(linux.seccomp(1, 0, &prog)) != .SUCCESS) return error.Seccomp;
}

const Filter = extern struct { code: u16, jt: u8, jf: u8, k: u32 };

/// What serve and say call, enforcing; anything else kills this program.
const own_calls = [_]linux.SYS{
    .ioctl,      .write, .pwrite64,     .ftruncate, .clock_gettime,
    .exit_group, .exit,  .rt_sigreturn,
};

const own_filter = blk: {
    var f: [1 + 2 * own_calls.len + 1]Filter = undefined;
    f[0] = .{ .code = 0x20, .jt = 0, .jf = 0, .k = 0 }; // load seccomp_data.nr
    for (own_calls, 0..) |sys, i| {
        f[1 + 2 * i] = .{ .code = 0x15, .jt = 0, .jf = 1, .k = @intCast(@backingInt(sys)) };
        f[2 + 2 * i] = .{ .code = 0x06, .jt = 0, .jf = 0, .k = 0x7fff0000 }; // allow
    }
    f[f.len - 1] = .{ .code = 0x06, .jt = 0, .jf = 0, .k = 0x80000000 }; // kill the process
    break :blk f;
};

/// struct seccomp_notif, and struct seccomp_notif_resp.
const Notif = extern struct {
    id: u64,
    pid: u32,
    flags: u32,
    nr: i32,
    arch: u32,
    ip: u64,
    args: [6]u64,
};
const Resp = extern struct { id: u64, val: i64, @"error": i32, flags: u32 };

/// _IOWR('!', 0, struct seccomp_notif) and _IOWR('!', 1, struct seccomp_notif_resp).
const notif_recv: u32 = 0xc0000000 | @as(u32, @sizeOf(Notif)) << 16 | 0x21 << 8 | 0;
const notif_send: u32 = 0xc0000000 | @as(u32, @sizeOf(Resp)) << 16 | 0x21 << 8 | 1;
const flag_continue: u32 = 1;

const max_rows = 512;
const max_learned = 4096;

/// One call refused this boot.
const Row = struct { nr: u32, count: u64, pid: u32, first: i64 };

fn serve(fd: i32, learn: bool, table: i32) noreturn {
    var rows: [max_rows]Row = undefined;
    var n_rows: usize = 0;
    var learned: [max_learned]u64 = undefined;
    var n_learned: usize = 0;
    var buf: [64 << 10]u8 = undefined;
    while (true) {
        var req: Notif = std.mem.zeroes(Notif);
        const rc = linux.ioctl(fd, notif_recv, @intFromPtr(&req));
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .INTR, .NOENT => continue, // the caller died while waiting
            else => |e| {
                say("listener gone: {s}", .{@tagName(e)});
                linux.exit_group(1);
            },
        }
        const nr: u32 = @bitCast(req.nr);
        const allow = learn and !isNever(nr);
        var exe_buf: [256]u8 = undefined;
        const exe = if (allow) exeOf(req.pid, &exe_buf) else "";
        const resp: Resp = .{
            .id = req.id,
            .val = 0,
            .@"error" = if (allow) 0 else -@as(i32, @backingInt(linux.E.NOSYS)),
            .flags = if (allow) flag_continue else 0,
        };
        _ = linux.ioctl(fd, notif_send, @intFromPtr(&resp));
        if (allow) {
            const key = std.hash.Wyhash.hash(nr, exe);
            if (std.mem.findScalar(u64, learned[0..n_learned], key) != null) continue;
            if (n_learned < learned.len) {
                learned[n_learned] = key;
                n_learned += 1;
            }
            say(
                "{{\"event\":\"learned\",\"call\":\"{s}\",\"promise\":\"{s}\",\"exe\":\"{s}\"}}",
                .{ callName(nr), promiseName(nr), exe },
            );
            continue;
        }
        const row = for (rows[0..n_rows]) |*r| {
            if (r.nr == nr) break r;
        } else blk: {
            say(
                "{{\"event\":\"refused\",\"call\":\"{s}\",\"promise\":\"{s}\",\"pid\":{d}}}",
                .{ callName(nr), promiseName(nr), req.pid },
            );
            if (n_rows == max_rows) continue;
            var ts: linux.timespec = undefined;
            _ = linux.clock_gettime(.REALTIME, &ts);
            rows[n_rows] = .{ .nr = nr, .count = 0, .pid = req.pid, .first = ts.sec };
            n_rows += 1;
            break :blk &rows[n_rows - 1];
        };
        row.count += 1;
        row.pid = req.pid;
        if (table >= 0) {
            const text = tableText(&buf, rows[0..n_rows]);
            _ = linux.pwrite(table, text.ptr, text.len, 0);
            _ = linux.ftruncate(table, @intCast(text.len));
        }
    }
}

/// The refused table: CALL COUNT LAST_PID FIRST_SECONDS PROMISE a line.
fn tableText(buf: []u8, rows: []const Row) []const u8 {
    var out: std.Io.Writer = .fixed(buf);
    for (rows) |r| out.print("{s} {d} {d} {d} {s}\n", .{
        callName(r.nr), r.count, r.pid, r.first, promiseName(r.nr),
    }) catch break;
    return out.buffered();
}

fn isNever(nr: u32) bool {
    for (seal.never) |sys| if (@backingInt(sys) == nr) return true;
    return false;
}

/// The promise that would allow the call, or never, or none.
fn promiseName(nr: u32) []const u8 {
    if (isNever(nr)) return "never";
    var it = seal.promisesOf(nr).iterator();
    return if (it.next()) |p| @tagName(p) else "none";
}

/// The call's name on this architecture, or its number.
fn callName(nr: u32) []const u8 {
    for (std.enums.values(linux.SYS)) |sys| if (@backingInt(sys) == nr) return @tagName(sys);
    const S = struct {
        var buf: [16]u8 = undefined;
    };
    return std.mem.print(&S.buf, "{d}", .{nr}) catch "?";
}

/// /proc/PID/exe, as plain characters only, or "?" for a process gone.
fn exeOf(pid: u32, buf: *[256]u8) []const u8 {
    var path: [32]u8 = undefined;
    const p = std.mem.print(path[0 .. path.len - 1], "/proc/{d}/exe", .{pid}) catch return "?";
    path[p.len] = 0;
    const n = linux.readlink(@ptrCast(&path), buf, buf.len);
    if (linux.errno(n) != .SUCCESS) return "?";
    for (buf[0..n]) |*c| if (c.* < 0x20 or c.* == '"' or c.* == '\\' or c.* > 0x7e) {
        c.* = '?';
    };
    return buf[0..n];
}

var line_buf: [512]u8 = undefined;

/// One line on the console.
fn say(comptime fmt: []const u8, args: anytype) void {
    const s = std.mem.print(&line_buf, "seal-watch: " ++ fmt ++ "\n", args) catch return;
    _ = linux.write(1, s.ptr, s.len);
}

const testing = std.testing;

test own_filter {
    try testing.expectEqual(1 + 2 * own_calls.len + 1, own_filter.len);
    try testing.expectEqual(@as(u32, 0x80000000), own_filter[own_filter.len - 1].k);
    try testing.expect(std.mem.findScalar(linux.SYS, &own_calls, .ioctl) != null);
    try testing.expect(std.mem.findScalar(linux.SYS, &own_calls, .openat) == null);
}

test callName {
    try testing.expectEqualStrings("read", callName(@intCast(@backingInt(linux.SYS.read))));
    try testing.expectEqualStrings("4000", callName(4000));
}

test promiseName {
    try testing.expectEqualStrings(
        "memfd",
        promiseName(@intCast(@backingInt(linux.SYS.memfd_create))),
    );
    try testing.expectEqualStrings("never", promiseName(@intCast(@backingInt(linux.SYS.bpf))));
    try testing.expectEqualStrings("none", promiseName(@intCast(@backingInt(linux.SYS.ptrace))));
}

test tableText {
    const rows = [_]Row{.{
        .nr = @intCast(@backingInt(linux.SYS.keyctl)),
        .count = 2,
        .pid = 97,
        .first = 1791335742,
    }};
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("keyctl 2 97 1791335742 never\n", tableText(&buf, &rows));
}

test "ioctl numbers" {
    // As the kernel's uapi header has them, for 64-bit architectures.
    try testing.expectEqual(@as(u32, 0xc0502100), notif_recv);
    try testing.expectEqual(@as(u32, 0xc0182101), notif_send);
}
