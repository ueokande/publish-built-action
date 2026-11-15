#!/usr/bin/env bash
set -euo pipefail

script=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/scripts/publish.sh
suite=$(mktemp -d)
cleanup() {
  if [[ -d $suite/gnupg ]]; then gpgconf --homedir "$suite/gnupg" --kill gpg-agent; fi
  rm -rf -- "$suite"
}
trap cleanup EXIT
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_NAME=Tester GIT_COMMITTER_NAME=Tester
export GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_EMAIL=test@example.com
count=0
cases=0
original_path=$PATH

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
eq() { [[ $1 == "$2" ]] || fail "Expected [$2], got [$1]"; }
fixture() {
  count=$((count + 1))
  root="$suite/$count"
  mkdir -p "$root"
  git init --bare -q "$root/remote.git"
  git init -q -b main "$root/source"
  cd "$root/source"
  printf 'dist/\n' > .gitignore
  printf 'source\n' > source.txt
  printf 'export const value = 1;\n' > source.ts
  printf 'readme\n' > README.md
  printf 'changelog\n' > CHANGELOG.md
  printf 'license\n' > LICENSE
  mkdir .github
  printf 'development config\n' > .github/development.yml
  git add .
  git commit -qm 'feat: initial source'
  git remote add origin "$root/remote.git"
  git push -q origin HEAD
  source_sha=$(git rev-parse HEAD)
  mkdir -p dist
  printf 'built\n' > dist/index.js
  export PUBLISH_TAG=v1.2.3 PUBLISH_PATHS=dist PUBLISH_WORKING_DIRECTORY="$PWD"
  export GITHUB_OUTPUT="$root/outputs" RUNNER_TEMP="$root"
  : > "$GITHUB_OUTPUT"
  unset PUBLISH_FLOATING_TAGS
  unset PUBLISH_COPY_RELEASE_NOTES_FROM PUBLISH_RELEASE_REPOSITORY
  export PUBLISH_GENERATE_RELEASE_NOTES=false
  unset PUBLISH_SIGNING_KEY PUBLISH_AUTHOR_NAME PUBLISH_AUTHOR_EMAIL PUBLISH_GPG_PRIVATE_KEY PUBLISH_GPG_PASSPHRASE
  export PUBLISH_SIGN_COMMIT=false PUBLISH_SIGN_TAG=false
  unset PUBLISH_RELEASE_LABEL
  export PUBLISH_CREATE_RELEASE=false
  export MOCK_MODE=disabled MOCK_ROOT="$root"
  mkdir "$root/bin"
  cat > "$root/bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$MOCK_ROOT/gh-calls"
[[ $MOCK_MODE != disabled ]] || exit 99
case "$1 $2" in
  'release view')
    [[ $* == 'release view --repo owner/project --json body --jq .body -- source-v1.2.3' ]]
    ! git --git-dir="$MOCK_ROOT/remote.git" show-ref --verify --quiet refs/tags/v1.2.3
    [[ $MOCK_MODE != read-failure ]] || exit 1
    cat "$MOCK_ROOT/notes"
    ;;
  'release create')
    label_count=0
    case "${PUBLISH_RELEASE_LABEL:-}" in
      none)
        [[ ${*: -3:1} == --latest=false ]]
        label_count=1
        ;;
      prerelease)
        [[ ${*: -4:2} == '--prerelease --latest=false' ]]
        label_count=2
        ;;
      latest)
        [[ ${*: -3:1} == --latest ]]
        label_count=1
        ;;
    esac
    if (( label_count > 0 )); then
      set -- "${@:1:$(( $# - label_count - 2 ))}" -- "${@: -1}"
    fi
    if [[ -n ${PUBLISH_COPY_RELEASE_NOTES_FROM:-} ]]; then
      [[ $* == 'release create --repo owner/project --verify-tag --title v1.2.3 --notes-file '*' -- v1.2.3' ]]
      cmp -- "$MOCK_ROOT/notes" "${9}"
    elif [[ $PUBLISH_GENERATE_RELEASE_NOTES == true ]]; then
      [[ $* == 'release create --repo owner/project --verify-tag --title v1.2.3 --generate-notes -- v1.2.3' ]]
    else
      [[ ${*:1:7} == 'release create --repo owner/project --verify-tag --title v1.2.3' ]]
      [[ $# == 11 && ${8} == --notes && -z ${9} && ${10} == -- && ${11} == v1.2.3 ]]
    fi
    git --git-dir="$MOCK_ROOT/remote.git" show-ref --verify --quiet refs/tags/v1.2.3
    [[ $MOCK_MODE != create-failure ]] || exit 1
    printf 'https://github.com/owner/project/releases/tag/v1.2.3\n'
    ;;
  *) exit 99 ;;
esac
MOCK
  chmod +x "$root/bin/gh"
  export PATH="$root/bin:$original_path"
}
publish() { bash "$script" > "$root/log" 2>&1; }
reject() {
  if publish; then fail 'Publication unexpectedly succeeded'; fi
  [[ ! -s $GITHUB_OUTPUT ]] || fail 'Failed publication exposed outputs'
}
remote() { git --git-dir="$root/remote.git" "$@"; }
absent() {
  if remote show-ref --verify --quiet "refs/tags/$PUBLISH_TAG"; then fail 'Unexpected remote tag'; fi
}
pass() { cases=$((cases + 1)); printf 'ok %s - %s\n' "$cases" "$*"; }

fixture
printf 'staged\n' > unrelated.txt
git add unrelated.txt
printf 'unstaged\n' >> source.txt
printf 'uncommitted readme\n' >> README.md
printf 'untracked\n' > untracked.txt
git tag -a other -m 'Unrelated tag'
git config push.followTags true
before_index=$(git hash-object .git/index)
before_status=$(git status --porcelain=v1)
before_config=$(git config --local --list)
publish
commit=$(sed -n 's/^commit=//p' "$GITHUB_OUTPUT")
[[ ! -e $root/gh-calls ]] || fail 'Tag-only mode called GitHub CLI'
eq "$(remote cat-file -t refs/tags/v1.2.3)" tag
eq "$(remote for-each-ref --format='%(taggername)' refs/tags/v1.2.3)" 'github-actions[bot]'
eq "$(remote for-each-ref --format='%(contents:subject)' refs/tags/v1.2.3)" "Release v1.2.3 (source $source_sha)"
eq "$(remote rev-parse 'refs/tags/v1.2.3^{}')" "$commit"
eq "$(remote rev-list --parents -n 1 "$commit")" "$commit"
eq "$(remote rev-list --count "$commit")" 1
eq "$(remote show "$commit:dist/index.js")" built
eq "$(remote ls-tree -r --name-only "$commit")" dist/index.js
if remote cat-file -e "$commit:unrelated.txt" 2>/dev/null; then fail 'Included unrelated staged file'; fi
eq "$(remote for-each-ref --format='%(refname)' refs/tags)" refs/tags/v1.2.3
eq "$(remote rev-parse refs/heads/main)" "$source_sha"
eq "$(git rev-parse HEAD)" "$source_sha"
eq "$(git hash-object .git/index)" "$before_index"
eq "$(git status --porcelain=v1)" "$before_status"
eq "$(git config --local --list)" "$before_config"
eq "$(git for-each-ref --format='%(refname)' refs/tags)" refs/tags/other
eq "$(sed -n 's/^source=//p' "$GITHUB_OUTPUT")" "$source_sha"
eq "$(sed -n 's/^tag=//p' "$GITHUB_OUTPUT")" v1.2.3
eq "$(remote show -s --format=%an "$commit")" 'github-actions[bot]'
[[ -z $(find "$root" -maxdepth 1 -name 'publish-built-action.*' -print) ]] || fail 'Temporary index leaked'
pass 'annotated tag, ignored build, orphan history, explicit contents, outputs, identity and caller state'

: > "$GITHUB_OUTPUT"
old_tag=$(remote rev-parse refs/tags/v1.2.3)
reject
eq "$(remote rev-parse refs/tags/v1.2.3)" "$old_tag"
pass 'remote tag rerun fails without mutation'

fixture
git tag "$PUBLISH_TAG"
reject
absent
pass 'local tag is rejected'

fixture
PUBLISH_TAG='bad tag'
reject
pass 'invalid tag is rejected'

fixture
PUBLISH_PATHS=''
reject
absent
pass 'empty paths are rejected'

fixture
PUBLISH_PATHS=missing
reject
absent
pass 'missing build is rejected'

fixture
for path in /tmp ../outside . ./dist dist/../source.txt .git .git/config; do
  PUBLISH_PATHS=$path
  reject
  absent
done
pass 'absolute, dot, parent and Git metadata paths are rejected'

fixture
mkdir -p 'build output'
printf 'literal\n' > 'build output/[entry]*.js'
PUBLISH_PATHS=$'dist\nbuild output/[entry]*.js'
publish
commit=$(sed -n 's/^commit=//p' "$GITHUB_OUTPUT")
eq "$(remote show "$commit:build output/[entry]*.js")" literal
eq "$(remote show "$commit:dist/index.js")" built
pass 'multiple paths, spaces and literal pathspec metacharacters'

fixture
PUBLISH_PATHS='dist/*'
reject
absent
pass 'wildcards do not select files implicitly'

fixture
git remote set-url origin "$root/nonexistent.git"
reject
absent
pass 'remote lookup failure does not mean tag absence'

fixture
cat > "$root/remote.git/hooks/pre-receive" <<'HOOK'
#!/usr/bin/env bash
exit 1
HOOK
chmod +x "$root/remote.git/hooks/pre-receive"
before_index=$(git hash-object .git/index)
reject
absent
eq "$(git hash-object .git/index)" "$before_index"
eq "$(git rev-parse HEAD)" "$source_sha"
[[ -z $(find "$root" -maxdepth 1 -name 'publish-built-action.*' -print) ]] || fail 'Temporary index leaked'
eq "$(git for-each-ref --format='%(refname)' refs/tags)" ''
pass 'push rejection preserves state, cleans temporary files and emits no outputs'

fixture
# Simulate another publisher winning after the remote's ref advertisement.
cat > .git/hooks/pre-push <<'HOOK'
#!/usr/bin/env bash
set -eu
git --git-dir="$RACE_REMOTE" update-ref refs/tags/v1.2.3 "$RACE_SOURCE"
HOOK
chmod +x .git/hooks/pre-push
export RACE_REMOTE="$root/remote.git" RACE_SOURCE="$source_sha"
reject
eq "$(remote rev-parse refs/tags/v1.2.3)" "$source_sha"
pass 'concurrent tag creation is never overwritten'

fixture
printf 'second\n' >> source.txt
git add source.txt
git commit -qm 'feat: second source'
git push -q origin HEAD
source_sha=$(git rev-parse HEAD)
git clone -q --depth=1 "file://$root/remote.git" "$root/shallow" --branch main
cd "$root/shallow"
git checkout -q --detach
mkdir dist
printf 'shallow build\n' > dist/index.js
PUBLISH_WORKING_DIRECTORY="$PWD"
eq "$(git rev-parse --is-shallow-repository)" true
publish
commit=$(sed -n 's/^commit=//p' "$GITHUB_OUTPUT")
eq "$(remote rev-list --parents -n 1 "$commit")" "$commit"
eq "$(remote rev-list --count "$commit")" 1
eq "$(remote show "$commit:dist/index.js")" 'shallow build'
pass 'shallow detached checkout needs no full fetch'

fixture
mkdir nested
PUBLISH_WORKING_DIRECTORY="$PWD/nested"
reject
absent
pass 'repository root is required'

fixture
unset GITHUB_OUTPUT
if publish; then fail 'Missing output file unexpectedly succeeded'; fi
absent
pass 'missing output binding fails before publication'

release_fixture() {
  fixture
  export PUBLISH_CREATE_RELEASE=true
  export PUBLISH_COPY_RELEASE_NOTES_FROM=source-v1.2.3
  export PUBLISH_RELEASE_REPOSITORY=owner/project
  export MOCK_MODE=success
  # Keep inherited credentials out of the stub: only presence is needed here.
  export GH_TOKEN=test-only-not-a-credential
  cat > "$root/notes" <<'NOTES'
## Changes

- Preserve `code`, "quotes", and $variables.

NOTES
}

release_fixture
publish
eq "$(sed -n 's/^release-url=//p' "$GITHUB_OUTPUT")" 'https://github.com/owner/project/releases/tag/v1.2.3'
eq "$(wc -l < "$root/gh-calls" | tr -d ' ')" 2
pass 'source notes copied before push and Release created afterward with verified tag'

release_fixture
MOCK_MODE=read-failure
reject
absent
eq "$(wc -l < "$root/gh-calls" | tr -d ' ')" 1
pass 'source Release lookup failure prevents tag publication'

release_fixture
MOCK_MODE=create-failure
reject
remote show-ref --verify --quiet refs/tags/v1.2.3 || fail 'Published tag was removed'
eq "$(git rev-parse HEAD)" "$source_sha"
[[ $(cat "$root/log") == *'Retry only Release creation'* ]] || fail 'Missing recovery guidance'
[[ -z $(find "$root" -maxdepth 1 -name 'publish-built-action.*' -print) ]] || fail 'Notes leaked'
pass 'Release creation failure preserves tag, cleans notes and explains recovery'

release_fixture
GH_TOKEN=''
reject
absent
pass 'missing Release token fails before push'

release_fixture
PUBLISH_COPY_RELEASE_NOTES_FROM=$PUBLISH_TAG
reject
absent
pass 'source and distribution Release tags must differ'

release_fixture
PUBLISH_COPY_RELEASE_NOTES_FROM='bad tag'
reject
absent
pass 'invalid source Release tag is rejected before push'

release_fixture
cat > "$root/remote.git/hooks/pre-receive" <<'HOOK'
#!/usr/bin/env bash
exit 1
HOOK
chmod +x "$root/remote.git/hooks/pre-receive"
reject
absent
eq "$(wc -l < "$root/gh-calls" | tr -d ' ')" 1
pass 'rejected tag push never attempts Release creation'

release_fixture
unset PUBLISH_COPY_RELEASE_NOTES_FROM
publish
eq "$(wc -l < "$root/gh-calls" | tr -d ' ')" 1
eq "$(sed -n 's/^release-url=//p' "$GITHUB_OUTPUT")" 'https://github.com/owner/project/releases/tag/v1.2.3'
pass 'Release creation without copying passes explicit empty notes and skips source lookup'

release_fixture
PUBLISH_CREATE_RELEASE=false
reject
absent
[[ ! -e $root/gh-calls ]] || fail 'Invalid options called GitHub CLI'
pass 'copying without Release creation is rejected before publication'

fixture
PUBLISH_CREATE_RELEASE=yes
reject
absent
pass 'invalid create-release boolean is rejected'

fixture
# Documentation is optional and never synthesized, including the license.
git rm -q README.md CHANGELOG.md LICENSE
git commit -qm 'docs: remove documentation'
source_sha=$(git rev-parse HEAD)
publish
commit=$(sed -n 's/^commit=//p' "$GITHUB_OUTPUT")
eq "$(remote ls-tree -r --name-only "$commit")" dist/index.js
pass 'missing documentation is omitted without inventing files'

fixture
printf 'name: Distribution\n' > action.yml
PUBLISH_PATHS=$'action.yml\ndist'
publish
commit=$(sed -n 's/^commit=//p' "$GITHUB_OUTPUT")
eq "$(remote show "$commit:action.yml")" 'name: Distribution'
eq "$(remote ls-tree -r --name-only "$commit")" $'action.yml\ndist/index.js'
# A fresh clone of the tag must contain only the isolated distribution history.
git clone -q --branch "$PUBLISH_TAG" "file://$root/remote.git" "$root/distribution" 2> "$root/clone-log"
eq "$(git -C "$root/distribution" rev-list --count HEAD)" 1
[[ ! -e $root/distribution/source.ts && ! -e $root/distribution/.github ]] || fail 'Source files leaked'
pass 'explicit action metadata and fresh tag clone contain only distribution files'

fixture
printf 'working readme\n' > README.md
PUBLISH_PATHS=$'dist\nREADME.md\nCHANGELOG.md\nLICENSE'
publish
commit=$(sed -n 's/^commit=//p' "$GITHUB_OUTPUT")
eq "$(remote ls-tree -r --name-only "$commit")" $'CHANGELOG.md\nLICENSE\nREADME.md\ndist/index.js'
eq "$(remote show "$commit:README.md")" 'working readme'
eq "$(remote show "$commit:CHANGELOG.md")" changelog
eq "$(remote show "$commit:LICENSE")" license
pass 'explicit documentation paths include their working-tree contents'

fixture
PUBLISH_PATHS=$'dist\nMISSING-LICENSE'
reject
absent
pass 'missing explicitly selected documentation is an error'

release_fixture
unset PUBLISH_COPY_RELEASE_NOTES_FROM
PUBLISH_GENERATE_RELEASE_NOTES=true
publish
eq "$(wc -l < "$root/gh-calls" | tr -d ' ')" 1
pass 'generated notes use only --generate-notes and skip source lookup'

release_fixture
PUBLISH_GENERATE_RELEASE_NOTES=true
reject
absent
[[ ! -e $root/gh-calls ]] || fail 'Conflicting options called GitHub CLI'
pass 'copying and generation are mutually exclusive before publication'

release_fixture
unset PUBLISH_COPY_RELEASE_NOTES_FROM
PUBLISH_CREATE_RELEASE=false
PUBLISH_GENERATE_RELEASE_NOTES=true
reject
absent
[[ ! -e $root/gh-calls ]] || fail 'Disabled Release called GitHub CLI'
pass 'generated notes require Release creation'

fixture
PUBLISH_GENERATE_RELEASE_NOTES=yes
reject
absent
pass 'invalid generate-release-notes boolean is rejected'

# Use a throwaway, unprotected key only inside this isolated test directory.
export GNUPGHOME="$suite/gnupg"
mkdir -m 700 "$GNUPGHOME"
gpg --batch --pinentry-mode loopback --passphrase '' \
  --quick-generate-key 'Signing Test <signing@example.com>' ed25519 sign 0 > "$suite/keygen.log" 2>&1
fingerprint=$(gpg --batch --with-colons --list-secret-keys 2> /dev/null | awk -F: '$1 == "fpr" {print $10; exit}')
[[ -n $fingerprint ]] || fail 'Test signing key was not created'

for mode in commit tag both; do
  fixture
  export PUBLISH_SIGNING_KEY="$fingerprint"
  export PUBLISH_AUTHOR_NAME='Signing Test' PUBLISH_AUTHOR_EMAIL=signing@example.com
  if [[ $mode != tag ]]; then PUBLISH_SIGN_COMMIT=true; fi
  if [[ $mode != commit ]]; then PUBLISH_SIGN_TAG=true; fi
  before_config=$(git config --local --list)
  publish
  commit=$(sed -n 's/^commit=//p' "$GITHUB_OUTPUT")
  if [[ $mode != tag ]]; then
    remote verify-commit --raw "$commit" > "$root/verify-commit" 2>&1
    [[ $(cat "$root/verify-commit") == *"VALIDSIG $fingerprint "* ]] || fail 'Unexpected commit signing key'
  elif remote cat-file commit "$commit" | grep -q '^gpgsig '; then
    fail 'Unexpected commit signature'
  fi
  if [[ $mode != commit ]]; then
    remote verify-tag --raw "refs/tags/$PUBLISH_TAG" > "$root/verify-tag" 2>&1
    [[ $(cat "$root/verify-tag") == *"VALIDSIG $fingerprint "* ]] || fail 'Unexpected tag signing key'
  elif remote cat-file tag "refs/tags/$PUBLISH_TAG" | grep -q 'BEGIN PGP SIGNATURE'; then
    fail 'Unexpected tag signature'
  fi
  eq "$(remote show -s --format=%ae "$commit")" signing@example.com
  eq "$(git config --local --list)" "$before_config"
  eq "$(git rev-parse HEAD)" "$source_sha"
  eq "$(git for-each-ref --format='%(refname)' refs/tags)" ''
  eq "$(remote rev-list --count "$commit")" 1
  pass "GPG signatures verify with independent signing scope: $mode"
done

for mode in commit tag; do
  fixture
  if [[ $mode == commit ]]; then PUBLISH_SIGN_COMMIT=true; else PUBLISH_SIGN_TAG=true; fi
  reject
  absent
  pass "$mode signing requires an explicit signing key"

  export PUBLISH_SIGNING_KEY=0000000000000000000000000000000000000000
  reject
  absent
  eq "$(git rev-parse HEAD)" "$source_sha"
  eq "$(git for-each-ref --format='%(refname)' refs/tags)" ''
  pass "unavailable $mode signing key fails without publishing a tag"
done

for mode in commit tag; do
  fixture
  if [[ $mode == commit ]]; then PUBLISH_SIGN_COMMIT=yes; else PUBLISH_SIGN_TAG=yes; fi
  reject
  absent
  pass "invalid sign-$mode boolean is rejected"
done

fixture
export PUBLISH_SIGN_COMMIT=true PUBLISH_SIGN_TAG=true PUBLISH_SIGNING_KEY="$fingerprint"
cat > "$root/gpg-wrapper" <<'GPG'
#!/usr/bin/env bash
printf 'called\n' >> "$MOCK_ROOT/gpg-calls"
exec gpg "$@"
GPG
chmod +x "$root/gpg-wrapper"
git config gpg.openpgp.program "$root/gpg-wrapper"
git config gpg.format ssh
before_config=$(git config --local --list)
publish
commit=$(sed -n 's/^commit=//p' "$GITHUB_OUTPUT")
remote verify-commit "$commit" > "$root/verify-commit" 2>&1
remote verify-tag "refs/tags/$PUBLISH_TAG" > "$root/verify-tag" 2>&1
eq "$(wc -l < "$root/gpg-calls" | tr -d ' ')" 2
eq "$(git config --local --list)" "$before_config"
pass 'caller OpenPGP program works for commit and isolated tag without changing config'

fixture
git config commit.gpgSign true
git config tag.gpgSign true
git config gpg.program "$root/nonexistent-gpg"
publish
commit=$(sed -n 's/^commit=//p' "$GITHUB_OUTPUT")
if remote cat-file commit "$commit" | grep -q '^gpgsig '; then fail 'Unexpected default commit signature'; fi
if remote cat-file tag "refs/tags/$PUBLISH_TAG" | grep -q 'BEGIN PGP SIGNATURE'; then fail 'Unexpected default tag signature'; fi
pass 'signing stays opt-in despite caller automatic signing configuration'

fixture
git remote set-url origin "$root/unavailable-remote.git"
RUNNER_TEMP="$root/unavailable-temp-directory"
PUBLISH_CREATE_RELEASE=yes
reject
[[ $(cat "$root/log") == *'create-release must be true or false.'* ]] || fail 'Local validation did not precede remote access and temporary setup'
absent
pass 'invalid configuration is reported before remote lookup or temporary setup'

fixture
export PUBLISH_FLOATING_TAGS=$'v1\nv1.2\nstable'
git tag v1
git tag -a unused -m 'Unrelated tag'
git config push.followTags true
publish
commit=$(sed -n 's/^commit=//p' "$GITHUB_OUTPUT")
for alias in v1 v1.2 stable; do
  eq "$(remote cat-file -t "refs/tags/$alias")" tag
  eq "$(remote rev-parse "refs/tags/$alias^{}")" "$commit"
  eq "$(remote for-each-ref --format='%(tag)' "refs/tags/$alias")" "$alias"
done
eq "$(remote for-each-ref --format='%(refname)' refs/tags)" $'refs/tags/stable\nrefs/tags/v1\nrefs/tags/v1.2\nrefs/tags/v1.2.3'
eq "$(git rev-parse refs/tags/v1)" "$source_sha"
eq "$(remote rev-parse refs/heads/main)" "$source_sha"
pass 'floating tags are annotated aliases of one orphan commit without changing local refs'

old_fixed=$(remote rev-parse refs/tags/v1.2.3)
old_commit=$commit
PUBLISH_TAG=v1.2.4
printf 'new build\n' > dist/index.js
: > "$GITHUB_OUTPUT"
publish
commit=$(sed -n 's/^commit=//p' "$GITHUB_OUTPUT")
[[ $commit != "$old_commit" ]] || fail 'Expected a new distribution commit'
eq "$(remote rev-list --count "$commit")" 1
eq "$(remote rev-parse refs/tags/v1.2.3)" "$old_fixed"
for alias in v1 v1.2 stable; do eq "$(remote rev-parse "refs/tags/$alias^{}")" "$commit"; done
pass 'floating refs advance while earlier fixed releases and orphan history are preserved'

current_alias=$(remote rev-parse refs/tags/stable)
: > "$GITHUB_OUTPUT"
reject
eq "$(remote rev-parse refs/tags/stable)" "$current_alias"
pass 'existing fixed version prevents all floating updates'

PUBLISH_TAG=v1.2.2
reject
absent
eq "$(remote rev-parse refs/tags/stable)" "$current_alias"
[[ $(cat "$root/log") == *'backward'* ]] || fail 'Expected downgrade rejection'
pass 'an older release cannot move floating tags backward'

fixture
export PUBLISH_FLOATING_TAGS=stable
remote update-ref refs/tags/stable "$source_sha"
reject
absent
eq "$(remote rev-parse refs/tags/stable)" "$source_sha"
[[ $(cat "$root/log") == *'Cannot identify a fixed version'* ]] || fail 'Expected unknown version rejection'
pass 'unknown existing floating target is never overwritten'

fixture
export PUBLISH_FLOATING_TAGS=stable
PUBLISH_TAG=v1.9.0
publish
PUBLISH_TAG=v1.10.0
: > "$GITHUB_OUTPUT"
publish
eq "$(remote rev-parse 'refs/tags/stable^{}')" "$(sed -n 's/^commit=//p' "$GITHUB_OUTPUT")"
PUBLISH_TAG=v1.8.0
: > "$GITHUB_OUTPUT"
reject
absent
pass 'version ordering compares decimal numbers instead of lexical tag order'

fixture
export PUBLISH_FLOATING_TAGS=stable
PUBLISH_TAG=v1.999999999999999999999999999999.0
publish
PUBLISH_TAG=v1.1000000000000000000000000000000.0
: > "$GITHUB_OUTPUT"
publish
PUBLISH_TAG=v1.999999999999999999999999999998.0
: > "$GITHUB_OUTPUT"
reject
absent
pass 'large version components cannot overflow downgrade checks'

for invalid in $'v1\nv1' v1.2.3 v1.2.2 $'v1\nv1/stable' 'bad tag'; do
  fixture
  export PUBLISH_FLOATING_TAGS="$invalid"
  reject
  absent
  eq "$(remote for-each-ref --format='%(refname)' refs/tags)" ''
  pass "invalid floating names are rejected before publication: ${invalid//$'\n'/,}"
done

for invalid in custom-tag v1.2.3-rc.1 v1.2.3+build v01.2.3; do
  fixture
  export PUBLISH_FLOATING_TAGS=stable
  PUBLISH_TAG=$invalid
  reject
  absent
  pass "floating publication requires a stable full version: $invalid"
done

fixture
export PUBLISH_FLOATING_TAGS=$'\nchannels/stable\n\n'
publish
eq "$(remote rev-parse 'refs/tags/channels/stable^{}')" "$(sed -n 's/^commit=//p' "$GITHUB_OUTPUT")"
pass 'namespaced floating names and blank lines are supported'

fixture
export PUBLISH_FLOATING_TAGS=stable
remote config receive.advertiseAtomic false
reject
absent
eq "$(remote for-each-ref --format='%(refname)' refs/tags)" ''
pass 'unsupported atomic push never falls back to partial publication'

fixture
export PUBLISH_FLOATING_TAGS=stable
cat > "$root/remote.git/hooks/update" <<'HOOK'
#!/usr/bin/env bash
[[ $1 != refs/tags/stable ]]
HOOK
chmod +x "$root/remote.git/hooks/update"
reject
absent
eq "$(remote for-each-ref --format='%(refname)' refs/tags)" ''
pass 'server rejection of one alias rejects the complete atomic publication'

fixture
export PUBLISH_FLOATING_TAGS=stable
cat > .git/hooks/pre-push <<'HOOK'
#!/usr/bin/env bash
set -eu
git --git-dir="$RACE_REMOTE" update-ref refs/tags/stable "$RACE_SOURCE"
HOOK
chmod +x .git/hooks/pre-push
export RACE_REMOTE="$root/remote.git" RACE_SOURCE="$source_sha"
reject
absent
eq "$(remote rev-parse refs/tags/stable)" "$source_sha"
pass 'an alias created concurrently cannot be overwritten or leave a fixed tag behind'

fixture
export PUBLISH_FLOATING_TAGS=stable
publish
old_fixed=$(remote rev-parse refs/tags/v1.2.3)
PUBLISH_TAG=v1.2.4
: > "$GITHUB_OUTPUT"
cat > .git/hooks/pre-push <<'HOOK'
#!/usr/bin/env bash
set -eu
git --git-dir="$RACE_REMOTE" update-ref refs/tags/stable "$RACE_SOURCE"
HOOK
chmod +x .git/hooks/pre-push
export RACE_REMOTE="$root/remote.git" RACE_SOURCE="$source_sha"
reject
absent
eq "$(remote rev-parse refs/tags/stable)" "$source_sha"
eq "$(remote rev-parse refs/tags/v1.2.3)" "$old_fixed"
pass 'an alias changed after lookup rejects the complete update using its exact old object'

fixture
export PUBLISH_FLOATING_TAGS=stable
cat > .git/hooks/pre-push <<'HOOK'
#!/usr/bin/env bash
set -eu
git --git-dir="$RACE_REMOTE" update-ref refs/tags/v1.2.3 "$RACE_SOURCE"
HOOK
chmod +x .git/hooks/pre-push
export RACE_REMOTE="$root/remote.git" RACE_SOURCE="$source_sha"
reject
eq "$(remote rev-parse refs/tags/v1.2.3)" "$source_sha"
if remote show-ref --verify --quiet refs/tags/stable; then fail 'Alias was published after fixed-tag race'; fi
pass 'a fixed-tag race leaves floating tags unpublished'

fixture
export PUBLISH_FLOATING_TAGS=$'v1\nstable'
export PUBLISH_SIGN_COMMIT=true PUBLISH_SIGN_TAG=true PUBLISH_SIGNING_KEY="$fingerprint"
publish
commit=$(sed -n 's/^commit=//p' "$GITHUB_OUTPUT")
remote verify-commit "$commit" > "$root/verify-commit" 2>&1
for alias in v1.2.3 v1 stable; do
  remote verify-tag --raw "refs/tags/$alias" > "$root/verify-tag" 2>&1
  [[ $(cat "$root/verify-tag") == *"VALIDSIG $fingerprint "* ]] || fail 'Wrong alias signing key'
done
pass 'fixed and floating annotated tags have independently verifiable GPG signatures'

release_fixture
export PUBLISH_FLOATING_TAGS=stable
publish
eq "$(wc -l < "$root/gh-calls" | tr -d ' ')" 2
eq "$(remote rev-parse 'refs/tags/stable^{}')" "$(sed -n 's/^commit=//p' "$GITHUB_OUTPUT")"
pass 'only the fixed tag receives a GitHub Release after all refs are published'

release_fixture
export PUBLISH_FLOATING_TAGS=stable
MOCK_MODE=create-failure
reject
remote show-ref --verify --quiet refs/tags/v1.2.3 || fail 'Fixed tag was removed'
remote show-ref --verify --quiet refs/tags/stable || fail 'Floating tag was removed'
[[ $(cat "$root/log") == *'Retry only Release creation'* ]] || fail 'Missing recovery guidance'
pass 'Release failure retains both fixed and floating tags for Release-only recovery'

release_fixture
export PUBLISH_FLOATING_TAGS=source-v1.2.3
reject
absent
[[ ! -e $root/gh-calls ]] || fail 'Source Release was read before validating its tag'
pass 'source Release tag cannot be overwritten as a floating alias'

fixture
PUBLISH_TAG=v1.2.2
publish
commit=$(sed -n 's/^commit=//p' "$GITHUB_OUTPUT")
remote update-ref refs/tags/stable "$commit"
export PUBLISH_FLOATING_TAGS=stable
PUBLISH_TAG=v1.2.3
: > "$GITHUB_OUTPUT"
publish
eq "$(remote cat-file -t refs/tags/stable)" tag
eq "$(remote rev-parse 'refs/tags/stable^{}')" "$(sed -n 's/^commit=//p' "$GITHUB_OUTPUT")"
pass 'existing lightweight aliases advance when their fixed version is known'

fixture
export PUBLISH_FLOATING_TAGS=stable
publish
commit=$(sed -n 's/^commit=//p' "$GITHUB_OUTPUT")
remote tag -a v2.0.0 "$commit" -m 'Another fixed version of the same commit'
PUBLISH_TAG=v1.3.0
: > "$GITHUB_OUTPUT"
reject
absent
eq "$(remote rev-parse 'refs/tags/stable^{}')" "$commit"
pass 'downgrade protection checks every fixed version sharing an alias target'

fixture
export PUBLISH_FLOATING_TAGS=stable
git remote set-url origin "$root/unavailable.git"
reject
absent
pass 'floating tag lookup failure stops publication'

fixture
export PUBLISH_FLOATING_TAGS=stable PUBLISH_SIGN_TAG=true PUBLISH_SIGNING_KEY="$fingerprint"
cat > "$root/failing-gpg" <<'GPG'
#!/usr/bin/env bash
set -eu
if [[ -e $MOCK_ROOT/signed-once ]]; then exit 1; fi
: > "$MOCK_ROOT/signed-once"
exec gpg "$@"
GPG
chmod +x "$root/failing-gpg"
git config gpg.program "$root/failing-gpg"
reject
absent
[[ -e $root/signed-once ]] || fail 'Expected the fixed tag to be signed before alias signing failed'
eq "$(remote for-each-ref --format='%(refname)' refs/tags)" ''
eq "$(git for-each-ref --format='%(refname)' refs/tags)" ''
pass 'floating tag signing failure publishes neither the signed fixed tag nor aliases'

fixture
IFS= read -r literal_alias <<'TAG'
$(touch${IFS}unexpected-marker)
TAG
export PUBLISH_FLOATING_TAGS="$literal_alias"
publish
PUBLISH_TAG=v1.2.4
: > "$GITHUB_OUTPUT"
publish
eq "$(remote rev-parse "refs/tags/$literal_alias^{}")" "$(sed -n 's/^commit=//p' "$GITHUB_OUTPUT")"
[[ ! -e unexpected-marker ]] || fail 'Floating tag data was evaluated as shell code'
pass 'floating tag names remain literal during lookup and update'

# Export keys only to the isolated suite directory; never print their contents.
gpg --batch --armor --export-secret-keys "$fingerprint" > "$suite/signing-key.asc"
passphrase='test-only signing passphrase'
gpg --batch --pinentry-mode loopback --passphrase "$passphrase" \
  --quick-generate-key 'Protected Signing Test <protected@example.com>' ed25519 sign 0 > "$suite/protected-keygen.log" 2>&1
protected_fingerprint=$(gpg --batch --with-colons --list-secret-keys protected@example.com 2> /dev/null | awk -F: '$1 == "fpr" {print $10; exit}')
gpg --batch --pinentry-mode loopback --passphrase "$passphrase" --armor \
  --export-secret-keys "$protected_fingerprint" > "$suite/protected-key.asc"
gpg --batch --armor --export "$fingerprint" > "$suite/public-key.asc"

imported_key_fixture() {
  fixture
  export PUBLISH_SIGN_COMMIT=true PUBLISH_SIGN_TAG=true
  export PUBLISH_GPG_PRIVATE_KEY
  PUBLISH_GPG_PRIVATE_KEY=$(cat "$suite/signing-key.asc")
}

for protection in unprotected protected; do
  imported_key_fixture
  if [[ $protection == protected ]]; then
    PUBLISH_GPG_PRIVATE_KEY=$(cat "$suite/protected-key.asc")
    export PUBLISH_GPG_PASSPHRASE="$passphrase"
    expected_fingerprint=$protected_fingerprint
  else
    expected_fingerprint=$fingerprint
  fi
  export PUBLISH_FLOATING_TAGS=stable
  before_keys=$(gpg --batch --with-colons --list-secret-keys 2> /dev/null)
  before_config=$(git config --local --list)
  publish
  commit=$(sed -n 's/^commit=//p' "$GITHUB_OUTPUT")
  remote verify-commit --raw "$commit" > "$root/verify-commit" 2>&1
  [[ $(cat "$root/verify-commit") == *"VALIDSIG $expected_fingerprint "* ]] || fail 'Wrong imported commit key'
  for alias in v1.2.3 stable; do
    remote verify-tag --raw "refs/tags/$alias" > "$root/verify-tag" 2>&1
    [[ $(cat "$root/verify-tag") == *"VALIDSIG $expected_fingerprint "* ]] || fail 'Wrong imported tag key'
  done
  eq "$(gpg --batch --with-colons --list-secret-keys 2> /dev/null)" "$before_keys"
  eq "$(git config --local --list)" "$before_config"
  [[ $(cat "$root/log") != *"$PUBLISH_GPG_PRIVATE_KEY"* ]] || fail 'Private key appeared in logs'
  if [[ -n ${PUBLISH_GPG_PASSPHRASE:-} ]]; then
    [[ $(cat "$root/log") != *"$PUBLISH_GPG_PASSPHRASE"* ]] || fail 'Passphrase appeared in logs'
  fi
  [[ -z $(find "$root" -maxdepth 1 -name 'publish-built-action.*' -print) ]] || fail 'Imported private keyring leaked'
  pass "private key import signs commits and aliases with automatic fingerprint selection: $protection"
done

for invalid in wrong-passphrase invalid-key public-key-only missing-selected-key; do
  imported_key_fixture
  case "$invalid" in
    wrong-passphrase)
      PUBLISH_GPG_PRIVATE_KEY=$(cat "$suite/protected-key.asc")
      export PUBLISH_GPG_PASSPHRASE='incorrect passphrase'
      ;;
    invalid-key) PUBLISH_GPG_PRIVATE_KEY='not a private key' ;;
    public-key-only) PUBLISH_GPG_PRIVATE_KEY=$(cat "$suite/public-key.asc") ;;
    missing-selected-key) export PUBLISH_SIGNING_KEY=0000000000000000000000000000000000000000 ;;
  esac
  reject
  absent
  [[ -z $(find "$root" -maxdepth 1 -name 'publish-built-action.*' -print) ]] || fail 'Failed import leaked key material'
  pass "invalid imported key configuration prevents publication and cleans its keyring: $invalid"
done

imported_key_fixture
PUBLISH_GPG_PRIVATE_KEY=$(cat "$suite/signing-key.asc" "$suite/protected-key.asc")
reject
absent
[[ $(cat "$root/log") == *'Select exactly one imported secret key'* ]] || fail 'Expected ambiguous key rejection'
export PUBLISH_SIGNING_KEY="$fingerprint"
publish
commit=$(sed -n 's/^commit=//p' "$GITHUB_OUTPUT")
remote verify-commit --raw "$commit" > "$root/verify-commit" 2>&1
[[ $(cat "$root/verify-commit") == *"VALIDSIG $fingerprint "* ]] || fail 'Wrong explicitly selected key'
pass 'multiple imported secret keys require explicit selection and use the selected key'

imported_key_fixture
PUBLISH_SIGN_COMMIT=false
PUBLISH_SIGN_TAG=false
reject
absent
pass 'private key import requires explicit signing options'

fixture
export PUBLISH_SIGN_TAG=true PUBLISH_SIGNING_KEY="$fingerprint" PUBLISH_GPG_PASSPHRASE=passphrase
reject
absent
pass 'a passphrase cannot be supplied without a private key import'

imported_key_fixture
export PUBLISH_GPG_PASSPHRASE=$'invalid\npassphrase'
reject
absent
pass 'multiline GPG passphrases are rejected before importing keys'

imported_key_fixture
cat > "$root/remote.git/hooks/pre-receive" <<'HOOK'
#!/usr/bin/env bash
exit 1
HOOK
chmod +x "$root/remote.git/hooks/pre-receive"
reject
absent
[[ -z $(find "$root" -maxdepth 1 -name 'publish-built-action.*' -print) ]] || fail 'Rejected push leaked imported keys'
pass 'push rejection cleans the imported private keyring'

release_fixture
export PUBLISH_SIGN_TAG=true PUBLISH_GPG_PRIVATE_KEY
PUBLISH_GPG_PRIVATE_KEY=$(cat "$suite/signing-key.asc")
MOCK_MODE=create-failure
reject
remote show-ref --verify --quiet refs/tags/v1.2.3 || fail 'Published signed tag was removed'
[[ -z $(find "$root" -maxdepth 1 -name 'publish-built-action.*' -print) ]] || fail 'Release failure leaked imported keys'
pass 'Release creation failure cleans imported keys while retaining the published tag'

for label in none prerelease latest; do
  release_fixture
  export PUBLISH_RELEASE_LABEL="$label"
  publish
  eq "$(wc -l < "$root/gh-calls" | tr -d ' ')" 2
  pass "Release label maps to the expected GitHub CLI flags: $label"
done

release_fixture
unset PUBLISH_COPY_RELEASE_NOTES_FROM
export PUBLISH_RELEASE_LABEL=none
publish
pass 'empty notes and an unlabeled normal Release can be selected together'

release_fixture
unset PUBLISH_COPY_RELEASE_NOTES_FROM
export PUBLISH_GENERATE_RELEASE_NOTES=true PUBLISH_RELEASE_LABEL=latest
publish
pass 'generated notes and Latest label can be selected together'

release_fixture
export PUBLISH_RELEASE_LABEL=unknown
reject
absent
[[ ! -e $root/gh-calls ]] || fail 'Invalid label called GitHub CLI'
pass 'invalid Release label fails before publication or source lookup'

fixture
export PUBLISH_RELEASE_LABEL=latest
reject
absent
pass 'Release labels require explicit Release creation'

release_fixture
export PUBLISH_RELEASE_LABEL=prerelease
MOCK_MODE=create-failure
reject
remote show-ref --verify --quiet refs/tags/v1.2.3 || fail 'Published tag was removed'
[[ $(cat "$root/log") == *'Retry only Release creation'* ]] || fail 'Missing labeled Release recovery guidance'
pass 'labeled Release creation failure preserves the tag for Release-only recovery'

printf 'Passed %s integration scenarios.\n' "$cases"
