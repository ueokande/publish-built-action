# Publish built action

Create a distribution commit containing prebuilt artifacts and push a new,
annotated release tag. Keep generated JavaScript out of your development branch
while making an action consumable directly from a release tag.

This is a composite action implemented with Bash and Git. Supported environments
are GitHub-hosted Ubuntu runners (`ubuntu-22.04` and `ubuntu-24.04`, including
`ubuntu-latest`). No Node.js runtime, package installation, or full Git history
is required by this action.

## Contract

The caller checks out the source, builds and tests it, then places the generated
files in that checkout. This action:

1. Uses the current `HEAD` as the source commit.
2. Creates a tree from that commit plus only the specified artifact paths,
   force-adding ignored files.
3. Creates a child distribution commit and an annotated tag with source provenance.
4. Pushes only that tag to `origin` and returns outputs after success.

The source branch, `HEAD`, caller's index, local tags, and Git configuration stay
unchanged. Unrelated staged, unstaged, and untracked files are excluded. Changes
inside selected paths are included; tracked deletions within a selected existing
directory are included too. A distribution commit is created even when the
selected files match `HEAD`. The bot identity is `github-actions[bot]` with email
`41898282+github-actions[bot]@users.noreply.github.com`.

Existing local or remote tags are errors, even if they already point to the
expected commit. A remote lookup failure is an error. An explicit absent-ref
lease also rejects a competing publisher that creates the tag before the push.
The action never updates a branch or reuses, moves, or deletes a tag. It does not
provide server-side tag protection: configure GitHub tag rulesets to prevent
other actors from updating or deleting release tags.

This action does not decide versions, check out source, build, test, transfer
artifacts, create GitHub Releases or release notes, publish npm packages, maintain
a distribution branch, or update floating tags such as `v1`.

## Inputs and outputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `tag` | Yes | — | New tag name, for example `v1.2.3`. Must be a valid Git tag ref. |
| `paths` | Yes | — | Newline-separated literal artifact paths relative to the source repository root. |
| `working-directory` | No | `.` | Source repository root; useful for checkouts in a subdirectory. |

Paths may name files or directories, including ignored paths and names containing
spaces. Globs are not expanded: `dist/*` means a file literally named `*` within
`dist`. Specify `dist` to include a directory recursively. Empty lines are ignored;
at least one path must remain. Each path must exist. Absolute paths, `.` or `..`
components, carriage returns, and `.git` components are rejected. Avoid selecting
the entire repository; list the generated directories explicitly. Build symlinks
are stored as Git symlinks, not dereferenced. Submodules and nested repositories
are not artifact bundles; flatten their generated files before calling the action.
Git attributes and clean filters apply when adding files, as with `git add`.

| Output | Description |
| --- | --- |
| `tag` | Successfully published tag name. |
| `commit` | Distribution commit SHA (the annotated tag's target). |
| `source` | Source `HEAD` SHA (the distribution commit's parent). |

Failed runs do not return success outputs. A lost connection can make a push's
outcome uncertain; inspect the remote tag before attempting recovery. Objects
created locally may remain unreachable after a failure; no local release ref is
created. Builds should be complete and no other process should modify the checkout
while publishing.

## Permissions and authentication

The publishing job needs `permissions: contents: write`. `origin` must point to
the intended repository and Git must already have push authentication. With
`actions/checkout`, use `persist-credentials: true` (the default). A shallow or
detached checkout works; `fetch-depth: 0` is unnecessary.

If checkout uses `persist-credentials: false`, the caller must configure a supported
Git credential mechanism before publication. Setting `GH_TOKEN` alone does not
configure `git push`. This action accepts no token and does not change credentials.
For another repository, supply an appropriately scoped GitHub App token or PAT to
checkout. Repository rulesets can still reject the push; configure the publishing
identity's permissions accordingly. Never run a publishing job on untrusted code
with write credentials.

Tag pushes authenticated by `GITHUB_TOKEN` generally do not trigger additional
GitHub Actions workflows. Create the GitHub Release in the same workflow, or use
an appropriately scoped GitHub App token if downstream workflow triggers are needed.

## Build and publish in one job

**No release tag of this action has been published yet.** In every example below,
`REVIEWED_COMMIT_SHA` is a placeholder: replace it with a reviewed full commit SHA
of this repository. These examples do not assume an available `v1` or `v1.2.3`
release of this action. Other actions use version references for readability;
pin their full commit SHAs according to your dependency policy.

This example assumes the caller has `package-lock.json`, `npm test`, and
`npm run build` producing `dist`.

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
      - uses: actions/checkout@v4
        with:
          persist-credentials: true
      - uses: actions/setup-node@v4
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
          paths: dist
      - name: Create GitHub Release
        env:
          GH_TOKEN: ${{ github.token }}
          RELEASE_TAG: ${{ steps.publish.outputs.tag }}
        run: gh release create "$RELEASE_TAG" --verify-tag --generate-notes
```

## Separate build and publication jobs

Pass the exact source SHA between jobs so that downloaded artifacts are attached
to the source that produced them. Upload `dist/` as the artifact root and download
it into `dist`; this avoids accidentally nesting `dist/dist`. For multiple build
roots, preserve their relative layout in the uploaded artifact. Artifact transfers
do not preserve executable permissions; restore any required modes in the caller.
Hidden files require the upload action's `include-hidden-files: true` option after
checking that those files contain no secrets.

```yaml
name: Release with artifact
on:
  workflow_dispatch:
    inputs:
      tag:
        description: New immutable distribution tag
        required: true
        type: string
permissions:
  contents: read
concurrency:
  group: release-${{ inputs.tag }}
  cancel-in-progress: false
jobs:
  build:
    runs-on: ubuntu-24.04
    outputs:
      source: ${{ steps.source.outputs.sha }}
    steps:
      - uses: actions/checkout@v4
        with:
          persist-credentials: false
      - id: source
        run: echo "sha=$(git rev-parse HEAD)" >> "$GITHUB_OUTPUT"
      - uses: actions/setup-node@v4
        with:
          node-version: '22'
          cache: npm
      - run: npm ci
      - run: npm test
      - run: npm run build
      - uses: actions/upload-artifact@v4
        with:
          name: distribution-build
          path: dist/
          if-no-files-found: error
          retention-days: 1
  publish:
    needs: build
    runs-on: ubuntu-24.04
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@v4
        with:
          ref: ${{ needs.build.outputs.source }}
          persist-credentials: true
      - uses: actions/download-artifact@v4
        with:
          name: distribution-build
          path: dist
      - uses: ueokande/publish-built-action@REVIEWED_COMMIT_SHA
        with:
          tag: ${{ inputs.tag }}
          paths: dist
```

## Use release-please outputs

Keep release-please's source tags distinct from distribution tags. For a root Node
package, a release-please manifest configuration can use the `source` component:

```json
{
  "packages": {
    ".": {
      "release-type": "node",
      "component": "source",
      "include-component-in-tag": true,
      "tag-separator": "-"
    }
  }
}
```

Use that as `release-please-config.json` with an initialized
`.release-please-manifest.json` (for example `{".": "0.0.0"}` for a new package).
Release-please creates `source-v1.2.3`; the distribution action creates `v1.2.3`
using its `version` output. Do not let release-please create the distribution tag
first. This example uses root-package outputs; monorepos need path-prefixed outputs.
The distribution Release copies the source Release body rather than generating
new notes. Fetch the body before publishing the tag so a failed read does not
leave a distribution tag without its notes. Replace `master` with your development
branch if necessary.

```yaml
name: Release with release-please
on:
  push:
    branches: [master]
permissions:
  contents: read
concurrency:
  group: release-please
  cancel-in-progress: false
jobs:
  release:
    runs-on: ubuntu-24.04
    permissions:
      contents: write
      pull-requests: write
      issues: write
    outputs:
      created: ${{ steps.release.outputs.release_created }}
      source: ${{ steps.release.outputs.sha }}
      source_tag: ${{ steps.release.outputs.tag_name }}
      version: ${{ steps.release.outputs.version }}
    steps:
      - uses: googleapis/release-please-action@v4
        id: release
        with:
          target-branch: master
          config-file: release-please-config.json
          manifest-file: .release-please-manifest.json
  publish:
    needs: release
    if: needs.release.outputs.created == 'true'
    runs-on: ubuntu-24.04
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@v4
        with:
          ref: ${{ needs.release.outputs.source }}
          persist-credentials: true
      - uses: actions/setup-node@v4
        with:
          node-version: '22'
          cache: npm
      - run: npm ci
      - run: npm test
      - run: npm run build
      - name: Copy source GitHub Release notes
        env:
          GH_TOKEN: ${{ github.token }}
          SOURCE_TAG: ${{ needs.release.outputs.source_tag }}
        run: gh release view "$SOURCE_TAG" --json body --jq '.body' > "$RUNNER_TEMP/release-notes.md"
      - uses: ueokande/publish-built-action@REVIEWED_COMMIT_SHA
        id: publish
        with:
          tag: v${{ needs.release.outputs.version }}
          paths: dist
      - name: Create distribution GitHub Release
        env:
          GH_TOKEN: ${{ github.token }}
          RELEASE_TAG: ${{ steps.publish.outputs.tag }}
        run: gh release create "$RELEASE_TAG" --verify-tag --title "$RELEASE_TAG" --notes-file "$RUNNER_TEMP/release-notes.md"
```

## Recover a failed GitHub Release step

If the tag push succeeds but GitHub Release creation fails, **do not rerun this
action or the entire publishing job**. The existing tag will correctly cause an
error. Verify the remote tag and retry only GitHub Release creation, for example
from an authenticated checkout or a separate manually dispatched recovery job:

```bash
gh release create v1.2.3 --verify-tag --generate-notes
```

For the release-please example, copy the source Release notes again and create
only the distribution Release, using the actual source and distribution tags:

```bash
gh release view source-v1.2.3 --json body --jq '.body' > release-notes.md
gh release create v1.2.3 --verify-tag --title v1.2.3 --notes-file release-notes.md
```

Do not use `--generate-notes` for this recovery; preserve the source Release body.
First check `gh release view v1.2.3` if the API outcome was uncertain. If a Release
already exists, inspect it rather than recreating or moving the tag. A source
release created by release-please is separate from the distribution release.

## Development

Run the existing tests without installing dependencies:

```bash
bash -n scripts/publish.sh tests/integration.sh
bash tests/integration.sh
```

Tests use temporary local bare remotes and never publish tags to GitHub. CI runs
Bash syntax checks, ShellCheck, integration tests, and an actual composite-action
smoke test on Ubuntu 22.04 and 24.04, plus actionlint for workflow validation.
The smoke test also pushes exclusively to a temporary local bare remote.

The repository's existing [LICENSE](LICENSE) is unchanged.
