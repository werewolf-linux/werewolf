//! Promises: what a program may do, in a few words, and the system calls
//! each word brings (docs/design/pledge.md, System calls: promises). The
//! seal (cmd/init) allows the promises the machine makes, leash a service's
//! own, and seal-watch and `seal` name a refused call by the promise that
//! would allow it. Which calls a word brings is known here alone, for both
//! architectures: a name the one being built for lacks is passed over.

const std = @import("std");
const linux = std.os.linux;

pub const Promise = enum(u5) {
    stdio,
    rpath,
    watch,
    wpath,
    inet,
    unix,
    netlink,
    packet,
    connect,
    listen,
    proc,
    exec,
    setuid,
    setgid,
    setgroups,
    caps,
    chroot,
    mount,
    umount,
    namespace,
    seccomp,
    landlock,
    memfd,
    ipc,
    mlock,
    aio,
    settime,
    hostname,
    syslog,
    reboot,
};

/// A set of promises.
pub const Set = std.EnumSet(Promise);

/// The calls each promise brings, by name. inet, unix, netlink and packet
/// bring socket (and unix socketpair): the seal cannot tell their families
/// apart, so it allows socket for any of them, and leash, per service,
/// checks the family.
const table = [_]struct { p: Promise, names: []const []const u8 }{
    .{ .p = .stdio, .names = &.{
        "read",                   "write",              "readv",
        "writev",                 "pread64",            "pwrite64",
        "preadv",                 "pwritev",            "preadv2",
        "pwritev2",               "close",              "close_range",
        "dup",                    "dup2",               "dup3",
        "lseek",                  "fstat",              "newfstatat",
        "fstatat64",              "statx",              "fcntl",
        "ioctl",                  "flock",              "fsync",
        "fdatasync",              "fadvise64",          "readahead",
        "sendfile",               "splice",             "tee",
        "copy_file_range",        "mmap",               "munmap",
        "mprotect",               "mremap",             "madvise",
        "brk",                    "msync",              "mincore",
        "membarrier",             "futex",              "futex_waitv",
        "set_robust_list",        "get_robust_list",    "set_tid_address",
        "rseq",                   "rt_sigaction",       "rt_sigprocmask",
        "rt_sigreturn",           "rt_sigtimedwait",    "rt_sigsuspend",
        "rt_sigpending",          "sigaltstack",        "restart_syscall",
        "nanosleep",              "clock_nanosleep",    "clock_gettime",
        "clock_getres",           "gettimeofday",       "time",
        "times",                  "getitimer",          "setitimer",
        "alarm",                  "pause",              "timer_create",
        "timer_settime",          "timer_gettime",      "timer_getoverrun",
        "timer_delete",           "timerfd_create",     "timerfd_settime",
        "timerfd_gettime",        "exit",               "exit_group",
        "getpid",                 "gettid",             "getppid",
        "getuid",                 "geteuid",            "getgid",
        "getegid",                "getresuid",          "getresgid",
        "getgroups",              "getpgid",            "getpgrp",
        "getsid",                 "getrlimit",          "prlimit64",
        "getrusage",              "sysinfo",            "uname",
        "getcpu",                 "sched_yield",        "sched_getaffinity",
        "sched_getparam",         "sched_getscheduler", "sched_get_priority_max",
        "sched_get_priority_min", "getpriority",        "getrandom",
        "pipe",                   "pipe2",              "poll",
        "ppoll",                  "select",             "pselect6",
        "epoll_create",           "epoll_create1",      "epoll_ctl",
        "epoll_wait",             "epoll_pwait",        "epoll_pwait2",
        "eventfd",                "eventfd2",           "signalfd",
        "signalfd4",              "sendto",             "recvfrom",
        "sendmsg",                "recvmsg",            "sendmmsg",
        "recvmmsg",               "getsockopt",         "setsockopt",
        "getsockname",            "getpeername",        "shutdown",
        "prctl",                  "capget",             "arch_prctl",
        "umask",                  "get_mempolicy",
    } },
    .{ .p = .rpath, .names = &.{
        "open",       "openat",     "openat2",    "getdents",
        "getdents64", "readlink",   "readlinkat", "access",
        "faccessat",  "faccessat2", "stat",       "lstat",
        "statfs",     "fstatfs",    "getcwd",     "chdir",
        "fchdir",     "getxattr",   "lgetxattr",  "fgetxattr",
        "listxattr",  "llistxattr", "flistxattr",
    } },
    // inotify sees file events by name even where Landlock denies the
    // directory (it does not mediate fsnotify), so watching is its own
    // promise, off unless a service asks: a service that only reads files
    // cannot watch the machine's activity.
    .{ .p = .watch, .names = &.{
        "inotify_init",     "inotify_init1", "inotify_add_watch",
        "inotify_rm_watch", "fanotify_init", "fanotify_mark",
    } },
    .{ .p = .wpath, .names = &.{
        "creat",     "mkdir",       "mkdirat",         "rmdir",
        "unlink",    "unlinkat",    "rename",          "renameat",
        "renameat2", "link",        "linkat",          "symlink",
        "symlinkat", "chmod",       "fchmod",          "fchmodat",
        "fchmodat2", "chown",       "fchown",          "fchownat",
        "lchown",    "truncate",    "ftruncate",       "fallocate",
        "utime",     "utimes",      "utimensat",       "futimesat",
        "mknod",     "mknodat",     "setxattr",        "lsetxattr",
        "fsetxattr", "removexattr", "lremovexattr",    "fremovexattr",
        "sync",      "syncfs",      "sync_file_range",
    } },
    .{ .p = .inet, .names = &.{"socket"} },
    .{ .p = .unix, .names = &.{ "socket", "socketpair" } },
    .{ .p = .netlink, .names = &.{"socket"} },
    .{ .p = .packet, .names = &.{"socket"} },
    .{ .p = .connect, .names = &.{"connect"} },
    .{ .p = .listen, .names = &.{ "bind", "listen", "accept", "accept4" } },
    .{ .p = .proc, .names = &.{
        "clone",             "clone3",          "fork",               "vfork",
        "wait4",             "waitid",          "kill",               "tkill",
        "tgkill",            "rt_sigqueueinfo", "rt_tgsigqueueinfo",  "setpgid",
        "setsid",            "pidfd_open",      "pidfd_send_signal",  "setpriority",
        "sched_setaffinity", "sched_setparam",  "sched_setscheduler", "sched_setattr",
        "sched_getattr",
    } },
    .{ .p = .exec, .names = &.{ "execve", "execveat" } },
    .{ .p = .setuid, .names = &.{ "setuid", "setreuid", "setresuid", "setfsuid" } },
    .{ .p = .setgid, .names = &.{ "setgid", "setregid", "setresgid", "setfsgid" } },
    .{ .p = .setgroups, .names = &.{"setgroups"} },
    .{ .p = .caps, .names = &.{"capset"} },
    .{ .p = .chroot, .names = &.{"chroot"} },
    .{ .p = .mount, .names = &.{
        "mount",      "fsopen",     "fsconfig",  "fsmount",
        "fspick",     "move_mount", "open_tree", "mount_setattr",
        "pivot_root",
    } },
    .{ .p = .umount, .names = &.{ "umount2", "umount" } },
    .{ .p = .namespace, .names = &.{ "unshare", "setns" } },
    .{ .p = .seccomp, .names = &.{"seccomp"} },
    .{
        .p = .landlock,
        .names = &.{ "landlock_create_ruleset", "landlock_add_rule", "landlock_restrict_self" },
    },
    .{ .p = .memfd, .names = &.{ "memfd_create", "memfd_secret" } },
    .{ .p = .ipc, .names = &.{
        "shmget", "shmat",  "shmdt",      "shmctl",
        "semget", "semop",  "semtimedop", "semctl",
        "msgget", "msgsnd", "msgrcv",     "msgctl",
    } },
    .{ .p = .mlock, .names = &.{ "mlock", "mlock2", "munlock", "mlockall", "munlockall" } },
    // Legacy asynchronous file I/O (not io_uring, which no promise brings):
    // nginx sets up an AIO context at startup.
    .{ .p = .aio, .names = &.{
        "io_setup",             "io_destroy",   "io_submit",
        "io_cancel",            "io_getevents", "io_pgetevents",
        "io_pgetevents_time64",
    } },
    .{ .p = .settime, .names = &.{ "settimeofday", "clock_settime", "clock_adjtime", "adjtimex" } },
    .{ .p = .hostname, .names = &.{ "sethostname", "setdomainname" } },
    .{ .p = .syslog, .names = &.{"syslog"} },
    .{ .p = .reboot, .names = &.{"reboot"} },
};

/// The calls each promise brings on this architecture, by promise.
const by_promise = blk: {
    var lists: [std.enums.values(Promise).len][]const linux.SYS = @splat(&.{});
    for (table) |e| for (e.names) |name| {
        if (@hasField(linux.SYS, name))
            lists[@backingInt(e.p)] = lists[@backingInt(e.p)] ++
                [_]linux.SYS{@field(linux.SYS, name)};
    };
    break :blk lists;
};

/// The calls promise p brings on this architecture.
pub fn calls(p: Promise) []const linux.SYS {
    return by_promise[@backingInt(p)];
}

/// The promises that bring the call numbered nr, or none.
pub fn promisesOf(nr: u32) Set {
    var set: Set = .empty;
    for (std.enums.values(Promise)) |p| {
        for (calls(p)) |sys| if (@backingInt(sys) == nr) set.insert(p);
    }
    return set;
}

/// The words of a pledge, as a set; an unknown word is an error, with bad
/// set to it.
pub fn parse(words: []const u8, bad: *[]const u8) !Set {
    var set: Set = .empty;
    var it = std.mem.tokenizeAny(u8, words, " \t\n");
    while (it.next()) |w| {
        bad.* = w;
        set.insert(std.meta.stringToEnum(Promise, w) orelse return error.UnknownPromise);
    }
    return set;
}

/// What werewolf's own programs promise between them, which every machine
/// makes: init's after the seal, fence, runit and its services, the mount
/// broker, leash before it confines a service, posture, the updater and
/// the DHCP client; and `syslog`, so `dmesg` can read the kernel's log
/// (dmesg_restrict still keeps it to root). Each confines itself further,
/// or will (pledge.md, Order).
pub const base: Set = .initMany(&.{
    .stdio,  .rpath,  .wpath,   .inet,     .unix,   .netlink,   .packet, .connect,
    .listen, .proc,   .exec,    .setuid,   .setgid, .setgroups, .caps,   .chroot,
    .mount,  .umount, .seccomp, .landlock, .reboot, .syslog,
});

/// The system calls no promise brings, whatever a pledge says, each where
/// the architecture has it:
///
///   bpf, perf_event_open           eBPF and kernel tracing, which rootkits
///                                  are made of
///   init_module .. delete_module   modules: the loader closed already
///   kexec_load, kexec_file_load    another kernel: lockdown refuses already
///   io_uring_*                     makes kernel.io_uring_disabled permanent
///   userfaultfd                    the usual way to win a kernel race
///   open_by_handle_at, name_..     walking past mounts by inode handle
///   add_key, keyctl, request_key   the kernel keyring; cryptsetup is done
///                                  with it before init hands over
///   process_vm_readv, _writev      another process's memory: Yama refuses
///   modify_ldt, iopl, ioperm       16-bit code and I/O ports
///   acct .. vhangup                unused here; old, rarely audited code
const never_names = [_][]const u8{
    "bpf",               "perf_event_open",   "init_module",     "finit_module",
    "delete_module",     "kexec_load",        "kexec_file_load", "io_uring_setup",
    "io_uring_enter",    "io_uring_register", "userfaultfd",     "open_by_handle_at",
    "name_to_handle_at", "add_key",           "keyctl",          "request_key",
    "process_vm_readv",  "process_vm_writev", "modify_ldt",      "iopl",
    "ioperm",            "acct",              "swapon",          "swapoff",
    "quotactl",          "quotactl_fd",       "lookup_dcookie",  "uselib",
    "vhangup",
};

/// Those of never_names this architecture has.
pub const never: []const linux.SYS = blk: {
    var list: []const linux.SYS = &.{};
    for (never_names) |name| {
        if (@hasField(linux.SYS, name)) list = list ++ [_]linux.SYS{@field(linux.SYS, name)};
    }
    break :blk list;
};

// --- filters -------------------------------------------------------------------

pub const Filter = extern struct { code: u16, jt: u8, jf: u8, k: u32 };

const LD_W_ABS = 0x20;
const JEQ_K = 0x15;
const JGE_K = 0x35;
const JSET_K = 0x45;
const RET_K = 0x06;
pub const RET_KILL_PROCESS: u32 = 0x80000000;
pub const RET_USER_NOTIF: u32 = 0x7fc00000;
pub const RET_ERRNO: u32 = 0x00050000;
pub const RET_ALLOW: u32 = 0x7fff0000;
/// A refused call fails as if the kernel had no such call, which programs
/// expect of an older kernel and handle.
pub const RET_ENOSYS: u32 = RET_ERRNO | @as(u32, @backingInt(linux.E.NOSYS));

/// The architecture every system call must come in as. Any other, which on
/// aarch64 is a 32-bit (AArch32) program's, kills the process: werewolf ships
/// no 32-bit code, and the kernel has no switch to turn those calls off.
pub const native_arch: u32 = switch (@import("builtin").cpu.arch) {
    .aarch64 => 0xc00000b7, // AUDIT_ARCH_AARCH64
    .x86_64 => 0xc000003e, // AUDIT_ARCH_X86_64
    else => unreachable,
};

const max_calls = 512;
pub const max_filter = 6 + 4 + 2 * 5 + 5 + 2 * max_calls + 1;
const AT_EMPTY_PATH = 0x1000;

/// The socket families each socket promise brings.
const families = [_]struct { p: Promise, af: u32 }{
    .{ .p = .unix, .af = linux.AF.UNIX },
    .{ .p = .inet, .af = linux.AF.INET },
    .{ .p = .inet, .af = linux.AF.INET6 },
    .{ .p = .netlink, .af = linux.AF.NETLINK },
    .{ .p = .packet, .af = linux.AF.PACKET },
};

/// A seccomp filter allowing the calls of promises, and handing the rest
/// to the listener (seal-watch). Load the architecture; kill another; load
/// the number; each promised call allowed. Each comparison is followed by
/// its own return, so no jump is longer than a few instructions, however
/// many calls. On x86_64 a number with bit 30 set is an x32 call, under
/// x86_64's own architecture: it would pass every comparison as another
/// number, so it kills the process too.
///
/// The seal's (per_service false) reads numbers, never arguments, so the
/// kernel answers every allowed call from its cache. A service's (true)
/// also reads socket's family, its first argument: a service makes few
/// sockets, and inet, unix, netlink and packet are the family. And without
/// exec, it allows only execveat of a descriptor (AT_EMPTY_PATH), which is
/// how leash becomes the service: Landlock lets a service run only the
/// program it is, so a service that did not pledge exec can become itself
/// again and nothing else.
pub fn buildFilter(buf: *[max_filter]Filter, promises: Set, per_service: bool) []const Filter {
    // A service's own filter refuses with ENOSYS, needing no listener (so
    // leash installs it after dropping CAP_SYS_ADMIN); the machine seal's,
    // on PID 1, hands the rest to seal-watch to say and count.
    const other = if (per_service) RET_ENOSYS else RET_USER_NOTIF;
    var n: usize = 0;
    const put = struct {
        fn f(b: *[max_filter]Filter, i: *usize, code: u16, jt: u8, jf: u8, k: u32) void {
            b[i.*] = .{ .code = code, .jt = jt, .jf = jf, .k = k };
            i.* += 1;
        }
    }.f;
    put(buf, &n, LD_W_ABS, 0, 0, 4); // seccomp_data.arch
    put(buf, &n, JEQ_K, 1, 0, native_arch);
    put(buf, &n, RET_K, 0, 0, RET_KILL_PROCESS);
    put(buf, &n, LD_W_ABS, 0, 0, 0); // seccomp_data.nr
    if (@import("builtin").cpu.arch == .x86_64) {
        put(buf, &n, JGE_K, 0, 1, 0x40000000); // __X32_SYSCALL_BIT
        put(buf, &n, RET_K, 0, 0, RET_KILL_PROCESS);
    }
    const socket: u32 = @intCast(@backingInt(linux.SYS.socket));
    if (per_service and !promises.contains(.exec)) {
        put(buf, &n, JEQ_K, 0, 4, @intCast(@backingInt(linux.SYS.execveat)));
        put(buf, &n, LD_W_ABS, 0, 0, 48); // seccomp_data.args[4], low word: flags
        put(buf, &n, JSET_K, 0, 1, AT_EMPTY_PATH);
        put(buf, &n, RET_K, 0, 0, RET_ALLOW);
        put(buf, &n, RET_K, 0, 0, other);
    }
    if (per_service) {
        var afs: [families.len]u32 = undefined;
        var m: usize = 0;
        for (families) |f| if (promises.contains(f.p)) {
            afs[m] = f.af;
            m += 1;
        };
        // socket: its family, the low word of args[0] (both architectures
        // are little-endian), against each promised; else the listener.
        put(buf, &n, JEQ_K, 0, @intCast(2 + 2 * m), socket);
        put(buf, &n, LD_W_ABS, 0, 0, 16); // seccomp_data.args[0], low word
        for (afs[0..m]) |af| {
            put(buf, &n, JEQ_K, 0, 1, af);
            put(buf, &n, RET_K, 0, 0, RET_ALLOW);
        }
        put(buf, &n, RET_K, 0, 0, other);
    }
    var seen: [max_calls]u32 = undefined;
    var n_seen: usize = 0;
    var it = promises.iterator();
    while (it.next()) |p| for (calls(p)) |sys| {
        const nr: u32 = @intCast(@backingInt(sys));
        if (per_service and nr == socket) continue;
        if (std.mem.findScalar(u32, seen[0..n_seen], nr) != null) continue;
        seen[n_seen] = nr;
        n_seen += 1;
        put(buf, &n, JEQ_K, 0, 1, nr);
        put(buf, &n, RET_K, 0, 0, RET_ALLOW);
    };
    put(buf, &n, RET_K, 0, 0, other);
    return buf[0..n];
}

/// Install filter on this thread. With listener (the machine seal, on
/// PID 1, which holds CAP_SYS_ADMIN), the result is a notification
/// descriptor for seal-watch; without it (a service, after dropping
/// capabilities), there is none, and no_new_privs is enough.
pub fn install(filter: []const Filter, listener: bool) !i32 {
    const SECCOMP_SET_MODE_FILTER = 1;
    const SECCOMP_FILTER_FLAG_NEW_LISTENER = 1 << 3;
    const prog = extern struct { len: u16, filter: [*]const Filter }{
        .len = @intCast(filter.len),
        .filter = filter.ptr,
    };
    const rc = linux.seccomp(
        SECCOMP_SET_MODE_FILTER,
        if (listener) SECCOMP_FILTER_FLAG_NEW_LISTENER else 0,
        &prog,
    );
    if (linux.errno(rc) != .SUCCESS) return error.Seccomp;
    return if (listener) @intCast(rc) else -1;
}

/// fd, sent over sock (SCM_RIGHTS) with bytes: from init, l to learn or e
/// to enforce; from leash, the service's name.
pub fn sendListener(sock: i32, fd: i32, bytes: []const u8) bool {
    var control: [24]u8 align(8) = @splat(0);
    const e = @import("builtin").cpu.arch.endian();
    std.mem.writeInt(usize, control[0..8], 20, e); // CMSG_LEN(sizeof(int))
    std.mem.writeInt(i32, control[8..12], linux.SOL.SOCKET, e);
    std.mem.writeInt(i32, control[12..16], 1, e); // SCM_RIGHTS
    std.mem.writeInt(i32, control[16..20], fd, e);
    const iov = [_]std.posix.iovec_const{.{ .base = bytes.ptr, .len = bytes.len }};
    const msg: linux.msghdr_const = .{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = 1,
        .control = &control,
        .controllen = control.len,
        .flags = 0,
    };
    return linux.errno(linux.sendmsg(sock, &msg, linux.MSG.NOSIGNAL)) == .SUCCESS;
}

/// Where init writes the seal it installed: `mode enforce|learn`, then
/// `promises WORD...`, one line each.
pub const policy_path = "/run/werewolf/seal/policy";
/// Where seal-watch counts what it refused, one line a call and asker:
/// `NAME COUNT LAST_PID FIRST_SECONDS PROMISE WHO`, WHO the service's name,
/// or - for the seal itself.
pub const refused_path = "/run/werewolf/seal/refused";

const testing = std.testing;

/// What a filter returns for a call: run as the kernel runs it, for the
/// few instructions these use.
fn action(filter: []const Filter, arch: u32, nr: u32, arg0: u32) u32 {
    var a: u32 = 0;
    var pc: usize = 0;
    while (true) {
        const i = filter[pc];
        switch (i.code) {
            LD_W_ABS => a = switch (i.k) {
                4 => arch,
                0 => nr,
                16, 48 => arg0,
                else => unreachable,
            },
            JSET_K => pc += if (a & i.k != 0) i.jt else i.jf,
            JEQ_K => pc += if (a == i.k) i.jt else i.jf,
            JGE_K => pc += if (a >= i.k) i.jt else i.jf,
            RET_K => return i.k,
            else => unreachable,
        }
        pc += 1;
    }
}

fn nrOf(sys: linux.SYS) u32 {
    return @intCast(@backingInt(sys));
}

test buildFilter {
    var buf: [max_filter]Filter = undefined;
    // Every promise at once fits.
    _ = buildFilter(&buf, .full, true);
    const machine = buildFilter(&buf, .initMany(&.{ .stdio, .inet }), false);
    try testing.expectEqual(RET_ALLOW, action(machine, native_arch, nrOf(.read), 0));
    try testing.expectEqual(RET_ALLOW, action(machine, native_arch, nrOf(.socket), linux.AF.UNIX));
    // The machine seal hands the rest to the listener (seal-watch).
    try testing.expectEqual(RET_USER_NOTIF, action(machine, native_arch, nrOf(.memfd_create), 0));
    for (never) |sys| try testing.expectEqual(
        RET_USER_NOTIF,
        action(machine, native_arch, nrOf(sys), 0),
    );
    try testing.expectEqual(RET_KILL_PROCESS, action(machine, 0x40000028, 0, 0)); // AUDIT_ARCH_ARM
    try testing.expectEqual(RET_KILL_PROCESS, action(machine, 0x40000003, 0, 0)); // AUDIT_ARCH_I386
    if (@import("builtin").cpu.arch == .x86_64)
        try testing.expectEqual(
            RET_KILL_PROCESS,
            action(machine, native_arch, 0x40000000 | nrOf(.read), 0),
        );

    // A service's own filter refuses with ENOSYS, needing no listener.
    const service = buildFilter(&buf, .initMany(&.{ .stdio, .inet }), true);
    try testing.expectEqual(RET_ALLOW, action(service, native_arch, nrOf(.socket), linux.AF.INET));
    try testing.expectEqual(RET_ALLOW, action(service, native_arch, nrOf(.socket), linux.AF.INET6));
    try testing.expectEqual(RET_ENOSYS, action(service, native_arch, nrOf(.socket), linux.AF.UNIX));
    try testing.expectEqual(
        RET_ENOSYS,
        action(service, native_arch, nrOf(.socketpair), linux.AF.UNIX),
    );
    try testing.expectEqual(RET_ALLOW, action(service, native_arch, nrOf(.write), 0));
    try testing.expectEqual(RET_ENOSYS, action(service, native_arch, nrOf(.clone), 0));
    // The findings' risky calls, refused to a plain reader-and-server.
    for ([_]linux.SYS{
        .memfd_create,
        .shmget,
        .msgget,
        .inotify_add_watch,
        .ptrace,
        .unshare,
    }) |sys|
        try testing.expectEqual(RET_ENOSYS, action(service, native_arch, nrOf(sys), 0));

    // Without exec: execveat of a descriptor, the way leash becomes the
    // service, and nothing else that runs a program.
    try testing.expectEqual(
        RET_ALLOW,
        action(service, native_arch, nrOf(.execveat), AT_EMPTY_PATH),
    );
    try testing.expectEqual(RET_ENOSYS, action(service, native_arch, nrOf(.execveat), 0));
    try testing.expectEqual(RET_ENOSYS, action(service, native_arch, nrOf(.execve), 0));
    const exec = buildFilter(&buf, .initMany(&.{ .stdio, .exec }), true);
    try testing.expectEqual(RET_ALLOW, action(exec, native_arch, nrOf(.execve), 0));
    try testing.expectEqual(RET_ALLOW, action(exec, native_arch, nrOf(.execveat), 0));

    const none = buildFilter(&buf, .initMany(&.{.stdio}), true);
    try testing.expectEqual(RET_ENOSYS, action(none, native_arch, nrOf(.socket), linux.AF.INET));
    try testing.expectEqual(RET_ALLOW, action(none, native_arch, nrOf(.read), 0));

    // The longest filter, every promise, still fits the kernel's 4096.
    const biggest = buildFilter(&buf, .full, true);
    try testing.expect(biggest.len <= 4096);
    // No never call is ever allowed, even by the fullest filter.
    for (never) |sys| try testing.expectEqual(
        RET_ENOSYS,
        action(biggest, native_arch, nrOf(sys), 0),
    );
}

test calls {
    // No promise brings a never call.
    for (std.enums.values(Promise)) |p| {
        for (calls(p)) |sys| try testing.expect(std.mem.findScalar(linux.SYS, never, sys) == null);
    }
    try testing.expect(std.mem.findScalar(linux.SYS, calls(.memfd), .memfd_create) != null);
}

test promisesOf {
    const socket: u32 = @intCast(@backingInt(linux.SYS.socket));
    try testing.expect(promisesOf(socket).contains(.inet));
    try testing.expect(promisesOf(socket).contains(.unix));
    try testing.expect(promisesOf(@intCast(@backingInt(linux.SYS.memfd_create))).contains(.memfd));
    // inotify is `watch`, not `rpath`, so reading files does not bring it.
    const inotify: u32 = @intCast(@backingInt(linux.SYS.inotify_add_watch));
    try testing.expect(promisesOf(inotify).contains(.watch));
    try testing.expect(!promisesOf(inotify).contains(.rpath));
    // ptrace belongs to no promise, so nothing can ask for it.
    try testing.expectEqual(
        @as(usize, 0),
        promisesOf(@intCast(@backingInt(linux.SYS.ptrace))).count(),
    );
    // Every never call belongs to no promise.
    for (never) |sys| try testing.expectEqual(
        @as(usize, 0),
        promisesOf(@intCast(@backingInt(sys))).count(),
    );
}

test "no promise grants a risky call" {
    // The calls an escape would want, each reachable only through the one
    // narrow promise that names it, never a broad one.
    const Case = struct { sys: linux.SYS, want: Promise };
    const cases = [_]Case{
        .{ .sys = .memfd_create, .want = .memfd },
        .{ .sys = .execve, .want = .exec },
        .{ .sys = .setuid, .want = .setuid },
        .{ .sys = .setgid, .want = .setgid },
        .{ .sys = .setgroups, .want = .setgroups },
        .{ .sys = .capset, .want = .caps },
        .{ .sys = .chroot, .want = .chroot },
        .{ .sys = .mount, .want = .mount },
        .{ .sys = .umount2, .want = .umount },
        .{ .sys = .unshare, .want = .namespace },
        .{ .sys = .setns, .want = .namespace },
        .{ .sys = .shmget, .want = .ipc },
        .{ .sys = .settimeofday, .want = .settime },
        .{ .sys = .sethostname, .want = .hostname },
        .{ .sys = .inotify_add_watch, .want = .watch },
    };
    for (cases) |c| {
        const set = promisesOf(@intCast(@backingInt(c.sys)));
        var it = set.iterator();
        while (it.next()) |p| try testing.expectEqual(c.want, p);
        try testing.expect(set.contains(c.want));
    }
    // A plain reader-and-server pledge brings none of them.
    const plain: Set = .initMany(&.{ .stdio, .rpath, .inet, .listen });
    inline for (cases) |c| for (calls(c.want)) |sys| if (!plain.contains(c.want)) {
        try testing.expect(!hasCall(plain, @intCast(@backingInt(sys))));
    };
}

/// Whether the calls of promises include nr (test helper).
fn hasCall(promises: Set, nr: u32) bool {
    var it = promises.iterator();
    while (it.next()) |p| for (calls(p)) |sys| if (@backingInt(sys) == nr) return true;
    return false;
}

test parse {
    var bad: []const u8 = "";
    const set = try parse("stdio rpath\tinet\n", &bad);
    try testing.expect(set.contains(.inet) and !set.contains(.exec));
    try testing.expectError(error.UnknownPromise, parse("stdio ptrace", &bad));
    try testing.expectEqualStrings("ptrace", bad);
}
