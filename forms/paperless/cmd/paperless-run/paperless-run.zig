//! paperless-run starts Paperless's four programs and stops the rest if
//! one exits. They share one data directory, so they are one service:
//! the web server, the consumer, the worker, and the scheduler. The
//! public URL is https:// plus the machine's domain.

const std = @import("std");
const Io = std.Io;
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

const python = "/usr/lib/paperless/bin/python3";
const app = "/usr/lib/paperless/app";

const Child = struct {
    argv: []const [*:0]const u8,
    pid: i32 = 0,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();
    run(io, gpa, init.minimal.environ) catch |err| {
        say(io, "{s}", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn run(io: Io, gpa: Allocator, environ: std.process.Environ) !void {
    const domain = environ.getAlloc(gpa, "DOMAIN") catch return error.NoDomain;
    var url_buf: [8 + 253 + 1]u8 = undefined;
    const url = try publicUrl(domain, &url_buf);
    const paperless_url = try gpa.printSentinel("PAPERLESS_URL={s}", .{url}, 0);
    // JSON, so the service file cannot hold it: a quote is not an env word.
    const proxy: [*:0]const u8 = "PAPERLESS_PROXY_SSL_HEADER=[\"HTTP_X_FORWARDED_PROTO\",\"https\"]";
    say(io, "url {s}", .{url});

    const granian = [_][*:0]const u8{
        python,        "-m",     "granian",
        "--interface", "asginl", "--ws",
        "--loop",      "uvloop", "--host",
        "127.0.0.1",   "--port", "8000",
        "--workers",   "1",      "paperless.asgi:application",
    };
    const consumer = [_][*:0]const u8{ python, app ++ "/manage.py", "document_consumer" };
    const worker = [_][*:0]const u8{
        python,             "-m",               "celery",     "--app",
        "paperless",        "worker",           "--loglevel", "INFO",
        "--without-mingle", "--without-gossip",
    };
    const beat = [_][*:0]const u8{
        python, "-m", "celery", "--app", "paperless", "beat", "--loglevel", "INFO",
    };
    var kids = [_]Child{
        .{ .argv = &granian },
        .{ .argv = &consumer },
        .{ .argv = &worker },
        .{ .argv = &beat },
    };
    var envs: std.ArrayList([*:0]const u8) = .empty;
    try envs.append(gpa, paperless_url.ptr);
    try envs.append(gpa, proxy);
    for (environ.block.view().slice) |e| {
        const line = std.mem.sliceTo(e, 0);
        if (std.mem.startsWith(u8, line, "PAPERLESS_URL=")) continue;
        if (std.mem.startsWith(u8, line, "PAPERLESS_PROXY_SSL_HEADER=")) continue;
        try envs.append(gpa, e);
    }
    for (&kids) |*kid| kid.pid = try spawn(kid.argv, envs.items);
    var status: i32 = 0;
    const gone = linux.waitpid(-1, &status, 0);
    if (linux.errno(gone) != .SUCCESS) return error.Wait;
    const child: i32 = @intCast(gone);
    for (kids) |kid| {
        if (kid.pid != child) _ = linux.kill(kid.pid, linux.SIG.TERM);
    }
    const s: u32 = @bitCast(status);
    const code: u8 = if (linux.W.IFEXITED(s)) linux.W.EXITSTATUS(s) else 1;
    say(io, "a program exited ({d})", .{code});
    std.process.exit(code);
}

fn spawn(argv: []const [*:0]const u8, envs: []const [*:0]const u8) !i32 {
    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS) return error.Fork;
    if (pid == 0) {
        if (linux.errno(linux.chdir(app)) != .SUCCESS) linux.exit_group(127);
        var buf: [16:null]?[*:0]const u8 = @splat(null);
        for (argv, 0..) |arg, i| buf[i] = arg;
        var env: [128:null]?[*:0]const u8 = @splat(null);
        if (envs.len >= env.len) linux.exit_group(127);
        for (envs, 0..) |e, i| env[i] = e;
        _ = linux.execve(buf[0].?, &buf, &env);
        linux.exit_group(127);
    }
    return @intCast(pid);
}

fn publicUrl(domain: []const u8, buf: []u8) ![:0]u8 {
    if (domain.len == 0 or domain.len > 253) return error.BadDomain;
    if (std.mem.indexOfAny(u8, domain, "/ \t") != null) return error.BadDomain;
    const printed = try std.mem.print(buf, "https://{s}", .{domain});
    if (printed.len == buf.len) return error.BadDomain;
    buf[printed.len] = 0;
    return buf[0..printed.len :0];
}

fn say(io: Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [320]u8 = undefined;
    const line = std.mem.print(&buf, "paperless-run: " ++ fmt ++ "\n", args) catch return;
    Io.File.stdout().writeStreamingAll(io, line) catch {};
}

test "the public url is https and the domain" {
    var buf: [64]u8 = undefined;
    const url = try publicUrl("paper.home.arpa", &buf);
    try std.testing.expectEqualStrings("https://paper.home.arpa", url);
    try std.testing.expectError(error.BadDomain, publicUrl("", &buf));
    try std.testing.expectError(error.BadDomain, publicUrl("paper.home.arpa/docs", &buf));
}
