# Go on werewolf

Build a static Go HTTP server and run it as the unprivileged `app` user.
The VM needs no Go compiler.

Install the [build tools](../README.md#build-host), then run these commands
from the repository root.

## Declare the app

The [form](../../forms/example-go.yaml) inherits `app.yaml`, which adds an
application user to `prod`. It declares the service and port 8080.
[main.go](main.go) is compiled for Linux and installed at `/usr/lib/app/server`.

A form declares the machine's packages, users, services and network permissions.
Keep it with your code in version control. Building changes into a read-only
image gives each replacement VM the same starting configuration.

## Build and run

```sh
make -C examples/go image
make -C examples/go deploy-qemu

# In another terminal:
curl -f http://127.0.0.1:8080/
curl -f http://127.0.0.1:8080/health
```

You should see `Hello from Go on werewolf!` and `ok`.
Quit QEMU with `Ctrl-a x`. Relaunching preserves the VM's data and updates;
to try rebuilt code, choose a [fresh QEMU disk](../README.md#what-the-makefiles-do).

The build selects the Linux architecture and disables cgo. Install Go on
the build host; the example uses only its standard library.

## Deploy on GCP

Complete the [GCP setup](../README.md#prepare-gcp-once) to set
`GCP_PROJECT`, `GCP_BUCKET` and `GCP_SOURCE_RANGES`, then:

```sh
make -C examples/go deploy-gcp ARCH=x86_64
```

Open the printed URL; append `/health` for a health check.
Use `ARCH=aarch64` instead for an Arm VM. To read the boot log:

```sh
make -C examples/go serial-gcp ARCH=x86_64
```

## Automatic updates

Werewolf checks for system updates after boot and every 20 hours. When updates
are available, it builds a new system image, reboots and keeps the previous
image for rollback.
Application data survives updates and rollbacks.

Wolfi packages and the kernel update automatically. The Go runtime, standard
library and modules are compiled into the app; updating them or your code
requires rebuilding the image with the updated toolchain and dependencies.

For application changes, rebuild, test with a fresh QEMU disk, then deploy
under a new name:

```sh
make -C examples/go deploy-gcp ARCH=x86_64 GCP_NAME=werewolf-go-v2
```

Check the new VM before moving traffic. New VMs start with empty data;
migrate any saved data first. See the [update guide](../README.md#change-update-and-remove)
for package refreshes and rollback details.

## Clean up

These commands remove the example VMs, their disks and data, and deployment
resources. The shared bucket stays.

```sh
make -C examples/go delete-gcp ARCH=x86_64
# If you deployed v2:
make -C examples/go delete-gcp ARCH=x86_64 GCP_NAME=werewolf-go-v2
```

Use the same settings as deployment. [Cleanup details](../README.md#change-update-and-remove).
