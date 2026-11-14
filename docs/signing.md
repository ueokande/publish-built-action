# GPG signing for distribution commits and release tags

Use `sign-commit` and `sign-tag` independently, or enable both. Both default to
`false`; repository-level automatic signing settings do not enable them.
`sign-tag` applies to the fixed tag and every explicitly selected floating tag.

Pass an ASCII-armored OpenPGP private key through `gpg-private-key` and its
optional single-line passphrase through `gpg-passphrase`. The action imports the
key into an isolated temporary GPG home and signs noninteractively. No separate
action, Bash import step or Git signing configuration is required.

With one imported secret key, `signing-key` is detected automatically. If the
input contains multiple secret keys, supply `signing-key` to select one; a full
fingerprint is recommended. Missing keys, ambiguous selection and incorrect
passphrases fail before any tag is pushed. SSH and X.509 signing are not supported.

Private keyring files, the passphrase file and the action's GPG agent are cleaned
up when the action exits, including after a failed import, signature, push or
Release operation. The caller's keyring and Git configuration are preserved.
All signatures are prepared before pushing; a signing failure creates no remote
tag or Release.

## Example

Store the ASCII-armored key in the repository secret `PRIVATE_SIGNING_KEY` and,
if protected, its passphrase in `GPG_PASSPHRASE`. Set repository variables
`GPG_AUTHOR_NAME` and `GPG_AUTHOR_EMAIL` to the signing identity. Do not store keys
or passphrases in the checkout or supply secret values as literal workflow text.

Adjust the build commands and explicit distribution paths for your repository.
Lock the example's dependencies with `gh actions-lock` in your own repository.

```yaml
name: Signed distribution
on:
  workflow_dispatch:
    inputs:
      tag:
        description: New immutable distribution tag
        required: true
        type: string
permissions:
  contents: read
concurrency:
  group: signed-release-${{ inputs.tag }}
  cancel-in-progress: false
jobs:
  publish:
    runs-on: ubuntu-24.04
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@v7.0.1
        with:
          persist-credentials: true
      - uses: actions/setup-node@v7.1.0
        with:
          node-version: '22'
          cache: npm
      - run: npm ci
      - run: npm test
      - run: npm run build
      - uses: ueokande/publish-built-action@v0.0.1
        with:
          tag: ${{ inputs.tag }}
          paths: |
            action.yml
            dist
            README.md
            CHANGELOG.md
            LICENSE
          sign-commit: 'true'
          sign-tag: 'true'
          gpg-private-key: ${{ secrets.PRIVATE_SIGNING_KEY }}
          gpg-passphrase: ${{ secrets.GPG_PASSPHRASE }}
          author-name: ${{ vars.GPG_AUTHOR_NAME }}
          author-email: ${{ vars.GPG_AUTHOR_EMAIL }}
```

## Existing keyrings

If `gpg-private-key` is omitted, supply `signing-key` for an already available
private key. This preserves the caller's `GNUPGHOME` and OpenPGP program
(`gpg.openpgp.program`, then `gpg.program`, otherwise `gpg`). In that mode, prepare
any agent or passphrase handling yourself; `gpg-passphrase` requires a private-key
input. The action does not clean or stop the caller's keyring or agent.

With an imported key, signing always uses the system GnuPG with loopback
passphrase handling in the isolated home. Key import requires at least one of
`sign-commit` and `sign-tag` to be enabled; it never enables signing implicitly.

## Identity and verification

`author-name` and `author-email` apply to the commit's author and committer and
the tag's tagger. Their defaults are `github-actions[bot]` and
`41898282+github-actions[bot]@users.noreply.github.com`.
For a personal or machine-account signing key, use an identity corresponding to
that key, as shown above. GitHub's Verified badge also depends on GitHub knowing
the public key and associating the signing identity's email with the account;
a valid cryptographic signature alone does not guarantee that badge.

After fetching the tag, verify locally with the public key in your keyring:

```bash
git verify-tag v1.2.3
git verify-commit 'v1.2.3^{commit}'
```

These commands validate the annotated tag and distribution commit respectively;
run the checks corresponding to the signing options you enabled. Signing does
not change orphan history, tag immutability checks, or Git push authentication.
