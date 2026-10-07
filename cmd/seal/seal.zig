//! seal: say what the machine and each service promised, and what was
//! refused.
//!
//!     $ seal
//!     seal: enforcing; the machine promises stdio rpath wpath inet unix ...
//!     services:
//!       app        stdio rpath inet listen
//!       nginx      stdio rpath inet listen
//!     refused this boot:
//!       keyctl         never   1 time, last by pid 97, first at 2026-10-07 01:14:03 UTC
//!     never allowed: bpf perf_event_open init_module ...
//!
//! A refusal's promise is the one that would have allowed the call. These
//! are the machine seal's: a leashed service holds itself to its pledge and
//! refuses the rest silently, so what is counted here is what werewolf's
//! own programs made outside the machine's promises
//! (docs/design/pledge.md, System calls: promises). It reads what init wrote
//! as it sealed the machine, the services' files, and what seal-watch
//! counts; it changes nothing, and anyone may run it.

const std = @import("std");
const seal = @import("seal");
const linux = std.os.linux;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();
    const policy = std.Io.Dir.cwd().readFileAlloc(
        io,
        seal.policy_path,
        gpa,
        .limited(64 << 10),
    ) catch {
        std.debug.print(
            "seal: no {s}: this machine was not sealed by werewolf's init\n",
            .{seal.policy_path},
        );
        std.process.exit(1);
    };
    const refused = std.Io.Dir.cwd().readFileAlloc(
        io,
        seal.refused_path,
        gpa,
        .limited(1 << 20),
    ) catch "";

    var services: std.ArrayList(Pledged) = .empty;
    if (std.Io.Dir.cwd().openDir(io, "/etc/sv", .{ .iterate = true })) |d| {
        var dir = d;
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |e| {
            const path = try gpa.print("{s}/service", .{e.name});
            const text = dir.readFileAlloc(io, path, gpa, .limited(64 << 10)) catch continue;
            try services.append(
                gpa,
                .{ .name = try gpa.dupe(u8, e.name), .words = pledgeOf(text) },
            );
        }
    } else |_| {}
    std.mem.sort(Pledged, services.items, {}, Pledged.less);

    var out: std.Io.Writer.Allocating = .init(gpa);
    try report(&out.writer, policy, services.items, refused);
    try std.Io.File.stdout().writeStreamingAll(io, out.written());
}

const Pledged = struct {
    name: []const u8,
    words: []const u8,

    fn less(_: void, a: Pledged, b: Pledged) bool {
        return std.mem.order(u8, a.name, b.name) == .lt;
    }
};

/// The words of a service file's pledge line, or "" if it has none.
fn pledgeOf(text: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = if (std.mem.findScalar(u8, raw, '#')) |i| raw[0..i] else raw;
        var words = std.mem.tokenizeAny(u8, line, " \t");
        const key = words.next() orelse continue;
        if (std.mem.eql(u8, key, "pledge")) return std.mem.trim(u8, words.rest(), " \t");
    }
    return "";
}

/// The rest of the line in text that starts with key and a space.
fn field(text: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, key)) return "";
        if (line.len > key.len and std.mem.startsWith(u8, line, key) and line[key.len] == ' ')
            return line[key.len + 1 ..];
    }
    return null;
}

fn report(
    w: *std.Io.Writer,
    policy: []const u8,
    services: []const Pledged,
    refused: []const u8,
) !void {
    const mode = field(policy, "mode") orelse "unknown";
    try w.print("seal: {s}; the machine promises {s}\n", .{
        if (std.mem.eql(u8, mode, "learn"))
            "learning: what no promise allows is allowed, and said"
        else
            "enforcing",
        field(policy, "promises") orelse "?",
    });
    if (services.len > 0) {
        try w.writeAll("services:\n");
        for (services) |s| try w.print("  {s:<12} {s}\n", .{
            s.name,
            if (s.words.len > 0) s.words else "(not leashed: under the machine's promises alone)",
        });
    }
    var lines = std.mem.tokenizeScalar(u8, refused, '\n');
    if (lines.peek() == null) {
        try w.writeAll("refused this boot: none\n");
    } else {
        try w.writeAll("refused this boot:\n");
        while (lines.next()) |line| {
            var f = std.mem.tokenizeScalar(u8, line, ' ');
            const name = f.next() orelse continue;
            const times = std.fmt.parseInt(u64, f.next() orelse "0", 10) catch 0;
            const pid = f.next() orelse "?";
            const first = std.fmt.parseInt(i64, f.next() orelse "0", 10) catch 0;
            const promise = f.next() orelse "?";
            try w.print("  {s:<16} {s:<9} {d} time{s}, last by pid {s}, first at ", .{
                name, promise, times, if (times == 1) "" else "s", pid,
            });
            try utc(w, first);
            try w.writeByte('\n');
        }
    }
    try w.writeAll("never allowed:");
    for (seal.never) |sys| try w.print(" {s}", .{@tagName(sys)});
    try w.writeByte('\n');
}

/// Seconds since the epoch, as a UTC date and time.
fn utc(w: *std.Io.Writer, secs: i64) !void {
    if (secs <= 0) return w.writeAll("?");
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(secs) };
    const day = es.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const ds = es.getDaySeconds();
    try w.print("{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} UTC", .{
        day.year,             md.month.numeric(),      md.day_index + 1,
        ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    });
}

const testing = std.testing;

test pledgeOf {
    try testing.expectEqualStrings(
        "stdio rpath",
        pledgeOf("exec /a\npledge  stdio rpath # ok\nuser x\n"),
    );
    try testing.expectEqualStrings("", pledgeOf("exec /a\n# pledge stdio\n"));
}

test report {
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try report(
        &w,
        "mode enforce\npromises stdio inet\n",
        &.{.{ .name = "app", .words = "stdio inet listen" }},
        "keyctl 1 97 1791335742 never\n",
    );
    const text = w.buffered();
    try testing.expect(std.mem.indexOf(
        u8,
        text,
        "seal: enforcing; the machine promises stdio inet\n",
    ) != null);
    try testing.expect(std.mem.indexOf(u8, text, "  app          stdio inet listen\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "keyctl") != null);
    try testing.expect(std.mem.indexOf(
        u8,
        text,
        "never     1 time, last by pid 97, first at 2026-10-07 01:15:42 UTC",
    ) != null);
    try testing.expect(std.mem.indexOf(u8, text, "never allowed: bpf") != null);
}
