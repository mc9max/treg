#!/usr/bin/env sh
# treg entrypoint — runs as root (PID 1). Railway mounts volumes
# root-owned, so a non-root user cannot write /app/data; root can.
#
# Order:
#   1. Ensure /app/data is writable and create the treg key file on first boot.
#      treg's crypto.py (line 18) falls back to an EPHEMERAL Fernet key if no
#      TREG_SECRET_KEY is set — which would leave every encrypted secret from
#      a previous boot undecryptable.  Mint one on the volume once; export it.
#   2. `treg upgrade` — idempotent schema + catalog migrations.  Upstream
#      Render blueprint runs the same command in preDeploy; Railway has no
#      preDeploy hook, so we do it here, every boot.  `python -m treg`
#      (_prepare_serve) runs it AGAIN in-process — safe, this is the
#      explicitly documented pattern (see src/treg/__main__.py).
#   3. `python -m treg` — runs _prepare_serve() [upgrade + single-user
#      bootstrap (no-op on public deploy)] then uvicorn on $PORT.
set -eu

export TREG_HOME=/app/data
DATA_DIR=/app/data
mkdir -p "$DATA_DIR"

# 1) persistent Fernet key, on the volume (0600)
KEY_FILE="$DATA_DIR/treg-key"
if [ ! -s "$KEY_FILE" ]; then
  python -c "from treg.crypto import new_key; import sys; sys.stdout.write(new_key())" \
    > "$KEY_FILE"
  chmod 600 "$KEY_FILE"
fi
export TREG_SECRET_KEY="$(cat "$KEY_FILE")"

# 2) schema + catalog migrations (idempotent)
python -m treg upgrade || true

# 3) exec the server (PID 1, clean SIGTERM handling)
exec python -m treg
