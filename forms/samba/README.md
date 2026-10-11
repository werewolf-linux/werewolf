# Samba - Hardened VM

File shares over SMB: [Samba](https://www.samba.org), one directory per user. The form's manifest is [form.yaml](form.yaml).

## Security Posture

- smbd runs as its own user. The root is read-only. Files live on `/data`.
- SMB3 only. Encryption and signing are required. NetBIOS is off.
- There is no guest and no anonymous login. A share names its one user.
- Printers are off. A share does not follow a symlink out of itself.
- smbd sets its umask to 0 and applies the share's create mask itself. A new file is mode 0600.

## Getting Started

### Local test deployment (lima, qemu, firecracker)

```sh
umask 077
printf '%s\n' "alice:$(openssl rand -base64 18)" >users
howl create samba --with samba --users users
```

Each line of `users` is `name:password`. The share has that name. A client is in [Samba's documentation](https://www.samba.org/samba/docs/current/man-html/smbclient.1.html).

```text
smbclient //ADDRESS/alice -U alice
```

### Cloud production deployment (aws, gcp, azure, proxmox)

```sh
umask 077
printf '%s\n' "alice:$(openssl rand -base64 18)" >users
howl create samba --with samba --on gcp --allow-from me --users users
```

`--allow-from me` admits your address to port 445.

### Importing data

There is no database to import. After the share answers, copy files in with an SMB client. Each user's files are that user's directory.

### Known Quirks

- A password is ASCII, 8 to 128 characters, with no colon. A trailing newline on the file is the end of the last line.
- Changing `users` and creating again replaces the passwords. A directory already on `/data` is kept.
- The address is the server. There is no NetBIOS name.

### Network Exposure

- listen: tcp/445 *
