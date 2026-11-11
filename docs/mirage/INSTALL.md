# Installing Mirage with Ksign

`Mirage-9.1.90.ipa` is Spotify 9.1.90 with **Vitrine** and **Mirage** injected. It is unsigned (fakesigned),
so Ksign signs it with your own certificate.

1. Get the IPA onto the iPhone. AirDrop it, save it to Files, or open a download link in Safari.
2. Open **Ksign**, then **Files** (or **Import**), and pick `Mirage-9.1.90.ipa`.
3. Tap the imported app, then **Sign**:
   - Certificate: your AppTesters certificate.
   - Bundle ID: either keep `com.spotify.client` or change it. If you change it, the lock screen
     "Now Playing" card can't reopen the app. Vitrine's README explains why. A different ID does let it install next to an
     existing Spotify.
   - Leave the tweak injection options **off**. Vitrine, Mirage and the CydiaSubstrate shim are already inside.
4. Tap **Install**. The first time, iOS may ask you to trust the certificate under
   Settings → General → VPN & Device Management.
5. Open Spotify. Tap your avatar (top left) to open the side drawer. **Mod Settings** is Vitrine and
   **Mirage** sits right below it.

## Using backgrounds

Go to Mirage, then **Choose from Photos** or **Choose from Files**:

- **Images**: PNG, JPG and HEIC. They are resized to your screen and saved in Spotify's Documents/Mirage folder.
- **GIFs**: converted once into a looping MP4, which is much lighter on the battery than a live GIF.
- **Videos**: MP4 and MOV. They play muted from the video track only, never touch Spotify's audio or AirPlay,
  and pause while Spotify is in the background.

Then set **Blur**, **Dim**, **Scale** (Fill / Fit / Stretch) and where the background shows (**Home**, **Now Playing**, **Library**,
**Everywhere**). **Clear page backgrounds** makes Spotify's own page fill see-through, so the background shows behind
the content and Vitrine's glass.

## SideStore

To debug with `get-task-allow`, sign the same IPA in SideStore instead. Nothing else changes.

## Updating

Install a newer `Mirage-*.ipa` over the old one with the same bundle ID and certificate. Your settings and picked
backgrounds stay, because they live in the app's own container.
