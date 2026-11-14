# Workflow examples

[Back to README](../README.md)

These examples build and test a Node.js action before publishing. Adjust the
scripts and explicit distribution paths for your repository; every selected path
must exist. Generate your own workflow lockfile with `gh actions-lock`; this
repository's lockfile does not cover callers.

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
      - uses: actions/checkout@v7.0.1
        with:
          persist-credentials: false
      - id: source
        run: echo "sha=$(git rev-parse HEAD)" >> "$GITHUB_OUTPUT"
      - uses: actions/setup-node@v7.1.0
        with:
          node-version: '22'
          cache: npm
      - run: npm ci
      - run: npm test
      - run: npm run build
      - uses: actions/upload-artifact@v7.0.2
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
      - uses: actions/checkout@v7.0.1
        with:
          ref: ${{ needs.build.outputs.source }}
          persist-credentials: true
      - uses: actions/download-artifact@v8.0.2
        with:
          name: distribution-build
          path: dist
      - uses: ueokande/publish-built-action@v0.0.1
        with:
          tag: ${{ inputs.tag }}
          paths: |
            action.yml
            dist
            README.md
            CHANGELOG.md
            LICENSE
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
using its `version` output. Copying source notes preserves release-please's release
description. Do not let release-please create the distribution tag first. This example uses root-package outputs; monorepos need path-prefixed outputs.
The action copies the source Release body rather than generating new notes. It
fetches the body before publishing the tag so a failed read does not leave a
distribution tag without its notes. Replace `master` with your development
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
      - uses: googleapis/release-please-action@v5.0.0
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
      - uses: actions/checkout@v7.0.1
        with:
          ref: ${{ needs.release.outputs.source }}
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
          tag: v${{ needs.release.outputs.version }}
          paths: |
            action.yml
            dist
            README.md
            CHANGELOG.md
            LICENSE
          create-release: 'true'
          copy-release-notes-from: ${{ needs.release.outputs.source_tag }}
```

