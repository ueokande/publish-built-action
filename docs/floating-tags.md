# Floating tags

[Back to README](../README.md)

`tag` is an immutable release identifier. `floating-tags` is an optional,
newline-separated list of aliases that should follow the newly published
release. Its default is empty, preserving fixed-tag-only publication.

```yaml
with:
  tag: v1.2.3
  floating-tags: |
    v1
    v1.2
    stable
  paths: |
    action.yml
    dist
    README.md
    LICENSE
```

Each name is literal: the action does not derive aliases or interpret `v1` as
a version range. Select the aliases appropriate to the release yourself. Blank
lines are ignored. Names must be valid Git tag refs and cannot be duplicates,
conflict by path prefix (for example `v1` and `v1/stable`), equal the fixed tag,
look like full version tags, or equal `copy-release-notes-from`.

## Update rules

When floating tags are requested, `tag` must have the stable form
`vMAJOR.MINOR.PATCH`, without leading zeroes, prerelease suffixes or build
metadata. Without floating tags, other valid fixed tag names remain supported.
Aliases may use names such as `v1`, `v1.2`, `stable` or `channels/stable`.

All tags are annotated tags targeting the same parentless distribution commit.
Each annotation records the fixed version and source SHA. `sign-tag: 'true'`
signs each tag independently with the configured key. The source checkout,
local tags and branches remain unchanged, even when a local floating tag
already exists. No distribution branch is pushed.

For each existing remote alias, the action finds stable fixed version tags that
point to the same commit. Both lightweight and annotated aliases are supported.
The incoming version must not be older than any matching fixed version. If no
matching fixed version can be found, publication fails rather than guessing.
This prevents an older release job from moving a newer alias backward, even if
it starts after the newer job has completed. Version components are compared as
decimal numbers, without machine integer limits.

The fixed tag and all aliases are pushed in one atomic Git operation:

- The fixed tag must still be absent. Existing fixed tags are never reused.
- Each alias must still have the exact object observed before publication, or
  remain absent if it is new. A concurrent change causes the whole push to fail.
- A server-side rejection of any tag rejects the entire publication.
- A server without atomic push support causes an error; there is no partial-push
  fallback. GitHub supports atomic pushes.

Repository rulesets must permit updates to the selected aliases while protecting
fixed versions as appropriate. No tags are deleted, and unrelated aliases are
never updated.

## Releases and retries

`create-release: 'true'` creates a GitHub Release for the fixed tag only, after the
complete tag push succeeds. Floating tags do not get separate Releases.
If Release creation fails, the fixed tag and aliases stay published. Follow the
[Release-only recovery procedure](reference.md#recover-a-failed-github-release-step);
do not rerun this action or move tags back automatically.

If the Git push fails, inspect the remote refs before retrying, especially after
a lost connection. A successful retry requires the fixed tag to be absent.

## Migration

To replace an existing `v1` alias, its current commit must also have a stable
fixed version tag such as `v1.2.2`. Then publishing `v1.2.3` with `floating-tags: v1`
can safely replace the alias. The old fixed version remains unchanged.

If the alias has no identifiable fixed version, inspect its contents and history
before migrating. Restore a legitimate version mapping or repair the alias in a
separate, reviewed operation; this action provides no bypass for unknown targets
or downgrades. An existing `latest` branch is neither required nor updated.
