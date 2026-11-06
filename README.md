# legacy-erp

The ERP solution that the company depends on

A **RHEL 10 image mode (bootc)** virtual machine created from the Box1 golden path (`box1-org/box1-templates`, template `rhel-image-vm`). It runs the legacy ERP appliance from [`box1-org/box1-ops-erp-simulator`](https://github.com/box1-org/box1-ops-erp-simulator) natively, and boots straight into the ERP console on the serial console ([box1-docs#25](https://github.com/box1-org/box1-docs/issues/25)). The operating system is a container image built from this repository and the simulator's source.

```
Containerfile          stage 1: build the ERP wheel from erp-src/ (box1-ops-erp-simulator)
                       stage 2: rhel10/rhel-bootc:10.2 (pinned) + packages + rootfs/ + ERP install
                                + bootc container lint
rootfs/                box1-erp.target (default boot target), the ERP data volume units,
                       the deploy user, bootc update plumbing, console kargs, sudoers
build/repos/           RHEL CDN repositories for dnf (no credentials)
.tekton/               Pipelines-as-Code: PR build check, and the shared release pipeline
local/                 build and boot an arm64 copy on an Apple Silicon Mac
```

## One pipeline for both repositories

`.tekton/appliance-pipeline.yaml` (Pipeline `legacy-erp-appliance`) is the only release definition. **A push to `main` in either repository runs it:**

| Push to | Trigger | Commits used |
| --- | --- | --- |
| `legacy-erp` | `.tekton/release.yaml` here | this commit + simulator `main` |
| `box1-ops-erp-simulator` | its `.tekton/release.yaml`, which loads this repo's pipeline file from `main` | legacy-erp `main` + that commit |

Both commits are resolved once at the start. The run then:

1. **resolve**: records both commits (`os-revision`, `erp-revision`);
2. **erp-test**: runs the simulator's `ruff` and `pytest` against its pinned `box1-ops-contracts`;
3. **build**: fetches the simulator into `erp-src/`, builds and pushes `box1-ci/legacy-erp@<digest>`. Both commits are recorded in the image labels and in `/usr/lib/box1-image-release`;
4. **security**: runs the TPA and ACS scans in observe mode and links the reports from the run's results;
5. **disk**: builds a new install disk, `box1-ci/legacy-erp-disk`;
6. **current**: stops here if either `main` moved since step 1, so the newer run promotes;
7. **promote**: opens and merges a box1-workloads-dev PR that records the digest on the VirtualMachine;
8. **channel**: moves `box1-ci/legacy-erp:development` to that digest;
9. **deploy**: as `box1-deploy`, runs `sudo bootc upgrade --apply` in the VM (the VM reboots). It then requires the booted digest to equal the built digest, `box1-erp.target` as the default target, and `box1-erp-worker` and `box1-erp-tui@ttyS0` active;
10. **smoke**: checks the Argo CD, VM and guest-agent state.

Pull requests build the image without pushing it (`legacy-erp-validate`), using simulator `main`. Pull requests in the simulator run its own tests only.

## The appliance

- **Boot:** `box1-erp.target` is the default target. It keeps `multi-user.target` (network, sshd, guest agent) and adds `box1-erp-worker.service` and `box1-erp-tui@ttyS0.service`. `serial-getty@ttyS0` is masked, so the ERP console owns ttyS0.
- **Data:** PVC `legacy-erp-data` (KubeVirt disk serial `erpdata`) is mounted at `/srv/box1-erp`. `/srv` is a symlink to `/var/srv`, so the mount unit is `var-srv-box1\x2derp.mount`.
  - On first boot, `box1-erp-data-format.service` formats the disk only if it is blank: no signature and an all-zero first MiB.
  - `box1-erp-data-provision.service` runs the simulator's `provision-data-volume.sh`. It initialises the ledger only once; a marker file `.box1-initialized` on the volume records that.
  - If the disk is missing, the mount fails and neither ERP unit starts. No ledger is ever created on the root filesystem.
  - OS updates and root-disk rebuilds do not touch the volume.
- **Application:** a venv at `/usr/lib/box1-erp/venv` on the system Python 3.12, standard library only; `/usr/bin/box1-erp`; config in `/etc/box1-erp/erp.conf`; the simulator's runbook in `/usr/share/doc/box1-erp/`.

## Access

- **ERP console:** `virtctl console legacy-erp -n legacy-erp-dev`, or the VM's serial console in the OpenShift console. It opens directly in the ERP application, with no login. Anyone who can open the console can operate the ERP, so console access is controlled with OpenShift RBAC on `virtualmachineinstances/console`.
- **Admin SSH:** `virtctl ssh -n legacy-erp-dev cloud-user@vm/legacy-erp` (passwordless sudo). Keys come from the GitOps Secret in `workloads/legacy-erp/admin-access.yaml` in box1-workloads-dev.
- **Pipeline deploy:** `box1-deploy` may only run `sudo bootc upgrade --apply` and `sudo bootc status --format json`. Its public key is in `workloads/legacy-erp/deploy-access.yaml`. Its private key is Secret `box1-ci/legacy-erp-deploy-ssh`, created outside Git.

## Recovery

```sh
virtctl ssh -n legacy-erp-dev cloud-user@vm/legacy-erp
sudo systemctl restart box1-erp-worker            # worker only; the console keeps running
sudo systemctl restart box1-erp-tui@ttyS0         # console only; ingestion keeps running
sudo systemctl isolate multi-user.target          # leave the appliance target (getty stays masked on ttyS0)
sudo systemctl isolate box1-erp.target            # return to it
journalctl -u 'var-srv-box1\x2derp.mount' -u box1-erp-data-provision -u box1-erp-worker   # storage / startup
sudo bootc status                                 # booted / rollback digests
sudo bootc rollback --apply                       # boot the previous OS image (data volume untouched)
```

If SSH is unavailable, open the boot menu from the serial console and add `systemd.unit=rescue.target`. For a durable rollback, revert the commit and let the pipeline release again, or re-promote an earlier digest in box1-workloads-dev.

## Where things are

| What | Where |
| --- | --- |
| VM, disks and access (desired state) | `box1-org/box1-workloads-dev`: `workloads/legacy-erp/`, synced by Argo CD Application `legacy-erp` |
| OS images | `box1-ci/legacy-erp` (update channel `:development`) and `box1-ci/legacy-erp-disk` |
| Registry access for `bootc upgrade` | At boot, `box1-registry-setup.service` installs the service CA and a pull token from two VM disks (`serviceca`, `regtoken`) |
| Shared build tasks | `box1-org/box1-gitops`: `platform/pipelines/tasks/bootc-*.yaml`; see `GOLDEN-PATH.md` |
| ERP application, units and VM contract | `box1-org/box1-ops-erp-simulator` (`docs/VM-INTEGRATION.md`, `docs/RUNBOOK.md`) |

## Build locally (Apple Silicon)

```sh
REGISTRY_AUTH_FILE=/path/to/auth.json ENTITLEMENT_DIR=/path/to/ent local/build-local.sh   # ERP_REVISION=<sha> to pin
local/run-local.sh
```

You need a `registry.redhat.io` auth file and the cluster's entitlement certificate (`entitlement.pem` and `entitlement-key.pem`), both under `/Users` or `/private`. These are build inputs only and are never copied into this repository or the image. The script clones the simulator into `erp-src/`, which is git-ignored.

The local VM has no `erpdata` disk, and its console is `hvc0`, not `ttyS0`. The OS boots, but the ERP units stay down there by design.
