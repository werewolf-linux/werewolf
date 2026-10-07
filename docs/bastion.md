# SSH bastion

`bastion` inherits `prod` and runs OpenSSH as user `bastion`, not root.
It permits local TCP forwarding only: no shell, commands, SFTP, agent
forwarding, remote forwarding or tunnels. The base form permits no
destinations.

## Configure it

Create `forms/my-bastion.yaml`:

```yaml
include: bastion.yaml
```

Create `forms/my-bastion/etc/ssh/bastion-destinations.conf`:

```text
PermitOpen 10.20.0.10:22 10.20.0.11:22
```

Use exact addresses and ports, not wildcards. Clients must request those
same addresses. To allow a port other than 22, also copy the base service
file into your overlay and add that port to `connect`; add a corresponding
`connect bastion tcp/PORT` rule to `forms/my-bastion.net`.

Supply credentials separately from the image. Generate the host key once;
keep it for subsequent boots and verify its fingerprint with your clients:

```sh
mkdir -p config/bastion
chmod 700 config/bastion
ssh-keygen -t ed25519 -N '' -f config/bastion/host_key
cp ~/.ssh/id_ed25519.pub config/bastion/authorized_keys
chmod 600 config/bastion/host_key config/bastion/authorized_keys
ssh-keygen -lf config/bastion/host_key.pub
make FORM=my-bastion run
```

Use your own public-key path in the `cp` command. Do not replace an
existing host key unless you intend to rotate it. Leash copies only the
two named files into `/run/svc/sshd`, owned by `bastion`, mode `0600`.
Missing credentials keep SSH down.

For the QEMU instance, forward a local port:

```sh
ssh -p 2222 -N -L 127.0.0.1:2200:10.20.0.10:22 bastion@127.0.0.1
```

Verify the displayed host fingerprint before accepting it. In another
terminal, connect to your destination through port 2200. The destination
still authenticates you with its own account and key. QEMU's host must be
able to reach the destination.

## Deploy and update

Build a boot disk with `make FORM=my-bastion disk`. Supply the same config
tar through a config disk or [cloud metadata](cloud.md); restrict inbound
TCP 22 to your clients in the cloud firewall. The unprivileged server
cannot read other boot secrets. `PermitOpen` restricts forwarding requests;
the kernel policy separately limits outgoing TCP ports, not destination IPs.

Configuration is declarative: edit the form and rebuild, rather than
editing the running VM. On an A/B installation, Werewolf's updater rebuilds
the saved form with package updates. Policy edits need a new deployment;
credentials remain outside the image. See [releases.md](releases.md).

The server requires hybrid post-quantum key exchange (`mlkem768x25519` or
`sntrup761x25519`); incompatible clients cannot connect. Host and user
signatures remain Ed25519, not post-quantum. For `ProxyJump`, the connection
to the destination negotiates independently: configure that server too if
it must require post-quantum exchange. See [OpenSSH's explanation](https://www.openssh.org/pq.html)
and [forwarding controls](https://man.openbsd.org/sshd_config).
