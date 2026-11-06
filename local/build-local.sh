#!/usr/bin/env bash
# Build the bootc image and a raw disk for Apple Silicon (arm64) inside the
# existing podman machine. Rootful podman runs inside the machine via
# `podman machine ssh sudo`; the machine itself stays rootless.
#
#   REGISTRY_AUTH_FILE=/path/to/auth.json ENTITLEMENT_DIR=/path/to/ent local/build-local.sh
#
# REGISTRY_AUTH_FILE must contain a registry.redhat.io credential.
# ENTITLEMENT_DIR must contain entitlement.pem and entitlement-key.pem (the
# cluster's openshift-config-managed/etc-pki-entitlement), used only as build
# secrets for dnf. Both must live under /Users or /private so the machine can
# read them. Neither is ever copied into the repository or the image.
#
# The image also builds the ERP from box1-org/box1-ops-erp-simulator, cloned into
# erp-src/ (git-ignored) at ERP_REVISION (default: main), as CI does.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
AUTH=${REGISTRY_AUTH_FILE:?set REGISTRY_AUTH_FILE to a registry.redhat.io auth.json}
ENT=${ENTITLEMENT_DIR:?set ENTITLEMENT_DIR to a directory with entitlement.pem and entitlement-key.pem}
SSH_PUB=${SSH_PUB:-$HOME/.ssh/id_ed25519.pub}
OUT=${OUT:-$REPO/local/output}
IMAGE=localhost/legacy-erp:local
BIB=registry.redhat.io/rhel10/bootc-image-builder:10.2@sha256:14adeb06f5fca459c8ac534b59f1dec6d08576dfdf4605b0b27f177ad19f1de8
REV=$(git -C "$REPO" rev-parse --verify -q HEAD || echo local)
WORK=/var/tmp/legacy-erp   # inside the machine, off virtiofs
ERP_REVISION=${ERP_REVISION:-main}

rm -rf "$REPO/erp-src"
git clone -q https://github.com/box1-org/box1-ops-erp-simulator.git "$REPO/erp-src"
git -C "$REPO/erp-src" checkout -q --detach "$ERP_REVISION"
ERP_REV=$(git -C "$REPO/erp-src" rev-parse HEAD)
rm -rf "$REPO/erp-src/.git"
echo "ERP source: box1-ops-erp-simulator $ERP_REV"

mkdir -p "$OUT"
# The local-only disk config adds an admin user with your SSH public key.
# On a local VM there is no qemu-guest-agent channel, so the key is baked into the
# local disk only. Cluster VMs receive keys at runtime from KubeVirt accessCredentials.
printf '[[customizations.user]]\nname = "cloud-user"\nkey = "%s"\ngroups = ["wheel"]\n' "$(cat "$SSH_PUB")" > "$OUT/config.local.toml"
# The local VM has no erpdata disk, so the ERP worker and console stay down (by
# design: no ledger on the root filesystem). Add a second blank disk with serial
# erpdata to run them.

vm() { podman machine ssh -- "$@"; }

vm sudo podman build --platform linux/arm64 --authfile "$AUTH" \
  --secret id=entitlement-cert,src="$ENT/entitlement.pem" \
  --secret id=entitlement-key,src="$ENT/entitlement-key.pem" \
  --build-arg SOURCE_REVISION="$REV" --build-arg EXTRA_SOURCE_REVISION="$ERP_REV" -t "$IMAGE" "$REPO"
vm sudo podman pull -q --authfile "$AUTH" "$BIB"
vm sudo rm -rf "$WORK"
vm sudo mkdir -p "$WORK/output"
vm sudo podman run --rm --privileged --pull=never \
  --security-opt label=type:unconfined_t \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  -v "$OUT/config.local.toml:/config.toml:ro" \
  -v "$WORK/output:/output" \
  "$BIB" --type raw --rootfs xfs "$IMAGE"
vm sudo cp --sparse=always "$WORK/output/image/disk.raw" "$OUT/disk.raw"
vm sudo rm -rf "$WORK"
echo "disk: $OUT/disk.raw"
