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
  unset PUBLISH_COPY_RELEASE_NOTES_FROM PUBLISH_RELEASE_REPOSITORY PUBLISH_RELEASE_NOTES
  export PUBLISH_GENERATE_RELEASE_NOTES=false
  unset PUBLISH_SIGNING_KEY PUBLISH_AUTHOR_NAME PUBLISH_AUTHOR_EMAIL
  export PUBLISH_SIGN_COMMIT=false PUBLISH_SIGN_TAG=false
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
    if [[ -n ${PUBLISH_COPY_RELEASE_NOTES_FROM:-} ]]; then
      [[ $* == 'release create --repo owner/project --verify-tag --title v1.2.3 --notes-file '*' -- v1.2.3' ]]
      cmp -- "$MOCK_ROOT/notes" "${9}"
    elif [[ $PUBLISH_GENERATE_RELEASE_NOTES == true ]]; then
      [[ $* == 'release create --repo owner/project --verify-tag --title v1.2.3 --generate-notes -- v1.2.3' ]]
    else
      [[ ${*:1:7} == 'release create --repo owner/project --verify-tag --title v1.2.3' ]]
      [[ $# == 11 && ${8} == --notes && ${9} == "${PUBLISH_RELEASE_NOTES:-}" && ${10} == -- && ${11} == v1.2.3 ]]
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
unset PUBLISH_COPY_RELEASE_NOTES_FROM
export PUBLISH_RELEASE_NOTES
PUBLISH_RELEASE_NOTES=$(cat <<'NOTES'
## Explicit notes

- Preserve "quotes", `code` and $variables.
--generate-notes
NOTES
)
publish
pass 'explicit multiline notes are passed as one literal --notes argument'

for mode in copy-generate copy-explicit generate-explicit all; do
  release_fixture
  if [[ $mode == generate-explicit ]]; then unset PUBLISH_COPY_RELEASE_NOTES_FROM; fi
  if [[ $mode != copy-explicit ]]; then PUBLISH_GENERATE_RELEASE_NOTES=true; fi
  if [[ $mode != copy-generate ]]; then export PUBLISH_RELEASE_NOTES='Explicit notes'; fi
  reject
  absent
  [[ ! -e $root/gh-calls ]] || fail 'Conflicting options called GitHub CLI'
  pass "conflicting note sources rejected before publication: $mode"
done

for mode in generate explicit; do
  release_fixture
  unset PUBLISH_COPY_RELEASE_NOTES_FROM
  PUBLISH_CREATE_RELEASE=false
  if [[ $mode == generate ]]; then
    PUBLISH_GENERATE_RELEASE_NOTES=true
  else
    export PUBLISH_RELEASE_NOTES='Explicit notes'
  fi
  reject
  absent
  [[ ! -e $root/gh-calls ]] || fail 'Disabled Release called GitHub CLI'
  pass "$mode notes require Release creation"
done

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

printf 'Passed %s integration scenarios.\n' "$cases"
