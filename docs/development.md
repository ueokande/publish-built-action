# Development

[Back to README](../README.md)

Run tests with Bash, Git and GnuPG (`gpg` and `gpgconf`), available on the
supported GitHub-hosted Ubuntu runners:

```bash
bash -n scripts/publish.sh tests/integration.sh
bash tests/integration.sh
```

Tests use temporary local bare remotes and a stub GitHub CLI for Release calls;
they never publish tags or Releases to GitHub. Signing tests generate an isolated
ephemeral key, verify commit and tag signatures, and remove the test keyring and
its GPG agent afterward. The stub checks body transfer,
operation order and failure recovery without requiring credentials. Floating-tag
tests cover atomic rejection, concurrent ref updates, downgrade checks and
independent tag signatures. CI runs
Bash syntax checks, ShellCheck, integration tests, and an actual composite-action
smoke test on Ubuntu 22.04 and 24.04, plus actionlint for workflow validation.
The smoke test also pushes exclusively to a temporary local bare remote.

## Workflow dependencies

CI references exact action versions and locks their commit SHAs and repository
identities in `.github/workflows/actions.lock`. Regenerate the lockfile with the
official extension after changing action references, then review and commit both
the workflow and lockfile changes:

```bash
gh extension install github/gh-actions-lock --pin v0.4.1
gh actions-lock --ignore-local-actions
gh actions-lock --verify --ignore-local-actions
```

The `--ignore-local-actions` option keeps the composite smoke test's `uses: ./`
reference: it intentionally tests the checked-out working tree and the action
contains only Bash steps, with no external action dependencies. Revisit this
choice if external action dependencies are added to `action.yml`.

Generation and full verification require GitHub API access and an authenticated
GitHub CLI. `gh actions-lock --verify-local --ignore-local-actions` checks
coverage offline but does not verify upstream provenance. CI performs the full
verification using its read-only `GITHUB_TOKEN`. Never edit the lockfile by hand.

See the repository [LICENSE](../LICENSE).
