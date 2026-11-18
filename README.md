# Chase's Repo

An APT repository hosting modernized **iOS 15–16+ rootless** (`iphoneos-arm64`) jailbreak tweaks for **Dopamine** and **Palera1n**, served via GitHub Pages at `https://chasedustevich.github.io/repo/`.

## Adding the Repository

Open one of the direct links below on your jailbroken device or add `https://chasedustevich.github.io/repo/` manually:

- **Sileo:** `sileo://source/https://chasedustevich.github.io/repo/`
- **Zebra:** `zbra://sources/add/https://chasedustevich.github.io/repo/`
- **Installer:** `installer://add/repo=https://chasedustevich.github.io/repo/`

## Hosted Packages

| Package | Bundle ID | Version | Architecture | Source |
|---|---|---|---|---|
| **Asteroid** | `com.midnightchips.asteroid` | `4.0.0` | `iphoneos-arm64` | [chasedustevich/Asteroid](https://github.com/chasedustevich/Asteroid) |
| **Snoverlay 2** | `com.ryannair05.snoverlay` | `1.1.1` | `iphoneos-arm64` | [chasedustevich/Snoverlay-2](https://github.com/chasedustevich/Snoverlay-2) |
| **Axon** | `me.nepeta.axon` | `1.5.1` | `iphoneos-arm64` | [chasedustevich/axon-ios16-compatibility](https://github.com/chasedustevich/axon-ios16-compatibility) |
| **S8Edge** | `com.brunonfl.s8edge` | `1.3.1` | `iphoneos-arm64` | [chasedustevich/s8edge](https://github.com/chasedustevich/s8edge) |

## Updating Packages & Rebuilding Indices

Drop a built `.deb` into `debs/` and run:

```sh
./update-repo.sh
```

Or pull the latest release `iphoneos-arm64` `.deb` builds automatically from the sibling tweak workspaces (`../Asteroid`, `../Snoverlay-2`, `../axon-ios16-compatibility`, `../s8edge`), prune older duplicate versions, sync depiction version strings, and regenerate `Packages`, `Packages.bz2`, `Packages.gz`, and `Packages.xz`:

```sh
./update-repo.sh --sync
```

Then commit and push to GitHub Pages.
