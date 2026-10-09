# syntax=docker/dockerfile:1
# ============================================================================
# Railway Template: treg
# ----------------------------------------------------------------------------
# "OpenRouter for agent tools" — a self-hosted registry of 2,896 agent-
# friendly MCP/HTTP tools with pay-per-use metering.
#
# Upstream: superdesigndev/treg (vendor copy at the root of this repo; this
# template's git repo is a clean fork of it, so the template's Dockerfile is
# the source of truth for how the runtime image is assembled).
#
# Two build stages:
#
#   1. dash    Node 22 + Vue: `npm --prefix frontend ci --include=dev` then
#              `npm --prefix frontend run build` (which is the upstream's real
#              build script:  vue-tsc --noEmit && vite build && vite build
#              -c vite.agent-setup.config.ts && node scripts/copy-runtime.mjs).
#              Vite's outDir is frontend/../src/treg/web/dashboard (per
#              frontend/vite.config.ts) with emptyOutDir: true, so stale
#              dashboard files are wiped before each build.
#
#   2. runtime python 3.12 (pyproject: requires-python = ">=3.12,<3.14")+ uv.
#              uv sync --frozen --no-dev --extra server installs the locked
#              dep set (frozen = refuse to drift past uv.lock, same guarantee
#              upsteam's Render blueprint gets from `uv sync --locked …`).
#
# Runtime:
#   - Data lives on a Railway VOLUME at /app/data.  config.py defaults the
#     SQLite path to ./treg.db (relative to CWD=/app), so we set
#     TREG_DATABASE_URL to /app/data/treg.db explicitly, and the TREG key
#     file + any runtime state treg writes under ~/.treg is chowned to point
#     at the same dir (see entrypoint.sh).
#   - Port 18790 by default; __main__.py honors $PORT (uvicorn.run binds
#     os.environ.get("PORT","18790")).
#   - healthcheck: GET /meta  (Render's own blueprint uses this path; the
#     landing page and dashboard also call it client-side to pull metadata).
#   - entrypoint.sh:
#       · mint a persistent TREG_SECRET_KEY on the volume (treg/crypto.py
#         else falls back to an EPHEMERAL Fernet key, which would make
#         every encrypted secret from a previous boot undecryptable)
#       · run `treg upgrade` (idempotent schema/catalog migrations; upstream
#         Render blueprint runs the same command in preDeploy — Railway has
#         no preDeploy hook, so we run it inside entrypoint)
#       · exec `python -m treg` → _prepare_serve() (which re-runs upgrade
#         idempotently and then single-user bootstrap — a no-op on a public
#         deploy because `single_user_ok` demands loopback+sqlite) →
#         uvicorn on $PORT
#
# Identity
#   `single_user_ok` and `expose_dev_code` are both gated on the DB being
#   SQLite AND public_url being loopback — the app refuses no-login mode
#   when it is fronted by a public domain (config.py, single_user_ok docstring).
#   The correct first-login path on a public Railway deploy is therefore
#   OAuth:  GitHub (recommended; every deployer already has one), Google, or
#   email OTP via Resend (requires a Resend-verified from-domain).
#
#   TREG_PUBLIC_URL MUST equal the deployment's actual public domain — treg
#   derives every OAuth callback URL and every transactional-email link from
#   it.  template-vars.json pre-fills it from Railway's system.domain.
# ============================================================================

ARG UV_VERSION=0.12.3

# ---- 1. browser-app build --------------------------------------------------
# Node 22:  vite.config.ts opts into rolldown's `codeSplitting.groups` API
# (needs Node >= 22.1).  Upstream Render pins 22.22.0.
#
# The build step (`npm run build` from frontend/) references files in the
# *sibling* `src/` tree (e.g. `../../src/treg/web/media/redesign/dashboard.css`
# in frontend/src/main.ts, and `vite.agent-setup.config.ts` reading
# `src/treg/web/enrich-arena.html` for copy-runtime), so we have to copy
# enough of the project that those paths resolve.
FROM node:22-slim AS dash
WORKDIR /src
# manifests + lockfile first → npm layer cache
COPY frontend/package.json frontend/package-lock.json* ./frontend/
RUN cd frontend && npm ci --include=dev
# minimal src/ needed for the build's cross-tree imports (css + one html)
# Copy the full src/treg/web/ dir — it's static and small, and copy-runtime
# also validates a vendored Vue version from there.
COPY src/treg/web/ ./src/treg/web/
# frontend source tree
COPY frontend/ ./frontend/
RUN cd frontend && npm run build
# the build's output (relative to /src → /src/src/treg/web/dashboard)
RUN ls -la /src/src/treg/web/dashboard/ 2>/dev/null || echo "WARN: no dashboard out"
RUN test -f /src/src/treg/web/dashboard/index.html

# ---- 2. runtime --------------------------------------------------------------
FROM python:3.12-slim AS runtime
ARG UV_VERSION

# image provenance — links the ghcr package to its repo AT PACKAGE CREATION
# (this push is the first one, so put it before any other push of this image).
LABEL org.opencontainers.image.source=https://github.com/mc9max/treg

# base tools + uv, pinned to the exact version the uv.lock/Render blueprint
# assumes (0.12.3).  python:3.12-slim ships pip, so `pip install uv` is the
# most reliable version-pinned install (astral's installer has dropped its
# `--install-dir` flag and ignores the older dir env vars).
RUN set -eux; \
    apt-get update; \
    pip install --no-cache-dir "uv==${UV_VERSION}"; \
    uv --version; \
    uvx --version 2>/dev/null || true; \
    apt-get clean; rm -rf /var/lib/apt/lists/*

# named user (uid 10001) that owns /app — the volume's files stay consistent
# across redeploys (avoids a stray root-owned file blocking the treg run)
RUN useradd --system --uid 10001 --home-dir /app treg
WORKDIR /app

ENV PATH="/app/.venv/bin:${PATH}" \
    UV_LINK_MODE=copy \
    UV_CACHE_DIR=/root/.cache/uv \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PORT=18790 \
    TREG_DATABASE_URL="sqlite+aiosqlite:////app/data/treg.db" \
    TREG_HOME="/app/data"

# -- 2a: copy the project + `uv sync` the locked [server] deps.
#       Order matters: `uv sync --active` builds the project as an EDITABLE
#       wheel, and hatchling validates `readme = "README.md"` +
#       `license = { file = "LICENSE" }` (and links `src/treg`) at build time
#       — so those files must exist before `uv sync`, not after. (An earlier
#       version tried to cache a deps-only layer without src/ and failed
#       with "OSError: License file does not exist".)
#       `--frozen` = refuse to drift past uv.lock (upstream Render uses
#       `--locked`; same guarantee).
COPY pyproject.toml uv.lock ./
COPY LICENSE README.md hatch_build.py ./
COPY src/ ./src/
COPY scripts/ ./scripts/
RUN uv sync --frozen --no-dev --extra server --active
RUN rm -rf /root/.cache/uv

# -- 2c: overlay the FULL built web dir from the dash stage.
#       The dash stage built:
#         · the Vue dashboard  → src/treg/web/dashboard
#         · the vendored Vue global build → src/treg/web/vendor/vue-…global.prod.js
#       (both via copy-runtime.mjs + vite's outDir).  `COPY src/` above would
#       otherwise ship the in-tree `src/treg/web` WITHOUT those generated files,
#       so the login screen and the standalone enrich-arena page would 404.
COPY --from=dash /src/src/treg/web ./.web-full
RUN rm -rf src/treg/web && mv .web-full src/treg/web && rmdir .web-full 2>/dev/null || true

# the full built web dir (css, html, favicon, vendor, llms.txt, install.sh,
# media/, dashboard/, …) was baked in in 2c.  Confirm the pieces treg reads
# from _WEB_DIR are present.
RUN test -f src/treg/web/landing.html \
 && test -f src/treg/web/catalog.css \
 && test -f src/treg/web/dashboard/index.html \
 && test -f src/treg/web/robots.txt \
 && test -f src/treg/web/media/redesign/dashboard.css \
 && ls src/treg/web/vendor/vue-*.global.prod.js >/dev/null

# -- 2d: prepare the data volume dir + entrypoint.
#       Create /app/data AS ROOT — the /app tree was just COPY'd and
#       therefore root-owned; the treg user can't mkdir into a root-owned
#       755 dir.  Own the whole /app as treg (single-user app container;
#       secrets live under /app/data + /app/.venv) so runtime writes work
#       without setuid tricks.
RUN mkdir -p /app/data && chmod 750 /app/data \
 && chown -R treg:treg /app
USER treg
COPY --chown=treg:treg entrypoint.sh /entrypoint.sh
RUN chmod 755 /entrypoint.sh

VOLUME ["/app/data"]
EXPOSE 18790

HEALTHCHECK --interval=30s --timeout=5s --start-period=90s --retries=4 \
  CMD python -c "import os,urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:%s/meta'%os.environ.get('PORT','18790'),timeout=3).status==200 else 1)" \
    || exit 1

ENTRYPOINT ["/entrypoint.sh"]
