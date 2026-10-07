//! slot: building and installing the other slot. From packages: apk's
//! fetcher as _update, then root's offline install into a new root, the
//! root image, its dm-verity tree, and stage0. Then install: the slot
//! written whole, `attempt` kept, and its one try armed, last. Each takes
//! the Update of slot-update.zig, whose methods call these as their own.

const std = @import("std");
const m = @import("slot-update.zig");
const Io = m.Io;
const Dir = m.Dir;
const Allocator = m.Allocator;
const linux = m.linux;
const sandbox = m.sandbox;
const verity = m.verity;

const apk_seconds = m.apk_seconds;
const attempt_path = m.attempt_path;
const cache_dir = m.cache_dir;
const max_apk_file = m.max_apk_file;
const max_read = m.max_read;
const meta_dir = m.meta_dir;
const update_id = m.update_id;
const work_dir = m.work_dir;

const appendUnique = m.appendUnique;
const Package = m.Package;
const parentDir = m.parentDir;
const parseCmdline = m.parseCmdline;
const parseInstalled = m.parseInstalled;
const pathOf = m.pathOf;
const testing = std.testing;
const Update = m.Update;

// --- build ------------------------------------------------------------------
pub fn buildSlot(u: *Update, arch: []const u8, new_kernel: []const u8) !void {
    const io = u.io;
    const root = work_dir ++ "/root";
    try Dir.cwd().createDirPath(io, work_dir ++ "/slot");

    // What apko does that apk does not: busybox's links, no setuid or setgid.
    u.step = "root";
    try u.busyboxLinks(root);
    // werewolf's own files as the build laid them, and the apk setup and
    // build record the next update will need.
    for (try u.lines(try u.read(meta_dir ++ "/overlay"))) |p| try u.copyInto(root, p);
    for (&[_][]const u8{ "etc/apk/repositories", "etc/apk/arch" }) |p| try u.copyInto(root, p);
    for (try u.listDir("/etc/apk/keys")) |name| try u.copyInto(
        root,
        try u.gpa.print("etc/apk/keys/{s}", .{name}),
    );
    try u.copyTree(root, "usr/share/werewolf");
    const form = std.mem.trim(u8, try u.read(meta_dir ++ "/form"), "\n");
    try u.write(
        root ++ meta_dir ++ "/kernel",
        try u.gpa.print("{s}\n", .{new_kernel}),
    );
    try u.write(
        root ++ meta_dir ++ "/release",
        try u.gpa.print(
            "{s} {s} {s} updated-on-{s}\n",
            .{ form, try u.nowText(), new_kernel, u.host },
        ),
    );
    try u.stripSetid(root);
    // The slot's / is this directory's owner and mode: root's, 0755,
    // whoever made it, or sshd's StrictModes refuses every key.
    _ = try u.sys(
        linux.fchownat(linux.AT.FDCWD, root, 0, 0, linux.AT.SYMLINK_NOFOLLOW),
        "chown the new root",
    );
    _ = try u.sys(linux.fchmodat(linux.AT.FDCWD, root, 0o755), "chmod the new root");
    // As the build makes it (Makefile, EROFS_OPTS), so a slot built here
    // boots as a published one does: zstd at level 9 in 64 KiB clusters
    // boots faster than larger clusters or higher levels, and builds in
    // seconds, not minutes.
    try u.run(&.{
        "/usr/bin/mkfs.erofs",
        "-b",
        "4096",
        "-zzstd,level=9",
        "-C65536",
        "-Eall-fragments,dedupe",
        work_dir ++ "/slot/root.erofs",
        root,
    });
    // Its dm-verity hash tree after it, and the line stage0 opens it with,
    // for stage0's /verity below: as the build makes them (tools/verity.zig).
    u.step = "verity";
    const image = try Dir.cwd().openFile(
        io,
        work_dir ++ "/slot/root.erofs",
        .{ .mode = .read_write },
    );
    defer image.close(io);
    const tree = try verity.build(u.gpa, io, image);
    try image.writePositionalAll(io, tree.tree, try image.length(io));

    // Alpine's arm64 kernel is an EFI zboot image; the slot carries the raw
    // Image inside it, as the build does (see Makefile).
    u.step = "vmlinuz";
    const vmlinuz = try u.read(work_dir ++ "/kernel/boot/vmlinuz-virt");
    try u.write(work_dir ++ "/slot/vmlinuz", try unwrapZboot(u.gpa, vmlinuz));

    u.step = "stage0";
    const s = work_dir ++ "/stage0";
    try u.apkAdd(
        s,
        arch,
        &.{ "--keys-dir", "/etc/apk/keys", "--repositories-file", "/etc/apk/repositories" },
        try u.words(try u.read(meta_dir ++ "/stage0.world")),
    );
    try u.busyboxLinks(s);
    try u.stripSetid(s);
    try Dir.cwd().copyFile(
        meta_dir ++ "/stage0.init",
        Dir.cwd(),
        s ++ "/init",
        io,
        .{ .permissions = .fromMode(0o755) },
    );
    // werewolf's module loader, as the build lays it in stage0.
    try Dir.cwd().copyFile(
        "/usr/lib/werewolf/modload",
        Dir.cwd(),
        s ++ "/usr/lib/werewolf/modload",
        io,
        .{ .make_path = true, .permissions = .fromMode(0o755) },
    );
    const kvers = try u.listDir(work_dir ++ "/kernel/lib/modules");
    if (kvers.len != 1) return error.NotOneKernel;
    const src = try u.gpa.print(
        "{s}/kernel/lib/modules/{s}",
        .{ work_dir, kvers[0] },
    );
    const dst = try u.gpa.print("{s}/usr/lib/modules/{s}", .{ s, kvers[0] });
    const dep = try u.read(try u.gpa.print("{s}/modules.dep", .{src}));
    const order = try moduleOrder(u.gpa, dep, try u.lines(try u.read(meta_dir ++ "/modules")));
    // Decompressed, as the build does: Alpine's kernel cannot, and the
    // loader hands it each file as it is.
    for (order) |p| {
        const ko = try gunzip(
            u.gpa,
            try u.read(try u.gpa.print("{s}/{s}", .{ src, p })),
        );
        const out = try u.gpa.print("{s}/{s}", .{ dst, withoutGz(p) });
        try Dir.cwd().createDirPath(io, parentDir(out));
        try u.write(out, ko);
    }
    const list = try moduleList(u.gpa, order, try u.read(meta_dir ++ "/module-params"));
    try u.write(try u.gpa.print("{s}/werewolf.modules", .{dst}), list);
    var line: Io.Writer.Allocating = .init(u.gpa);
    try tree.params.format(&line.writer);
    try u.write(s ++ "/verity", line.written());
    try u.writeCpio(s, work_dir ++ "/stage0.cpio");
    try u.run(&.{
        "/usr/bin/zstd",
        "-19",
        "-q",
        "-f",
        "-o",
        work_dir ++ "/slot/initramfs.zst",
        work_dir ++ "/stage0.cpio",
    });
}

// --- install ----------------------------------------------------------------
// root.erofs beside this slot's on the victim's filesystem; the kernel and
// stage0 in /boot/werewolf, beside GRUB's directory. Both mounted apart
// and writable, since /victim is read-only.
pub fn install(u: *Update, build: []const u8) !void {
    if (u.cmd.grubenv.len == 0) return u.installEsp(build);
    const io = u.io;
    u.step = "install";
    const victim = try u.held(.victim);
    defer victim.release();
    const grub = try u.held(.grub);
    defer grub.release();
    const v = victim.path();
    const g = grub.path();

    const gpath = pathOf(u.cmd.grubenv);
    const kdir = try u.gpa.print(
        "{s}{s}/werewolf/{s}",
        .{ g, parentDir(parentDir(gpath)), u.other },
    );
    const rdir = try u.gpa.print(
        "{s}{s}/{s}",
        .{ v, pathOf(u.cmd.victim), u.other },
    );
    try Dir.cwd().createDirPath(io, kdir);
    try Dir.cwd().createDirPath(io, rdir);
    // Disarm first: a staged slot's try is set, and until the new slot
    // is whole, nothing boots it; nor does `attempt` name it.
    const env = try u.gpa.print("{s}{s}", .{ g, gpath });
    Dir.cwd().deleteFile(io, attempt_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    try u.run(&.{ "/usr/lib/werewolf/grub-setenv", env, "next_entry", "" });
    // Each through a temporary name (copyFile), so whole or absent.
    try Dir.cwd().copyFile(
        work_dir ++ "/slot/root.erofs",
        Dir.cwd(),
        try u.gpa.print("{s}/root.erofs", .{rdir}),
        io,
        .{},
    );
    for (&[_][]const u8{ "vmlinuz", "initramfs.zst" }) |f| {
        try Dir.cwd().copyFile(
            try u.gpa.print("{s}/slot/{s}", .{ work_dir, f }),
            Dir.cwd(),
            try u.gpa.print("{s}/{s}", .{ kdir, f }),
            io,
            .{},
        );
    }
    linux.sync();
    // The image's kernel arguments, which bite's entries read from
    // GRUB's environment for each slot, so an update's new arguments
    // reach a machine bitten before them.
    const args = try std.mem.join(u.gpa, " ", try u.words(try u.slotCmdline()));
    try u.run(&.{
        "/usr/lib/werewolf/grub-setenv",
        env,
        try u.gpa.print("werewolf_args_{s}", .{u.other}),
        args,
    });
    // Then `attempt`, kept, and last the one try: a slot is armed only
    // with its attempt on record, and an attempt never outlives a try
    // that was not set.
    try u.writeAttempt(build);
    errdefer Dir.cwd().deleteFile(io, attempt_path) catch {};
    const entry = try u.gpa.print("werewolf-{s}", .{u.other});
    try u.run(&.{ "/usr/lib/werewolf/grub-setenv", env, "next_entry", entry });
}

pub fn writeAttempt(u: *Update, build: []const u8) !void {
    try u.writeReplacing(
        attempt_path,
        try u.gpa.print("{s} {s} {s}\n", .{ u.other, build, try u.bootId() }),
    );
}

/// The other slot onto werewolf's own disk (docs/design/native-boot.md): its
/// root.erofs to the ext4 partition, as install does; its kernel and
/// stage0 to the EFI partition; and a loader entry with one try, which
/// systemd-boot boots next because it is the newest. slot-keep removes the
/// count once the slot is healthy; if it is not, systemd-boot has spent
/// the try and boots the slot this one replaced.
pub fn installEsp(u: *Update, build: []const u8) !void {
    const io = u.io;
    u.step = "install";
    const victim = try u.held(.victim);
    defer victim.release();
    const esp = try u.held(.esp);
    defer esp.release();
    const v = victim.path();
    const e = esp.path();

    const rdir = try u.gpa.print(
        "{s}{s}/{s}",
        .{ v, pathOf(u.cmd.victim), u.other },
    );
    const kdir = try u.gpa.print("{s}/werewolf/{s}", .{ e, u.other });
    const entries = try u.gpa.print("{s}/loader/entries", .{e});
    try Dir.cwd().createDirPath(io, rdir);
    try Dir.cwd().createDirPath(io, kdir);
    try Dir.cwd().createDirPath(io, entries);

    // The other slot's entry goes first, and `attempt` with it: from
    // here until the new one is written, nothing boots the other slot
    // while its files change. vfat keeps no journal, so the deletes are
    // made to stick before any file changes.
    Dir.cwd().deleteFile(io, attempt_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    for (try u.listDir(entries)) |name| {
        if (isEntryOf(
            name,
            u.other,
        )) try Dir.cwd().deleteFile(io, try u.gpa.print("{s}/{s}", .{ entries, name }));
    }
    linux.sync();
    // Each through a temporary name (copyFile), so whole or absent.
    try Dir.cwd().copyFile(
        work_dir ++ "/slot/root.erofs",
        Dir.cwd(),
        try u.gpa.print("{s}/root.erofs", .{rdir}),
        io,
        .{},
    );
    for (&[_][]const u8{ "vmlinuz", "initramfs.zst" }) |f| {
        try Dir.cwd().copyFile(
            try u.gpa.print("{s}/slot/{s}", .{ work_dir, f }),
            Dir.cwd(),
            try u.gpa.print("{s}/{s}", .{ kdir, f }),
            io,
            .{},
        );
    }
    linux.sync();

    // Now, or a second past the newest werewolf entry left, the running
    // slot's, if the clock is behind the one that wrote it: systemd-boot
    // boots the newest version, so an older one would never be tried.
    var newest: u64 = 0;
    for (try u.listDir(entries)) |name| {
        if (!std.mem.startsWith(u8, name, "werewolf-") or
            !std.mem.endsWith(u8, name, ".conf")) continue;
        const text = try u.read(try u.gpa.print("{s}/{s}", .{ entries, name }));
        newest = @max(newest, entrySecs(text) orelse continue);
    }
    const now: u64 = @intCast(@divFloor(
        Io.Timestamp.now(io, .real).nanoseconds,
        std.time.ns_per_s,
    ));
    const version = try compactTime(u.gpa, @max(now, newest + 1));
    const options = try withSlot(
        u.gpa,
        try u.read("/proc/cmdline"),
        try u.slotCmdline(),
        u.other,
    );
    const entry = try loaderEntry(u.gpa, u.other, version, options);
    const tmp = try u.gpa.print("{s}/werewolf-{s}.tmp", .{ entries, u.other });
    try u.write(tmp, entry);
    // `attempt` kept first, then the one try, as install does.
    try u.writeAttempt(build);
    errdefer Dir.cwd().deleteFile(io, attempt_path) catch {};
    try Dir.cwd().rename(
        tmp,
        Dir.cwd(),
        try u.gpa.print("{s}/werewolf-{s}+1.conf", .{ entries, u.other }),
        io,
    );
    linux.sync();
}

// --- helpers ----------------------------------------------------------------
/// Install packages into a new root, through a cache on /data named for
/// the root (root, kernel, stage0), so a check that finds nothing new
/// downloads indexes and nothing else. Each root has a cache of its own,
/// so cleaning one keeps nothing another needs.
///
/// Root does not touch the network. apk's network half runs first, as
/// _update (apkFetcher): the indexes, fresh every time, since apk would
/// otherwise trust a cached one for hours, and every package the new
/// root takes, into the cache. Root takes the cache back and installs
/// from it with --no-network, checking every signature and hash against
/// its own keys, as apk always does. Then it prunes the cache to the
/// packages the new root took, so it holds one copy of the image, no
/// more.
pub fn apkAdd(
    u: *Update,
    root: []const u8,
    arch: []const u8,
    source: []const []const u8,
    packages: []const []const u8,
) !void {
    const name = std.fs.path.basename(root);
    const cache = try u.gpa.printSentinel("{s}/{s}", .{ cache_dir, name }, 0);
    const scratch = try u.gpa.printSentinel(
        "{s}/apk-{s}",
        .{ work_dir, name },
        0,
    );
    try Dir.cwd().createDirPath(u.io, cache);
    Dir.cwd().deleteTree(u.io, scratch) catch {};
    try Dir.cwd().createDirPath(u.io, scratch);
    _ = try u.sys(
        linux.fchownat(
            linux.AT.FDCWD,
            scratch,
            update_id,
            update_id,
            linux.AT.SYMLINK_NOFOLLOW,
        ),
        "chown scratch",
    );

    // The indexes, then the packages: `cache download` fetches no index.
    const world = try std.mem.join(u.gpa, "\n", packages);
    for ([_][]const []const u8{ &.{"update"}, &.{ "cache", "download" } }) |applet| {
        var fetch_argv: std.ArrayList(?[*:0]const u8) = .empty;
        for ([_][]const u8{
            "/usr/bin/apk",
            "--root",
            scratch,
            "--arch",
            arch,
            "--cache-dir",
            cache,
        }) |arg| try fetch_argv.append(u.gpa, try u.gpa.dupeSentinel(u8, arg, 0));
        for (source) |arg| try fetch_argv.append(u.gpa, try u.gpa.dupeSentinel(u8, arg, 0));
        for ([_][]const u8{
            "--quiet",
            "--no-progress",
        }) |arg| try fetch_argv.append(u.gpa, try u.gpa.dupeSentinel(u8, arg, 0));
        for (applet) |arg| try fetch_argv.append(u.gpa, try u.gpa.dupeSentinel(u8, arg, 0));
        const argv_z = try fetch_argv.toOwnedSliceSentinel(u.gpa, null);
        _ = try u.sys(
            linux.fchownat(
                linux.AT.FDCWD,
                cache,
                update_id,
                update_id,
                linux.AT.SYMLINK_NOFOLLOW,
            ),
            "chown cache",
        );
        const fetched = u.child(
            apkFetcher,
            .{ argv_z, world, cache, scratch },
            64 << 10,
            apk_seconds,
        );
        try u.reclaim(cache);
        const e = fetched catch |err| {
            u.detail = "apk, as _update";
            return err;
        };
        if (e.code != 0) {
            u.detail = try u.gpa.print(
                "apk, as _update: {s}",
                .{std.mem.trim(u8, e.out[0..@min(e.out.len, 400)], " \n")},
            );
            return error.CommandFailed;
        }
    }
    try Dir.cwd().deleteTree(u.io, scratch);

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(
        u.gpa,
        &.{
            "/usr/bin/apk",
            "--root",
            root,
            "--arch",
            arch,
            "--cache-dir",
            cache,
            "--no-network",
        },
    );
    try argv.appendSlice(u.gpa, source);
    try argv.appendSlice(
        u.gpa,
        &.{ "--no-scripts", "--quiet", "--no-progress", "add", "--initdb" },
    );
    try argv.appendSlice(u.gpa, packages);
    try u.run(argv.items);
    try u.prune(cache, root);
}

/// The cache, down to the packages root has installed, and the indexes.
/// Not apk's `cache clean`: without --purge it keeps any version an
/// index still lists, which for Wolfi is all of them, and with it,
/// where the root is on a disk, it deletes every package.
pub fn prune(u: *Update, cache: []const u8, root: []const u8) !void {
    const installed = try parseInstalled(
        u.gpa,
        try u.read(try u.gpa.print("{s}/lib/apk/db/installed", .{root})),
    );
    var d = try Dir.cwd().openDir(u.io, cache, .{ .iterate = true, .follow_symlinks = false });
    defer d.close(u.io);
    var old: std.ArrayList([]const u8) = .empty;
    var it = d.iterate();
    while (try it.next(u.io)) |e| {
        if (std.mem.endsWith(u8, e.name, ".apk") and
            !isCachedOf(e.name, installed)) try old.append(u.gpa, try u.gpa.dupe(u8, e.name));
    }
    for (old.items) |name| try d.deleteFile(u.io, name);
}

/// The cache, root's again once the fetcher is gone: each entry a regular
/// file of a name apk gives one, owned by root, mode 0644. Anything else
/// it left is removed unread.
pub fn reclaim(u: *Update, cache: [:0]const u8) !void {
    _ = try u.sys(
        linux.fchownat(linux.AT.FDCWD, cache, 0, 0, linux.AT.SYMLINK_NOFOLLOW),
        "chown cache",
    );
    var d = try Dir.cwd().openDir(u.io, cache, .{ .iterate = true, .follow_symlinks = false });
    defer d.close(u.io);
    var strays: std.ArrayList([]const u8) = .empty;
    var it = d.iterate();
    while (try it.next(u.io)) |e| {
        if (e.kind != .file or !cacheName(e.name)) {
            try strays.append(u.gpa, try u.gpa.dupe(u8, e.name));
            continue;
        }
        const file = try u.gpa.dupeSentinel(u8, e.name, 0);
        _ = try u.sys(
            linux.fchownat(d.handle, file, 0, 0, linux.AT.SYMLINK_NOFOLLOW),
            "chown cached file",
        );
        // And root's mode: the fetcher, dead by now, chose the last.
        _ = try u.sys(linux.fchmodat(d.handle, file, 0o644), "chmod cached file");
    }
    for (strays.items) |stray| try d.deleteTree(u.io, stray);
}

pub fn busyboxLinks(u: *Update, root: []const u8) !void {
    const d = try u.gpa.print("{s}/etc/busybox-paths.d", .{root});
    for (u.listDir(d) catch return) |name| {
        for (try u.lines(try u.read(try u.gpa.print(
            "{s}/{s}",
            .{ d, name },
        )))) |p| {
            const link = try u.gpa.print(
                "{s}/{s}",
                .{ root, std.mem.trimStart(u8, p, "/") },
            );
            _ = Dir.cwd().statFile(u.io, link, .{ .follow_symlinks = false }) catch {
                try Dir.cwd().symLink(u.io, "/usr/bin/busybox", link, .{});
            };
        }
    }
}

pub fn stripSetid(u: *Update, root: []const u8) !void {
    var d = try Dir.cwd().openDir(u.io, root, .{ .iterate = true });
    defer d.close(u.io);
    var w = try d.walk(u.gpa);
    while (try w.next(u.io)) |e| {
        if (e.kind != .file) continue;
        const st = try e.dir.statFile(u.io, e.basename, .{ .follow_symlinks = false });
        const mode = st.permissions.toMode();
        if (mode & 0o6000 != 0) {
            try e.dir.setFilePermissions(
                u.io,
                e.basename,
                .fromMode(mode & ~@as(std.posix.mode_t, 0o6000)),
                .{ .follow_symlinks = false },
            );
        }
    }
}

/// Copy /path to root/path, with its permissions.
/// path, a directory, and everything under it, from this root into
/// root: the build record, whose etc/ holds the image's accounts.
pub fn copyTree(u: *Update, root: []const u8, path: []const u8) !void {
    var d = Dir.cwd().openDir(
        u.io,
        try u.gpa.print("/{s}", .{path}),
        .{ .iterate = true },
    ) catch |err| {
        u.detail = path;
        return err;
    };
    defer d.close(u.io);
    var w = try d.walk(u.gpa);
    defer w.deinit();
    while (try w.next(u.io)) |e| {
        if (e.kind == .directory) continue;
        try u.copyInto(root, try u.gpa.print("{s}/{s}", .{ path, e.path }));
    }
}

/// path, from this root into root. A symlink stays a symlink: a form's
/// `run` that links to a binary must not become a copy of the old one.
/// A .mountpoint is the empty file that keeps a mount point's directory
/// in the image; here what is mounted there hides it, so it is made.
pub fn copyInto(u: *Update, root: []const u8, path: []const u8) !void {
    errdefer u.detail = path;
    const src = try u.gpa.print("/{s}", .{path});
    const dst = try u.gpa.print("{s}/{s}", .{ root, path });
    if (std.mem.eql(u8, std.fs.path.basename(path), ".mountpoint")) {
        try Dir.cwd().createDirPath(u.io, parentDir(dst));
        return Dir.cwd().writeFile(u.io, .{ .sub_path = dst, .data = "" });
    }
    var buf: [Dir.max_path_bytes]u8 = undefined;
    const n = Dir.cwd().readLink(u.io, src, &buf) catch |err| switch (err) {
        error.NotLink => return Dir.cwd().copyFile(
            src,
            Dir.cwd(),
            dst,
            u.io,
            .{ .make_path = true },
        ),
        else => return err,
    };
    try Dir.cwd().createDirPath(u.io, parentDir(dst));
    Dir.cwd().deleteFile(u.io, dst) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    try Dir.cwd().symLink(u.io, buf[0..n], dst, .{});
}

/// A newc cpio of everything under root, as the kernel unpacks an
/// initramfs: owned by root, children after their directory. The type
/// and device numbers come from statx, since the stage0 root has device
/// nodes (/dev/console, which the kernel opens before anything mounts
/// /dev) as well as files, directories and links.
pub fn writeCpio(u: *Update, root: []const u8, out_path: []const u8) !void {
    var out: Io.Writer.Allocating = .init(u.gpa);
    var d = try Dir.cwd().openDir(u.io, root, .{ .iterate = true });
    defer d.close(u.io);
    var w = try d.walk(u.gpa);
    var ino: u32 = 1;
    var link_buf: [Dir.max_path_bytes]u8 = undefined;
    while (try w.next(u.io)) |e| : (ino += 1) {
        const path = try u.gpa.printSentinel("{s}/{s}", .{ root, e.path }, 0);
        var st: linux.Statx = undefined;
        const rc = linux.statx(
            linux.AT.FDCWD,
            path,
            linux.AT.SYMLINK_NOFOLLOW,
            .{ .TYPE = true, .MODE = true },
            &st,
        );
        if (linux.errno(rc) != .SUCCESS) return error.StatFailed;
        const node: Node = .{
            .name = e.path,
            .mode = st.mode,
            .ino = ino,
            .rdev_major = st.rdev_major,
            .rdev_minor = st.rdev_minor,
        };
        const data: []const u8 = switch (st.mode & linux.S.IFMT) {
            linux.S.IFREG => try e.dir.readFileAlloc(
                u.io,
                e.basename,
                u.gpa,
                .limited(max_read),
            ),
            linux.S.IFLNK => link_buf[0..try e.dir.readLink(u.io, e.basename, &link_buf)],
            linux.S.IFDIR, linux.S.IFCHR, linux.S.IFBLK => "",
            else => return error.UnexpectedFileKind,
        };
        try cpioEntry(&out.writer, node, data);
    }
    try cpioEntry(&out.writer, .{ .name = "TRAILER!!!", .mode = 0, .ino = 0 }, "");
    try u.write(out_path, out.written());
}

// --- apk's network half, as _update -----------------------------------------

/// As _update, apk's network half: argv, run with no environment, in
/// scratch, a root of its own holding only world and an empty database. It
/// reads the image (/usr, /etc and the resolver's file), runs nothing but
/// apk, writes only beneath cache and scratch, connects over TCP only to
/// ports 443 and 53, and starts no process. What it says goes to out.
fn apkFetcher(
    argv: [:null]const ?[*:0]const u8,
    world: []const u8,
    cache: [:0]const u8,
    scratch: [:0]const u8,
    out: i32,
    parent: linux.pid_t,
) noreturn {
    sandbox.tieTo(parent);
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    apkExec(
        argv,
        world,
        cache,
        scratch,
        out,
    ) catch |err| sandbox.say(out, 1, sandbox.whyNot(arena.allocator(), err), "");
}

fn apkExec(
    argv: [:null]const ?[*:0]const u8,
    world: []const u8,
    cache: [:0]const u8,
    scratch: [:0]const u8,
    out: i32,
) !noreturn {
    try sandbox.closeAllBut(&.{out});
    for ([_]i32{ 1, 2 }) |fd| _ = try sandbox.sys(linux.dup3(out, fd, 0), "dup3");
    // What it may reach, opened while root can. resolv.conf leads, on a
    // machine with DHCP, to the client's in /run.
    const dir: linux.O = .{ .PATH = true, .DIRECTORY = true, .CLOEXEC = true, .NOFOLLOW = true };
    const file: linux.O = .{ .PATH = true, .CLOEXEC = true };
    var rules: [9]sandbox.Rule = undefined;
    var n: usize = 0;
    for ([_]struct { [:0]const u8, linux.O, u64 }{
        .{ "/usr", dir, sandbox.read_file | sandbox.read_dir },
        .{ "/etc", dir, sandbox.read_file | sandbox.read_dir },
        .{ "/usr/bin/apk", file, sandbox.execute },
        .{ interpreter, file, sandbox.execute },
        .{ "/dev/null", file, sandbox.read_file | sandbox.write_file },
        .{ cache, dir, sandbox.own_dir },
        .{ "/etc/resolv.conf", file, sandbox.read_file },
    }) |r| {
        const fd = linux.openat(linux.AT.FDCWD, r[0], r[1], 0);
        if (linux.errno(fd) == .NOENT and std.mem.eql(u8, r[0], "/etc/resolv.conf")) continue;
        rules[n] = .{
            .fd = @intCast(try sandbox.sys(fd, "open what apk may reach")),
            .access = r[2],
        };
        n += 1;
    }
    const root: i32 = @intCast(try sandbox.sys(
        linux.openat(linux.AT.FDCWD, scratch, dir, 0),
        "open scratch",
    ));
    rules[n] = .{ .fd = root, .access = sandbox.own_dir };
    n += 1;
    // No file bigger than any package or index, so a child that turns on
    // root cannot fill /data with one.
    try sandbox.limit(.FSIZE, max_apk_file);
    try sandbox.dropTo(update_id, null);
    for ([_][:0]const u8{ "etc", "etc/apk", "lib", "lib/apk", "lib/apk/db" }) |d| {
        const rc = linux.mkdirat(root, d, 0o755);
        if (linux.errno(rc) != .EXIST) _ = try sandbox.sys(rc, "mkdir in scratch");
    }
    try writeAt(root, "etc/apk/world", world);
    try writeAt(root, "lib/apk/db/installed", "");
    try sandbox.landlock(rules[0..n], &.{ 443, 53 });

    // What apk 2.14 calls to fetch, as traced, under glibc on either
    // architecture (x86_64's arch_prctl sets up thread-local storage); the
    // names one lacks are skipped. It tries to mount /proc
    // in its root, which is refused as for any unprivileged process, and
    // carries on.
    var f: sandbox.Filter = .{};
    inline for (.{
        "read",            "readv",           "pread64",         "write",
        "writev",          "pwrite64",        "openat",          "open",
        "close",           "fstat",           "newfstatat",      "stat",
        "lstat",           "statx",           "fstatfs",         "statfs",
        "lseek",           "getdents64",      "faccessat",       "faccessat2",
        "access",          "readlinkat",      "readlink",        "mkdirat",
        "mkdir",           "renameat",        "renameat2",       "rename",
        "unlinkat",        "unlink",          "utimensat",       "ftruncate",
        "fsync",           "fdatasync",       "fcntl",           "flock",
        "dup",             "dup2",            "dup3",            "umask",
        "mmap",            "munmap",          "mprotect",        "mremap",
        "madvise",         "brk",             "futex",           "getpid",
        "gettid",          "getuid",          "geteuid",         "getgid",
        "getegid",         "connect",         "getsockopt",      "setsockopt",
        "getsockname",     "getpeername",     "sendto",          "recvfrom",
        "sendmsg",         "recvmsg",         "sendmmsg",        "recvmmsg",
        "shutdown",        "poll",            "ppoll",           "pselect6",
        "select",          "rt_sigaction",    "rt_sigprocmask",  "rt_sigreturn",
        "getrandom",       "clock_gettime",   "gettimeofday",    "nanosleep",
        "clock_nanosleep", "set_tid_address", "set_robust_list", "rseq",
        "prlimit64",       "uname",           "execve",          "exit_group",
        "exit",            "restart_syscall", "arch_prctl",
    }) |name| f.allow(name);
    // IP, and nothing else: glibc's lookups also try nscd's Unix socket,
    // and netlink for the addresses configured, and do without.
    f.allowArg("socket", 0, linux.AF.INET);
    f.allowArg("socket", 0, linux.AF.INET6);
    f.refuse("socket");
    // FIONREAD, and isatty's TCGETS and TCGETS2.
    for ([_]u32{ 0x541b, 0x5401, 0x802c542a }) |req| f.allowArg("ioctl", 1, req);
    f.refuse("mount");
    f.refuse("umount2");
    try f.install();

    const envp = [_:null]?[*:0]const u8{};
    _ = try sandbox.sys(linux.execve(argv[0].?, argv.ptr, &envp), "execve apk");
    unreachable;
}

/// glibc's dynamic loader, which the kernel runs apk with; what it runs in
/// turn would be as confined as apk is.
const interpreter = switch (@import("builtin").cpu.arch) {
    .x86_64 => "/lib64/ld-linux-x86-64.so.2",
    .aarch64 => "/lib/ld-linux-aarch64.so.1",
    else => @compileError("werewolf builds for x86_64 and aarch64"),
};

/// A file beneath dir, written whole.
fn writeAt(dir: i32, name: [*:0]const u8, data: []const u8) !void {
    const fd: i32 = @intCast(try sandbox.sys(
        linux.openat(
            dir,
            name,
            .{
                .ACCMODE = .WRONLY,
                .CREAT = true,
                .TRUNC = true,
                .CLOEXEC = true,
                .NOFOLLOW = true,
            },
            0o644,
        ),
        "create in scratch",
    ));
    defer _ = linux.close(fd);
    var off: usize = 0;
    while (off < data.len) off += try sandbox.sys(
        linux.write(fd, data[off..].ptr, data.len - off),
        "write in scratch",
    );
}

/// Whether file, a package in apk's cache (NAME-VERSION.HASH.apk), is one
/// of pkgs.
fn isCachedOf(file: []const u8, pkgs: []const Package) bool {
    const stem = file[0 .. std.mem.findScalarLast(
        u8,
        file[0 .. file.len - ".apk".len],
        '.',
    ) orelse return false];
    for (pkgs) |p| {
        if (stem.len == p.name.len + 1 + p.version.len and std.mem.startsWith(u8, stem, p.name) and
            stem[p.name.len] == '-' and std.mem.endsWith(u8, stem, p.version)) return true;
    }
    return false;
}

/// A name apk gives a file in its cache.
fn cacheName(name: []const u8) bool {
    return std.mem.eql(u8, name, "installed") or std.mem.endsWith(u8, name, ".apk") or
        (std.mem.startsWith(u8, name, "APKINDEX.") and std.mem.endsWith(u8, name, ".tar.gz"));
}

// --- pure functions, tested below -------------------------------------------

/// This boot's command line, for the other slot: what the machine was
/// booted with (its console, werewolf.mac) carries over, but the image's
/// own arguments (/usr/share/werewolf/cmdline, which the build writes from
/// the form's allowances) replace any of the same name, so an entry edited
/// to loosen one does not outlive the next update, and one an update adds
/// reaches machines installed before it. werewolf.slot is the other slot's;
/// initrd= and BOOT_IMAGE= belong to the loader that wrote them, and are
/// dropped.
fn withSlot(
    gpa: Allocator,
    cmdline: []const u8,
    image: []const u8,
    slot: []const u8,
) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.tokenizeAny(u8, cmdline, " \n");
    next: while (it.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "werewolf.slot=") or
            std.mem.startsWith(u8, arg, "initrd=") or
            std.mem.startsWith(u8, arg, "BOOT_IMAGE=")) continue;
        var own = std.mem.tokenizeAny(u8, image, " \n");
        while (own.next()) |o| if (std.mem.eql(u8, argName(arg), argName(o))) continue :next;
        try out.print(gpa, "{s} ", .{arg});
    }
    var own = std.mem.tokenizeAny(u8, image, " \n");
    while (own.next()) |o| try out.print(gpa, "{s} ", .{o});
    try out.print(gpa, "werewolf.slot={s}", .{slot});
    return out.items;
}

/// A kernel argument's name: what comes before its =, or all of it.
fn argName(arg: []const u8) []const u8 {
    return arg[0 .. std.mem.findScalar(u8, arg, '=') orelse arg.len];
}

/// A systemd-boot entry (the Boot Loader Specification's type 1) for slot.
/// version orders the slots, newest first; sort-key keeps them together.
fn loaderEntry(
    gpa: Allocator,
    slot: []const u8,
    version: []const u8,
    options: []const u8,
) ![]const u8 {
    return gpa.print(
        \\title werewolf {s}
        \\sort-key werewolf
        \\version {s}
        \\linux /werewolf/{s}/vmlinuz
        \\initrd /werewolf/{s}/initramfs.zst
        \\options {s}
        \\
    , .{ slot, version, slot, slot, options });
}

/// Whether name is one of slot's entries: werewolf-b.conf, werewolf-b+1.conf
/// with tries left, werewolf-b+0-1.conf with none.
fn isEntryOf(name: []const u8, slot: []const u8) bool {
    const prefix = "werewolf-";
    if (!std.mem.startsWith(u8, name, prefix) or !std.mem.endsWith(u8, name, ".conf")) return false;
    const rest = name[prefix.len .. name.len - ".conf".len];
    if (!std.mem.startsWith(u8, rest, slot)) return false;
    return rest.len == slot.len or rest[slot.len] == '+';
}

/// secs as a version systemd-boot orders by time: 20261006T120000Z.
fn compactTime(gpa: Allocator, secs: u64) ![]const u8 {
    const es: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return gpa.print("{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{
        yd.year,              md.month.numeric(),      md.day_index + 1,
        ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    });
}

/// An entry's version as compactTime writes it, in seconds since the
/// epoch; null if it has none, or one of another form.
fn entrySecs(entry: []const u8) ?u64 {
    var it = std.mem.tokenizeScalar(u8, entry, '\n');
    const v = while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "version ")) break line["version ".len..];
    } else return null;
    if (v.len != 16 or v[8] != 'T' or v[15] != 'Z') return null;
    var f: [6]u64 = undefined;
    for (&f, [_][]const u8{ v[0..4], v[4..6], v[6..8], v[9..11], v[11..13], v[13..15] }) |*n, s| {
        for (s) |c| if (!std.ascii.isDigit(c)) return null;
        n.* = std.fmt.parseUnsigned(u64, s, 10) catch return null;
    }
    const y, const mo, const d, const h, const mi, const s = f;
    if (y < 1970 or mo < 1 or mo > 12 or d < 1 or d > 31 or h > 23 or mi > 59 or
        s > 59) return null;
    // Days from 1970-01-01, by the proleptic Gregorian calendar (Hinnant's
    // days_from_civil), the years counted from March so leap days come last.
    const ym = if (mo <= 2) y - 1 else y;
    const yoe = ym % 400;
    const doy = (153 * ((mo + 9) % 12) + 2) / 5 + d - 1;
    const days = ym / 400 * 146097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719468;
    return days * std.time.s_per_day + h * 3600 + mi * 60 + s;
}

/// The order to load modules in: each leaf's dependencies from modules.dep,
/// read back to front, then the leaf; each module once.
fn moduleOrder(
    gpa: Allocator,
    dep: []const u8,
    leaves: []const []const u8,
) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (leaves) |leaf| {
        const suffix = try gpa.print("/{s}.ko.gz", .{leaf});
        var lines_it = std.mem.splitScalar(u8, dep, '\n');
        const line = while (lines_it.next()) |l| {
            const colon = std.mem.findScalar(u8, l, ':') orelse continue;
            if (std.mem.endsWith(u8, l[0..colon], suffix)) break l;
        } else return error.ModuleNotFound;
        var fields: std.ArrayList([]const u8) = .empty;
        var f = std.mem.tokenizeAny(u8, line, ": ");
        while (f.next()) |x| try fields.append(gpa, x);
        var i = fields.items.len;
        while (i > 0) {
            i -= 1;
            try appendUnique(gpa, &out, fields.items[i]);
        }
    }
    return out.items;
}

/// werewolf.modules for a load order: each path without .gz, and after it
/// the parameters /usr/share/werewolf/module-params gives its module, a
/// line `MODULE KEY=VALUE`, as the build writes them (Makefile,
/// MODULE_PARAMS). Parameters for a module not in the order are an error,
/// not a module loaded without them.
fn moduleList(gpa: Allocator, order: []const []const u8, params: []const u8) ![]const u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    for (order) |p| {
        const path = withoutGz(p);
        try out.writer.writeAll(path);
        const stem = std.fs.path.basename(path);
        var lines_it = std.mem.tokenizeScalar(u8, params, '\n');
        while (lines_it.next()) |line| {
            const space = std.mem.findScalar(u8, line, ' ') orelse return error.BadModuleParams;
            if (std.mem.eql(
                u8,
                line[0..space],
                stem[0 .. stem.len - ".ko".len],
            )) try out.writer.print(" {s}", .{line[space + 1 ..]});
        }
        try out.writer.writeByte('\n');
    }
    var lines_it = std.mem.tokenizeScalar(u8, params, '\n');
    next: while (lines_it.next()) |line| {
        const name = line[0 .. std.mem.findScalar(u8, line, ' ') orelse line.len];
        for (order) |p| {
            const stem = std.fs.path.basename(withoutGz(p));
            if (std.mem.eql(u8, name, stem[0 .. stem.len - ".ko".len])) continue :next;
        }
        return error.ParamsForMissingModule;
    }
    return out.written();
}

/// Alpine's arm64 vmlinuz is an EFI zboot image: "MZ", "zimg", then the
/// gzipped Image's offset and size as little-endian u32. Anything else is
/// returned as it is.
/// A gzip stream, inflated.
fn gunzip(gpa: Allocator, data: []const u8) ![]const u8 {
    var in: Io.Reader = .fixed(data);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var gz: std.compress.flate.Decompress = .init(&in, .gzip, &window);
    var out: Io.Writer.Allocating = .init(gpa);
    _ = try gz.reader.streamRemaining(&out.writer);
    return out.written();
}

/// kernel/fs/ext4/ext4.ko.gz -> kernel/fs/ext4/ext4.ko
fn withoutGz(path: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, path, ".gz")) path[0 .. path.len - 3] else path;
}

fn unwrapZboot(gpa: Allocator, image: []const u8) ![]const u8 {
    if (image.len < 16 or !std.mem.eql(u8, image[4..8], "zimg")) return image;
    const off = std.mem.readInt(u32, image[8..12], .little);
    const size = std.mem.readInt(u32, image[12..16], .little);
    if (@as(u64, off) + size > image.len) return error.BadZboot;
    var in: Io.Reader = .fixed(image[off .. off + size]);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var gz: std.compress.flate.Decompress = .init(&in, .gzip, &window);
    var out: Io.Writer.Allocating = .init(gpa);
    _ = try gz.reader.streamRemaining(&out.writer);
    return out.written();
}

const Node = struct {
    name: []const u8,
    mode: u32,
    ino: u32,
    rdev_major: u32 = 0,
    rdev_minor: u32 = 0,
};

/// One newc cpio entry: header, name and data, each padded to 4 bytes.
fn cpioEntry(w: *Io.Writer, n: Node, data: []const u8) !void {
    const fields = [_]u32{
        n.ino,
        n.mode,
        0,
        0,
        1,
        0,
        @intCast(data.len),
        0,
        0,
        n.rdev_major,
        n.rdev_minor,
        @intCast(n.name.len + 1),
        0,
    };
    try w.writeAll("070701");
    for (fields) |f| try w.print("{x:0>8}", .{f});
    try w.writeAll(n.name);
    try w.writeByte(0);
    try w.splatByteAll(0, pad4(110 + n.name.len + 1));
    try w.writeAll(data);
    try w.splatByteAll(0, pad4(data.len));
}

fn pad4(n: usize) usize {
    return (4 - n % 4) % 4;
}

// --- tests ------------------------------------------------------------------

test "systemd-boot entries" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = parseCmdline(
        "console=hvc0 werewolf.slot=a werewolf.victim=ab:/werewolf werewolf.esp=57E1-F000\n",
    );
    try testing.expectEqualStrings("57E1-F000", c.esp);
    try testing.expectEqualStrings("", c.grubenv);
    try testing.expectEqualStrings(
        "console=hvc0 werewolf.victim=ab:/werewolf werewolf.esp=57E1-F000 werewolf.mac=52:55 " ++
            "werewolf.slot=b",
        try withSlot(
            a,
            "initrd=\\werewolf\\a\\initramfs.zst console=hvc0 werewolf.slot=a " ++
                "werewolf.victim=ab:/werewolf werewolf.esp=57E1-F000  werewolf.mac=52:55\n",
            "",
            "b",
        ),
    );
    // The image's arguments replace any of the same name, and are added
    // where missing.
    try testing.expectEqualStrings(
        "console=hvc0 werewolf.victim=ab:/werewolf debugfs=off proc_mem.force_override=never " ++
            "werewolf.slot=b",
        try withSlot(
            a,
            "console=hvc0 proc_mem.force_override=always werewolf.slot=a " ++
                "werewolf.victim=ab:/werewolf\n",
            "debugfs=off proc_mem.force_override=never\n",
            "b",
        ),
    );
    try testing.expectEqualStrings(
        \\title werewolf b
        \\sort-key werewolf
        \\version 20261006T120000Z
        \\linux /werewolf/b/vmlinuz
        \\initrd /werewolf/b/initramfs.zst
        \\options x werewolf.slot=b
        \\
    , try loaderEntry(a, "b", "20261006T120000Z", "x werewolf.slot=b"));
    try testing.expectEqualStrings("20261006T120000Z", try compactTime(a, 1791288000));
    // And back, for the entries a new one must be newer than: mkdisk's
    // first, a leap day, and versions of other forms, which count as none.
    for ([_]u64{ 0, 315532800, 1835481599, 1835481600, 1791288000 }) |secs| {
        const entry = try a.print("title werewolf a\nversion {s}\n", .{try compactTime(a, secs)});
        try testing.expectEqual(secs, entrySecs(entry).?);
    }
    try testing.expectEqualStrings("20280229T235959Z", try compactTime(a, 1835481599));
    for ([_][]const u8{
        "title werewolf a\n",
        "version 0-werewolf-a\n",
        "version 20261306T120000Z\n",
        "version 2026100GT120000Z\n",
        "version +0261006T120000Z\n",
        "version 19691231T235959Z\n",
    }) |entry| try testing.expectEqual(null, entrySecs(entry));
    for ([_][]const u8{
        "werewolf-b.conf",
        "werewolf-b+1.conf",
        "werewolf-b+0-1.conf",
    }) |n| try testing.expect(isEntryOf(n, "b"));
    for ([_][]const u8{
        "werewolf-a.conf",
        "werewolf-b.tmp",
        "werewolf-bb.conf",
        "other-b.conf",
    }) |n| try testing.expect(!isEntryOf(n, "b"));
}

test cacheName {
    for ([_][]const u8{
        "installed",
        "APKINDEX.f8759e6a.tar.gz",
        "zstd-1.5.7-r10.cc2743ad.apk",
    }) |n| try testing.expect(cacheName(n));
    for ([_][]const u8{
        "APKINDEX.f8759e6a.tar",
        ".apk.27182ee91faf",
        "installed.new",
        "lib",
        "zstd-1.5.7-r10.apk.tmp",
    }) |n| try testing.expect(!cacheName(n));
}

test isCachedOf {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const pkgs = try parseInstalled(
        arena.allocator(),
        "P:zstd\nV:1.5.7-r10\n\nP:glibc-2.44\nV:2.44-r8\n",
    );
    try testing.expect(isCachedOf("zstd-1.5.7-r10.cc2743ad.apk", pkgs));
    try testing.expect(isCachedOf("glibc-2.44-2.44-r8.b91ee306.apk", pkgs));
    try testing.expect(!isCachedOf("glibc-2.44-2.44-r7.53c9e93b.apk", pkgs));
    try testing.expect(!isCachedOf("zstd-1.5.7-r1.cc2743ad.apk", pkgs));
    try testing.expect(!isCachedOf("libzstd1-1.5.7-r10.933e1e74.apk", pkgs));
    try testing.expect(!isCachedOf("zstd-1.5.7-r10.apk", pkgs));
    try testing.expect(!isCachedOf(".apk", pkgs));
}

test withoutGz {
    try testing.expectEqualStrings(
        "kernel/fs/ext4/ext4.ko",
        withoutGz("kernel/fs/ext4/ext4.ko.gz"),
    );
    try testing.expectEqualStrings("kernel/fs/ext4/ext4.ko", withoutGz("kernel/fs/ext4/ext4.ko"));
}

test moduleOrder {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const dep =
        \\kernel/fs/ext4/ext4.ko.gz: kernel/lib/crc/crc16.ko.gz kernel/fs/mbcache.ko.gz kernel/fs/jbd2/jbd2.ko.gz
        \\kernel/fs/xfs/xfs.ko.gz:
        \\kernel/fs/jbd2/jbd2.ko.gz:
    ;
    const order = try moduleOrder(arena.allocator(), dep, &.{ "ext4", "xfs", "jbd2" });
    try testing.expectEqual(5, order.len);
    try testing.expectEqualStrings("kernel/fs/jbd2/jbd2.ko.gz", order[0]);
    try testing.expectEqualStrings("kernel/fs/ext4/ext4.ko.gz", order[3]);
    try testing.expectEqualStrings("kernel/fs/xfs/xfs.ko.gz", order[4]);
    try testing.expectError(error.ModuleNotFound, moduleOrder(arena.allocator(), dep, &.{"btrfs"}));
}

test moduleList {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const order = [_][]const u8{
        "kernel/arch/x86/kvm/kvm.ko.gz",
        "kernel/arch/x86/kvm/kvm-intel.ko.gz",
    };
    try testing.expectEqualStrings(
        "kernel/arch/x86/kvm/kvm.ko\nkernel/arch/x86/kvm/kvm-intel.ko\n",
        try moduleList(a, &order, ""),
    );
    try testing.expectEqualStrings(
        "kernel/arch/x86/kvm/kvm.ko\nkernel/arch/x86/kvm/kvm-intel.ko nested=0 ept=1\n",
        try moduleList(a, &order, "kvm-intel nested=0\nkvm-intel ept=1\n"),
    );
    try testing.expectError(
        error.ParamsForMissingModule,
        moduleList(a, &order, "kvm-amd nested=0\n"),
    );
    try testing.expectError(error.BadModuleParams, moduleList(a, &order, "kvm-intel\n"));
}

test cpioEntry {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try cpioEntry(&out.writer, .{ .name = "init", .mode = 0o100755, .ino = 1 }, "ab");
    const b = out.written();
    try testing.expectEqualStrings("070701", b[0..6]);
    try testing.expectEqualStrings("000081ed", b[14..22]);
    try testing.expectEqualStrings("init\x00", b[110..115]);
    try testing.expectEqual(0, (110 + 5 + pad4(115)) % 4);
    try testing.expectEqual(b.len, 110 + 5 + pad4(115) + 2 + pad4(2));

    out.clearRetainingCapacity();
    try cpioEntry(
        &out.writer,
        .{ .name = "dev/console", .mode = 0o020620, .ino = 2, .rdev_major = 5, .rdev_minor = 1 },
        "",
    );
    const c = out.written();
    try testing.expectEqualStrings("00002190", c[14..22]);
    try testing.expectEqualStrings("00000005", c[78..86]);
    try testing.expectEqualStrings("00000001", c[86..94]);
}

test unwrapZboot {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const plain = "not a zboot image, at all";
    try testing.expectEqualStrings(plain, try unwrapZboot(arena.allocator(), plain));
    var bad: [16]u8 = @splat(0);
    @memcpy(bad[4..8], "zimg");
    std.mem.writeInt(u32, bad[8..12], 8, .little);
    std.mem.writeInt(u32, bad[12..16], 100, .little);
    try testing.expectError(error.BadZboot, unwrapZboot(arena.allocator(), &bad));
}
