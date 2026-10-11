# gvm-link

## Summary

gvm-link copies bytes between gsad and gvmd. The two images do not share a directory, and gsad talks to the manager only over a Unix socket.

## Background

gvmd and gsad are separate images. Each one's `/run` is its own directory on the host. gsad has no TCP address for the manager, only `GSAD_MANAGER_UNIX_SOCKET`. A mode 0666 socket would let every local user speak GMP to gvmd.

## Goals

- gsad can open the manager socket. No other user can.
- gvm-link can open gvmd's socket, and holds no other privilege while it does.
- The check `greenbone-bind` sees mode 0660, and `greenbone-link` sees `_oci-gvmd` in gvm-link's groups.

## Non-Goals

- Scanning, or the Greenbone feed.
- A shared writable volume between the two images. werewolf does not have one.

## Detailed design

runit starts gvm-link as root, because the socket has to be created in gsad's directory and that directory is not group-writable. `/etc/werewolf/gvm-link` names the two host paths. gvm-link binds the listen socket, gives it to `_glink` and the group `_oci-gsad`, mode 0660, then becomes `_glink` with only `_oci-gvmd` as a supplementary group and no capabilities. A system group, one below 65536, is refused. After that it accepts, connects and copies. A GMP command still needs the administrator password.

## Drawbacks

The forwarder is a program we maintain. It is the cost of two images that must share one socket.

## Alternatives Considered

- Mode 0666. Any local user could then open gvmd.
- Making gvm-link a leashed service with `group:`. The leash could set the group, and could not create a socket in gsad's directory.
- One image for both programs. The published images do not ship both binaries.
