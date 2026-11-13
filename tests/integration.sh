#!/usr/bin/env bash
set -euo pipefail

script=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/scripts/publish.sh
suite=$(mktemp -d)
trap 'rm -rf -- "$suite"' EXIT
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
  unset PUBLISH_SOURCE_RELEASE_TAG PUBLISH_RELEASE_REPOSITORY
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
    [[ $* == 'release create --repo owner/project --verify-tag --title v1.2.3 --notes-file '*' -- v1.2.3' ]]
    git --git-dir="$MOCK_ROOT/remote.git" show-ref --verify --quiet refs/tags/v1.2.3
    cmp -- "$MOCK_ROOT/notes" "${9}"
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
eq "$(remote rev-parse 'refs/tags/v1.2.3^{}')" "$commit"
eq "$(remote rev-parse "$commit^")" "$source_sha"
eq "$(remote show "$commit:dist/index.js")" built
eq "$(remote show "$commit:source.txt")" source
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
pass 'annotated tag, ignored build, parent, outputs, identity and caller state'

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
eq "$(remote rev-parse "$commit^")" "$source_sha"
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
  export PUBLISH_SOURCE_RELEASE_TAG=source-v1.2.3
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
PUBLISH_SOURCE_RELEASE_TAG=$PUBLISH_TAG
reject
absent
pass 'source and distribution Release tags must differ'

release_fixture
PUBLISH_SOURCE_RELEASE_TAG='bad tag'
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

printf 'Passed %s integration scenarios.\n' "$cases"
