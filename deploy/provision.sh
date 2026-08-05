#!/usr/bin/env bash
#
# One-time (or on-change) provisioning for readout on the VPS.
#
# Run this once before the first `tugboat deploy`, and again whenever this file
# changes. Routine deploys do NOT run it — they ship a new image tar and restart
# the unit (see ../deploy.toml).
#
#   scp deploy/provision.sh deepwa7er:/tmp/ && ssh deepwa7er 'bash /tmp/provision.sh'
#
# Unlike the Rust fleet services, readout runs as a Docker container: the VPS has
# Ruby 3.2.3 and this app needs 3.4.8, so a native install would mean maintaining
# a second Ruby on the host. The systemd unit below is still the thing tugboat
# restarts and health-checks, so the deploy transaction and rollback behave
# exactly like every other service.

set -euo pipefail

NAME=readout
PORT=8101
APP_DIR=/opt/readout
STORAGE_DIR="${APP_DIR}/storage"
IMAGE_TAR="${APP_DIR}/readout-image.tar"
IMAGE_TAG=readout:deploy

echo "==> creating ${APP_DIR}"
mkdir -p "${STORAGE_DIR}"

# The container runs as uid/gid 1000 (the `rails` user in the image), so the
# storage directory it writes SQLite into must be owned by that uid on the host.
chown -R 1000:1000 "${STORAGE_DIR}"
chmod 0750 "${APP_DIR}"

# Rails needs the master key to read encrypted credentials. It is deliberately
# NOT baked into the image: the image tar is shipped over the network and lands
# in a world-readable-ish path, whereas this file is 0600 root-only.
if [ ! -f "${APP_DIR}/master.key" ]; then
  echo "!! ${APP_DIR}/master.key is missing."
  echo "   Copy it from the repo (config/master.key), which is gitignored:"
  echo "     scp config/master.key deepwa7er:${APP_DIR}/master.key"
  echo "   then re-run this script."
  exit 1
fi

# Owned by uid 1000 so the container's `rails` user can read it, and still 0600.
# uid 1000 is unassigned on this host, so this grants no host account access —
# root-owned 0600 would simply be unreadable inside the container, which fails
# the deploy with a bare "Permission denied @ rb_sysopen".
chown 1000:1000 "${APP_DIR}/master.key"
chmod 0600 "${APP_DIR}/master.key"

# The runner lives on the dev box, so the dashboard needs its address. Docker
# containers on this host cannot resolve MagicDNS names — the daemon hands them
# public resolvers, which know nothing about the tailnet — so the NAME is
# resolved here, on the host, and the resulting IP is passed in.
#
# Resolved at unit start rather than baked into this file, for the reason
# breakwater documents: a node's tailnet IP is not a constant. An address change
# is repaired by restarting the service, not by editing config.
#
# If the dev box is offline the lookup yields nothing, RUNNER_URL is left empty,
# and the dashboard simply hides the launch button. That degradation is
# deliberate: a dashboard that still reads results is far better than one that
# fails to start because a laptop is asleep.
echo "==> installing the runner address resolver"
cat > /usr/local/bin/readout-resolve-runner <<'RESOLVER'
#!/bin/sh
# Writes RUNNER_URL for readout.service, resolving the dev box's tailnet IPv4.
set -eu

name="${RUNNER_HOST:-deepwater-1.tailcfab97.ts.net}"
port="${RUNNER_PORT:-7881}"
ip="$(getent ahostsv4 "$name" 2>/dev/null | awk '{print $1; exit}')"

if [ -n "$ip" ]; then
  echo "RUNNER_URL=http://${ip}:${port}"
else
  echo "readout: could not resolve ${name}; launch UI will be hidden" >&2
  echo "RUNNER_URL="
fi
RESOLVER
chmod 0755 /usr/local/bin/readout-resolve-runner

if [ ! -f "${APP_DIR}/runner-token" ]; then
  echo "!! ${APP_DIR}/runner-token is missing."
  echo "   Copy it from the dev box (campfire-stress/.runner-token):"
  echo "     scp ~/code/campfire-stress/.runner-token deepwa7er:${APP_DIR}/runner-token"
  echo "   then re-run this script."
  exit 1
fi
# Readable by the container's uid 1000, like the master key.
chown 1000:1000 "${APP_DIR}/runner-token"
chmod 0600 "${APP_DIR}/runner-token"

echo "==> writing systemd unit"
cat > /etc/systemd/system/${NAME}.service <<UNIT
[Unit]
Description=Readout — campfire-stress results dashboard
Documentation=https://github.com/deepwa7er
After=network-online.target docker.service
Requires=docker.service

[Service]
Type=exec
Restart=on-failure
RestartSec=3

# tugboat ships a new image tar and restarts this unit; loading on every start
# is what makes the restart pick up the new build. Loading an already-present
# image is a fast no-op, so this costs nothing on an ordinary restart.
ExecStartPre=-/usr/bin/docker rm -f ${NAME}
ExecStartPre=/usr/bin/docker load -i ${IMAGE_TAR}
ExecStartPre=/bin/sh -c '/usr/local/bin/readout-resolve-runner > /run/readout-runner.env'
EnvironmentFile=-/run/readout-runner.env

# Binds loopback only: breakwater is the sole tailnet-facing entry point, the
# same model as every other fleet service.
#
# Memory is the binding constraint on this box (2GB total, shared with the rest
# of the fleet), so Puma runs a single worker and the container is capped. Left
# unbounded, a Rails app will happily use more than this VPS has.
#
# The master key is mounted to config/master.key rather than passed as an env
# var: Rails reads that path natively, and there is no RAILS_MASTER_KEY_FILE
# variable. Keeping it out of the image also keeps it out of the shipped tar.
ExecStart=/usr/bin/docker run --rm --name ${NAME} \\
  -p 127.0.0.1:${PORT}:80 \\
  -e RAILS_ENV=production \\
  -e WEB_CONCURRENCY=1 \\
  -e RAILS_MAX_THREADS=3 \\
  -e RUNNER_URL=\${RUNNER_URL} \\
  -e RUNNER_TOKEN_FILE=/rails/config/runner-token \\
  -v ${STORAGE_DIR}:/rails/storage \\
  -v ${APP_DIR}/master.key:/rails/config/master.key:ro \\
  -v ${APP_DIR}/runner-token:/rails/config/runner-token:ro \\
  --memory=400m \\
  --memory-swap=400m \\
  ${IMAGE_TAG}

ExecStop=/usr/bin/docker stop ${NAME}

[Install]
WantedBy=multi-user.target
UNIT

echo "==> reloading systemd"
systemctl daemon-reload
systemctl enable ${NAME}.service

echo
echo "Provisioned. Next:"
echo "  1. tugboat deploy      (from the readout repo — ships the image and starts it)"
echo "  2. add the breakwater route and deploy breakwater"
echo
echo "The service will not start until an image tar exists at ${IMAGE_TAR}."
