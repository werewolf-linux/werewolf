//! dtrack-setup replaces Dependency-Track's published administrator
//! password, admin/admin, with the config's, before Caddy opens the API.
//! It runs once: a later boot finds the mark and the new password.
//!
//!     dtrack-setup
//!
//! leash runs it as the caddy user (forms/dependency-track/form.yaml).
//! See forms/dependency-track/README.md.

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;
const net = Io.net;
const json = std.json;

const password_path = "/run/svc/caddy/admin-password";
const done = "/data/svc/caddy/dtrack-setup-done";
const port = 8080;
const wait_seconds = 900;

const Response = struct { status: u16, body: []const u8 };

pub fn main(init: std.process.Init) void {
    const io = init.io;
    run(io, init.arena.allocator()) catch |err| {
        say(io, "{{\"event\":\"failed\",\"why\":\"{s}\"}}", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn run(io: Io, gpa: Allocator) !void {
    defer Dir.cwd().deleteFile(io, password_path) catch {};
    if (Dir.cwd().access(io, done, .{})) |_| {
        say(io, "{{\"event\":\"set up already\"}}", .{});
        return;
    } else |_| {}

    const text = Dir.cwd().readFileAlloc(io, password_path, gpa, .limited(4 << 10)) catch |err|
        switch (err) {
            error.FileNotFound => return error.NoAdminPassword,
            else => return err,
        };
    const password = std.mem.trimEnd(u8, text, "\r\n");
    if (password.len < 12 or password.len > 128) return error.AdminPasswordRefused;
    for (password) |c| if (c < 0x20 or c == 0x7f) return error.AdminPasswordRefused;

    try awaitApi(io, gpa);
    const fresh = try credentials(gpa, "admin", password);
    if ((try login(io, gpa, fresh)).len != 0) {
        try mark(io);
        say(io, "{{\"event\":\"admin already set\"}}", .{});
        return;
    }
    const published = try credentials(gpa, "admin", "admin");
    const token = try login(io, gpa, published);
    if (token.len == 0) return error.PublishedPasswordRefused;
    const change = try json.Stringify.valueAlloc(gpa, .{
        .username = "admin",
        .password = "admin",
        .newPassword = password,
        .confirmPassword = password,
    }, .{});
    const changed = try request(io, gpa, "POST", "/api/v1/user/forceChangePassword", token, change);
    if (changed.status != 200) return error.PasswordNotChanged;
    if ((try login(io, gpa, fresh)).len == 0) return error.NewPasswordRefused;
    try mark(io);
    say(io, "{{\"event\":\"admin set\"}}", .{});
}

fn credentials(gpa: Allocator, user: []const u8, password: []const u8) ![]const u8 {
    return json.Stringify.valueAlloc(gpa, .{ .username = user, .password = password }, .{});
}

/// login returns the bearer token, or an empty slice when the password is
/// refused. Any other answer is an error: setup does not guess.
fn login(io: Io, gpa: Allocator, body: []const u8) ![]const u8 {
    const got = try request(io, gpa, "POST", "/api/v1/user/login", null, body);
    if (got.status == 401 or got.status == 403) return "";
    if (got.status != 200) return error.LoginRefused;
    const Token = struct { token: []const u8 = "" };
    const parsed = json.parseFromSliceLeaky(Token, gpa, got.body, .{
        .ignore_unknown_fields = true,
    }) catch return error.LoginAnswerNotUnderstood;
    if (parsed.token.len == 0) return error.LoginAnswerNotUnderstood;
    return parsed.token;
}

fn awaitApi(io: Io, gpa: Allocator) !void {
    var i: u32 = 0;
    while (i < wait_seconds) : (i += 1) {
        const got = request(io, gpa, "GET", "/api/version", null, null) catch {
            try io.sleep(.fromSeconds(1), .awake);
            continue;
        };
        if (got.status == 200) return;
        try io.sleep(.fromSeconds(1), .awake);
    }
    return error.ApiNotUp;
}

fn request(
    io: Io,
    gpa: Allocator,
    method: []const u8,
    path: []const u8,
    token: ?[]const u8,
    body: ?[]const u8,
) !Response {
    const addr = try net.IpAddress.parse("127.0.0.1", port);
    const s = try addr.connect(io, .{ .mode = .stream });
    defer s.close(io);
    var wbuf: [4096]u8 = undefined;
    var w = s.writer(io, &wbuf);
    const out = &w.interface;
    try out.print("{s} {s} HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nAccept: application/json\r\n" ++
        "Connection: close\r\n", .{ method, path, port });
    if (token) |t| try out.print("Authorization: Bearer {s}\r\n", .{t});
    const b = body orelse "";
    if (body != null) try out.writeAll("Content-Type: application/json\r\n");
    try out.print("Content-Length: {d}\r\n\r\n{s}", .{ b.len, b });
    try out.flush();
    var rbuf: [4096]u8 = undefined;
    var r = s.reader(io, &rbuf);
    return parse(gpa, try r.interface.allocRemaining(gpa, .limited(1 << 20)));
}

fn parse(gpa: Allocator, raw: []const u8) !Response {
    const end = std.mem.find(u8, raw, "\r\n\r\n") orelse return error.BadAnswer;
    const head = raw[0..end];
    if (head.len < 12 or !std.mem.startsWith(u8, head, "HTTP/1.1 ")) return error.BadAnswer;
    const status = std.fmt.parseInt(u16, head[9..12], 10) catch return error.BadAnswer;
    var body = raw[end + 4 ..];
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    _ = lines.next();
    while (lines.next()) |l| {
        const colon = std.mem.findScalar(u8, l, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(l[0..colon], "transfer-encoding") and
            std.ascii.findIgnoreCase(l[colon + 1 ..], "chunked") != null)
            body = try unchunk(gpa, body);
    }
    return .{ .status = status, .body = body };
}

fn unchunk(gpa: Allocator, chunked: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var rest = chunked;
    while (true) {
        const eol = std.mem.find(u8, rest, "\r\n") orelse return error.BadAnswer;
        const size_text = rest[0 .. std.mem.findScalar(u8, rest[0..eol], ';') orelse eol];
        const size = std.fmt.parseInt(usize, std.mem.trim(u8, size_text, " "), 16) catch
            return error.BadAnswer;
        rest = rest[eol + 2 ..];
        if (size == 0) return out.items;
        if (rest.len < size + 2) return error.BadAnswer;
        try out.appendSlice(gpa, rest[0..size]);
        rest = rest[size + 2 ..];
    }
}

fn mark(io: Io) !void {
    var f = try Dir.cwd().createFile(io, done, .{ .permissions = .fromMode(0o600) });
    defer f.close(io);
    try f.writeStreamingAll(io, "Dependency-Track's administrator password is the config's.\n");
    try f.sync(io);
}

fn say(io: Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const line = std.mem.print(&buf, "dtrack-setup: " ++ fmt ++ "\n", args) catch return;
    Io.File.stdout().writeStreamingAll(io, line) catch {};
}

const testing = std.testing;

test "parse reads the status and joins chunks" {
    const plain = try parse(testing.allocator, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}");
    try testing.expectEqual(200, plain.status);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const chunked = try parse(
        arena.allocator(),
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\n{\"a\"\r\n3\r\n:1}\r\n0\r\n\r\n",
    );
    try testing.expectEqualStrings("{\"a\":1}", chunked.body);
}
