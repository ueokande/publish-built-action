#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'publish-built-action: %s\n' "$*" >&2
  exit 1
}

: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
cd -- "${PUBLISH_WORKING_DIRECTORY:-.}"
[[ $(git rev-parse --is-inside-work-tree) == true ]] || fail 'A source checkout is required.'
[[ -z $(git rev-parse --show-prefix) ]] || fail 'working-directory must be the repository root.'
source_sha=$(git rev-parse --verify 'HEAD^{commit}')
tag=${PUBLISH_TAG:-}
[[ -n $tag ]] || fail 'tag is required.'
git check-ref-format "refs/tags/$tag" || fail 'Invalid tag name.'
ref="refs/tags/$tag"
if git show-ref --verify --quiet "$ref"; then
  fail "Tag already exists locally: $tag"
fi

# An absent ref returns 2; transport and authentication errors must remain errors.
if git ls-remote --exit-code --refs origin "$ref" > /dev/null; then
  fail "Tag already exists on origin: $tag"
else
  status=$?
  [[ $status == 2 ]] || fail "Cannot check origin for the release tag (exit $status)."
fi

paths=()
while IFS= read -r path || [[ -n $path ]]; do
  [[ -n $path ]] || continue
  path=${path%/}
  [[ -n $path && $path != /* && $path != *$'\r'* ]] || fail 'Paths must be relative and contain no carriage returns.'
  [[ ! $path =~ (^|/)\.\.?(/|$) ]] || fail 'Paths cannot contain dot or parent components.'
  [[ ! ${path,,} =~ (^|/)\.git(/|$) ]] || fail 'Paths cannot contain .git components.'
  [[ -e $path || -L $path ]] || fail "Build path does not exist: $path"
  paths+=(":(literal)$path")
done <<< "${PUBLISH_PATHS:-}"
(( ${#paths[@]} > 0 )) || fail 'At least one build path is required.'

# Seed a separate index from HEAD, excluding unrelated staged and unstaged edits.
temp_dir=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/publish-built-action.XXXXXX")
trap 'rm -rf -- "$temp_dir"' EXIT
source_release=${PUBLISH_SOURCE_RELEASE_TAG:-}
release_url=''
if [[ -n $source_release ]]; then
  git check-ref-format "refs/tags/$source_release" || fail 'Invalid source-release-tag.'
  [[ $source_release != "$tag" ]] || fail 'Source and distribution tags must differ.'
  [[ -n ${GH_TOKEN:-} ]] || fail 'A token is required for Release creation.'
  [[ -n ${PUBLISH_RELEASE_REPOSITORY:-} ]] || fail 'release-repository is required for Release creation.'
  command -v gh > /dev/null || fail 'GitHub CLI is required for Release creation.'
  # Fetch before publishing so a missing source Release cannot leave a new tag.
  gh release view --repo "$PUBLISH_RELEASE_REPOSITORY" \
    --json body --jq '.body' -- "$source_release" > "$temp_dir/release-notes.md"
fi
export GIT_INDEX_FILE="$temp_dir/index"
git read-tree "$source_sha"
git add --force -- "${paths[@]}"
tree=$(git write-tree)

# Use command-scoped identity and plumbing; do not change HEAD, config or local refs.
export GIT_AUTHOR_NAME='github-actions[bot]'
export GIT_AUTHOR_EMAIL='41898282+github-actions[bot]@users.noreply.github.com'
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
commit=$(printf 'release: prepare %s from %s\n' "$tag" "$source_sha" | git commit-tree "$tree" -p "$source_sha")
tag_object=$(
  {
    printf 'object %s\ntype commit\ntag %s\ntagger %s\n\n' "$commit" "$tag" "$(git var GIT_COMMITTER_IDENT)"
    printf 'Release %s (source %s)\n' "$tag" "$source_sha"
  } | git mktag
)

# The empty expected value requires the remote ref to be absent, including races.
# Explicit refspec and disabled followTags prevent publishing other refs.
git -c push.followTags=false push --no-follow-tags \
  --force-with-lease="$ref:" origin "$tag_object:$ref"

if [[ -n $source_release ]]; then
  if ! release_url=$(gh release create --repo "$PUBLISH_RELEASE_REPOSITORY" \
    --verify-tag --title "$tag" --notes-file "$temp_dir/release-notes.md" -- "$tag"); then
    fail "Tag $tag was pushed, but Release creation failed. Retry only Release creation; do not rerun this action."
  fi
fi

# Publish outputs only after successful publication. A failed Release step must retry
# Release creation alone, because this action intentionally rejects existing tags.
{
  printf 'tag=%s\n' "$tag"
  printf 'commit=%s\n' "$commit"
  printf 'source=%s\n' "$source_sha"
  printf 'release-url=%s\n' "$release_url"
} >> "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
printf 'Published %s at %s (source %s).\n' "$tag" "$commit" "$source_sha"
