# Publishing details and recovery

[Back to README](../README.md)

## Distribution contents and history

Only `paths` are added to an empty tree, from the working tree at publication
time. Relative layout is preserved, including edits to selected documentation.
No filenames are included automatically. A selected directory includes all its
contents, so select distribution directories rather than source directories.

Each tag targets a new parentless root commit on a disposable orphan branch.
`git log` at that tag contains one release commit, with no source or previous
release history. The source SHA is recorded in the commit message, tag annotation
and `source` output. The default identity is `github-actions[bot]`, with email
`41898282+github-actions[bot]@users.noreply.github.com`.

Only the fixed tag and explicitly selected floating tags are pushed. The
caller's branch, HEAD, index, local tags and Git configuration are preserved.
Existing local or remote fixed tags are rejected, even
when they target the expected commit. An absent-ref lease prevents overwriting
a concurrently created fixed tag. [Floating tag updates](floating-tags.md) use
leases against their observed objects and share the fixed tag's atomic push.
Use GitHub tag rulesets if other actors must also be prevented from moving or
deleting tags.

## Path rules

Paths may name files or directories, including ignored paths and names containing
spaces. Globs are not expanded: `dist/*` means a file literally named `*` within
`dist`. Specify `dist` to include a directory recursively. Empty lines are ignored;
at least one path must remain. Each path must exist. Absolute paths, `.` or `..`
components, carriage returns, and `.git` components are rejected. Avoid selecting
the entire repository; list the generated directories explicitly. Build symlinks
are stored as Git symlinks, not dereferenced. Submodules and nested repositories
are not artifact bundles; flatten their generated files before calling the action.
Git attributes and clean filters apply when adding files, as with `git add`.


## Permissions and authentication

The publishing job needs `permissions: contents: write`. `origin` must point to
the intended repository and Git must already have push authentication. With
`actions/checkout`, use `persist-credentials: true` (the default). A shallow or
detached checkout works; `fetch-depth: 0` is unnecessary.

If checkout uses `persist-credentials: false`, the caller must configure a supported
Git credential mechanism before publication. Setting `GH_TOKEN` alone does not
configure `git push`. The `token` input authenticates only the optional GitHub API calls and does not
change Git credentials.
For another repository, supply an appropriately scoped GitHub App token or PAT to
checkout. Repository rulesets can still reject the push; configure the publishing
identity's permissions accordingly. Never run a publishing job on untrusted code
with write credentials.

Release creation requires GitHub CLI (`gh`, preinstalled on GitHub-hosted Ubuntu)
and a token with `contents: write` on `release-repository`. For a checkout of
another repository, set both `release-repository` and `token` appropriately, in
addition to checkout's Git credentials. Both source and distribution Releases are
in that same repository. Tag-only mode does not call `gh` or require API access.

Tag pushes authenticated by `GITHUB_TOKEN` generally do not trigger additional
GitHub Actions workflows. Use the optional Release feature in this action, or use
an appropriately scoped GitHub App token if downstream workflow triggers are needed.

## Release behavior

Release creation produces a normal published Release titled with the distribution
tag. Copying preserves only the source body, not its title, assets, draft status
or prerelease status. Both Releases must be in `release-repository`, which must
match the checkout's `origin`. Existing Releases are never edited.

`copy-release-notes-from` and `generate-release-notes: 'true'` are mutually
exclusive and require `create-release: 'true'`. Invalid combinations fail before
publication. With neither selected, the body is empty; generation is never
implicit.

The source body is fetched before the tag push; a failed read prevents
publication. Release creation happens after the push, so a failure there leaves
the fixed and floating tags intact. Success outputs are written only after all
requested operations succeed. If a connection is lost, inspect the remote tag and Release before
retrying. Locally created objects can remain unreachable after failure, but no
release ref is left in the caller's repository. Finish builds and avoid concurrent
checkout modifications before calling the action.

## Recover a failed GitHub Release step

If the tag push succeeds but GitHub Release creation fails, **do not rerun this
action or the entire publishing job**. The existing tag will correctly cause an
error. Verify the remote tag and retry only GitHub Release creation from an
authenticated checkout or a separate manually dispatched recovery job.

If copying was enabled, copy the source Release notes again and create only the
distribution Release,
using the actual repository, source tag and distribution tag. Authenticate `gh`
with a token that has `contents: write`:

```bash
gh release view source-v1.2.3 --repo OWNER/REPO --json body --jq '.body' > release-notes.md
gh release create v1.2.3 --repo OWNER/REPO --verify-tag --title v1.2.3 --notes-file release-notes.md
```

For generated notes:

```bash
gh release create v1.2.3 --repo OWNER/REPO --verify-tag --title v1.2.3 --generate-notes
```

If no note source was specified, retry with explicitly empty notes:

```bash
gh release create v1.2.3 --repo OWNER/REPO --verify-tag --title v1.2.3 --notes ''
```

When copying was enabled, use `--notes-file` to preserve the source body.
First check `gh release view v1.2.3` if the API outcome was uncertain. If a Release
already exists, inspect it rather than recreating or moving the tag. A source
release created by release-please is separate from the distribution release.

