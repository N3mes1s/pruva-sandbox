# Pruva Sandbox Production Contract

This repository is the public execution surface for Pruva Codespaces
verification. The private `pruva` application owns ingestion, reproduction
generation, publishing, and API state. `pruva-sandbox` owns the reproducible
runtime that a public user opens from a `repro/<REPRO_ID>` branch.

## Runtime Boundary

The production handoff is intentionally narrow:

1. `pruva` publishes reproduction metadata and artifacts through the Pruva API.
2. `pruva` creates or updates `repro/<REPRO_ID>` in this repository.
3. The branch changes only the public Codespaces runtime configuration needed to
   set `containerEnv.REPRO_ID`.
4. Codespaces starts from `.devcontainer/devcontainer.json`.
5. `postCreateCommand` runs `pruva-verify "$REPRO_ID"`.
6. `pruva-verify` fetches metadata and artifacts from the API, applies any
   public patch from `repro-patches/<REPRO_ID>.patch`, runs the reproduction,
   and writes logs plus verdict artifacts under `pruva-results/`.

No private `pruva` source, private binaries, API tokens, Modal credentials, or
operator secrets belong in this repository, in reproduction branches, or in
patch files.

## Image Invariant

The same immutable `ghcr.io/n3mes1s/pruva-sandbox@sha256:<digest>` must be used
by:

- `.devcontainer/devcontainer.json` as the Codespaces image.
- `.devcontainer/devcontainer.json` `containerEnv.PRUVA_SANDBOX_IMAGE`.
- the private Pruva worker image build argument.
- reproduction metadata `environment.sandbox_image` when present.

Do not use `:latest` for production Codespaces or worker execution. `latest` is
only a development convenience and is not a production contract.

## Patch Policy

`repro-patches/` is the only supported place for public repro-specific fixes
that are not yet reflected in the upstream API artifact.

Patch files must:

- apply to `repro/reproduction_steps.sh` without editing the API artifact in
  place;
- keep dependencies and one-off tooling scoped to the repro that needs them;
- avoid broad devcontainer changes for single-repro issues;
- avoid embedding secrets, private repository references, or private binaries;
- prefer reusable setup caches only for expensive setup artifacts, not for final
  vulnerability state;
- preserve fresh final verification on every run.

## Production Gates

Run the cheap structural gate first:

```bash
./scripts/test-production-parity.sh --skip-modal
```

Run the public boundary check directly when reviewing patch-only changes:

```bash
./scripts/check-public-boundary.sh
```

Audit whether a local private `pruva` checkout is safe to use as an operator
execution path:

```bash
./scripts/audit-pruva-handoff.sh --pruva-repo ~/code/pruva --ref origin/main
```

Run the full public Codespaces startup gate before promoting a new sandbox
digest or declaring latest reproductions healthy:

```bash
./scripts/test-production-parity.sh \
  --real-codespaces \
  --codespaces-mode verify \
  --codespaces-max-parallel 3 \
  --skip-modal
```

Run Modal only when the required credentials are exported:

```bash
./scripts/test-production-parity.sh \
  --real-codespaces \
  --codespaces-mode verify \
  --codespaces-max-parallel 3 \
  --require-modal \
  --modal-repro-ids REPRO-2026-00185
```

For direct real Codespaces testing without the private `pruva` repo check:

```bash
./scripts/test-codespaces-gh.sh \
  --latest 20 \
  --mode verify \
  --max-parallel 3 \
  --api-url https://api.pruva.dev/v1
```

Use a small parallelism cap. Each lane creates a real Codespace and may pull
large Docker images; `3` is the default production recommendation.

## Promotion Checklist

Before a sandbox image or patch set is production-ready:

1. `git status --short --branch` is clean on `main`.
2. `./scripts/check-public-boundary.sh` passes.
3. `./scripts/audit-pruva-handoff.sh --pruva-repo ~/code/pruva --ref origin/main`
   passes for any checkout used to publish or operate production runs.
4. `bash -n scripts/test-codespaces-gh.sh scripts/test-production-parity.sh`
   passes.
5. `cargo test` passes under `pruva-verify-rs/`.
6. `./scripts/test-codespaces.sh --latest 20` passes.
7. `./scripts/test-codespaces-gh.sh --latest 20 --mode verify --max-parallel 3`
   passes or every failure has a linked issue with evidence.
8. Any Modal smoke required for the release passes with credentials supplied
   from the environment, never from command-line literals.
9. No `repro-patches/` file contains tokens, private repo URLs, private binary
   references, or generated payload bytes.
10. No stale `pruva-smoke-*` or PR validation Codespaces remain after testing.

## Operational Notes

Codespaces is the user-facing verification path. Modal is useful for additional
parity and fast sandbox smoke tests, but it does not replace a real Codespaces
startup check because Codespaces applies devcontainer features, branch-specific
`REPRO_ID`, and the exact web UI creation path.

The Codespaces devcontainer must keep the Docker CLI available through
Docker-outside-of-Docker while disabling the legacy `docker-compose` shim. Repro
scripts should use `docker compose`, which is provided by the Docker CLI plugin
without a separate mutable GitHub-release download during startup.

After changing the devcontainer contract, run `[Internal] Scan for New
Reproductions` so existing `repro/*` branches receive the same configuration.

When a repro is expensive, cache setup artifacts with `PRUVA_REPRO_CACHE_DIR` or
the Modal cache-volume option, but keep the final vulnerability trigger and
verdict generation uncached.
