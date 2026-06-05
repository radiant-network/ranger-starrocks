# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A self-contained Apache Ranger admin image (`FROM apache/ranger:2.8.0`) with the StarRocks integration
baked in, plus a Helm chart that deploys it. The same single image is used for three distinct phases
(`migrate` / `serve` / `register`) — see Architecture below. The repo contains no Java/Ranger source;
all customization is via the entrypoint, a Python registration script, JSON service-defs, and Helm
templates.

## Common commands

Local dev stack (the image is built once on the `ranger-migrate` service and reused by the other two):

```bash
docker compose up -d ranger-db ranger-migrate ranger ranger-register
# Admin UI: http://localhost:6080  (admin / rangerR0cks!)
```

Note: `compose.yaml` was designed to be `include`'d by a parent compose file in `backend/` that also
defines a `starrocks` service. Running it standalone works for the Ranger stack itself, but the
`ranger-register` phase expects a reachable `starrocks` host at `jdbc:mysql://starrocks:9030`.

Verify the StarRocks Test Connection against a running admin:

```bash
curl -s -u admin:<RANGER_ADMIN_PASSWORD> -H 'Content-Type: application/json' -X POST \
  http://localhost:6080/service/plugins/services/validateConfig \
  -d '{"name":"starrocks","type":"starrocks","configs":{"username":"root","password":"","jdbc.driverClassName":"com.mysql.cj.jdbc.Driver","jdbc.url":"jdbc:mysql://starrocks:9030"}}'
```

Helm:

```bash
helm lint helm/
helm unittest helm/                                            # all tests
helm unittest -f 'tests/phases_test.yaml' helm/                # single suite
# helm-unittest plugin: helm plugin install https://github.com/helm-unittest/helm-unittest --version v1.1.0 --verify=false
```

## Architecture

### Three phases, one image

The image has a custom `ENTRYPOINT` (`image/ranger-entrypoint.sh`) that dispatches on its first arg:

- **`migrate`** — render `install.properties` from env, run `setup.sh` (schema + account passwords),
  exit 0. Holds every account password. In k8s this is a `pre-install,pre-upgrade` Helm hook Job.
- **`serve`** — re-run setup (idempotent; also regenerates `ranger-admin-site.xml`), start the admin
  via `ranger-admin-services.sh`, then (unless `RANGER_REGISTER_ON_SERVE=false`) wait for the local
  REST endpoint and run `register-services.py`. Stays alive by `tail --pid` of the embedded Tomcat
  PID. In k8s this is the long-running Deployment + Service.
- **`register`** — pure REST client against an already-running admin: no DB setup, no server, just
  `register-services.py`. In k8s this is a `post-install,post-upgrade` Helm hook Job.

The split exists to **separate secrets by phase**: `migrate` sees DB creds + all account passwords;
`serve` sees only DB creds (user auth is resolved against the DB that migrate populated); `register`
sees admin + StarRocks creds but no DB creds. Preserve this least-privilege boundary when editing
`compose.yaml` or the Helm chart's per-phase `extraEnvFrom` plumbing.

### Configuration flow (env vars → files)

Only env vars prefixed `RANGER_*` are ever substituted into templates (Python `Template.safe_substitute`,
not shell `envsubst`). Two distinct substitution passes:

1. `ranger-entrypoint.sh::render_props` substitutes `${RANGER_*}` into `image/install.properties.tpl`
   and writes `${RANGER_HOME}/admin/install.properties` for `setup.sh` to consume. Shell tokens that
   `setup.sh` itself must evaluate (e.g. `$PWD`, `$LOGFILE`) are intentionally left untouched.
2. `register-services.py::load_json` substitutes `${RANGER_*}` into each baked JSON before parsing,
   so secrets (StarRocks user/password/JDBC URL) come from env (and ultimately k8s Secrets) rather
   than being committed.

Two StarRocks knobs are normalized in the entrypoint before either pass runs, so all modes see them:

- `RANGER_STARROCKS_AUTOCOMPLETE=yes` → `RANGER_STARROCKS_IMPL_CLASS=org.apache.ranger.services.starrocks.RangerServiceStarRocks`
  (enables UI Test Connection / resource autocomplete; **requires** StarRocks connection vars).
  Anything else → empty `implClass`, base class, no probing — connection vars become optional.
- `RANGER_STARROCKS_SERVICE_NAME` (default `starrocks`) → substituted into `services/starrocks.json`'s
  `name` field.

### `register-services.py` idempotency contract

Two directories scanned in order (so instances can reference their type):

| Dir (env override)                          | Object         | Behavior                  |
|---------------------------------------------|----------------|---------------------------|
| `/ranger/service-defs` (`RANGER_SERVICEDEF_DIR`) | service-def | **create-or-update** (so schema fixes like a corrected `implClass` propagate on re-run) |
| `/ranger/services` (`RANGER_SERVICE_DIR`)       | service     | **create-only** (never clobber a live service's config or attached policies) |

When adding a new baked service-def or instance, drop the JSON into the matching `image/service-defs/`
or `image/services/` dir — the `Dockerfile` `COPY`s them into the dirs the script already scans, so no
script changes are needed. Use `${RANGER_*}` placeholders for any secret/per-env value.

### Helm chart phase wiring

In `helm/templates/`, each phase is gated by `<phase>.enabled` and the two Jobs use Helm hook
annotations to sequence around the Deployment:

```
pre-install,pre-upgrade  (weight -5) : migrate-job.yaml
normal resource                       : deployment.yaml + service.yaml (+ ingress.yaml)
post-install,post-upgrade (weight  5) : register-job.yaml
```

`helm install/upgrade --wait` is what makes Helm block on `serve` becoming Ready before the post-hook
`register` Job fires. The chart **manages no Secrets** — credentials are supplied per phase via
`<phase>.extraEnvFrom` (a list of `secretRef` / `configMapRef` sources). When changing env-var names,
update both the image (entrypoint / templates) and the chart's per-phase env plumbing together.

### Dockerfile quirks to know about

- The base image's `setup.sh` contains a bare `export $DIST_NAME` with `DIST_NAME` empty, which would
  dump every env var (incl. secrets) to logs. The Dockerfile `sed -i`'s that line out and then asserts
  it's gone with `! grep` — so a base-image bump that changes that line will fail the build on purpose.
- The StarRocks plugin jar and MySQL JDBC driver are downloaded into
  `/opt/ranger/admin/ews/webapp/WEB-INF/classes/ranger-plugins/starrocks/` at build time. URLs are
  `ARG`s (`STARROCKS_PLUGIN_JAR`, `MYSQL_CONNECTOR_JAR`) — override via `--build-arg` when bumping.
