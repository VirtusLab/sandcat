# Pin image versions (issue #20, Phase 1) — Design

## Goal

Remove `latest`-tag supply-chain exposure from sandcat's security-critical image chain: the mitmproxy image (TLS interception + secret substitution) and the two derived secret-provider images (`sandcat-mitmproxy-op`, `sandcat-mitmproxy-pass`). Also freeze the rtk install script, currently fetched from a third-party repo's moving `master`.

## Motivation

`mitmproxy/mitmproxy:latest` sees all agent plaintext and holds real secret values. Today:

- the generated `compose-proxy.yml` references `mitmproxy/mitmproxy:latest` — every `docker compose pull` silently swaps the security boundary for whatever upstream published;
- both `images/*/Dockerfile` build `FROM mitmproxy/mitmproxy:latest` and a weekly cron republishes `ghcr.io/virtuslab/sandcat-mitmproxy-{op,pass}:latest` — the tag users' projects reference is overwritten in place every Monday;
- rtk installs via `raw.githubusercontent.com/rtk-ai/rtk/master/install.sh` — any push to that repo's master executes as root in every sandcat image build.

## Decisions (made with the maintainer)

1. **Pin exact version** (`12.2.3` at time of writing), bumped manually; automation (Renovate) is Phase 2.
2. **Versioned tags are immutable; `latest` remains a tracking channel.** The weekly cron rebuilds and pushes **only `latest`** (built `FROM mitmproxy/mitmproxy:latest`). Versioned tags (`sandcat-mitmproxy-op:12.2.3`) are published only by a master push (a bump commit) and never overwritten by cron.
3. **Generated projects reference versioned tags** — both the public mitmproxy image (provider `none`) and the ghcr images (providers `1password`/`protonpass`).

## Version source of truth — two files, one contract test

The version is needed on two sides that don't share a runtime:

- **CLI side** (ships in the installed sandcat tarball): `SCT_MITMPROXY_VERSION="12.2.3"` in `cli/lib/constants.bash`. Consumed by the template placeholder replacement and `apply_secret_provider`.
- **Build side** (CI workflows + Dockerfiles): `images/mitmproxy.env` with `MITMPROXY_VERSION=12.2.3`. Consumed by both image workflows as a `--build-arg`; both Dockerfiles take `ARG MITMPROXY_VERSION` (no default — same "no defaults on purpose" convention as the existing `pass-cli.env`).

A **contract bats test** asserts the two values are equal, so a bump that touches only one side fails CI. Bump = edit 2 lines in 2 files.

## Mechanics

### CLI side

- Template `cli/templates/devcontainer/sandcat/compose-proxy.yml`: `image: mitmproxy/mitmproxy:latest` → `image: mitmproxy/mitmproxy:__MITMPROXY_VERSION__`.
- `customize_agent_templates` (cli/lib/devcontainer.bash) already runs `apply_inline_placeholders` on compose-proxy.yml with `__MITM_HTTP2__` etc. — add `"__MITMPROXY_VERSION__" "$SCT_MITMPROXY_VERSION"` to that call.
- `apply_secret_provider` (cli/lib/composefile.bash): `ghcr.io/virtuslab/sandcat-mitmproxy-op:latest` → `...:$SCT_MITMPROXY_VERSION` (yq `env()` injection, matching the file's existing style); same for `-pass`.

### Build side

- `images/mitmproxy/Dockerfile` and `images/mitmproxy-pass/Dockerfile`: `ARG MITMPROXY_VERSION` + `FROM mitmproxy/mitmproxy:${MITMPROXY_VERSION}`.
- Both workflows (`build-mitmproxy-image.yml`, `build-mitmproxy-pass-image.yml`):
  - **push to master** (bump commit; `paths` trigger already covers `images/**`): read `images/mitmproxy.env`, pass as build-arg, tag with the version + sha. Do NOT move `latest`.
  - **schedule (weekly cron)**: pass `MITMPROXY_VERSION=latest` as build-arg, tag ONLY `latest`.
  - **pull_request**: build with the pinned version, no push (keep current PR behavior).
- Workflows also gain `paths: images/mitmproxy.env` in triggers so the bump commit rebuilds both images even when only the env file changes.

### rtk

`cli/lib/rtk.bash` install block: pin the install script to a specific commit SHA (`raw.githubusercontent.com/rtk-ai/rtk/<sha>/install.sh`). Honest limitation, documented in the comment: rtk publishes only `dev-*` pre-releases today, and its install.sh fetches a binary release internally — the SHA pin freezes the *script* (closing the arbitrary-shell-injection-via-master vector) but not necessarily the *binary*. Full binary pinning is deferred until rtk ships stable releases.

## Effective flow after the change

```
Bump commit (2 lines: constants.bash + images/mitmproxy.env)
   │  push to master, paths trigger
   ▼
CI builds FROM mitmproxy:12.3.0 → publishes sandcat-mitmproxy-op:12.3.0 (+sha)
   │
   ▼
Same commit's CLI generates projects referencing:
   - mitmproxy/mitmproxy:12.3.0            (provider none)
   - ghcr.io/.../sandcat-mitmproxy-op:12.3.0  (provider 1password)

Weekly cron: builds FROM mitmproxy:latest → pushes ONLY ghcr :latest (tracking channel, untouched by projects)
```

## Out of scope (deferred, with rationale)

- **Base images** (`mcr.microsoft.com/devcontainers/base:debian`, `debian:trixie-slim`) — agent-side, inside the sandbox boundary; lower criticality. Follow-up.
- **Agent CLI installers** (claude.ai, chatgpt.com, cursor.com) — vendor-official scripts for tools that self-update at runtime; a pin buys little.
- **devbox installer** — same category.
- **Phase 2**: Renovate automation (regex managers for the bash-heredoc Dockerfile fragments). **Phase 3**: digest pinning.

## Testing

- Contract bats test: `SCT_MITMPROXY_VERSION` == `images/mitmproxy.env` value; template placeholder resolves (no `__MITMPROXY_VERSION__` left in generated compose-proxy.yml).
- Existing `regression.bats` `assert_proxy_service` asserts `image == "mitmproxy/mitmproxy:latest"` — update to the pinned reference (this is a deliberate assertion change mandated by the feature, not a weakening).
- Integration: generated project (provider none) pulls and runs the pinned public image end-to-end; provider 1password renders the versioned ghcr tag (pull not asserted — the tag publishes only after this lands on master; noted in report).

## Global Constraints

- Pinned version at introduction: **12.2.3** (verified current `mitmproxy --version` of upstream latest).
- CLI constant: `SCT_MITMPROXY_VERSION` in `cli/lib/constants.bash`.
- Build env file: `images/mitmproxy.env`, key `MITMPROXY_VERSION`.
- Template placeholder literal: `__MITMPROXY_VERSION__`.
- Dockerfiles: `ARG MITMPROXY_VERSION` with **no default**.
- Cron semantics: schedule builds use `MITMPROXY_VERSION=latest` and push only the `latest` tag; version tags come only from master pushes.
- rtk: script pinned by commit SHA; comment documents the binary-pin limitation.
- No behavior change for generated projects beyond the image references.
