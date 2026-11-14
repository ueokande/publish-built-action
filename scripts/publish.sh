#!/usr/bin/env bash
set -euo pipefail

# The EXIT trap needs this directory after main's local variables go out of scope.
temp_dir=''

fail() {
  printf 'publish-built-action: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n $temp_dir ]]; then
    if [[ -d $temp_dir/gnupg ]]; then
      gpgconf --homedir "$temp_dir/gnupg" --kill all > /dev/null 2>&1 || true
    fi
    rm -rf -- "$temp_dir"
  fi
}

validate_boolean() {
  local name=$1 value=$2
  [[ $value == true || $value == false ]] || fail "$name must be true or false."
}

validate_paths() {
  local path
  while IFS= read -r path || [[ -n $path ]]; do
    [[ -n $path ]] || continue
    path=${path%/}
    [[ -n $path && $path != /* && $path != *$'\r'* ]] || fail 'Paths must be relative and contain no carriage returns.'
    [[ ! $path =~ (^|/)\.\.?(/|$) ]] || fail 'Paths cannot contain dot or parent components.'
    [[ ! ${path,,} =~ (^|/)\.git(/|$) ]] || fail 'Paths cannot contain .git components.'
    [[ -e $path || -L $path ]] || fail "Build path does not exist: $path"
    paths+=(":(literal)$path")
  done <<< "$paths_input"
  (( ${#paths[@]} > 0 )) || fail 'At least one build path is required.'
}

validate_floating_tags() {
  local floating_tag previous
  while IFS= read -r floating_tag || [[ -n $floating_tag ]]; do
    [[ -n $floating_tag ]] || continue
    git check-ref-format "refs/tags/$floating_tag" || fail "Invalid floating tag: $floating_tag"
    [[ -z $source_release || $floating_tag != "$source_release" ]] || fail 'The source Release tag cannot be a floating tag.'
    [[ ! $floating_tag =~ ^v?[0-9]+\.[0-9]+\.[0-9]+([+-].*)?$ ]] || fail 'Full version tags cannot be floating tags.'
    for previous in "$tag" "${floating_tags[@]}"; do
      [[ $floating_tag != "$previous" ]] || fail "Duplicate or fixed floating tag: $floating_tag"
      [[ $floating_tag != "$previous/"* && $previous != "$floating_tag/"* ]] || fail 'Tag names cannot have conflicting path prefixes.'
    done
    floating_tags+=("$floating_tag")
  done <<< "$floating_tags_input"
  if (( ${#floating_tags[@]} > 0 )); then
    [[ $tag =~ $stable_version_pattern ]] || fail 'floating-tags requires a stable vMAJOR.MINOR.PATCH tag.'
  fi
}

# Compare decimal components without integer overflow, even for large versions.
version_is_older() {
  local left=$1 right=$2 index LC_ALL=C
  local left_parts=() right_parts=()
  IFS=. read -r -a left_parts <<< "${left#v}"
  IFS=. read -r -a right_parts <<< "${right#v}"
  for index in 0 1 2; do
    if (( ${#left_parts[index]} < ${#right_parts[index]} )); then return 0; fi
    if (( ${#left_parts[index]} > ${#right_parts[index]} )); then return 1; fi
    if [[ ${left_parts[index]} != "${right_parts[index]}" ]]; then
      [[ ${left_parts[index]} < ${right_parts[index]} ]]
      return
    fi
  done
  return 1
}

read_remote_tags() {
  local snapshot object remote_ref
  if ! snapshot=$(git ls-remote --tags origin); then
    fail 'Cannot read origin tags.'
  fi
  while IFS=$'\t' read -r object remote_ref; do
    [[ -n $remote_ref ]] || continue
    if [[ $remote_ref == *'^{}' ]]; then
      remote_targets["${remote_ref%'^{}'}"]=$object
    else
      remote_objects["$remote_ref"]=$object
    fi
  done <<< "$snapshot"
}

check_floating_versions() {
  local floating_tag floating_ref target candidate_ref candidate_target version known
  for floating_tag in "${floating_tags[@]}"; do
    floating_ref="refs/tags/$floating_tag"
    [[ -n ${remote_objects["$floating_ref"]:-} ]] || continue
    target=${remote_targets["$floating_ref"]:-${remote_objects["$floating_ref"]}}
    known=false
    for candidate_ref in "${!remote_objects[@]}"; do
      version=${candidate_ref#refs/tags/}
      [[ $version =~ $stable_version_pattern ]] || continue
      candidate_target=${remote_targets["$candidate_ref"]:-${remote_objects["$candidate_ref"]}}
      [[ $candidate_target == "$target" ]] || continue
      known=true
      if version_is_older "$tag" "$version"; then
        fail "Refusing to move $floating_tag backward from $version to $tag."
      fi
    done
    [[ $known == true ]] || fail "Cannot identify a fixed version for floating tag: $floating_tag"
  done
}

validate_signing() {
  validate_boolean sign-commit "$sign_commit"
  validate_boolean sign-tag "$sign_tag"
  if [[ $sign_commit == true || $sign_tag == true ]]; then
    [[ -n $signing_key || -n $gpg_private_key ]] || fail 'signing-key or gpg-private-key is required when signing is enabled.'
  elif [[ -n $gpg_private_key || -n $gpg_passphrase ]]; then
    fail 'GPG key import requires sign-commit or sign-tag.'
  fi
  [[ -z $gpg_passphrase || -n $gpg_private_key ]] || fail 'gpg-passphrase requires gpg-private-key.'
  [[ $gpg_passphrase != *$'\n'* && $gpg_passphrase != *$'\r'* ]] || fail 'gpg-passphrase must be a single line.'
  if [[ -n $gpg_private_key ]]; then
    command -v gpg > /dev/null || fail 'GnuPG is required for key import.'
    command -v gpgconf > /dev/null || fail 'gpgconf is required for key cleanup.'
  fi
}

validate_release() {
  validate_boolean create-release "$create_release"
  validate_boolean generate-release-notes "$generate_notes"
  [[ -z $source_release || $generate_notes == false ]] || fail 'Choose only one of copy-release-notes-from and generate-release-notes.'
  if [[ -n $source_release || $generate_notes == true ]]; then
    [[ $create_release == true ]] || fail 'Release notes options require create-release.'
  fi
  if [[ $create_release == true ]]; then
    [[ -n ${GH_TOKEN:-} ]] || fail 'A token is required for Release creation.'
    [[ -n $release_repository ]] || fail 'release-repository is required for Release creation.'
    command -v gh > /dev/null || fail 'GitHub CLI is required for Release creation.'
  fi
  if [[ -n $source_release ]]; then
    git check-ref-format "refs/tags/$source_release" || fail 'Invalid copy-release-notes-from.'
    [[ $source_release != "$tag" ]] || fail 'Source and distribution tags must differ.'
  fi
}

validate_inputs() {
  cd -- "$working_directory"
  [[ $(git rev-parse --is-inside-work-tree) == true ]] || fail 'A source checkout is required.'
  [[ -z $(git rev-parse --show-prefix) ]] || fail 'working-directory must be the repository root.'
  source_sha=$(git rev-parse --verify 'HEAD^{commit}')
  [[ -n $tag ]] || fail 'tag is required.'
  git check-ref-format "refs/tags/$tag" || fail 'Invalid tag name.'
  ref="refs/tags/$tag"
  validate_paths
  validate_floating_tags
  validate_signing
  validate_release
}

ensure_tag_available() {
  local status
  if git show-ref --verify --quiet "$ref"; then
    fail "Tag already exists locally: $tag"
  fi

  if (( ${#floating_tags[@]} > 0 )); then
    read_remote_tags
    [[ -z ${remote_objects["$ref"]:-} ]] || fail "Tag already exists on origin: $tag"
    check_floating_versions
    return 0
  fi

  # An absent ref returns 2; transport and authentication errors remain errors.
  if git ls-remote --exit-code --refs origin "$ref" > /dev/null; then
    fail "Tag already exists on origin: $tag"
  else
    status=$?
    [[ $status == 2 ]] || fail "Cannot check origin for the release tag (exit $status)."
  fi
}

import_signing_key() {
  local key_listing fingerprints=()
  mkdir -m 700 "$temp_dir/gnupg"
  export GNUPGHOME="$temp_dir/gnupg"
  if ! printf '%s' "$gpg_private_key" | gpg --batch --import > "$temp_dir/import.log" 2>&1; then
    fail 'Could not import gpg-private-key.'
  fi

  local selector=()
  if [[ -n $signing_key ]]; then selector=(-- "$signing_key"); fi
  if ! key_listing=$(gpg --batch --with-colons --list-secret-keys "${selector[@]}" 2> "$temp_dir/key-list.log"); then
    fail 'Could not find signing-key among the imported secret keys.'
  fi
  mapfile -t fingerprints < <(awk -F: '
    $1 == "sec" { primary = 1; next }
    primary && $1 == "fpr" { print $10; primary = 0 }
  ' <<< "$key_listing")
  (( ${#fingerprints[@]} == 1 )) || fail 'Select exactly one imported secret key with signing-key.'
  if [[ -z $signing_key ]]; then signing_key=${fingerprints[0]}; fi

  printf '%s' "$gpg_passphrase" > "$temp_dir/passphrase"
  chmod 600 "$temp_dir/passphrase"
  export PUBLISH_GPG_PASSPHRASE_FILE="$temp_dir/passphrase"
  cat > "$temp_dir/gpg-sign" <<'GPG'
#!/usr/bin/env bash
exec gpg --batch --pinentry-mode loopback --passphrase-file "$PUBLISH_GPG_PASSPHRASE_FILE" "$@"
GPG
  chmod 700 "$temp_dir/gpg-sign"
  signing_config=(-c gpg.format=openpgp -c "gpg.openpgp.program=$temp_dir/gpg-sign")
}

prepare_signing() {
  local gpg_program
  if [[ $sign_commit == true || $sign_tag == true ]]; then
    if [[ -n $gpg_private_key ]]; then
      import_signing_key
    else
      # Preserve the caller's OpenPGP program when using its existing keyring.
      gpg_program=$(git config --get gpg.openpgp.program || git config --get gpg.program || printf gpg)
      signing_config=(-c gpg.format=openpgp -c "gpg.openpgp.program=$gpg_program")
    fi
  fi
  if [[ $sign_commit == true ]]; then commit_signing=("-S$signing_key"); fi
  if [[ $sign_tag == true ]]; then tag_signing=(--sign --local-user "$signing_key"); fi
}

prepare_workspace() {
  temp_dir=$(mktemp -d "$temp_base/publish-built-action.XXXXXX")
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  export GIT_INDEX_FILE="$temp_dir/index"
  export GIT_AUTHOR_NAME="$author_name" GIT_AUTHOR_EMAIL="$author_email"
  export GIT_COMMITTER_NAME="$author_name" GIT_COMMITTER_EMAIL="$author_email"
}

fetch_source_notes() {
  if [[ -n $source_release ]]; then
    # A failed read must stop publication before any tag is pushed.
    gh release view --repo "$release_repository" \
      --json body --jq '.body' -- "$source_release" > "$temp_dir/release-notes.md"
  fi
}

create_distribution_commit() {
  local tree
  git read-tree --empty
  git add --force -- "${paths[@]}"
  tree=$(git write-tree)
  commit=$(printf 'release: prepare %s from %s\n' "$tag" "$source_sha" |
    git "${signing_config[@]}" -c commit.gpgSign=false commit-tree "$tree" "${commit_signing[@]}")
}

create_distribution_tags() {
  local object_directory object_format release_tag tag_ref tag_object
  object_directory=$(git rev-parse --path-format=absolute --git-path objects)
  object_format=$(git rev-parse --show-object-format)
  git init --quiet --bare --initial-branch=distribution --object-format="$object_format" "$temp_dir/tag.git"
  # Keep the orphan branch and tag ref disposable; share only the objects.
  GIT_OBJECT_DIRECTORY="$object_directory" \
    git --git-dir="$temp_dir/tag.git" update-ref refs/heads/distribution "$commit"
  push_leases=("--force-with-lease=$ref:")
  for release_tag in "$tag" "${floating_tags[@]}"; do
    tag_ref="refs/tags/$release_tag"
    GIT_OBJECT_DIRECTORY="$object_directory" \
      git "${signing_config[@]}" --git-dir="$temp_dir/tag.git" tag --annotate "${tag_signing[@]}" \
        --message="Release $tag (source $source_sha)" -- "$release_tag" "$commit"
    tag_object=$(GIT_OBJECT_DIRECTORY="$object_directory" git --git-dir="$temp_dir/tag.git" rev-parse --verify "$tag_ref")
    push_refspecs+=("$tag_object:$tag_ref")
    if [[ $release_tag != "$tag" ]]; then
      push_leases+=("--force-with-lease=$tag_ref:${remote_objects["$tag_ref"]:-}")
    fi
  done
}

push_distribution_tags() {
  local atomic_args=()
  if (( ${#floating_tags[@]} > 0 )); then atomic_args=(--atomic); fi
  # Require the observed refs, and never fall back to a partial update.
  git -c push.followTags=false push --no-follow-tags "${atomic_args[@]}" \
    "${push_leases[@]}" origin "${push_refspecs[@]}"
}

create_github_release() {
  if [[ $create_release == false ]]; then return 0; fi
  local notes_args=(--notes '')
  if [[ -n $source_release ]]; then
    notes_args=(--notes-file "$temp_dir/release-notes.md")
  elif [[ $generate_notes == true ]]; then
    notes_args=(--generate-notes)
  fi
  if ! release_url=$(gh release create --repo "$release_repository" \
    --verify-tag --title "$tag" "${notes_args[@]}" -- "$tag"); then
    fail "Tag $tag was pushed, but Release creation failed. Retry only Release creation; do not rerun this action."
  fi
}

write_outputs() {
  # Outputs describe success only after all requested operations complete.
  {
    printf 'tag=%s\n' "$tag"
    printf 'commit=%s\n' "$commit"
    printf 'source=%s\n' "$source_sha"
    printf 'release-url=%s\n' "$release_url"
  } >> "$output_file"
  printf 'Published %s at %s (source %s).\n' "$tag" "$commit" "$source_sha"
}

main() {
  local output_file=${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}
  local working_directory=${PUBLISH_WORKING_DIRECTORY:-.}
  local tag=${PUBLISH_TAG:-} paths_input=${PUBLISH_PATHS:-}
  local floating_tags_input=${PUBLISH_FLOATING_TAGS:-}
  local stable_version_pattern='^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
  local sign_commit=${PUBLISH_SIGN_COMMIT:-false} sign_tag=${PUBLISH_SIGN_TAG:-false}
  local signing_key=${PUBLISH_SIGNING_KEY:-}
  local gpg_private_key=${PUBLISH_GPG_PRIVATE_KEY:-} gpg_passphrase=${PUBLISH_GPG_PASSPHRASE:-}
  local author_name=${PUBLISH_AUTHOR_NAME:-github-actions[bot]}
  local author_email=${PUBLISH_AUTHOR_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}
  local create_release=${PUBLISH_CREATE_RELEASE:-false}
  local source_release=${PUBLISH_COPY_RELEASE_NOTES_FROM:-}
  local generate_notes=${PUBLISH_GENERATE_RELEASE_NOTES:-false}
  local release_repository=${PUBLISH_RELEASE_REPOSITORY:-}
  local temp_base=${RUNNER_TEMP:-${TMPDIR:-/tmp}}

  # Phase functions share these inputs, prepared options and publication results.
  local paths=() signing_config=() commit_signing=() tag_signing=(--no-sign)
  local source_sha='' ref='' commit='' release_url=''
  local floating_tags=() push_refspecs=() push_leases=()
  local -A remote_objects=() remote_targets=()

  # Call phases directly so failures retain errexit, rather than in conditionals
  # or command substitutions that could mask a failed preparation command.
  validate_inputs
  ensure_tag_available
  prepare_workspace
  prepare_signing
  fetch_source_notes
  create_distribution_commit
  create_distribution_tags
  push_distribution_tags
  create_github_release
  write_outputs
}

main "$@"
