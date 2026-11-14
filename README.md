# Publish built action

Publish prebuilt GitHub Actions as immutable release tags, with optional floating
tags, GitHub Releases and GPG signatures.

```text
Source branch          Package contents          Release tag

  o  source-v1.1.0 ────────────────────────────> o  v1.1.0
  |
  o
  |
  o  source-v1.0.0 ────────────────────────────> o  v1.0.0
  |
  o
```

Arrows represent file transfer, not ancestry: each release has a parentless
commit. Only tags are pushed; the source checkout is preserved.

Supported on GitHub-hosted Ubuntu 22.04 and 24.04, including `ubuntu-latest`.
The caller checks out, builds and tests the source; this Bash/Git action publishes
only the files listed in `paths`.

## Quick start

This example uses `npm test` and `npm run build` producing `dist`. Adjust the
commands and `paths` for your repository. Every selected path must exist;
README, CHANGELOG, LICENSE and action metadata are never included automatically.

```yaml
name: Release
on:
  workflow_dispatch:
    inputs:
      tag:
        description: New immutable distribution tag, such as v1.2.3
        required: true
        type: string
permissions:
  contents: read
concurrency:
  group: release-${{ inputs.tag }}
  cancel-in-progress: false
jobs:
  publish:
    runs-on: ubuntu-24.04
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@v7.0.1
        with:
          persist-credentials: true
      - uses: actions/setup-node@v7.1.0
        with:
          node-version: '22'
          cache: npm
      - run: npm ci
      - run: npm test
      - run: npm run build
      - uses: ueokande/publish-built-action@v0.0.1
        id: publish
        with:
          tag: ${{ inputs.tag }}
          paths: |
            action.yml
            dist
            README.md
            CHANGELOG.md
            LICENSE
```

The publishing job needs `contents: write` and authenticated Git access to
`origin`. Checkout's `persist-credentials: true` supplies Git authentication;
the `token` input is for Release API calls only. Full Git history is not required.
See [authentication details](docs/reference.md#permissions-and-authentication).

## Inputs

### Distribution

| Input | Default | Description |
| --- | --- | --- |
| `tag` | Required | New fixed tag, such as `v1.2.3`. Existing local or remote tags are rejected. |
| `paths` | Required | Newline-separated literal paths relative to the checkout root. Ignored files are included; globs are not expanded. |
| `working-directory` | `.` | Source checkout root. |
| `floating-tags` | Empty | Newline-separated aliases to create or update, such as `v1` or `stable`. |

With floating tags, `tag` must be a stable `vMAJOR.MINOR.PATCH` version. The fixed
tag and aliases are pushed atomically, with conflict and downgrade checks.
See [floating tag examples and rules](docs/floating-tags.md) and [path rules](docs/reference.md#path-rules).

### GitHub Releases

| Input | Default | Description |
| --- | --- | --- |
| `create-release` | `false` | Create a GitHub Release after pushing the tags. |
| `copy-release-notes-from` | Empty | Copy the body from this source Release tag; must differ from `tag`. |
| `generate-release-notes` | `false` | Generate notes using GitHub. |
| `release-repository` | `${{ github.repository }}` | Repository for Releases; must match `origin`. |
| `token` | `${{ github.token }}` | API token for Release operations; does not authenticate Git. |

Note options require `create-release: 'true'` and are mutually exclusive. With
neither selected, notes are empty. Boolean inputs accept only `true` or `false`.

**If Release creation fails after the push, retry only Release creation.** Do
not rerun this action or the publishing job: the fixed tag already exists.
See [recovery commands](docs/reference.md#recover-a-failed-github-release-step).

### Commit and tag signing

| Input | Default | Description |
| --- | --- | --- |
| `sign-commit` | `false` | GPG-sign the distribution commit. |
| `sign-tag` | `false` | GPG-sign the fixed tag and all floating tags. |
| `gpg-private-key` | Empty | ASCII-armored OpenPGP private key, supplied through a secret. |
| `gpg-passphrase` | Empty | Optional single-line passphrase for `gpg-private-key`. |
| `signing-key` | Empty | Key fingerprint. Required for existing keyrings or multiple-key imports; detected automatically for a single-key import. |
| `author-name` | `github-actions[bot]` | Commit author, committer and tagger name. |
| `author-email` | [Bot email](docs/signing.md#identity-and-verification) | Commit author, committer and tagger email. |

Enable signing explicitly; providing a key alone does not enable it. The action
imports and cleans up private keys itself. See [key setup, examples and verification](docs/signing.md).

## Outputs

| Output | Description |
| --- | --- |
| `tag` | Published fixed tag name. |
| `commit` | Distribution commit SHA. |
| `source` | Source HEAD SHA, recorded as provenance. |
| `release-url` | Created Release URL; empty when Release creation is disabled. |

Outputs are written after all requested operations succeed.

## Guides

- [Separate build and publish jobs using artifacts](docs/examples.md#separate-build-and-publication-jobs)
- [Use release-please and copy source Release notes](docs/examples.md#use-release-please-outputs)
- [Publication details, authentication and recovery](docs/reference.md)
- [Tests and workflow lockfile maintenance](docs/development.md)

Generate a workflow lockfile in your own repository with `gh actions-lock` to
pin the examples' action versions. See [LICENSE](LICENSE).
