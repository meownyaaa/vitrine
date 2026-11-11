# Mirage addons

The Addon Shop (Settings → Mirage → Shop) lists addons from
[`addons/index.json`](../../addons/index.json), fetched from
`https://raw.githubusercontent.com/x4nzz/Mirage/main/addons/index.json`. A copy of that list is built into Mirage,
so the shop works offline and on first launch; pull down in the shop to fetch it again.

**Addons are features that ship inside Mirage.** The shop never downloads and runs code (an iOS app can't do that
safely). Installing an addon flips its switch (`mirage.addon.<id>` in Spotify's preferences); removing it puts Spotify
back the way it was. An addon listed in the index that this build doesn't carry shows "Update Mirage".

## Vinyl (Now Playing)

The cover shrinks and moves to one side, and a record peeks out from behind it. The record spins while a song
plays and stops when you pause; its label is the album art, and the grooves and light are drawn in code.
Settings: spin speed (Chill, 33⅓, 45) and which side the record is on. If Spotify's player changes and the
cover can't be found, Now Playing stays stock and the DJ log says `vinyl: player cover not found`.

Code: `mirage/Sources/MRGVinyl.x`.

## Adding an addon

1. Write the feature in `mirage/Sources/` and gate every hook on `MRGAddonInstalled(@"<id>")`. Check each class with
   `NSClassFromString`, use `respondsToSelector:` before every message to Spotify, wrap the work in `@try`, and
   restore Spotify's own state when the addon is off. Listen for `MRGSettingsChangedNotification` to react to
   installs and setting changes.
2. Add the id to `MRGAddonBuiltIn()` in `mirage/Sources/MRGAddons.m`. If it has settings, give it a settings row
   and page there, like Vinyl's.
3. Add an entry to `addons/index.json`:

   ```json
   {
     "id": "my-addon",
     "name": "My Addon",
     "description": "What it changes, in a sentence or two.",
     "preview": "https://raw.githubusercontent.com/x4nzz/Mirage/main/addons/previews/my-addon.png",
     "version": "1.0",
     "type": "Now Playing",
     "author": "you",
     "min_mirage": "0.6.0"
   }
   ```

   `min_mirage` is the first Mirage version that carries it; older builds show "Update Mirage".
4. Add a 16:9 preview (1200×675 PNG) in `addons/previews/`. Previews are cached per id and version, so bump
   `version` when you change the picture.
5. Update the built-in copy (`kBundledIndex` in `MRGAddons.m`) to match `index.json`.
