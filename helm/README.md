# Ranger Helm Chart

Deploys Apache Ranger on Kubernetes using the three-phase image built in `backend/ranger/`
(`migrate` / `serve` / `register`). The same image runs in all three phases; the chart maps each phase
to the right Kubernetes workload and sequences them via Helm release hooks.

## Phase model

| Phase | Workload | Helm role | Purpose |
|---|---|---|---|
| `migrate` | Job | `pre-install,pre-upgrade` hook (weight `-5`) | Create/patch the Ranger schema (SeparateDBA) and set account passwords, then exit. Helm blocks until it completes. |
| `serve` | Deployment + Service | normal resource | The long-running Ranger admin (UI + REST) on port 6080. |
| `register` | Job | `post-install,post-upgrade` hook (weight `5`) | Register the StarRocks service-def + instance against the running admin via REST. `restartPolicy: OnFailure` so it retries until the admin answers. |

Lifecycle on `helm install/upgrade --wait`:

```
pre-hook: migrate (wait for Complete)
   -> apply Deployment + Service (--wait -> wait Ready)
      -> post-hook: register (admin is reachable)
```

## Prerequisites

- The `ranger` dual-mode image, pushed to a registry your cluster can pull (`image.repository`).
- An external/managed PostgreSQL, with the database + runtime role pre-created (SeparateDBA mode — the
  image does not create the DB or a superuser at runtime).
- One or more Kubernetes Secrets holding the credentials (see [Secrets](#secrets)).

## Secrets

**The chart manages no Secrets** — you pre-create them. You declare each credential **once** under
`db` / `accounts` / `starrocks`, pointing it at an existing Secret (or ConfigMap) key, and the chart
routes it into **only** the phases that need it. You never wire phases yourself, and credentials a
phase doesn't need are never injected into it (e.g. the DB password never reaches `register`).

There are two ways to supply credentials, and you can mix them.

**1. Group default (terse).** Set `<group>.secret` once and every credential in that group is read
from that Secret, using a default key equal to the **env-var name**:

```yaml
db:
  host: my-postgres:5432
  secret: ranger-db          # must contain key RANGER_DB_PASSWORD (and RANGER_DB_HOST etc. if those fields are empty)
accounts:
  secret: ranger-accounts    # keys: RANGER_ADMIN_PASSWORD, RANGER_KEYADMIN_PASSWORD, RANGER_TAGSYNC_PASSWORD, RANGER_USERSYNC_PASSWORD
starrocks:
  jdbcUrl: jdbc:mysql://starrocks:9030
  secret: ranger-starrocks   # keys: RANGER_STARROCKS_USERNAME, RANGER_STARROCKS_PASSWORD
```

Because the default keys are the env-var names, the same Secret also works as a raw `extraEnvFrom`
import. (`db.rootPassword` is optional and is **not** auto-pulled by `db.secret` — set it explicitly
if you need it.)

**2. Per-field source (explicit; overrides the group).** Every field under `db` / `accounts` /
`starrocks` — including connection fields like `db.host` / `db.name` / `db.user` — is
"literal-or-sourced":

```yaml
secret:    { name: <secret>,    key: <key> }   # -> valueFrom.secretKeyRef (name/key fall back to group secret / env-var name)
configMap: { name: <configmap>, key: <key> }   # -> valueFrom.configMapKeyRef
value:     "<literal>"                         # -> plain value (explicit map form)
```

Plain scalars also work (e.g. `db.host: my-pg:5432`). A field left empty (`""`) with no group
`secret` renders nothing — use a phase's `extraEnv` / `extraEnvFrom` escape hatch for those.

| Credential field | Env var | Routed to |
|---|---|---|
| `db.password` | `RANGER_DB_PASSWORD` | migrate, serve |
| `db.rootPassword` | `RANGER_DB_ROOT_PASSWORD` (unused under SeparateDBA) | migrate |
| `accounts.admin` | `RANGER_ADMIN_PASSWORD` | migrate, register |
| `accounts.keyadmin` | `RANGER_KEYADMIN_PASSWORD` | migrate |
| `accounts.tagsync` | `RANGER_TAGSYNC_PASSWORD` | migrate |
| `accounts.usersync` | `RANGER_USERSYNC_PASSWORD` | migrate |
| `starrocks.username` | `RANGER_STARROCKS_USERNAME` | register |
| `starrocks.password` | `RANGER_STARROCKS_PASSWORD` | register |

> Account passwords must be ≥8 chars with upper + lower + digit, or the migrate step fails.

> `starrocks.username`/`password` are needed **only** when `register.enabled` and
> `starrocks.autocomplete: true`. With `register.enabled: false` or `autocomplete: false`, leave them
> empty — nothing is rendered.

For anything outside this set, each phase still has generic `extraEnv` (raw `EnvVar` objects) and
`extraEnvFrom` (bulk `secretRef` / `configMapRef`) escape hatches.

## Installation

```bash
helm install ranger backend/ranger/helm/ \
  --set image.repository=ghcr.io/org/ranger \
  --set image.tag=2.8.0 \
  --set db.host=my-postgres:5432 \
  --set ranger.externalUrl=https://ranger.internal \
  --set starrocks.jdbcUrl=jdbc:mysql://starrocks:9030 \
  -f my-secrets-values.yaml \
  --wait --atomic
```

`--wait` is what makes Helm wait for `serve` to be Ready before the `register` post-hook fires.
`--atomic` rolls the whole release back on any failure.

## Running a single phase

Each phase has an `enabled` flag. To run, e.g., serve-only (migrate already applied against the DB,
registration handled elsewhere):

```bash
helm install ranger backend/ranger/helm/ \
  --set image.repository=ghcr.io/org/ranger \
  --set db.host=my-postgres:5432 \
  --set migrate.enabled=false \
  --set register.enabled=false \
  -f my-secrets-values.yaml
```

## Init containers / SSL certs for StarRocks

The `serve` Deployment supports `initContainers`, `extraVolumes`, `extraVolumeMounts`, `extraEnv`, and
`extraEnvFrom`. The common use is mounting a CA cert for a TLS StarRocks connection:

```yaml
serve:
  initContainers:
    - name: copy-ssl-cert
      image: busybox:1.36
      command: ["sh", "-c", "cp /certs-src/ca.crt /ssl/ca.crt && chmod 444 /ssl/ca.crt"]
      volumeMounts:
        - { name: ssl-cert-src, mountPath: /certs-src, readOnly: true }
        - { name: ssl-cert, mountPath: /ssl }
  extraVolumes:
    - name: ssl-cert-src
      secret: { secretName: starrocks-tls-ca }
    - name: ssl-cert
      emptyDir: {}
  extraVolumeMounts:
    - { name: ssl-cert, mountPath: /ssl, readOnly: true }
  extraEnv:
    - { name: DB_SSL_CA, value: /ssl/ca.crt }
```

## Ingress

The `serve` admin (port 6080) can be exposed via an Ingress. When `serve.ingress.enabled` is true,
the ingress host defaults to the hostname extracted from `ranger.externalUrl` (scheme and port
stripped). Override with an explicit `serve.ingress.hosts` list when you need TLS or multiple hosts.

```yaml
ranger:
  externalUrl: https://ranger.dev.example.com

serve:
  ingress:
    enabled: true          # host derived from externalUrl automatically: ranger.dev.example.com
    ingressClassName: alb
    annotations:
      alb.ingress.kubernetes.io/target-type: ip
      alb.ingress.kubernetes.io/healthcheck-path: /login.jsp
```

To add TLS or override the host, set `serve.ingress.hosts` explicitly — it takes precedence over the
derived host:

```yaml
serve:
  ingress:
    enabled: true
    ingressClassName: alb
    hosts:
      - name: ranger.dev.example.com
        tls:
          enabled: true
          secretName: ranger-tls
```

A `tls` block is emitted only for hosts that set `tls.enabled: true`. TLS is only supported for
explicit hosts (the derived host has no `secretName`). No Ingress is rendered unless both
`serve.enabled` and `serve.ingress.enabled` are true.

## Configuration

| Key | Default | Description |
|---|---|---|
| `image.repository` | `""` | Image repo (required). |
| `image.tag` | `latest` | Image tag. |
| `image.pullPolicy` | `IfNotPresent` | Pull policy. |
| `ranger.externalUrl` | `""` | External admin URL — sets `RANGER_POLICYMGR_EXTERNAL_URL` and is used as the default ingress host (scheme + port stripped). |
| `db.host` | `""` | PostgreSQL `host:port`. Literal or sourced (see [Secrets](#secrets)). |
| `db.name` | `ranger` | Database name (pre-created). Literal or sourced. |
| `db.user` | `rangeradmin` | Runtime DB role. Literal or sourced. |
| `db.rootUser` | `rangeradmin` | Root DB user (unused under SeparateDBA). Literal or sourced. |
| `db.secret` | `""` | Default Secret name for all empty `db.*` fields (keys default to the env-var name). |
| `db.password` | `""` | `RANGER_DB_PASSWORD` → migrate + serve. |
| `db.rootPassword` | `""` | `RANGER_DB_ROOT_PASSWORD` → migrate (optional; not auto-pulled by `db.secret`). |
| `accounts.secret` | `""` | Default Secret name for all empty `accounts.*` fields. |
| `accounts.admin` | `""` | `RANGER_ADMIN_PASSWORD` → migrate + register. |
| `accounts.keyadmin` | `""` | `RANGER_KEYADMIN_PASSWORD` → migrate. |
| `accounts.tagsync` | `""` | `RANGER_TAGSYNC_PASSWORD` → migrate. |
| `accounts.usersync` | `""` | `RANGER_USERSYNC_PASSWORD` → migrate. |
| `starrocks.autocomplete` | `true` | Boolean — `true` renders `RANGER_STARROCKS_AUTOCOMPLETE=yes` and requires `username`/`password`. |
| `starrocks.serviceName` | `starrocks` | `RANGER_STARROCKS_SERVICE_NAME`. Literal or sourced. |
| `starrocks.jdbcUrl` | `""` | `RANGER_STARROCKS_JDBC_URL`. Literal or sourced. |
| `starrocks.usersyncUser` | `rangerusersync` | `RANGER_USERSYNC_USER` → register (`policy.download.auth.users`); the image removes Ranger's anonymous legacy download endpoints. Literal or sourced. |
| `starrocks.tagsyncUser` | `rangertagsync` | `RANGER_TAGSYNC_USER` → register (`tag.download.auth.users`). Literal or sourced. |
| `starrocks.secret` | `""` | Default Secret name for all empty `starrocks.*` fields. |
| `starrocks.username` | `""` | `RANGER_STARROCKS_USERNAME` → register (required when `autocomplete`). |
| `starrocks.password` | `""` | `RANGER_STARROCKS_PASSWORD` → register (required when `autocomplete`). |
| `migrate.enabled` | `true` | Render the migrate Job. |
| `migrate.backoffLimit` | `3` | Job retries. |
| `migrate.ttlSecondsAfterFinished` | `300` | Auto-cleanup after completion. |
| `serve.enabled` | `true` | Render the Deployment + Service. |
| `serve.replicas` | `1` | Admin replicas. |
| `serve.initContainers` | `[]` | Init containers (raw specs). |
| `serve.extraVolumes` | `[]` | Extra pod volumes. |
| `serve.extraVolumeMounts` | `[]` | Extra container volume mounts. |
| `serve.resources` | `{}` | Resource requests/limits. |
| `serve.service.type` | `ClusterIP` | Service type. |
| `serve.service.port` | `6080` | Service port. |
| `serve.ingress.enabled` | `false` | Render an Ingress for the serve admin. |
| `serve.ingress.ingressClassName` | `""` | Ingress class (e.g. `alb`, `nginx`). |
| `serve.ingress.path` | `/` | Path for every host rule. |
| `serve.ingress.pathType` | `Prefix` | Path type for every host rule. |
| `serve.ingress.annotations` | `{}` | Ingress-level annotations (controller-specific). |
| `serve.ingress.hosts` | `[]` | Explicit host list `{ name, tls: { enabled, secretName } }`. Overrides the host derived from `ranger.externalUrl`. |
| `register.enabled` | `true` | Render the register Job. |
| `register.backoffLimit` | `6` | Job retries (until admin answers). |
| `register.ttlSecondsAfterFinished` | `300` | Auto-cleanup after completion. |
| `register.adminUrl` | `http://ranger:6080` | Internal admin REST URL the register Job targets. |
| `register.adminUser` | `admin` | Admin username. |
| `<phase>.extraEnv` | `[]` | Escape hatch: individual env vars (raw `EnvVar` objects) per phase. |
| `<phase>.extraEnvFrom` | `[]` | Escape hatch: bulk env sources (`secretRef` / `configMapRef`) per phase. |

## Testing

Unit tests (no cluster required) live in `tests/` and use the
[`helm-unittest`](https://github.com/helm-unittest/helm-unittest) plugin. They cover phase toggles,
command/hook wiring, credential routing per phase, ingress host derivation, and the optional
init-container/volume/env blocks.

```bash
helm plugin install https://github.com/helm-unittest/helm-unittest --version v1.1.0 --verify=false
helm lint backend/ranger/helm/
helm unittest backend/ranger/helm/
```
