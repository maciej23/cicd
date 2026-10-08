# cicd — shared GitHub Actions: plan

Status: **proposal**, nothing implemented yet.

## Goals

One place (`maciej23/cicd`) for these pieces, which every project calls:

1. **docker-build**: build and push a container image (multiple tags, monorepo subdirectories, custom args)
2. **flux-deploy**: bump image tag(s) in `maciej23/flux-config`, commit, push
3. **frontend-cloudflare**: build a static frontend and deploy it to Cloudflare

Shared across all three: opt-in pluggable notifications, rich `$GITHUB_STEP_SUMMARY`,
aggressive caching.

## Layout

```
cicd/
├── .github/workflows/
│   ├── docker-build.yml          # reusable (on: workflow_call)
│   ├── flux-deploy.yml           # reusable
│   ├── frontend-cloudflare.yml   # reusable, provider-specific shell
│   └── ci.yml                    # this repo's own CI: actionlint + zizmor + self-tests
├── actions/                      # composite actions, used by the workflows (and callable directly)
│   ├── notify/                   # provider-agnostic notification dispatcher
│   │   ├── action.yml
│   │   └── providers/
│   │       ├── discord.sh
│   │       └── telegram.sh       # adding a provider = adding one script
│   ├── frontend-build/           # provider-agnostic: detect PM, node, cached install, build
│   └── summary/                  # small helpers for consistent step summaries (maybe just a script)
├── tests/fixtures/               # tiny Dockerfile + tiny vite app for self-tests
├── examples/                     # copy-paste caller workflows (single app, monorepo matrix, frontend)
└── README.md
```

Callers do `uses: maciej23/cicd/.github/workflows/docker-build.yml@v1`.

**Versioning:** semver tags plus a movable `v1` major tag. A reusable workflow can't
use `./actions/...` relative paths, because the checkout is the *caller's* repo. So the
workflows reference `maciej23/cicd/actions/notify@v1` internally, and every release
moves `v1`.

**Access:** if `cicd` stays private, enable *Settings → Actions → General → Access →
"Accessible from repositories owned by the user"*.

---

## 1. `docker-build.yml`

### Inputs (all optional unless marked)

| input | default | notes |
|---|---|---|
| `context` | `.` | monorepo: `backend`, `services/worker`, … |
| `dockerfile` | `<context>/Dockerfile` | can live outside the context |
| `image` | `ghcr.io/<owner>/<repo>-<basename(context)>` | full image ref, any registry |
| `tags` | `type=sha,prefix=sha-` | **multiline, raw `docker/metadata-action` syntax**, so `type=raw,value=dev` + `type=sha,prefix=dev-` gives `dev` and `dev-abc1234` |
| `build-args` | — | multiline `KEY=VALUE` |
| `target` | — | multi-stage target |
| `platforms` | `linux/amd64` | `linux/amd64,linux/arm64` → sets up QEMU only when needed |
| `build-contexts` | — | extra named contexts (`shared=../libs`) |
| `pre-build` | — | shell snippet run before the build (codegen, fetching assets, …) |
| `push` | `true` | `false` for PR validation builds |
| `cache` | `registry` | `registry` \| `gha` \| `none` (see caching) |
| `skip-unchanged` | `false`? | retag instead of rebuild (see caching) |
| `notify-on` | `''` (off) | `failure`, `success`, `start`, comma-separated |
| `runs-on` | `ubuntu-latest` | e.g. `ubuntu-24.04-arm` for native arm builds |

Secrets: `build-secrets` (multiline `id=value`, mounted with `RUN --mount=type=secret`),
`registry-password` (defaults to `GITHUB_TOKEN` for ghcr), `NOTIFY_URL`.

### Outputs
- `image`: e.g. `ghcr.io/maciej23/sportino-backend`
- `tag`: the **immutable** tag meant for deploys (the sha-based one)
- `tags`: all pushed tags (newline-separated)
- `digest`: `sha256:…`, so deploys can pin `tag@digest`

### Custom build processes, escalating
1. `build-args` / `build-secrets` / `target` / `build-contexts`
2. `pre-build` shell hook
3. Escape hatch: the caller writes their own job and uses only `actions/notify` + summary helpers

### Summary
A table with image, every tag, digest, platforms, duration and a copy-pasteable
`docker pull`. Build args (secrets redacted) go in a collapsible `<details>`.
`build-push-action` also adds its own build record summary, which we keep.

---

## 2. `flux-deploy.yml`

### Inputs
| input | default | notes |
|---|---|---|
| `images` (**required**) | — | multiline `image=tag` or `image=tag@digest`. **Several images, one atomic commit** (monorepo: api + worker together) |
| `path` (**required**) | — | dir in flux repo, e.g. `apps/plume/sportino` |
| `flux-repo` | `maciej23/flux-config` | |
| `flux-branch` | `main` | |
| `mode` | `kustomize` | `kustomize`: upsert into `images:` of `kustomization.yaml`. `yq`: arbitrary expression for HelmRelease values etc. |
| `yq-expression` | — | for `mode: yq` |
| `environment` | — | GitHub Environment, for protection rules/approvals + deployment history |
| `app-name` | repo name | used in commit message / notifications |
| `changelog-paths` | — | limits `git log` to the component's paths (monorepo) |
| `commit-message` | `chore(<app>): deploy <image>:<tag>` | |
| `notify-on` | `''` | |

Secrets: `FLUX_TOKEN` (PAT), **or** `FLUX_APP_ID` + `FLUX_APP_PRIVATE_KEY` (GitHub App token via
`actions/create-github-app-token`: short-lived and scoped. Recommended, optional).

### Behaviour
- **No docker pull of kustomize**: edit `kustomization.yaml` with `yq` (preinstalled on runners), upserting the `images[]` entry.
- **Concurrency**: `concurrency: flux-<flux-repo>-<path>`. The push runs in a loop of
  `git pull --rebase && git push`, retried 5× with backoff, so simultaneous deploys from different repos don't fail.
- **No-op detection**: if the tag is unchanged, the summary says "already deployed" and there is no commit.
- **Changelog**: read the previous tag, extract the sha (any `*-<sha>` or `sha-<sha>` convention),
  run `git log prev..HEAD -- <changelog-paths>`, and cap the length.
- Outputs: `previous-tag`, `flux-commit`, `changelog`, `changed` (bool).

### Summary
Environment, an old → new tag diff per image, a link to the flux-config commit, and the changelog.

---

## 3. `frontend-cloudflare.yml`

Split into a **provider-agnostic build** (`actions/frontend-build`) and a **Cloudflare deploy step**.
A future `frontend-netlify.yml` / `frontend-s3.yml` reuses the build action and only adds its own deploy step.

### Inputs
| input | default | notes |
|---|---|---|
| `working-directory` | `.` | `frontend`, `apps/web`, … |
| `package-manager` | auto | detected from the lockfile (pnpm/npm/yarn/bun); pnpm version from `packageManager` or input |
| `node-version-file` | `.nvmrc` (falls back to `<wd>/.nvmrc`, then `package.json` engines) | |
| `install-command` / `build-command` | `<pm> install --frozen-lockfile` / `<pm> run build` | overridable |
| `output-dir` | `dist` | |
| `env-prefix` | `VITE_` | **every repo/environment variable (`vars`) starting with this prefix is exported to the build automatically**, so no per-variable boilerplate, and dev/prod differ only by GitHub Environment |
| `build-env` | — | extra multiline `KEY=VALUE` |
| `project-name` (**required**) | — | Cloudflare Pages project |
| `branch` | `github.ref_name` | Pages branch (production vs preview) |
| `environment` / `environment-url` | — | GitHub Environment |
| `pr-preview-comment` | `false` | comment the preview URL on the PR |
| `wrangler-version` | `4` | run via `npx wrangler@<v>`, **not installed into the project** (removes the workspace-root hack) |
| `notify-on` | `''` | |

Secrets: `CLOUDFLARE_API_TOKEN`; `CLOUDFLARE_ACCOUNT_ID` (secret or var).
Outputs: `deployment-url`, `alias-url`.

### Summary
Project, branch, deployment URL plus alias URL, a bundle-size table (top files in `dist` + total),
and which `VITE_*` vars were injected (names only).

---

## Notifications (shared design)

**Opt-in:** every workflow has `notify-on: ''`, so they are off unless the caller lists events.

**Pluggable via a single secret, `NOTIFY_URL`, where the URL scheme selects the provider:**
```
discord://<webhook_id>/<webhook_token>        (or a plain https://discord.com/api/webhooks/... URL)
telegram://<bot_token>@<chat_id>[?thread=<topic_id>]
ntfy://ntfy.sh/<topic>                        (later)
slack://...                                    (later)
```
Switching Discord → Telegram means changing one secret, not touching any workflow.

**The `actions/notify` composite action:**
1. The workflow builds a **normalized event** as JSON:
   `{status: started|success|failure, title, url, description, fields: [{name, value, inline}], changelog}`
2. The dispatcher parses the scheme and pipes the JSON to `providers/<scheme>.sh`
3. Each provider script renders natively (Discord embeds with colours; Telegram HTML via `sendMessage`)
   and **owns its limits** (Discord: 1024 chars/field, 6000 total; Telegram: 4096).
4. Always `continue-on-error`: a broken webhook never fails a deploy.

Adding a provider = one ~30-line script + one line in the README. The rejected alternative is
Apprise/Shoutrrr (100+ providers for free, but you lose rich Discord embeds and pull a
dependency on every run). Possible fallback: `apprise://` for anything not implemented natively.

---

## Caching (aggressive)

| layer | technique |
|---|---|
| Docker layers | **registry cache** (`type=registry,ref=<image>:buildcache,mode=max,image-manifest=true`). It isn't subject to the 10 GB / 7-day eviction of the GHA cache, it's shared across branches, and it's per image, so monorepos don't clobber. `cache: gha` stays available, **with a per-image `scope`**. |
| PR builds | `cache-from` also reads the `main` cache, so a branch's first build is warm |
| Docker `RUN --mount=type=cache` (uv, pip, apt, pnpm) | opt-in `cache-mounts` input via `buildkit-cache-dance`, which persists mount caches in the GHA cache. Needs `--mount=type=cache` in the Dockerfile (the current Dockerfiles don't use it; I'd document it, not change them) |
| **Skip unchanged images** | hash = git tree of `context` + Dockerfile blob + build args + target + platforms. If `<image>:src-<hash>` exists, **retag** it with `docker buildx imagetools create` (seconds, no build). Big win in monorepos where a frontend-only commit would rebuild the backend. |
| Node deps | cache `node_modules` keyed on lockfile + node version, and skip `install` entirely on an exact hit; the pnpm store cache is the fallback |
| Frontend build | cache `node_modules/.vite`, `*.tsbuildinfo` (`tsc -b` incremental) |
| **Skip unchanged frontend** | cache `dist` keyed on the tree hash of `working-directory` + hash of injected env vars. On a hit there's no install or build, just the deploy (Cloudflare only uploads changed files anyway) |
| Tooling | no `docker pull` of kustomize; `yq`/`jq` are preinstalled; wrangler goes through the npm cache |

---

## Monorepos

Two supported patterns, both shown in `examples/`:

**A. One caller workflow per component** (simplest, what you have now): `on.push.paths: [backend/**]`.

**B. One workflow with a matrix**, using `dorny/paths-filter` to pick changed components:
```yaml
jobs:
  changes: { ... outputs: components: '["backend","worker"]' }
  build:
    needs: changes
    strategy: { matrix: { component: ${{ fromJSON(needs.changes.outputs.components) }} } }
    uses: maciej23/cicd/.github/workflows/docker-build.yml@v1
    with: { context: ${{ matrix.component }} }
  deploy:
    needs: build
    uses: maciej23/cicd/.github/workflows/flux-deploy.yml@v1
    with:
      images: |   # deterministic tags, so no need to collect matrix outputs
        ghcr.io/maciej23/app-backend=sha-${{ github.sha }}
        ghcr.io/maciej23/app-worker=sha-${{ github.sha }}
```
Matrix outputs from reusable workflows are "last one wins", so **deploy tags must be
deterministic** (computable from the commit sha). `skip-unchanged` keeps that true: it
retags old images with the new sha tag.

---

## Example caller (sportino after migration)

```yaml
name: backend
on:
  push: { branches: [main], paths: [backend/**] }
  workflow_dispatch:

jobs:
  build:
    uses: maciej23/cicd/.github/workflows/docker-build.yml@v1
    permissions: { contents: read, packages: write }
    with:
      context: backend
      tags: |
        type=sha,prefix=sha-
        type=raw,value=latest
      build-args: APP_VERSION=${{ github.ref_name }}-${{ github.sha }}
      notify-on: failure
    secrets:
      NOTIFY_URL: ${{ secrets.NOTIFY_URL }}

  deploy:
    needs: build
    uses: maciej23/cicd/.github/workflows/flux-deploy.yml@v1
    with:
      environment: plume
      path: apps/plume/sportino
      images: ${{ needs.build.outputs.image }}=${{ needs.build.outputs.tag }}
      changelog-paths: backend
      notify-on: success,failure
    secrets:
      FLUX_TOKEN: ${{ secrets.FLUX_CONFIG_PUSH_TOKEN }}
      NOTIFY_URL: ${{ secrets.NOTIFY_URL }}
```
About 30 lines instead of about 280.

---

## Quality of this repo
- `ci.yml`: `actionlint` + `zizmor` (workflow security lint) + shellcheck on provider scripts
- Self-tests: build `tests/fixtures/docker` with `push: false`, build the fixture frontend with no deploy,
  and run provider scripts in dry-run mode (print the payload instead of POSTing)
- Third-party actions pinned by SHA; Dependabot (`github-actions` ecosystem) bumps them
- Minimal `permissions:` per job

## Implementation order (tracer bullet first)
1. `docker-build` (minimal) + `flux-deploy` (minimal) + example caller: end-to-end on one project via a branch
2. `notify` action + Discord provider + Telegram provider
3. Summaries
4. Caching: registry cache → skip-unchanged → cache mounts
5. `frontend-build` action + `frontend-cloudflare` workflow
6. `ci.yml`, examples, README, tag `v1.0.0` + `v1`

## Open decisions
See the bottom of the chat / to be filled in.
