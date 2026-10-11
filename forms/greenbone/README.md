# Greenbone - Hardened VM

Vulnerability management: [Greenbone](https://greenbone.github.io/docs/) gvmd and gsad, behind Caddy, with PostgreSQL. The form's manifest is [form.yaml](form.yaml).

## Security Posture

- gsad and gvmd listen on loopback. Caddy is what the network sees.
- The administrator is `admin`. The password is the config's, applied at every start. `admin` / `admin` is refused.
- gvmd's socket is not mode 0666. It listens on loopback TCP.
- PostgreSQL takes one role, over loopback, and only gvmd may connect.
- The image's bash runs one script, then gvmd. gsad is its own program. The host has no shell.
- gvmd's socket is mode 0666 so gvm-link can carry it to gsad. A command on it still needs the administrator password.

## Getting Started

### Local test deployment (lima, qemu, firecracker)

```sh
openssl rand -base64 18 >admin-password
howl create greenbone --with greenbone \
	--domain scan.home.arpa --admin-password admin-password
```

Open `https://scan.home.arpa` and sign in as `admin`. The password is in `admin-password`. Give the machine 4 GB. Tasks and targets are in [Greenbone's documentation](https://greenbone.github.io/docs/).

### Cloud production deployment (aws, gcp, azure, proxmox)

```sh
openssl rand -base64 18 >admin-password
howl create greenbone --with greenbone --on gcp --allow-from me \
	--domain scan.example.com --admin-password admin-password
```

Sign in at `https://scan.example.com`. This machine does not scan from itself.

### Importing data

The database starts empty. This form does not import a Greenbone dump.

### Known Quirks

- gvmd listens on a Unix socket, not a TCP port. gvm-link, as `_glink`, copies it into gsad's directory. The socket is mode 0666.
- There is no scanner and no feed on this machine. A scan needs a scanner beside it.
- The database password is not a secret: only gvmd can open the port.
- Twelve characters at least, and not `admin`.

### Network Exposure

- listen: tcp/80 tcp/443 *
- connect: udp/53 tcp/53 *
