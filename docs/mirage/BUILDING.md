# Building Mirage

Mirage is a fork of [Vitrine](https://github.com/meownyaaa/vitrine). The repo builds two tweaks:

| Dir | What | Output |
|---|---|---|
| `tweak/` | Vitrine, unchanged (merge `upstream/main` to update) | `spotifyglass.dylib` |
| `mirage/` | Mirage: backgrounds, its drawer row and settings page | `Mirage.dylib`, `com.x4nzz.mirage_*.deb` |

`scripts/mirage-build.sh <decrypted Spotify.ipa>` builds both and injects them into the IPA with
[cyan](https://github.com/asdfzxcvbn/pyzule-rw), fakesigned, ready for Ksign or SideStore.
The output goes to `out/Mirage-<spotify version>.ipa`, `out/Mirage.dylib` and `out/com.x4nzz.mirage_*.deb`.

## On Linux

```sh
scripts/mirage-setup-linux.sh     # Theos, iOS toolchain, iPhoneOS 26.2 SDK (26.5 link stubs), Swift 6.2.3, wrappers, cyan
source ~/mirage-env.sh
scripts/mirage-build.sh ~/Downloads/Spotify-9.1.90-decrypted.ipa
```

Linux can't build Vitrine's **Live Activity widget**, because it needs Xcode's `appintentsmetadataprocessor`.
Everything else is built, Vitrine's Swift sources included. The build leaves the widget out and says so.

## On GitHub (macOS, with the Live Activity)

Actions → **Build Mirage IPA** → Run workflow, then paste a direct link to the decrypted IPA. The IPA
comes back as a workflow artifact that is kept for 3 days. It is never published as a release, because it contains Spotify.

## On a Mac

Install Theos, `brew install make dpkg ldid`, cyan and Pillow, then run `scripts/mirage-build.sh` the same way.

## Updating Vitrine

```sh
git fetch upstream && git merge upstream/main
```

Mirage never edits Vitrine's files (`tweak/`, `scripts/pipeline.sh` …), so merges stay clean. If Vitrine
moves to a new Spotify version, check the classes listed at the top of `mirage/Sources/MRGBackgrounds.x`
and `mirage/Sources/MRGDrawerRow.x` against a class dump of the new binary (for example `ipsw class-dump Spotify --headers`).
