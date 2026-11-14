# GPG signing for distribution commits and release tags

Enable `sign-commit`, `sign-tag`, or both. `sign-tag` covers the fixed tag and all
floating tags. Both options default to `false`, independently of Git's automatic
signing configuration. Only OpenPGP signing is supported.

## Sign with a repository secret

Store an ASCII-armored private key in the secret `PRIVATE_SIGNING_KEY` and its
optional single-line passphrase in `GPG_PASSPHRASE`. Set repository variables
`GPG_AUTHOR_NAME` and `GPG_AUTHOR_EMAIL` to the signing identity.

After checkout, build and test, use this step in a job with `contents: write`:

```yaml
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

No import action, Bash import step or Git signing configuration is needed. Keep
private keys and passphrases in secrets, not in workflow text or the checkout.

## Key selection and cleanup

A single imported secret key is selected automatically. If the input contains
multiple secret keys, set `signing-key` to the desired fingerprint. Key import
requires at least one signing option to be enabled.

The action uses system GnuPG with loopback passphrase handling in an isolated
GPG home. On exit, it removes that keyring and passphrase file and stops its own
agent, including after failed imports, signatures, pushes or Release creation.
The caller's keyring and Git configuration are preserved. All signatures are
prepared before pushing; a signing failure publishes no tags or Release.

## Use an existing keyring

Omit `gpg-private-key` and supply `signing-key` for an available private key.
The action uses the caller's `GNUPGHOME` and OpenPGP program (`gpg.openpgp.program`,
then `gpg.program`, otherwise `gpg`). Prepare unattended passphrase handling
yourself; `gpg-passphrase` is only for keys imported by this action. The caller's
keyring and agent are left running and unchanged.

## Identity and verification

`author-name` and `author-email` apply to the commit's author and committer and
the tag's tagger. Defaults are `github-actions[bot]` and
`41898282+github-actions[bot]@users.noreply.github.com`.

For GitHub's Verified badge, use an identity associated with the signing key and
register its public key with the corresponding GitHub account. A valid signature
alone does not guarantee the badge.

After fetching the tag, verify the signatures you enabled with the public key
in your local keyring:

```bash
git verify-tag v1.2.3
git verify-commit 'v1.2.3^{commit}'
```
