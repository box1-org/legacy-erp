# legacy-erp: RHEL 10 image mode (bootc) OS image, from the Box1 golden path
# (box1-org/box1-templates, templates/rhel-image-vm), running the legacy ERP
# appliance from box1-org/box1-ops-erp-simulator natively (box1-docs#25, #14).
#
# The build context must contain erp-src/: box1-ops-erp-simulator at a pinned
# commit. CI fetches it (box1-bootc-build extra-source-*) and passes that commit
# as EXTRA_SOURCE_REVISION; local/build-local.sh clones it.

# Stage 1: build the ERP wheel from source. Fixed timestamps for a stable wheel.
FROM registry.access.redhat.com/ubi10/python-312-minimal@sha256:7a3ccd58d8a660d782e8705585aaea2ffe2f2a5d3285507a265dae7d0302b233 AS erp-build
USER 0
COPY erp-src/ /src/
RUN cd /src \
 && python3 -m pip install --no-cache-dir --quiet build==1.3.0 \
 && SOURCE_DATE_EPOCH=315532800 python3 -m build --wheel --outdir /out . \
 && cp -r systemd packaging config /out/ \
 && cp docs/RUNBOOK.md docs/VM-INTEGRATION.md /out/ \
 && (cd /out && sha256sum *.whl)

# Stage 2: the OS image.
# The base is pinned by its multi-arch index digest, so the same file builds arm64
# (local Mac, local/) and amd64 (OpenShift) images. Refresh with:
#   skopeo inspect --raw docker://registry.redhat.io/rhel10/rhel-bootc:10.2 | sha256sum
FROM registry.redhat.io/rhel10/rhel-bootc:10.2@sha256:80485ddb9025df594891c36e23f865c63910739c10d37f41ae7247b0c64c2884

ARG SOURCE_REVISION=unknown
# box1-ops-erp-simulator commit in erp-src/.
ARG EXTRA_SOURCE_REVISION=unknown

# Packages come from the RHEL CDN with the cluster's Simple Content Access
# entitlement, supplied only at build time as secrets (never stored in a layer):
#   --secret id=entitlement-cert,src=.../entitlement.pem
#   --secret id=entitlement-key,src=.../entitlement-key.pem
# build/repos/rhel10-cdn.repo holds the repository definitions (no credentials).
# qemu-guest-agent is required: KubeVirt delivers admin SSH keys through it.
RUN --mount=type=secret,id=entitlement-cert,target=/run/secrets/entitlement/entitlement.pem,required=true \
    --mount=type=secret,id=entitlement-key,target=/run/secrets/entitlement/entitlement-key.pem,required=true \
    --mount=type=bind,source=build/repos,target=/run/box1-repos \
    dnf -y --disableplugin=subscription-manager,product-id --setopt=reposdir=/run/box1-repos \
        --setopt=install_weak_deps=False install \
        qemu-guest-agent  \
 && dnf clean all \
 && rm -rf /var/cache/dnf /var/cache/ldconfig /var/lib/dnf /var/lib/rhsm /var/log/dnf* /var/log/hawkey.log /var/log/rhsm /var/log/qemu-ga

COPY rootfs/ /
COPY --from=erp-build /out/ /tmp/box1-erp/

# Install the ERP as the simulator's docs/VM-INTEGRATION.md describes: fixed-ID
# users, a venv on the system Python (standard library only, nothing from the
# internet), the units, and config. The data volume is mounted at boot.
RUN install -m0644 /tmp/box1-erp/packaging/sysusers-box1-erp.conf /usr/lib/sysusers.d/box1-erp.conf \
 && systemd-sysusers \
 && python3 -m venv --system-site-packages /usr/lib/box1-erp/venv \
 && /usr/lib/box1-erp/venv/bin/pip install --no-index --no-deps --no-cache-dir /tmp/box1-erp/box1_ops_erp_simulator-*.whl \
 && ln -s /usr/lib/box1-erp/venv/bin/box1-erp /usr/bin/box1-erp \
 && install -m0644 /tmp/box1-erp/systemd/box1-erp-worker.service /tmp/box1-erp/systemd/box1-erp-tui@.service /usr/lib/systemd/system/ \
 && install -D -m0755 /tmp/box1-erp/packaging/provision-data-volume.sh /usr/libexec/box1-erp/provision-data-volume.sh \
 && install -D -m0640 -g box1erp /tmp/box1-erp/config/erp.conf.example /etc/box1-erp/erp.conf \
 && install -D -m0644 /tmp/box1-erp/RUNBOOK.md /usr/share/doc/box1-erp/RUNBOOK.md \
 && install -D -m0644 /tmp/box1-erp/VM-INTEGRATION.md /usr/share/doc/box1-erp/VM-INTEGRATION.md \
 && rm -rf /tmp/box1-erp /root/.cache

# virt_qemu_ga_manage_ssh lets qemu-guest-agent write ~/.ssh/authorized_keys, which
# KubeVirt accessCredentials needs; it is off by default in RHEL.
# The ERP venv's bin/ is labelled bin_t (default: lib_t) so systemd starts the
# worker and console as unconfined_service_t, like any packaged service. From
# lib_t they stayed in init_t, which may not create files in the data volume
# (avc denied create ledger.lock, box1-docs#25).
RUN rm -rf /run/secrets/entitlement /run/box1-repos /run/rhsm \
 && printf 'NAME=%s\nREVISION=%s\nERP_REVISION=%s\n' "legacy-erp" "${SOURCE_REVISION}" "${EXTRA_SOURCE_REVISION}" > /usr/lib/box1-image-release \
 && chmod 0755 /usr/libexec/box1/registry-setup /usr/libexec/box1-erp/format-data-disk /usr/libexec/box1-erp/provision-data \
 && chmod 0440 /etc/sudoers.d/90-box1-wheel /etc/sudoers.d/91-box1-deploy \
 && visudo -cf /etc/sudoers.d/90-box1-wheel && visudo -cf /etc/sudoers.d/91-box1-deploy \
 && setsebool -P virt_qemu_ga_manage_ssh on \
 && semanage fcontext -a -t bin_t '/usr/lib/box1-erp/venv/bin(/.*)?' \
 && restorecon -R /usr/lib/box1-erp/venv/bin \
 && systemctl set-default box1-erp.target \
 && systemctl mask serial-getty@ttyS0.service \
 && systemctl enable box1-registry-setup.service \
 && systemctl disable bootc-fetch-apply-updates.timer \
 && rpm -q qemu-guest-agent \
 && /usr/bin/box1-erp --help >/dev/null \
 && systemd-analyze verify --man=no box1-erp.target box1-erp-worker.service box1-erp-tui@ttyS0.service box1-erp-data-provision.service 'var-srv-box1\x2derp.mount' \
 && bootc container lint

LABEL org.opencontainers.image.source="https://github.com/box1-org/legacy-erp" \
      org.opencontainers.image.revision="${SOURCE_REVISION}" \
      org.opencontainers.image.title="legacy-erp" \
      org.box1.erp.source="https://github.com/box1-org/box1-ops-erp-simulator" \
      org.box1.erp.revision="${EXTRA_SOURCE_REVISION}" \
      containers.bootc="1"
