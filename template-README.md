# Deploy and Host treg on Railway

[![Deploy to Railway](https://railway.app/button.svg)](https://railway.com/deploy/heb2iW)

OpenRouter for agent tools — one base URL and one token to reach a catalog
of thousands of priced API endpoints (SEO, social, enrichment, ads, scraping,
image/video generation), plus your own tools and team keys. No provider
signups required.

Full reference (catalog, `treg CLI` usage, provider and skill docs,
architecture) lives in the app README on GitHub:
`github.com/mc9max/treg/blob/master/README.md`.

## About Hosting

treg is a single service: a Python/uvicorn API (serving the web dashboard and
JSON API on one port) plus your frontend assets baked into the image. The
container healthcheck probes `GET /meta`. All durable state lives under
`/app/data` — the bundled SQLite database, the Fernet encryption key (minted
on first boot), and any uploaded assets. A Railway volume named `treg-data`
mounted at `/app/data` (declared in `railway.json`) keeps all of this
durable; without it the app still boots but resets on each redeploy.

Startup is two stages in the image's `entrypoint.sh`: an idempotent
`treg upgrade` (catalog + schema migration) first, then uvicorn. On Railway
the `PORT` env var wins over the image default (8080 is the practical
default for a fresh deploy), and the public domain routes to that port.

## Why Deploy treg

- **One token, one base URL** for your agent to reach hundreds of upstream
  services. No per-provider signups, no per-provider keys in your agent
  config, no per-provider bill.
- **Own keys always win.** A teammate's Reseller, Stripe, or Apollo credential
  beats treg's catalog for calls made under their token; the credential never
  leaves the server, and those calls are not metered by treg.
- **Bring your own tools.** Register a `SKILL.md`, a CLI wrapper (`stripe`,
  `gh`), or an arbitrary `base_url` with its own OAuth/secret bindings — and
  every teammate with a token in the same org can call it through the same
  proxy.
- **Priced per call, at cost.** The catalog routes to a wide set of vendors
  under treg's own account and bills each agent at the per-call cost of the
  upstream (fractions of cent) — no markup.

## Common Use Cases

- An agent stack (your LLM provider + agent framework) that needs real-world
  actions — backlinks, social posts, company records, ad data, images,
  video — behind one `Authorization: Bearer <treg token>` header.
- A shared team dashboard to grant each teammate their own treg token, their
  own balance / own keys, and their own set of visible tools.
- A self-hosted "tools-as-HTTP" gateway in front of any LLM, so the LLM
  never has to learn a per-vendor SDK.

## Dependencies for treg on Railway

### Deployment Dependencies

Everything treg needs to run is either baked into the image or auto-populated
by the deploy form — **no sidecar service is required**:

- **Postgres** (optional, recommended for production) — `TREG_DATABASE_URL`
  defaults to the bundled SQLite on the persistent volume. Point this at a
  Postgres service when you want multi-replica durability.
- **A public domain** — `TREG_PUBLIC_URL` is pre-filled from `system.domain`
  (railway.com's `*.up.railway.app` by default); override it if you front
  treg with a custom domain. This value anchors the OAuth callback
  (`<TREG_PUBLIC_URL>/auth/github/callback`) and is what a fresh installer
  hits from their agent.

No other required services. The optional integrations (each a variable on
the deploy form; leaving them blank just disables that door — the deploy
still succeeds):

- **Email OTP via Resend** — `TREG_RESEND_API_KEY` + a Resend-verified
  sending domain (SPF/DKIM), with the `TREG_EMAIL_FROM` header set to that
  domain. One-time codes arrive by email.
- **Telemetry** — `TREG_TELEMETRY_DISABLE=true` stops your instance
  phoning treg.to from the agent-side; leave unset only if you want the
  hosted catalog kept in sync upstream.

GitHub OAuth is the only identity door configured in this template's form
(`TREG_GITHUB_CLIENT_ID` + `TREG_GITHUB_CLIENT_SECRET`); Google OAuth is
available in the codebase but is not exposed as a form variable here, and
self-hosted SMTP is likewise available in code but not surfaced as form
variables. If you want either, extend `template-vars.json` with the
`TREG_GOOGLE_*` / `TREG_SMTP_*` keys and re-publish — the image already
supports them.

## Notes

- **First login needs at least one identity provider configured** — the app
  intentionally refuses no-login mode when a public domain is in front of it,
  so pick one door in the deploy form before your first sign-in. GitHub OAuth
  is the zero-credential path: it only needs your own GitHub OAuth App, not
  a mail vendor or a Resend key.
- **The `treg-data` volume is mandatory for durable state** — without it the
  app boots and serves, but your SQLite database + Fernet key re-mint on
  every redeploy and your previous data is gone.
- **Port:** on Railway the public domain always routes to `8080` (Railway's
  injected default for the service), not the image default `18790`. The app
  reads `PORT` at runtime, so `http://SERVICE.railway.internal:8080` is the
  port for local health checks.
