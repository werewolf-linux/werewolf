# Suricata - Hardened VM

A network sensor: [Suricata](https://suricata.io) 8 reading one interface and writing alerts to `/data`. The form's manifest is [form.yaml](form.yaml).

## Security Posture

- span opens the packet socket and promiscuous mode, writes the pcap header, then becomes `_span` with no capabilities and a filter of `read`, `write`, `clock_gettime` and `exit_group`.
- Suricata runs as its own user. It reads the fifo and the rules in the image. It binds nothing and reaches nothing.
- The unix control socket is off. `suricata-update` and Python are not on the machine.

## Getting Started

### Local test deployment (lima, qemu, firecracker)

```sh
howl create suricata --with suricata
```

Alerts are in `/data/svc/suricata`. The one rule looks for the string `werewolf-suricata-marker` in HTTP. A ruleset of your own replaces `werewolf.rules` and is a new image. Rules are in [Suricata's documentation](https://docs.suricata.io/).

### Cloud production deployment (aws, gcp, azure, proxmox)

```sh
howl create suricata --with suricata --on gcp --allow-from me
```

Put the machine on a span port or a mirror. It still listens on nothing. GCP's network may not deliver traffic the VM did not address; a mirror on the hypervisor does.

### Importing data

There is nothing to import. Alerts from this machine are the files under `/data/svc/suricata`.

### Known Quirks

- No rule download. The image holds the rules.
- span's fifo is `/run/svc/suricata/feed`, mode 0400, Suricata's alone.
- Promiscuous mode is requested. Without `CAP_NET_ADMIN` the feed would be only what this host sends and receives; the form keeps that capability until span drops it.

### Network Exposure

- listen: none
- connect: none
