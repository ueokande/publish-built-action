# Publish built action

Publish prebuilt GitHub Actions without committing generated files to your source
branch. This composite action creates a parentless distribution commit and pushes
an annotated tag. It can also create a GitHub Release, optionally copying notes
from a source Release.

Supported on GitHub-hosted Ubuntu 22.04 and 24.04, including `ubuntu-latest`.
The caller checks out the source, builds and tests it; this action handles
publication with Bash and Git.

## Quick start

**This action has no published release tags yet.** Replace `REVIEWED_COMMIT_SHA`
with a reviewed full commit SHA. The example assumes `npm test`, `npm run build`
producing `dist`, and the files listed in `paths`. Adjust those paths to match your
repository: **nothing is included automatically**, including documentation.

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
      - uses: ueokande/publish-built-action@REVIEWED_COMMIT_SHA
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

## What gets published

- Only the files and directories listed in `paths`, including ignored build files.
- One orphan commit with no parent or source history; the source SHA is recorded
  as provenance.
- A new annotated tag, pushed to `origin`. No branch is pushed or updated.

Existing tags are errors and are never reused or overwritten. The caller's HEAD,
index and local tags are preserved. Version selection, checkout, builds, tests,
artifact transfer, npm publication and floating tag updates remain with the caller.

## Inputs

| Input | Default | Description |
| --- | --- | --- |
| `tag` | Required | New immutable distribution tag, such as `v1.2.3`. |
| `paths` | Required | Newline-separated literal distribution paths, relative to the checkout root. Include `action.yml`, documentation and other required files explicitly. |
| `working-directory` | `.` | Source checkout root. |
| `create-release` | `false` | Create a GitHub Release after pushing the tag. |
| `copy-release-notes-from` | Empty | Copy this source Release body. Requires `create-release: true`; must differ from `tag`. |
| `generate-release-notes` | `false` | Generate notes using GitHub. Requires `create-release: true`. |
| `release-notes` | Empty | Explicit notes body; supports multiline text. Requires `create-release: true` when nonempty. |
| `release-repository` | `${{ github.repository }}` | Repository for Releases; must match `origin`. |
| `token` | `${{ github.token }}` | API token for optional Release operations. Does not configure Git authentication. |

Paths must exist. Directories are included recursively; globs are not expanded.
See [path rules](docs/reference.md#path-rules) for details.

## GitHub Releases

`create-release` defaults to `false` (tag only). Set it to `true` and choose at
most one note source:

| Note source | GitHub CLI behavior |
| --- | --- |
| `copy-release-notes-from: source-v1.2.3` | Copy the source Release body with `--notes-file`. |
| `generate-release-notes: 'true'` | Generate notes with `--generate-notes`. |
| `release-notes: Your release notes` | Pass the supplied body to `--notes`. |
| None | Leave notes empty with `--notes ''`. |

Note sources are mutually exclusive and require Release creation. Boolean inputs
accept only `true` or `false`. See [note examples](docs/reference.md#release-behavior).

**If Release creation fails after the tag push, retry only Release creation.**
Do not rerun this action or the publishing job; the existing tag will be rejected.
See [recovery commands](docs/reference.md#recover-a-failed-github-release-step).

## Permissions

The publishing job needs `contents: write` and authenticated Git access to
`origin`. With checkout, use `persist-credentials: true`; full history is not
required. The `token` input authenticates API calls only, not `git push`.
Release operations use `gh`, preinstalled on GitHub-hosted Ubuntu.

For cross-repository publishing, alternate credentials and downstream workflow
triggers, see [authentication details](docs/reference.md#permissions-and-authentication).

## Outputs

| Output | Description |
| --- | --- |
| `tag` | Published tag name. |
| `commit` | Distribution commit SHA. |
| `source` | Source HEAD SHA, recorded as provenance rather than a parent. |
| `release-url` | Created Release URL; empty in tag-only mode. |

Outputs are available after all requested operations succeed.

## More examples and details

- [Separate build and publish jobs using artifacts](docs/examples.md#separate-build-and-publication-jobs)
- [Use release-please outputs and copy source release notes](docs/examples.md#use-release-please-outputs)
- [Publication behavior, path rules and recovery](docs/reference.md)
- [Tests and workflow lockfile maintenance](docs/development.md)

The examples use exact action versions. Generate a workflow lockfile in your own
repository with `gh actions-lock` to pin their commits. See [LICENSE](LICENSE).
