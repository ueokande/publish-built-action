# GPG signing

[Back to README](../README.md)

Use `sign-commit` and `sign-tag` independently, or enable both. Both default to
`false`; repository-level automatic signing settings do not enable them.
`sign-tag` applies to the fixed tag and every explicitly selected floating tag.
When either is enabled, `signing-key` must identify an imported OpenPGP private
key. A full fingerprint is recommended. SSH and X.509 signing are not supported.
The caller imports the key and makes it available for unattended signing through
GPG and its agent; this action does not import keys or accept a passphrase.

Signing uses the caller's `GNUPGHOME` and OpenPGP program (`gpg.openpgp.program`,
then `gpg.program`, otherwise `gpg`). Git configuration is applied per command,
including in the temporary tag repository, without modifying the caller's config.
All tag signatures are prepared before pushing. If signing a commit or any tag
fails, no tag is pushed and no Release is created.

## Example

This example uses the Import GPG action to load a protected key and configure
its agent. Store the ASCII-armored private key in the repository secret
`GPG_PRIVATE_KEY` and its passphrase in `GPG_PASSPHRASE`. Do not store private keys
or passphrases in the checkout or pass them as this action's inputs.

As in the [quick start](../README.md#quick-start), this action has no published
release tags yet: replace `REVIEWED_COMMIT_SHA` with a reviewed full commit.
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
      - uses: crazy-max/ghaction-import-gpg@v7.0.0
        id: gpg
        with:
          gpg_private_key: ${{ secrets.GPG_PRIVATE_KEY }}
          passphrase: ${{ secrets.GPG_PASSPHRASE }}
      - uses: ueokande/publish-built-action@REVIEWED_COMMIT_SHA
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
          signing-key: ${{ steps.gpg.outputs.fingerprint }}
          author-name: ${{ steps.gpg.outputs.name }}
          author-email: ${{ steps.gpg.outputs.email }}
```

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
