# Code signing

## Why this exists

Upkeep ships unsigned today. That causes two separate things:

- **SmartScreen** shows "Windows protected your PC" on the installer. SmartScreen
  weighs download prevalence and signing-certificate reputation. With no
  certificate there is nothing to accumulate reputation on, and every release is
  a new file hash starting from zero. This never improves on its own.
- **Avast and friends** score the build heuristically. Upkeep hits most of the
  inputs honestly: it is an unsigned, statically linked binary that requests
  administrator rights, ships through Inno Setup, and spawns PowerShell to
  download and install software. The scanners are reading it correctly. What is
  missing is publisher identity.

Signing fixes the first completely and most of the second.

## The plan: SignPath Foundation

[SignPath Foundation](https://signpath.org/) provides free OV code signing to
open-source projects. The private key lives in their HSM and never reaches this
repo or any build machine. The workflow uploads an artifact, SignPath verifies
it came from a specific run of a specific workflow on this repository, signs it,
and returns it.

Upkeep meets their conditions:

| Requirement | Status |
|---|---|
| OSI-approved license, no commercial dual-licensing | MIT |
| No proprietary or closed-source components | `vendor/` and `tools/` are gitignored and untracked. `NVCleanstall.exe` is downloaded at runtime by the user, never shipped. |
| Public repository, actively maintained | yes |
| Already released in the form to be signed | installer + portable zip |
| Built in CI | `.github/workflows/release.yml` |

**Tradeoff to be aware of:** the certificate belongs to SignPath Foundation, not
to you. Windows will show the publisher as *SignPath Foundation*, not
*joaovguedes*. You get the trust; the Foundation keeps the attribution, because
they are who the CA validated. The upside is that the certificate already
carries reputation from other projects, so releases usually skip the cold start
a fresh private certificate would have.

## Setup steps

1. **Apply** at <https://signpath.org/apply>, linking
   `https://github.com/joaovgaraujo/Upkeep` and pointing at an existing release.
2. **Create two artifact configurations** in the SignPath project, because the
   workflow signs two different things:
   - slug `exe` for `Upkeep.exe`
   - slug `installer` for `Upkeep-Setup.exe`
3. **Add repository variables** (Settings → Secrets and variables → Actions →
   Variables):
   - `SIGNPATH_ORGANIZATION_ID`
   - `SIGNPATH_PROJECT_SLUG`
   - `SIGNPATH_POLICY_SLUG`
4. **Add the repository secret** `SIGNPATH_API_TOKEN`.

The release workflow gates every signing step on
`vars.SIGNPATH_ORGANIZATION_ID != ''`, so it builds and publishes unsigned until
step 3 is done, then starts signing with no further edits.

## Signing order

`release.yml` signs `Upkeep.exe` **before** assembling the installer and
portable zip, then signs the installer afterwards, then repacks the portable zip
so it carries the signed exe.

This order is deliberate. Signing only the installer would leave an unsigned
binary sitting in Program Files after installation, which is the file Windows
actually executes every day and the one AV watches.

## What signing will not fix

`SystemUpdate_Topgrade.bat:97` bootstraps Chocolatey with:

```
iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
```

That is one of the most heavily signatured strings in Windows security tooling,
and Avast's script shield fires on what the script does at runtime, not on who
signed the exe that launched it. No certificate changes this. If the detection
matters, the fix is to replace the bootstrap, for example by installing
Chocolatey through winget or by vendoring the install script and running it from
disk after a checksum check.

## Free measures that stack with signing

- Submit false positives to
  [Avast](https://www.avast.com/false-positive-file-form.php) and
  [Microsoft](https://www.microsoft.com/wdsi/filesubmission). Avast's form works
  and turns around in a few days. Once signed, they can whitelist by publisher
  instead of per release.
- Publish to winget. Real download prevalence, and installs arrive through a
  Microsoft-signed client.
- `release.yml` already emits `SHA256SUMS.txt` and a build provenance
  attestation via `actions/attest-build-provenance`, so anyone can verify a
  download came from this repository's CI.

## Alternatives if the Foundation declines

| Route | Cost | SmartScreen |
|---|---|---|
| Azure Trusted Signing | ~$10/month | Reputation builds like OV. Eligibility is region-gated; confirm availability before planning on it. |
| OV certificate | ~$200-400/yr | Reputation builds on the cert and carries across releases. Requires a hardware token or cloud HSM. |
| EV certificate | ~$400-700/yr | Immediate trust, no warning from day one. Effectively requires a registered legal entity. |
