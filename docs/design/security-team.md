# A security team's machines

Built, 2026-10-10. Six of the ten uses have forms. The other four are
named here and are not built: each is a supervisor or a compose of
workers, which this platform will not start.

## Summary

The ten appliances a security team stands up for itself: collection,
detection, deception, vulnerability, intel, casework and identity
graphs. Where a form has an administrator, the published password
does not work. Elastic is not one of them. OpenSearch already is.

## Background

[corporate.md](corporate.md) is the company's shared services. A
security team adds machines that watch the rest. The ones that get
people breached are the sensor that is also a shell, the SIEM with
`admin/admin`, and the graph database with its HTTP open. A form here
is one leashed process, or a few, on one machine.

## Goals

- Each built form passes `make check-NAME` and `check-shellfree-NAME`.
- Its check ends in the login, or the socket, the defaults refuse.
- Capture is not a capability of the analyzer.

## Non-Goals

- Fleet beside Velociraptor, and any C2 or malware sandbox.
- Elastic Security, Security Onion, OpenCTI, TheHive, Cortex.
- Wazuh, MISP, Greenbone and DFIR-IRIS until each has one ELF to
  exec. Wazuh's `/init` is execline. The others are a compose, or an
  image whose command is not a server.

## Detailed design

span (`cmd/span`) opens one interface, writes a pcap header to a fifo,
drops to `_span` (uid 70) and keeps `read`, `write`, `clock_gettime`
and `exit_group`. Suricata and Zeek read the fifo. `packet` and
`netadmin` stay in the bounding set so span can open the socket; the
analyzers never have them.

| Form | State | Defaults; its check's attack |
| --- | --- | --- |
| `velociraptor` | built | keys generated on the machine; `admin` from the config at each start; GUI on loopback behind Caddy; clients on :8000 with mutual TLS; the server may run only its own binary; `admin`/`admin` and a stranger |
| `suricata` | built | span's fifo; the image's one rule; no unix socket, no rule download; the engine not root, the rules not writable |
| `zeek` | built | the same fifo, Zeek's `local` scripts, JSON logs on `/data`; the process not root |
| `dependency-track` | built | bundled jar, PostgreSQL on loopback, Caddy; `admin`/`admin` replaced before Caddy opens |
| `bloodhound` | built | CE behind Caddy; Neo4j Bolt on loopback, HTTP off; Cypher mutations off; the community-edition password refused |
| `wazuh` | not built | manager, indexer and dashboard are three entrypoints, and the manager's init is not an ELF |
| `opencanary` | built | Python on twistd, not the image's shell; FTP, SSH, HTTP, Telnet, RDP and VNC only; SMB and the host's logs off; a banner on :21, nothing on :445 |
| `misp` | not built | a compose of core and modules, started by a shell |
| `greenbone` | not built | gvmd, the scanner, gsad and redis, each with its own image |
| `iris` | not built | the image's command is `python3`, not a server |

## Drawbacks

span is a program we maintain. Two passwords for BloodHound, because
two services cannot share one config key. Neo4j's password is set
once; Dependency-Track's administrator is too.

## Alternatives Considered

- Leashing Suricata with `CAP_NET_RAW`. Posture allows a service no
  capability but `CAP_NET_BIND_SERVICE`. span is how capture stays
  outside that rule.
- Elastic as a form. It is a licensed cluster. OpenSearch is the
  search node.
- Running Wazuh's `/init`. It would supervise as root.

## Security Considerations

The fifo is mode 0400 after the header is written, so the reader
cannot see a partial header and cannot write the feed. Velociraptor
can run VQL that would exec; the leash allows only the server binary.
BloodHound's metrics port is loopback. Neo4j sends no usage report.

## Reliability Considerations

A sensor that exits is restarted by runit and finds the fifo still
open. Velociraptor's keys are kept on `/data`; a second boot does not
regenerate them. BloodHound waits out Neo4j by exiting until Bolt
answers, and runit starts it again.
