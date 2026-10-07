//! ssh-host-key: a leashed sshd's host key, made on the machine's first
//! boot and kept, as a distribution's first boot makes /etc/ssh's.
//!
//!     ssh-host-key KEY
//!
//! leash runs it as a service's `before`, as the service's user, inside its
//! Landlock rules. KEY is in the service's /data directory, since the root
//! is read-only: if it is there, it stands; if not, ssh-keygen makes an
//! Ed25519 key there, once. Without /data, or with /data in RAM, there is
//! nowhere to keep one, and a key made each boot would change the machine's
//! identity each boot, so the service stays down and says why.
//!
//! Every start logs the key's fingerprint and public half, for an operator
//! to pin (werewolf console NAME), never the private half.

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;
const linux = std.os.linux;

const keygen = "/usr/bin/ssh-keygen";

pub fn main(init: std.process.Init) void {
    const io = init.io;
    const gpa = init.arena.allocator();
    const args = init.minimal.args.toSlice(gpa) catch std.process.exit(1);
    if (args.len != 2 or !std.fs.path.isAbsolute(args[1])) {
        log(io, .{ .event = "host-key", .why = "usage: ssh-host-key KEY" });
        std.process.exit(1);
    }
    run(io, gpa, args[1]) catch |err| {
        log(io, .{ .event = "host-key", .key = args[1], .why = @errorName(err) });
        std.process.exit(1);
    };
}

fn run(io: Io, gpa: Allocator, key: []const u8) !void {
    var made = false;
    Dir.cwd().access(io, key, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            Dir.cwd().access(io, std.fs.path.dirname(key) orelse "/", .{}) catch
                return error.NoDataToKeepItIn;
            if (onRam("/data")) return error.DataIsRam;
            const r = try std.process.run(gpa, io, .{
                .argv = &.{ keygen, "-q", "-t", "ed25519", "-N", "", "-C", "werewolf", "-f", key },
            });
            if (r.term != .exited or r.term.exited != 0) return error.KeygenFailed;
            made = true;
        },
        else => return err,
    };
    const pub_path = try gpa.print("{s}.pub", .{key});
    const public = Dir.cwd().readFileAlloc(io, pub_path, gpa, .limited(16 << 10)) catch
        return error.NoPublicKey;
    const r = try std.process.run(gpa, io, .{ .argv = &.{ keygen, "-l", "-f", pub_path } });
    if (r.term != .exited or r.term.exited != 0) return error.KeygenFailed;
    log(io, .{
        .event = "host-key",
        .key = key,
        .from = if (made) "new, kept in /data" else "kept in /data",
        .fingerprint = fingerprintOf(r.stdout) orelse return error.KeygenFailed,
        .public = std.mem.trim(u8, public, " \n"),
    });
}

/// The SHA256:... word of ssh-keygen -l's line: BITS FINGERPRINT COMMENT (TYPE).
fn fingerprintOf(line: []const u8) ?[]const u8 {
    var words = std.mem.tokenizeAny(u8, line, " \n");
    _ = words.next() orelse return null;
    const f = words.next() orelse return null;
    return if (std.mem.startsWith(u8, f, "SHA256:")) f else null;
}

/// Whether path is on RAM (tmpfs), so nothing kept there outlives the boot:
/// /data, where a machine has no disk for it.
fn onRam(path: [*:0]const u8) bool {
    // struct statfs, whose first word is the filesystem's type.
    var buf: [128]u8 align(8) = undefined;
    const rc = linux.syscall2(.statfs, @intFromPtr(path), @intFromPtr(&buf));
    if (linux.errno(rc) != .SUCCESS) return false;
    return std.mem.readInt(u64, buf[0..8], .little) == 0x01021994; // TMPFS_MAGIC
}

fn log(io: Io, fields: anytype) void {
    var buf: [1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    w.writeAll("ssh-host-key: ") catch return;
    std.json.Stringify.value(fields, .{ .emit_null_optional_fields = false }, &w) catch return;
    w.writeByte('\n') catch return;
    Io.File.stdout().writeStreamingAll(io, w.buffered()) catch {};
}

test fingerprintOf {
    try std.testing.expectEqualStrings(
        "SHA256:3zl1uBjF3f/DiD5U6ZwuudMcXNBxcp6d4KoUd2tvbX4",
        fingerprintOf(
            "256 SHA256:3zl1uBjF3f/DiD5U6ZwuudMcXNBxcp6d4KoUd2tvbX4 werewolf (ED25519)\n",
        ).?,
    );
    try std.testing.expectEqual(null, fingerprintOf("garbage\n"));
}
