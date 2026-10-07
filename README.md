# werewolf

<img src="docs/media/logo-small.png" alt="werewolf logo" width="160" align="right">

werewolf is a security paranoid, high-performance Linux distro for VMs.

Our idea is: build a declarative Linux distribution so secure that your
software runs amazing on it, but impossible to execute malware on it.

werewolf takes inspiration from ChromeOS (signing, A/B upgrades), OpenBSD (pledge),
and Chainguard OS (shell-free images). It mixes an [Alpine](https://www.alpinelinux.org/) kernel,
[Wolfi](https://wolfi.dev/) packages, and it's own OpenBSD-style
privilege-separated binaries for basic functions such as auto-updates. Images are composed using [apko](https://github.com/chainguard-dev/apko).

## Secure by default

- **Declarative, Reproducible**: Uses apko (YAML) to declare what software can run within a VM; nothing else will. 
- **[Signed Binaries]**: by default, Werewolf only runs programs included in the build.
- **[Landlock/Seccomp Everywhere](docs/design/lockdown.md)**: all programs inherit a secure-by-default: including disabling ptrace, io_uring, /dev/kmem
- **[Application firewalling]**: every application defines which ports they listen on and connect to, violations are logged. 
- **[Shell-free execution](docs/design/shell-free.md)** Don't need a shell? Don't include it.
- All writeable partitions disallow execution: no /dev/shm droppers here!
- **[Privilege separation.](docs/programs.md)** werewolf's own programs are
  small static Zig binaries in the privilege-separated OpenBSD style. The half that reads untrusted input
  runs as its own user, chrooted, with no capabilities, under seccomp.
- **[Auditable updates.](docs/updater.md)** Packages and kernel come straight
  from Wolfi and Alpine, with no build server between. Each update logs the
  CVEs it fixes. A new image boots once and stays only if it stays healthy.
- **Damn Small.** Our `minimal` image is only 3MB and 7 packages large.
- **[Posture Tested.](docs/testing.md)** Every push asserts our security posture against dozens of attacks.

## Try it

```sh
make install-deps          # macOS, Debian, Ubuntu, Fedora, Arch; FreeBSD: tools/install-deps
make lima                  # build, boot and ssh in (macOS)

# or with QEMU alone
make run                   # the sshd form, with a root shell on the console
make run FORM=prod         # the production base: no shell, nothing listening
make run FORM=prod DEV=1   # the same, with a shell added for debugging
make run-ssh               # from another terminal
make webshell-demo         # a deliberately vulnerable web app on :8080; try to escape it
```

`posture` runs at every boot and prints what passed and what did not. It is
a static binary that assumes nothing about werewolf, so copy it to any Linux
machine and compare. See [docs/posture.md](docs/posture.md).

## Configure it

Secrets travel in a config tar. Put `authorized_keys`, `hostname` and
`data.key`, which puts `/data` in LUKS2, in `config/`, which is gitignored, and run
`make config-tar`. init finds the tar raw on any block device or in the
cloud's user data, and leaves it in `/run/config`, readable by root alone.
See [docs/cloud.md](docs/cloud.md).

## Forms

A form is an apko config in `forms/<name>.yaml`, with optional files, kernel
modules and network policy beside it. Forms build on each other, and every
one includes `minimal`. `make list-forms` shows the include chains.

| Form | What it is |
|---|---|
| `minimal` | the base: 9 packages, nothing listening |
| `prod` | DHCP, the cloud's metadata, updates itself, `/data` on a disk (in LUKS2 with `data.key`); no shell, nothing listening. Build yours on this. |
| `app` | `prod` plus an unprivileged application user and group; no runtime or service |
| `prod-ssh` | `prod` plus sshd |
| `bastion` | forwarding-only SSH with explicit destinations and hybrid post-quantum key exchange ([setup](docs/bastion.md)) |
| `tailscale` | unprivileged, userspace subnet router ([setup](docs/tailscale.md)) |
| `nginx`, `php`, `node`, `python`, `jre` | `prod` and one runtime, leashed: bake your site or application into a form on one ([docs/forms.md](docs/forms.md)) |
| `postgresql`, `demo` | leashed services |
| `webshell-example` | a deliberately vulnerable web app, to show the sandbox holds (`make webshell-demo`) |

CI publishes `minimal`, `prod` and `prod-ssh` as signed, reproducible releases. See
[docs/releases.md](docs/releases.md).

Build an application and run it on QEMU or GCP:
[PHP](examples/php/README.md), [Python](examples/python/README.md),
[Node.js](examples/nodejs/README.md), [Go](examples/go/README.md),
[Rust](examples/rust/README.md) or [ASP.NET Core](examples/aspnet/README.md).

## Take over an existing VM

When a provider will not boot a custom image, run `make bite-me` on a
Debian, Ubuntu, Fedora or Rocky VM. It installs werewolf beside the distro,
opens a shell in it, and offers to reboot. werewolf becomes the default only
after a healthy minute. See [docs/bite.md](docs/bite.md).

## Documentation

- [examples/](examples/README.md): shared build tools and QEMU/GCP setup for the application tutorials
- [docs/forms.md](docs/forms.md): the forms, and building your application into one
- [docs/programs.md](docs/programs.md): the programs in `cmd/` and what confines them in `lib/`
- [docs/data.md](docs/data.md): `/data`, disks and encryption
- [docs/postgresql.md](docs/postgresql.md) and [docs/demo.md](docs/demo.md): running a leashed service
- [docs/roadmap.md](docs/roadmap.md): what comes next
