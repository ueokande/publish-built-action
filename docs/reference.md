# Publishing details and recovery

## Distribution contents and history

The action adds only `paths` from the working tree to an empty tree, preserving
relative layout and selected edits. Each release gets a parentless commit with
no source or previous release history. The source SHA is recorded in its commit
message, tag annotation and `source` output.

Only the fixed tag and explicitly selected floating tags are pushed. The caller's
branch, HEAD, index, local tags and Git configuration are preserved. Existing
local or remote fixed tags are rejected even if they target the expected commit;
a failed remote lookup is an error. Use repository tag rulesets for protection
against changes by other actors. See [floating tag update rules](floating-tags.md).

## Path rules

Paths are newline-separated, literal file or directory names. Each must exist;
empty lines are ignored and at least one path is required.

- Directories are recursive, including ignored files. `dist/*` is not a glob:
  use `dist` to select the directory.
- Absolute paths, `.` or `..` components, carriage returns and `.git` components
  are rejected. List distribution paths explicitly instead of the whole checkout.
- Symlinks are stored as links, not dereferenced. Flatten build output from
  submodules or nested repositories before selecting it.
- Git attributes and clean filters apply, as with `git add`.

Finish the build and avoid concurrent checkout changes while publishing.

## Permissions and authentication

The publishing job needs `contents: write`. `origin` must point to the target
repository with Git push authentication already configured. Checkout's
`persist-credentials: true` provides this; shallow and detached checkouts work.

If credentials are not persisted, configure Git authentication yourself.
`GH_TOKEN` and this action's `token` input do not authenticate `git push`.
For another repository, supply a scoped GitHub App token or PAT to checkout,
and set `release-repository` and `token` for its Release API calls. Repository
rulesets can still reject the push. Do not publish untrusted code with write
credentials.

Release operations require `gh` (preinstalled on GitHub-hosted Ubuntu) and an API
token with `contents: write`. Source and distribution Releases must be in the
same `release-repository`, matching `origin`. Tag-only mode does not call `gh`.

Pushes using `GITHUB_TOKEN` generally do not trigger other GitHub Actions
workflows. Create the Release in this workflow, or use an appropriately scoped
GitHub App token if downstream workflow triggers are needed.

## Release behavior

`create-release: 'true'` creates a published Release titled with the fixed
tag. Choose either `copy-release-notes-from` or `generate-release-notes: 'true'`;
both require Release creation, and invalid combinations fail before publication.
With neither selected, notes are empty. Copying preserves only the source body,
not assets, title, draft status or prerelease status. Existing Releases are not
edited.

Source notes are fetched before the push; a failed read prevents publication.
Release creation happens afterward, so its failure leaves all tags published.
Success outputs are written only after all requested operations complete.
Locally created objects can remain unreachable after failure, but no release
ref is left in the caller's repository.

## Release labels and Marketplace settings

Use `release-label` with `create-release: 'true'`:

| Value | Release state | GitHub CLI flags |
| --- | --- | --- |
| `none` | Normal release, not marked Latest. | `--latest=false` |
| `prerelease` | Pre-release, not Latest. | `--prerelease --latest=false` |
| `latest` | Normal release marked Latest. | `--latest` |
| Empty (default) | Preserve GitHub's automatic latest selection. | No label flags. |

Labels control Release metadata only; tag and floating-tag rules remain
unchanged. The label is not inferred from the tag or copied from source notes.

The **Publish this Action to the GitHub Marketplace**, **Primary Category** and
**Another Category** fields are web-interface settings. The public
[Create Release API](https://docs.github.com/en/rest/releases/releases#create-a-release)
and `gh release create` do not expose them. This action therefore has no inputs
that claim to set those fields.

To configure them after this action creates a Release:

1. Open the Release using its `release-url` output, then choose **Edit**.
2. Select **Publish this Action to the GitHub Marketplace**.
3. Select **Primary Category** and, optionally, **Another Category**, then save.

The repository and account must meet GitHub's
[Marketplace publication requirements](https://docs.github.com/en/actions/how-tos/create-and-publish-actions/publish-in-github-marketplace),
including acceptance of the Marketplace Developer Agreement. Do not rerun this
action just to change Marketplace settings.

## Recover a failed GitHub Release step

**Do not rerun this action or the publishing job after a successful tag push.**
The fixed tag already exists and will be rejected. Retry only Release creation
from an authenticated checkout or a separate recovery job, using an API token
with `contents: write`.

If the API outcome was uncertain, first run
`gh release view v1.2.3 --repo OWNER/REPO`. If the Release exists, inspect it
rather than recreating it. After an uncertain push, also inspect the remote tags.
Never move published tags back automatically.

Preserve the original label too: add `--latest=false` for `none`,
`--prerelease --latest=false` for `prerelease`, or `--latest` for `latest` to the
commands below. Omit those flags if `release-label` was empty.

Use the same notes mode as the original attempt:

Copy the source body:

```bash
gh release view source-v1.2.3 --repo OWNER/REPO --json body --jq '.body' > release-notes.md
gh release create v1.2.3 --repo OWNER/REPO --verify-tag --title v1.2.3 --notes-file release-notes.md
```

Generate notes:

```bash
gh release create v1.2.3 --repo OWNER/REPO --verify-tag --title v1.2.3 --generate-notes
```

Leave notes empty:

```bash
gh release create v1.2.3 --repo OWNER/REPO --verify-tag --title v1.2.3 --notes ''
```
