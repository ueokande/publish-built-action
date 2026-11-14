# Development

## Tests and CI

Tests require Bash, Git and GnuPG (`gpg` and `gpgconf`), available on the supported
GitHub-hosted Ubuntu runners:

```bash
bash -n scripts/publish.sh tests/integration.sh
bash tests/integration.sh
```

Tests use temporary bare remotes, ephemeral signing keys and a stub GitHub CLI;
they never publish to GitHub. They cover signatures, protected-key import and
cleanup, note modes, atomic rejection, concurrent updates and downgrade checks.

CI runs the suite and composite-action smoke test on Ubuntu 22.04 and 24.04,
plus ShellCheck and actionlint. The smoke test also uses a temporary bare remote.

## Workflow dependencies

Action versions are pinned by `.github/workflows/actions.lock`. After changing
workflow dependencies, regenerate it with the official extension, review the
workflow and lockfile diff, and commit both. Never edit the lockfile by hand.

```bash
gh extension install github/gh-actions-lock --pin v0.4.1
gh actions-lock --ignore-local-actions
gh actions-lock --verify --ignore-local-actions
```

`--ignore-local-actions` preserves the smoke test's `uses: ./`, which tests the
working tree. It is safe here because the composite contains only Bash steps;
revisit this choice if external action dependencies are added.

Generation and full verification require API access and an authenticated GitHub
CLI; CI uses its read-only `GITHUB_TOKEN`. For offline coverage checks, use
`gh actions-lock --verify-local --ignore-local-actions`, which does not verify
upstream provenance.
