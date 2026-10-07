# Tailscale subnet router

`tailscale` inherits `prod` and runs as its own unprivileged user. It uses
userspace networking: no TUN device, kernel IP forwarding or permission to
change the host firewall. Tailscale SSH and the web client are disabled.

## Configure it

Create `forms/my-router.yaml`:

```yaml
include: tailscale.yaml
```

Copy the base configuration into your overlay:

```sh
mkdir -p forms/my-router/etc/tailscale
cp forms/tailscale/etc/tailscale/config.json forms/my-router/etc/tailscale/config.json
```

Set `advertiseRoutes` to the subnet you want to reach, for example
`["10.20.0.0/24"]`. The default is empty. Keep the other settings, including
`locked`, unchanged. Do not advertise default routes: this is a subnet
router, not an exit node.

Create a tagged, preauthorized auth key in your tailnet and put its value
in `config/tailscale/auth_key` (use a single-use key for one machine).
Keep that directory private and the file mode `0600`; do not put the key
in the form or image. Leash supplies a private copy to the daemon.

```sh
make FORM=my-router run
```

Approve the advertised routes in the Tailscale admin console, and grant
only the intended clients access to the subnet and ports. Advertising and
approving a route does not replace access policy. Linux clients also need
route acceptance enabled. See [Tailscale's subnet-router setup](https://tailscale.com/docs/features/subnet-routers).

From an allowed client, test SSH or HTTPS to a machine in the subnet;
also check that a client without a grant cannot connect.

## Network limits

The initial policy allows TCP 22 and 443 to destinations, plus DNS for
bootstrap. For another TCP port, copy the base service file into your
overlay, add the port to `connect`, and add
`connect tailscale tcp/PORT` to `forms/my-router.net`. The host policy
limits user and port, not destination CIDR; tailnet policy supplies the
client and subnet restrictions.

No public inbound rule is required. Direct UDP transport is blocked, so
connections use DERP relays over HTTPS. This trades direct-path performance
for a smaller network policy. This form is not a general-purpose UDP or
ICMP router. With userspace forwarding, destinations see the router's
address, not the original client's. See [userspace routing](https://tailscale.com/docs/reference/kernel-vs-userspace-routers).

## Deploy and update

Build a boot disk with `make FORM=my-router disk` and supply the config
through a config disk or [cloud metadata](cloud.md). Protect access to that
metadata. Persist `/data`: the node identity lives in
`/data/svc/tailscale`. Treat it as a secret and never clone it to another
router. Enrollment keys and node-key expiry are separate tailnet settings.

The form declares the desired configuration; the running machine does not
need manual edits. Tailscale's own updater is disabled. On an A/B
installation, Werewolf updates the packages with the image while keeping
the node's data. Changes to routes or policy files need a new deployment.
The [Tailscale configuration schema](https://tailscale.com/docs/reference/tailscaled/tailscaled-config-file)
is currently `alpha0`; check it when upgrading. See [releases.md](releases.md)
for Werewolf's update model.
