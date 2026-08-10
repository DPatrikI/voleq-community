# Releasing VolEq from the Community repository

Official macOS releases are built locally from a clean, reviewed `master`
commit. Normal contributor builds remain ad-hoc signed; release packaging
requires the project owner's Developer ID identity and notarization credentials.

## One-time signing setup

1. Create and install a **Developer ID Application** certificate using the Apple
   Developer account. Confirm that its private key appears in Keychain Access.
   See [Apple's certificate setup instructions](https://developer.apple.com/help/account/certificates/create-developer-id-certificates).
2. Verify that exactly one usable identity is available:

   ```sh
   security find-identity -v -p codesigning
   ```

3. In App Store Connect, open **Users and Access → Integrations → App Store
   Connect API** and generate a team API key dedicated to release automation.
   Individual API keys cannot authenticate `notarytool`. Download the `.p8`
   private key once, record its Key ID and Issuer ID, and retain an encrypted
   backup outside the repository.
4. Store the team API key in Keychain. The command prompts interactively for the
   `.p8` path, Key ID, and Issuer ID; never put these values or the private key
   in the repository or shell history:

   ```sh
   xcrun notarytool store-credentials "voleq-notary"
   ```

5. Confirm that Keychain authentication succeeds:

   ```sh
   xcrun notarytool history --keychain-profile "voleq-notary"
   ```

An Apple Account and app-specific password remain a supported fallback: leave
the API private-key prompt empty and provide the requested account, app-specific
password, and Team ID. Do not use the normal Apple Account password.

The default profile is `voleq-notary`. Set `VOLEQ_NOTARY_PROFILE` to use another
Keychain profile. If more than one Developer ID Application identity is present,
set `VOLEQ_SIGNING_IDENTITY` to the complete certificate name.

Apple's supported workflow requires Developer ID signing, Hardened Runtime, a
secure timestamp, `notarytool`, and stapling. See
[Apple's notarization overview](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
and [custom notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

## Release-candidate branch

From a clean release-branch commit, run:

```sh
./dev doctor
./dev test
./dev build macos
./dev benchmark mild-noise-suppression
VOLEQ_RELEASE_SUFFIX=rc1 ./dev package macos
```

The package command performs a fresh release build, enforces an arm64-only
binary, signs the executable and application with Hardened Runtime and a secure
timestamp, notarizes and staples the app, creates and signs the DMG, notarizes
and staples the DMG, runs Gatekeeper and integrity checks, and writes:

```text
dist/release/VolEq-Community-0.1.0-rc1-macOS-arm64.dmg
dist/release/SHA256SUMS.txt
dist/release/notarization/
```

The notarization directory is ignored build evidence. Inspect both notarization
logs even when Apple accepts the submissions. Mount the DMG, drag **VolEq** to
Applications, and smoke-test the packaged application before approving the PR.

## Final artifact and tag

The project owner merges the release PR manually. After merge, synchronize
`master`, wait for CI, and rebuild from that exact clean commit:

```sh
./dev package macos
```

This produces `VolEq-Community-0.1.0-macOS-arm64.dmg` and a matching checksum.
Do not reuse the release-candidate DMG because it was built from a different
commit. After the final artifact passes installation and smoke testing, create
an annotated `v0.1.0` tag on the verified merge commit. Push the tag only after
explicit owner authorization and wait for its CI run before publishing the
GitHub Release.

Attach the DMG and `SHA256SUMS.txt` to a normal GitHub Release. The historical
0.1.0 release remains titled `VolEq Community 0.1.0`; releases using the renamed
application use `VolEq <version>`. Keep the release as a draft until the owner
verifies the rendered notes, downloadable assets, and checksum.

## Failure handling

- A missing or ambiguous Developer ID identity stops packaging before signing.
- Authentication failures stop packaging without publishable outputs. Rejected
  submissions retain Apple's JSON response and detailed log when a submission
  ID is available.
- Each packaging attempt removes the previous DMG, checksum, and notarization
  evidence before signing or building. A failed rerun therefore leaves no stale
  publishable candidate at the documented output paths.
- Never bypass a failed signature, Gatekeeper, stapling, DMG, model-checksum, or
  notarization check.
- Never commit signing certificates, private keys, Apple credentials,
  app-specific passwords, or notarization responses.
- Revoke an App Store Connect API key immediately if its private key is lost or
  exposed.
- Do not tag a commit until the final artifact built from that commit passes.
