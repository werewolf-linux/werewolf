# slot-update

## Summary

The autoupdater. It keeps a machine booted from a slot current: it builds or
fetches the other slot, stages it, and boots it once when its fixes say it is
due. A slot that does not prove healthy rolls back on its own. Operations and
the log: [docs/updater.md](../../docs/updater.md). The policy:
[docs/design/update-policy.md](../../docs/design/update-policy.md).

## Background

A werewolf root is an immutable dm-verity erofs image, so a fix lands only as
a new image. A machine has two slots, `a` and `b`; the bootloader boots a new
slot once and falls back unless `slot-keep` commits it. The other slot comes
from the form's latest signed release (`prod`, `prod-ssh`), or is built on the
machine from Wolfi and Alpine (any other form built on `prod`).

| File | Holds |
| --- | --- |
| `slot-update.zig` | daemon, check, build, install, outcome, the log |
| `cve.zig` | CVE fetcher and reader children; root's checks of their lines |
| `release.zig` | release manifest: signature, checks, advisories |
| `tiers.zig` | the signed CVE tiers feed; tiering an update's fixes |
| `../../lib/update-policy.zig` | due times, settings, `why`, the log's chain |

## Goals

- Exploited CVEs fixed within about 75 minutes, high ones within hours.
- No update that can leave a machine unbootable.
- Nothing from the network decides anything as root.
- A log an auditor can read alone, every line chained to the one before.

## Non-Goals

- Fleet coordination, code compiled into a user's form, live patching.

## Detailed design

Invariants to keep when changing this code:

- **Staged means armed.** `attempt` holds `SLOT BUILD BOOT`, the boot that
  armed the slot (`boot_id`, read with pread: procfs sizes are 0). The daemon
  reboots only for a slot this boot armed; `outcome` judges nothing in that
  boot. Any reboot, whoever causes it, boots a staged slot.
- **Arming order.** Disarm and remove `attempt`; write the slot; sync; write
  `attempt` (fsync); arm last. `errdefer` removes `attempt` if arming fails.
  `pending` survives the install so first-seen times are never lost.
- **Nothing goes backwards.** Packages and the kernel never older (apk's
  order); releases never older than `serial`; the feed never older than
  `cve-tiers.json.serial`. Signed inputs are verified before parsing.
- **Fail toward sooner.** No valid feed: every fix, or the update itself,
  counts High. A refused form policy blocks the operator's file too.
- **Durability.** State files go through `writeReplacing` (fsync file and
  directory); each log line and report is fsync'd.
- **One pass at a time.** `check`, `outcome` and the reboot hold `lock`;
  `check` requires `/run/werewolf/committed`.

## Drawbacks

- `slot-update.zig` is over 2,000 lines, past the project's limit.
- The policy tiers Medium and Low from unsigned CVE sources; only Urgent
  and High rest on signed data alone.

## Alternatives Considered

- **Reboot as soon as built:** nightly reboots on a busy form.
- **Tier on each machine:** more untrusted parsing; CI tiers once and signs.

## Security Considerations

Trust boundaries:

- **Network to `_update` children** (apk fetcher, CVE fetcher and reader):
  uid 69, no capabilities, Landlock, seccomp, size limits. Root never parses
  a CVE source; it re-checks every line a reader sends and refuses a whole
  source on one bad line.
- **Signed inputs:** a release manifest (image key) and the tiers feed (its
  own key). A leaked feed key costs timing within bounds (serial at most a
  day ahead, expiry at most a week); a leaked image key costs what runs.

Known gaps, for the next reviewer:

- Root's apk unpacks the fetched index before checking its signature, as any
  apk does; the offline install belongs in a child.
- Paths in the new root are not resolved with `openat2(RESOLVE_IN_ROOT)`;
  they come from signed packages.
- systemd-boot's entry version comes from the clock.
- The verity tree is built in memory; root's tools have no deadline.

## Reliability Considerations

- One try, the deadman and `slot-keep` make a bad update cost a reboot and a
  rollback; `bad` stops it being tried again.
- No update reboot within an hour of boot, except a machine's first check.
- `make test`: unit tests here and in `lib/update-policy.zig`.
- `make check-updater`: a whole update over the network.
- `make check-updater-staged`: power cut with an update staged; the next boot
  must take it, and the log must still say it was staged.
- `make SEAL_LEARN=1 check-updater`: what the seal would refuse.
