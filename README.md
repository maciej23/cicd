# cicd

Shared, reusable GitHub Actions workflows for building containers, deploying
them via [flux-config](https://github.com/maciej23/flux-config), and
building/deploying frontends to Cloudflare Pages.

See [`PLAN.md`](./PLAN.md) for the original design write-up and rationale.
This README is the day-to-day usage reference.

## Repo access

This repo is private. Each repo that wants to call these workflows needs
access: **Settings → Actions → General → Access → "Accessible from
repositories owned by `maciej23`."**

## Versioning

Tag releases with semver (`v1.0.0`, `v1.1.0`, ...) and keep a movable `v1`
tag pointing at the latest `v1.x.y`. Callers pin to `@v1`:

```yaml
uses: maciej23/cicd/.github/workflows/docker-build.yml@v1
```

To cut a release:

```sh
git tag v1.0.0
git push origin v1.0.0
git tag -f v1
git push -f origin v1
```

---

## 1. `docker-build.yml`

Builds (and usually pushes) one image from one Dockerfile. For a monorepo,
call it once per component with a different `context`.

```yaml
jobs:
  build:
    uses: maciej23/cicd/.github/workflows/docker-build.yml@v1
    permissions:
      contents: read
      packages: write
    with:
      context: backend                 # subdirectory for monorepos
      tags: |                          # docker/metadata-action syntax
        type=raw,value=dev
        type=raw,value=dev-{{sha}}
      build-args: |
        APP_VERSION=${{ github.sha }}
      notify-on: failure                # started,success,failure - comma separated, empty = off
    secrets:
      NOTIFY_URL: ${{ secrets.NOTIFY_URL }}   # optional
```

- A `sha-<short sha>` tag is **always** pushed in addition to whatever
  `tags` asks for, so `outputs.tag` is always a real, immutable,
  per-commit tag you can hand to `flux-deploy.yml`.
- `tags` is raw `docker/metadata-action` config - use its
  [template variables](https://github.com/docker/metadata-action#typeraw)
  (`{{sha}}`, `{{branch}}`, `{{date 'YYYYMMDD'}}`, ...) for things like
  `dev` + `dev-{{sha}}`.
- **Outputs**: `image`, `tag` (the guaranteed sha tag), `tags` (full
  newline list), `digest`.
- **Unchanged source is retagged, not rebuilt** (`skip-unchanged: true`
  by default): the hash of the context tree + Dockerfile + build args +
  target + platforms is used as a `src-<hash>` tag; if that tag already
  exists in the registry, every requested tag is pointed at it via
  `docker buildx imagetools create` instead of running a build. In a
  monorepo this makes an unrelated component's commit nearly free.
- **Caching**: `cache: registry` (default) keeps a `<image>:buildcache`
  tag in the registry - no GHA cache size/eviction limits, shared across
  branches. `cache: gha` or `cache: none` are also available.
- **Custom build steps**: `pre-build` runs a shell snippet (cwd = context)
  before the build, for codegen or fetching assets. `build-args`,
  `build-secrets` (secret, `id=value` lines, mounted via
  `RUN --mount=type=secret`), `target`, and `build-contexts` cover most
  other cases. For anything else, write your own job and reuse
  `actions/notify` directly.
- **Multi-platform**: set `platforms: linux/amd64,linux/arm64`; QEMU is
  only set up when more than one platform is listed.
- Full input/secret/output list is documented inline in
  [`docker-build.yml`](./.github/workflows/docker-build.yml).

## 2. `flux-deploy.yml`

Bumps one or more images in a `flux-config` kustomization and pushes the
commit. Edits `kustomization.yaml`'s `images:` list directly with `yq` -
no `docker pull` of a kustomize image.

```yaml
jobs:
  deploy:
    needs: build
    uses: maciej23/cicd/.github/workflows/flux-deploy.yml@v1
    with:
      environment: plume                 # GitHub Environment (optional)
      path: apps/plume/myapp             # dir in flux-config
      images: ${{ needs.build.outputs.image }}=${{ needs.build.outputs.tag }}@${{ needs.build.outputs.digest }}
      changelog-paths: |                 # optional, scopes the changelog
        backend
      notify-on: success,failure
    secrets:
      FLUX_TOKEN: ${{ secrets.FLUX_CONFIG_PUSH_TOKEN }}
      NOTIFY_URL: ${{ secrets.NOTIFY_URL }}
```

- `images` is multiline `name=tag` or `name=tag@sha256:...`. Several lines
  = several images bumped in **one atomic commit** (monorepo: api + worker
  together). `name` must match an entry in the kustomization's `images:`
  list (or a new entry is appended).
- No-op if nothing changed: no commit, `outputs.changed` is `false`.
- Push races (two deploys to the same path at once) are handled with a
  `concurrency` group plus rebase-and-retry, up to 5 attempts.
- The changelog is `git log` between the previously deployed commit (parsed
  out of the previous tag) and `HEAD`, optionally scoped to
  `changelog-paths`.
- `FLUX_TOKEN` is a plain PAT with push access to the flux repo (a GitHub
  App token was tried and found too clunky for this; not supported here).

## 3. `frontend-cloudflare.yml`

Build is provider-agnostic (`actions/frontend-build`); only the deploy step
is Cloudflare-specific. A future `frontend-<other-provider>.yml` reuses the
same build action.

```yaml
jobs:
  deploy:
    uses: maciej23/cicd/.github/workflows/frontend-cloudflare.yml@v1
    with:
      working-directory: frontend
      project-name: myapp-dev            # Cloudflare Pages project
      environment: dev
      environment-url: https://myapp-dev.example.com
      notify-on: failure
    secrets:
      CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}
      CLOUDFLARE_ACCOUNT_ID: ${{ secrets.CLOUDFLARE_ACCOUNT_ID }}
      NOTIFY_URL: ${{ secrets.NOTIFY_URL }}
```

- Package manager (pnpm/npm/yarn/bun), Node version (`.nvmrc`), and caching
  are auto-detected; override with `package-manager` /
  `node-version-file` / `install-command` / `build-command` if needed.
- Every repo/environment **variable** (`vars`, not secrets) whose name
  starts with `env-prefix` (default `VITE_`) is exported to the build
  automatically - add a var in the GitHub Environment, no workflow edit
  needed. Dev vs. prod then differ only by which Environment you deploy
  to.
- Wrangler runs via `npx` at the pinned `wrangler-version`, not installed
  into the project (no `ignore-workspace-root-check` hacks needed).
- Unchanged source reuses the cached `dist/` and skips install+build
  entirely (`skip-unchanged: true` by default).

---

## Notifications

Opt-in, off by default: every workflow's `notify-on` input is empty unless
you list events (`started`, `success`, `failure`, comma-separated).

The provider is selected by the **scheme of a single secret**,
`NOTIFY_URL`:

```
discord://<webhook_id>/<webhook_token>
telegram://<bot_token>@<chat_id>[?thread=<topic_id>]
```

Switching Discord → Telegram is changing that one secret, not any
workflow. A failing webhook never fails the build/deploy - the dispatcher
(`actions/notify`) always swallows provider errors (as a warning
annotation).

**Adding a provider**: drop `actions/notify/providers/<scheme>.sh` in this
repo. It receives `NOTIFY_URL`, `STATUS` (`started`/`success`/`failure`),
`TITLE`, `LINK`, `DESCRIPTION`, `FIELDS` (multiline `Name|Value` pairs) as
env vars and does whatever HTTP call it needs. See
[`discord.sh`](./actions/notify/providers/discord.sh) for the shape.

---

## Caching, end to end

| layer | technique |
|---|---|
| Docker layers | registry cache (`<image>:buildcache`), per image, shared across branches, no GHA eviction limits |
| Unchanged Docker image | retag (`imagetools create`) instead of rebuild - see `skip-unchanged` above |
| Node deps | `actions/setup-node` cache keyed on the lockfile, via `actions/frontend-build` |
| Unchanged frontend | cached `dist/` keyed on the source tree hash - skips install *and* build |

---

## Monorepos

Two patterns - see [`examples/`](./examples):

- **One caller workflow per component**, gated by `on.push.paths`
  ([`backend-single-dockerfile.yml`](./examples/backend-single-dockerfile.yml)).
- **One workflow, a build matrix** over changed components via
  `dorny/paths-filter`, deploying every image in one flux commit
  ([`monorepo-matrix.yml`](./examples/monorepo-matrix.yml)). Deploy tags
  must be computable from the commit sha (not read back from matrix
  outputs, which is "last job wins") - `docker-build.yml`'s guaranteed
  `sha-<short sha>` tag is what makes that possible.

---

## Repo layout

```
.github/workflows/
  docker-build.yml          reusable: build + push a container image
  flux-deploy.yml            reusable: bump flux-config, commit, push
  frontend-cloudflare.yml    reusable: build frontend, deploy to Cloudflare Pages
  ci.yml                     this repo's own lint (actionlint, shellcheck, zizmor)
actions/
  notify/                    provider-agnostic notification dispatcher
    providers/discord.sh
    providers/telegram.sh
  frontend-build/            provider-agnostic frontend build (detect/cache/build)
examples/                    copy-paste caller workflows
PLAN.md                      original design doc
```
