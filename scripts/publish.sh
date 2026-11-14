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

# Build an isolated distribution tree without inheriting source files or history.
temp_dir=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/publish-built-action.XXXXXX")
trap 'rm -rf -- "$temp_dir"' EXIT
sign_commit=${PUBLISH_SIGN_COMMIT:-false}
sign_tag=${PUBLISH_SIGN_TAG:-false}
signing_key=${PUBLISH_SIGNING_KEY:-}
[[ $sign_commit == true || $sign_commit == false ]] || fail 'sign-commit must be true or false.'
[[ $sign_tag == true || $sign_tag == false ]] || fail 'sign-tag must be true or false.'
signing_config=()
commit_signing=()
tag_signing=(--no-sign)
if [[ $sign_commit == true || $sign_tag == true ]]; then
  [[ -n $signing_key ]] || fail 'signing-key is required when signing is enabled.'
  # Capture the caller's OpenPGP program for use in the disposable tag repository.
  gpg_program=$(git config --get gpg.openpgp.program || git config --get gpg.program || printf gpg)
  signing_config=(-c gpg.format=openpgp -c "gpg.openpgp.program=$gpg_program")
fi
if [[ $sign_commit == true ]]; then commit_signing=("-S$signing_key"); fi
if [[ $sign_tag == true ]]; then tag_signing=(--sign --local-user "$signing_key"); fi
create_release=${PUBLISH_CREATE_RELEASE:-false}
source_release=${PUBLISH_COPY_RELEASE_NOTES_FROM:-}
generate_notes=${PUBLISH_GENERATE_RELEASE_NOTES:-false}
release_notes=${PUBLISH_RELEASE_NOTES:-}
release_url=''
[[ $create_release == true || $create_release == false ]] || fail 'create-release must be true or false.'
[[ $generate_notes == true || $generate_notes == false ]] || fail 'generate-release-notes must be true or false.'
notes_modes=0
[[ -z $source_release ]] || notes_modes=$((notes_modes + 1))
[[ $generate_notes == false ]] || notes_modes=$((notes_modes + 1))
[[ -z $release_notes ]] || notes_modes=$((notes_modes + 1))
(( notes_modes <= 1 )) || fail 'Choose only one of copy-release-notes-from, generate-release-notes and release-notes.'
[[ $notes_modes == 0 || $create_release == true ]] || fail 'Release notes options require create-release.'
if [[ $create_release == true ]]; then
  [[ -n ${GH_TOKEN:-} ]] || fail 'A token is required for Release creation.'
  [[ -n ${PUBLISH_RELEASE_REPOSITORY:-} ]] || fail 'release-repository is required for Release creation.'
  command -v gh > /dev/null || fail 'GitHub CLI is required for Release creation.'
fi
if [[ -n $source_release ]]; then
  git check-ref-format "refs/tags/$source_release" || fail 'Invalid copy-release-notes-from.'
  [[ $source_release != "$tag" ]] || fail 'Source and distribution tags must differ.'
  # Fetch before publishing so a missing source Release cannot leave a new tag.
  gh release view --repo "$PUBLISH_RELEASE_REPOSITORY" \
    --json body --jq '.body' -- "$source_release" > "$temp_dir/release-notes.md"
fi
export GIT_INDEX_FILE="$temp_dir/index"
git read-tree --empty
git add --force -- "${paths[@]}"
tree=$(git write-tree)

# Use command-scoped identity and plumbing; do not change HEAD, config or local refs.
export GIT_AUTHOR_NAME="${PUBLISH_AUTHOR_NAME:-github-actions[bot]}"
export GIT_AUTHOR_EMAIL="${PUBLISH_AUTHOR_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}"
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
commit=$(printf 'release: prepare %s from %s\n' "$tag" "$source_sha" | git "${signing_config[@]}" -c commit.gpgSign=false commit-tree "$tree" "${commit_signing[@]}")
# Keep the tag ref in a disposable repository while sharing the object database.
object_directory=$(git rev-parse --path-format=absolute --git-path objects)
object_format=$(git rev-parse --show-object-format)
git init --quiet --bare --initial-branch=distribution --object-format="$object_format" "$temp_dir/tag.git"
# The disposable branch starts with an orphan root commit.
GIT_OBJECT_DIRECTORY="$object_directory" \
  git --git-dir="$temp_dir/tag.git" update-ref refs/heads/distribution "$commit"
GIT_OBJECT_DIRECTORY="$object_directory" \
  git "${signing_config[@]}" --git-dir="$temp_dir/tag.git" tag --annotate "${tag_signing[@]}" \
    --message="Release $tag (source $source_sha)" -- "$tag" "$commit"
tag_object=$(GIT_OBJECT_DIRECTORY="$object_directory" git --git-dir="$temp_dir/tag.git" rev-parse --verify "$ref")

# The empty expected value requires the remote ref to be absent, including races.
# Explicit refspec and disabled followTags prevent publishing other refs.
git -c push.followTags=false push --no-follow-tags \
  --force-with-lease="$ref:" origin "$tag_object:$ref"

if [[ $create_release == true ]]; then
  notes_args=(--notes "$release_notes")
  if [[ -n $source_release ]]; then
    notes_args=(--notes-file "$temp_dir/release-notes.md")
  elif [[ $generate_notes == true ]]; then
    notes_args=(--generate-notes)
  fi
  if ! release_url=$(gh release create --repo "$PUBLISH_RELEASE_REPOSITORY" \
    --verify-tag --title "$tag" "${notes_args[@]}" -- "$tag"); then
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
