//! leash-reap: a leashed service's ./finish. When runsv stops the service
//! -- on `sv down`, a crash, a restart, or shutdown -- it runs this, which
//! kills the service's cgroup, and so its whole process tree, any detached
//! child included, by writing cgroup.kill. The cgroup is
//! /run/cgroup/svc/NAME, where NAME is the service directory this runs in
//! (cmd/init makes the hierarchy, cmd/leash joins each service to its leaf).
//!
//! runsv runs ./finish as root, in the service's directory, with the run's
//! exit status as arguments, which this ignores. Where there is no cgroup2
//! (an older kernel; cmd/init said so at boot), there is nothing to kill
//! and it does nothing. It is one of werewolf's own tiny programs
//! (docs/programs.md): no arguments it trusts, one write, and done.

const std = @import("std");
const linux = std.os.linux;

pub fn main() void {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = linux.getcwd(&cwd_buf, cwd_buf.len);
    if (linux.errno(cwd) != .SUCCESS) return;
    const path = std.mem.sliceTo(cwd_buf[0..], 0);
    const name = std.fs.path.basename(path);
    // Refuse a name that is not a plain service name, so the path is only
    // ever a leaf of /run/cgroup/svc.
    if (name.len == 0 or name.len > 64) return;
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return;

    var kill_buf: [128]u8 = undefined;
    const written = std.mem.print(
        kill_buf[0 .. kill_buf.len - 1],
        "/run/cgroup/svc/{s}/cgroup.kill",
        .{name},
    ) catch return;
    kill_buf[written.len] = 0;
    const kill: [:0]const u8 = kill_buf[0..written.len :0];
    const fd = linux.open(kill, .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return; // no cgroup: nothing to reap
    defer _ = linux.close(@intCast(fd));
    _ = linux.write(@intCast(fd), "1", 1);
}
