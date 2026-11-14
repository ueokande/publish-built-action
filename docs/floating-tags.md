# Floating tags

Use `floating-tags` for aliases such as `v1`, `v1.2` or `stable` that should follow
the new release. The default is empty: only the immutable `tag` is published.
Names are literal; aliases are never derived or interpreted as version ranges.

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

## Requirements

- With floating tags, `tag` must be `vMAJOR.MINOR.PATCH`, without leading zeroes,
  prerelease suffixes or build metadata. Other fixed tag formats remain supported
  when no floating tags are requested.
- Alias names must be valid Git tag refs. Blank lines are ignored. Duplicates,
  full-version-like names, the fixed tag, and `copy-release-notes-from` are rejected.
- Names cannot conflict by path prefix, such as `v1` and `v1/stable`.

## Publication

Each alias is an annotated tag pointing to the same parentless commit as the
fixed tag. `sign-tag: 'true'` signs every tag independently. The caller's local
tags, branches and checkout are preserved; no distribution branch is pushed.

All refs are pushed atomically:

- The fixed tag must still be absent; it is never reused or overwritten.
- Each alias must still match the object observed before publication, or remain
  absent if new. Concurrent changes reject the whole push.
- Rejection of any ref, or lack of server atomic-push support, fails the entire
  publication. There is no partial-push fallback. GitHub supports atomic pushes.

Repository rulesets must allow the selected alias updates. No tags are deleted,
and unlisted aliases are unchanged. GitHub Releases are created for the fixed
tag only, after the complete push succeeds.

## Existing aliases and migration

Before updating an alias, the action finds stable fixed version tags pointing to
its current commit. The new version must not be older than any matching version.
If none can be identified, publication fails. Both lightweight and annotated
existing aliases are supported; new aliases are always annotated.

For example, an existing `v1` pointing to the same commit as `v1.2.2` can advance
to `v1.2.3`, leaving the old fixed tag intact. An older release job cannot move
it back. If the version mapping is missing, inspect and repair it in a separate,
reviewed operation. There is no bypass for unknown versions or downgrades.
An existing `latest` branch is neither required nor updated.

## Retries

After a failed or interrupted push, inspect the remote refs before retrying; the
fixed tag must be absent for another run to succeed.

If GitHub Release creation fails after the push, all tags stay published. Follow
[Release-only recovery](reference.md#recover-a-failed-github-release-step)
instead of rerunning this action or moving tags back.
