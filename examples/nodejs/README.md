# Node.js on werewolf

Run a Node.js HTTP server as the unprivileged `app` user.

Install the [build tools](../README.md#build-host), then run these commands
from the repository root.

## Declare the app

The [form](../../forms/example-node.yaml) inherits `node.yaml` and replaces
[server.js](../../forms/example-node/usr/lib/app/server.js). The parent supplies
Node.js, the service and network settings, and inherits its user from `app`.

A form declares the machine's packages, users, services and network permissions.
Keep it with your code in version control. Building changes into a read-only
image gives each replacement VM the same starting configuration.

## Build and run

```sh
make -C examples/nodejs image
make -C examples/nodejs deploy-qemu

# In another terminal:
curl -f http://127.0.0.1:8080/
curl -f http://127.0.0.1:8080/health
```

You should see `Hello from Node.js on werewolf!` and `ok`.
Quit QEMU with `Ctrl-a x`. Relaunching preserves the VM's data and updates;
to try rebuilt code, choose a [fresh QEMU disk](../README.md#what-the-makefiles-do).

For npm dependencies, commit `package-lock.json`, run `npm ci` on a compatible
Linux build host, and include production `node_modules/` with the app.

## Deploy on GCP

Complete the [GCP setup](../README.md#prepare-gcp-once) to set
`GCP_PROJECT`, `GCP_BUCKET` and `GCP_SOURCE_RANGES`, then:

```sh
make -C examples/nodejs deploy-gcp ARCH=x86_64
```

Open the printed URL; append `/health` for a health check.
Use `ARCH=aarch64` instead for an Arm VM. To read the boot log:

```sh
make -C examples/nodejs serial-gcp ARCH=x86_64
```

## Automatic updates

Werewolf checks for system updates after boot and every 20 hours. When updates
are available, it builds a new system image, reboots and keeps the previous
image for rollback.
Application data survives updates and rollbacks.

Node.js within its declared package stream and the kernel update automatically.
JavaScript and npm dependencies stay as built; changes to those, or a Node.js
major-version upgrade, need a new image.

For application changes, rebuild, test with a fresh QEMU disk, then deploy
under a new name:

```sh
make -C examples/nodejs deploy-gcp ARCH=x86_64 GCP_NAME=werewolf-nodejs-v2
```

Check the new VM before moving traffic. New VMs start with empty data;
migrate any saved data first. See the [update guide](../README.md#change-update-and-remove)
for package refreshes and rollback details.

## Clean up

These commands remove the example VMs, their disks and data, and deployment
resources. The shared bucket stays.

```sh
make -C examples/nodejs delete-gcp ARCH=x86_64
# If you deployed v2:
make -C examples/nodejs delete-gcp ARCH=x86_64 GCP_NAME=werewolf-nodejs-v2
```

Use the same settings as deployment. [Cleanup details](../README.md#change-update-and-remove).
