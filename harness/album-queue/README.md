# Album queue

With Spoof Premium on, an album page's header menu gets an **Add to Queue** fallback when Spotify
omits its own row. The backend resolves the album through Spotify's signed-in context resolver and
passes its ordered track list to `SPTPlayerQueueWrapperImpl.queueMultipleTracks:loggingParams:`.
It does not change account attributes, `offline`, or player restrictions.

The native header records its original menu button immediately before UIKit dispatches its
registered touch-up or primary action, through either target/selector or UIAction. The
redesign marks that original button immediately before its mirror fires it. One menu appearance
consumes one marker. Identity comes from the named Swift fields `template.creativeWork.uri` on the
Creative Work page and must match its header's `Components.UI.ContextMenuButton-<album id>`.
A changed model shape yields no fallback. No song menu is inferred to be an album menu.

## Local checks

Run from the repository root:

```sh
harness/album-queue/build.sh
harness/album-queue/build-activation.sh
scripts/check-layers.sh tweak/Sources
env -u MAKELEVEL gmake -C tweak clean package
```

The Mac harness runs the production context parser and Swift page reader: 17 context checks and
4 page identity checks. They cover disc/page order, repeated tracks, wrong response identity,
malformed entries, invalid URI types and characters, missing pages and pagination. Parsing fails
as a whole, so a valid prefix of a malformed album is never submitted.

The activation harness compiles the production native Logos hook into a UIKit simulator app.
Install and launch `harness/album-queue/build/activation/AlbumActivation.app` with `simctl` using
bundle ID `com.vitrine.albumactivation`; its console reports nine checks. It checks a two-second
hold before release, target/selector and UIAction dispatch without touch-down, source availability
inside the handler, cancellation and unrelated controls. A direct UIKit `accessibilityActivate`
call returned NO in this standalone app, so this verifies the action dispatch paths rather than
end-to-end VoiceOver activation. Live Spotify holds and physical-device VoiceOver remain untested.

The system menu harness supplies a no-op album installer for its existing player-menu fixtures.
The album action itself is exercised in Spotify, not by that stub.

## Simulator evidence, 2026-10-15

Spotify 9.1.90, existing signed-in iPhone 18 Pro Max simulator, iOS 27 runtime, playback paused:

- Context resolution of DAMN. returned HTTP 200 and 14 ordered track URIs.
- A direct single-item queue request using an album URI only inserted an album placeholder. That
  path is not used by the feature.
- The native bulk method completed without error. Readback preserved the existing 37 queued tracks
  as an identical prefix and inserted the exact 14 album track URIs immediately afterward, in order.
  The following context tracks remained in order in the observed 80-item queue window.
- The redesigned album menu's new row was tapped through `scripts/phone.py menu.pick 'Add to Queue'`.
  It reported `album queue: 14 tracks added`; queue readback matched the same prefix/order checks.
- The native album menu also shows the fallback in its footer. Tapping it reported 14 tracks added;
  readback passed the same prefix, exact album order and following-context checks.
- A song's own menu had no `spotifyglass.albumQueue` control.
- With Spoof Premium off, the redesigned album menu had no fallback control.
- The normal tweak package and the existing system-menu harness both build. The system-menu
  `rows` regression scenario passed all 15 checks.
- Test queues were saved with `getQueueWithCallback:` and restored with `setQueue:` using the latest
  revision. After each menu test, all 80 observed entries matched its saved queue.
  Both changed preferences were restored from their saved values.

Simulator setup and its private authentication headers stay local. Never print the headers or export
a driver build. Port 8088 is the test simulator; use the recorded native tab identifier
`TabBar.Item.Search` when the driver's generic `tab Search` cannot find the native bar.

## Remaining limits

Physical iPhone behavior and Spotify 9.1.78/9.1.88 have not been validated for this addition. The native
queue command retains Spotify's own capacity and rejection behavior. Album responses with a nonempty
`next_page_url`, unresolved pages, no tracks, or over 5000 tracks currently fail before submission;
they are not partially queued. The action is on the album page's header menu, not every album card's
context menu elsewhere in the app.
