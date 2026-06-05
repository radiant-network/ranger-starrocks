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

**The chart manages no secrets.** It injects only non-sensitive config (DB host, URLs, flags) as plain
env vars. All credentials are supplied by *you* via each phase's `extraEnvFrom` (a list of `secretRef`
/ `configMapRef` sources). This keeps secrets external and lets each phase see only the keys it needs.

Required secret keys **per phase** (the env-var names the image expects):

| Phase | Keys it needs |
|---|---|
| `migrate` | `RANGER_DB_PASSWORD`, `RANGER_DB_ROOT_PASSWORD` (unused under SeparateDBA), `RANGER_ADMIN_PASSWORD`, `RANGER_KEYADMIN_PASSWORD`, `RANGER_TAGSYNC_PASSWORD`, `RANGER_USERSYNC_PASSWORD` |
| `serve` | `RANGER_DB_PASSWORD` |
| `register` | `RANGER_ADMIN_PASSWORD`, `RANGER_STARROCKS_USERNAME`, `RANGER_STARROCKS_PASSWORD` |

> Account passwords must be ≥8 chars with upper + lower + digit, or the migrate step fails.

You can point all phases at one fat Secret or split them so each phase only mounts its slice
(recommended — preserves the least-privilege design). `extraEnvFrom` is a list, so you can stack
several `secretRef` / `configMapRef` sources; on key collision, later sources win.

```yaml
migrate:
  extraEnvFrom:
    - secretRef: { name: ranger-credentials }   # all 6 migrate keys
serve:
  extraEnvFrom:
    - secretRef: { name: ranger-db-secret }      # RANGER_DB_PASSWORD only
register:
  extraEnvFrom:
    - secretRef: { name: ranger-admin-secret }   # admin + starrocks creds
```

## Installation

```bash
helm install ranger backend/ranger/helm/ \
  --set image.repository=ghcr.io/org/ranger \
  --set image.tag=2.8.0 \
  --set db.host=my-postgres:5432 \
  --set ranger.policyMgrExternalUrl=https://ranger.internal \
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

The `serve` admin (port 6080) can be exposed via an Ingress. Override `ingressClassName`,
`path`/`pathType`, ingress-level `annotations`, and the `hosts` list (each host can opt into TLS):

```yaml
serve:
  ingress:
    enabled: true
    ingressClassName: alb
    # Prefix (not the chart default ImplementationSpecific): the AWS ALB controller turns
    # pathType Prefix "/" into the path-pattern "/*", so static assets route to the admin
    # too. ImplementationSpecific "/" matches only "/" exactly -> the UI bundle 404s.
    path: /
    pathType: Prefix
    annotations:
      alb.ingress.kubernetes.io/target-type: ip
      alb.ingress.kubernetes.io/healthcheck-path: /login.jsp
      alb.ingress.kubernetes.io/healthcheck-protocol: HTTP
    hosts:
      - name: ranger.dev.example.com
        tls:
          enabled: true
          secretName: ranger-tls
```

A `tls` block is emitted only for hosts that set `tls.enabled: true`. The Ingress always targets the
chart's `serve` Service on `serve.service.port`. No Ingress is rendered unless both `serve.enabled` and
`serve.ingress.enabled` are true.

## Configuration

| Key | Default | Description |
|---|---|---|
| `image.repository` | `""` | Image repo (required). |
| `image.tag` | `latest` | Image tag. |
| `image.pullPolicy` | `IfNotPresent` | Pull policy. |
| `db.host` | `""` | PostgreSQL `host:port` (required). |
| `db.name` | `ranger` | Database name (pre-created). |
| `db.user` | `rangeradmin` | Runtime DB role. |
| `ranger.policyMgrExternalUrl` | `http://ranger:6080` | External admin URL advertised in config. |
| `starrocks.autocomplete` | `yes` | `yes` enables the StarRocks plugin class (UI Test Connection / autocomplete). |
| `starrocks.serviceName` | `starrocks` | Registered service-instance name. |
| `starrocks.jdbcUrl` | `""` | StarRocks JDBC URL for the registered service. |
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
| `serve.ingress.hosts` | `[]` | List of `{ name, tls: { enabled, secretName } }`. |
| `register.enabled` | `true` | Render the register Job. |
| `register.backoffLimit` | `6` | Job retries (until admin answers). |
| `register.ttlSecondsAfterFinished` | `300` | Auto-cleanup after completion. |
| `register.adminUrl` | `http://ranger:6080` | Admin REST URL the register Job targets. |
| `register.adminUser` | `admin` | Admin username. |
| `<phase>.extraEnv` | `[]` | Individual env vars (raw `EnvVar` objects) per phase. |
| `<phase>.extraEnvFrom` | `[]` | Bulk env sources (`secretRef` / `configMapRef`) per phase — **how credentials are supplied**. |

## Testing

Unit tests (no cluster required) live in `tests/` and use the
[`helm-unittest`](https://github.com/helm-unittest/helm-unittest) plugin. They cover the phase toggles,
command/hook wiring, per-phase secret isolation, and the optional init-container/volume/env blocks.

```bash
helm plugin install https://github.com/helm-unittest/helm-unittest --version v1.1.0 --verify=false
helm lint backend/ranger/helm/
helm unittest backend/ranger/helm/
```
