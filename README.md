# WiX 6.0.2 internal build (temporary)

Build **from upstream source tag `v6.0.2`**, without distributing an upstream binary release, and package as **`6.0.2-ctech`** on GitHub Actions `windows-2022`.

The workflow lives at [`.github/workflows/build-wix6.yml`](.github/workflows/build-wix6.yml).

## Output

Actions -> **Build WiX 6.0.2 (CTech)** -> run -> **Artifacts**.

- `wix6-ctech-packages`: all generated `.nupkg` and `.snupkg` (if the upstream build produces any), plus a JSON manifest with package IDs, versions, SHA-256 and dependencies.
- `wix6-ctech-debug`: build/test logs (including MSBuild binlogs), when available.
- `wix6-ctech-other`: any upstream non-NuGet artifacts, when available.

The upstream project may generate PDB/ZIP outputs but **not** `.snupkg` packages; the workflow will not invent symbol packages after the build.

## Security and publication

This public repo contains **no internal feed URL, NuGet push key, or corporate secrets**. Download and verify the artifacts locally, then publish to the internal BaGetter separately.

All packages need to be validated before publishing. The `6.0.2-ctech` version suffix is added **before compiling and packing**, including the central package version map and MSBuild SDK pin.

The original upstream source remains under the MS-RL; review license and OSMF metadata before enterprise use.

Upstream commit expected: `b3f340393117094a75ea8ced77f2357e4aa095e7`.

The repo can be removed after the artifact ZIPs, logs, and manifest are downloaded and verified.
