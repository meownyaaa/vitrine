# Mirage DJ (AI DJ, bring your own key)

Mirage DJ, added in 0.2.0, plans a set and picks about 15 tracks that suit what you've been listening to and what you ask for, and plays them in Spotify's own player. Between tracks it says a short line, the way a radio DJ would, in the persona you choose. Since 0.3.0 you can also chat with it: ask about your listening, have it play or queue songs, and create or change playlists. The words come from an AI provider you choose, using your own API key.

## What's new in 0.4.4 (ElevenLabs presets)

- **Why Arabella sounded like Samantha**: picking a preset wrote the ElevenLabs voice but never switched the engine to
  ElevenLabs, so the iPhone voice (Samantha) kept speaking; and when ElevenLabs refused a line, Mirage quietly spoke it
  with the iPhone voice. Shared Voice Library voices also need a paid ElevenLabs plan through the API (free keys get
  HTTP 402 `paid_plan_required`; only premade voices work for free).
- Presets built on an ElevenLabs voice now switch the engine to ElevenLabs. If ElevenLabs refuses, nothing is spoken by
  the phone instead: the DJ sheet and the voice page show ElevenLabs' error in plain words with its status and code
  (and the full response body goes to the log).
- Picking such a preset adds its voice to your ElevenLabs voices when it isn't there yet (`GET /v1/shared-voices`, then
  `POST /v1/voices/add/{public_user_id}/{voice_id}` with `new_name`), then tests it. Nicole is one of ElevenLabs' old
  default voices being retired; if the library no longer has her, Classic Whisper takes the closest current female
  whisper voice from a library search.
- The Presets section says what is speaking now ("ElevenLabs · Arabella") and the last test's result ("✓ … spoke" or
  "✗ <the exact error>").

## What's new in 0.4.3 (bug fixes)

- **Crash when tapping a song** ("Assertion failure: tracks, SPTPlayerQueueWrapperImpl.m:174"): Spotify's queue wrapper
  (`queueMultipleTracks` → `queueTracksInternal` → `fetchQueueInternal`, and `fetchQueue`) chains on its own queue fetch
  and asserts the queue it gets back has tracks. Right after a context change (a tapped row) that queue isn't there,
  and 0.4.2 fired a fetch, a clear and a queue at exactly that moment. The throw happens in Spotify's later main-queue
  callback, so no `@try` can catch it. Now every queue command runs one at a time and waits until the player has
  settled (a track and an up-next list in its state, 1.5 s after the last play); the sync reads the queue from the
  player's state (`SPTPlayerState.future`) without calling Spotify; clearing uses the player's own `fetchQueue:on:` and
  `setQueue:` (0.4.2's wrapper `fetchQueue` returned a read-only `SPTPlayerQueueSnapshotImpl`, so every clear failed);
  only real `SPTPlayerTrack`s with a valid URI are ever sent, never an empty list; and a queue that isn't ready or
  can't be cleared falls back to step mode instead of being retried.
- **Start played the old vibe**: with an old set still listed, Start meant "Switch it up", which kept the earlier
  request ("the playlist clairo"); and no-request sets seeded from the three most played artists. Now Start is a fresh
  set seeded from the song playing now (the intro names it); Switch it up only applies while the set is playing and
  only keeps constraints like "underground"; stopping or a new request forgets the old focus, plan and pool; history
  adds at most 2 picks. Spotify's related-artists endpoint answers 404 to the app's token, so a small pool is only a hint.
- **Voice presets change only the voice**, never the persona or the music (0.4.2's Soft & soothing persona leaked into
  the sets).
- **ElevenLabs presets by ID**: *Soft & Close* (Ivy, `KhpuFRhu6kfNvpalcYtz`), *Classic Whisper* (Nicole,
  `piTKgcLEGmPE4e6mEKli`), *Playful Spark* (Arabella, `Z3R5wn05IrDiVCyEkUrK`). The picked voice is never swapped for
  another; when it isn't in your ElevenLabs voices the voice page says so and offers **Add to my ElevenLabs**
  (`GET /v1/shared-voices`, then `POST /v1/voices/add/{public_owner_id}/{voice_id}`, only when tapped).
- The vibe box understands "skip", "pause", "go back" and the like as player controls.

## What's new in 0.4.2

- **Queue sync**: Spotify can accept a queue command and not apply it, and a play can wipe the queue, so the set sheet no
  longer trusts commands. After queueing, after every track change and every 25 s, Spotify's real queue is read back
  (`SPTPlayerQueueWrapperImpl fetchQueue`, tracks with provider `queue`) and compared with what's left of the set. Each
  row says *pending…*, *in queue* or *not queued · Mirage plays it*. Missing songs: the queue's set songs are cleared and
  the rest of the set re-sent in order (songs you queued yourself are kept after them), twice per set at most; after that,
  step mode (Mirage plays each next song itself when the last one ends). If you reorder the queue in Spotify, the set
  follows your order. Log lines start with `sync:`.
- **On-topic picks**: every set has concrete seeds (the artist you asked for; otherwise what's playing and your most played
  artists lately). Their Spotify related artists (or a genre search when related-artists is closed), scored by how many
  seeds share them, plus your own repeats, form a pool the model must pick from. With no request or an artist request
  at most 3 picks may come from outside the pool; the rest are thrown out and replaced. `picks:` lines.
- **The vibe box answers questions**: "who is clairo", "what's this song", "why is this called shoegaze?" are answered (DJ
  card, spoken, and in the chat) without touching the music. Anything that asks for music, or reads like a vibe, still
  plays music. `vibe box: "…" → music | artist question | song question | question`.
- **Artist and song info** (`artist_info` in the chat, and the vibe box): Spotify (picture, followers, genres,
  popularity, top tracks, monthly listeners from the public artist page when it answers), Wikipedia's REST summary (only a
  music page), and with Gemini also Google Search grounding. The card lists its sources; answers use only those facts.
  `info:` lines.
- **Two new voice presets**: *Warm Velvet* (very soft, slow, close and caring) and *Playful Spark* (young, bright, very
  expressive). When the matching ElevenLabs voice isn't in your account, the preset uses the shared-library voice by ID
  (Mia, Arabella; paid ElevenLabs plans can do that).

## What's new in 0.4.1

- **One artist resolver for every entry point** (the sheet's "Ask for a vibe", the chat, play_artist, start_dj_set):
  Spotify's artist search first; when that match is weak (nothing, a tiny artist, a short abbreviation, or only found
  through a track) the model reads the text with your top artists, and labels / crews count: "yvl" is Playboi Carti's
  Young Vamp Life imprint, not the 13-listener artist called YVL. A label's roster also comes from an album search on
  `label:"…"`. Each request logs one `focus: "<what you typed>" → <artist> (<spotify:artist:…>) via …` line.
- **"play <artist>" plays their catalog**: top tracks, then albums and singles newest first (`/artists/{id}/albums`,
  `/albums/{id}/tracks`), de-duplicated by title, up to 80 songs (pages of an `artist:"Name"` search when those endpoints
  are closed); a label / crew takes each artist's top tracks in turns. A few songs before the end the next set (artists
  like them, none of their own songs) is picked and queued behind it, and so on.
- **The queue is replaced** on every new vibe, chat request, artist, Switch it up and playlist: Spotify's queue is read
  (`SPTPlayerQueueWrapperImpl fetchQueue`), the tracks whose provider is `queue` are dropped and it's sent back with the
  player's `setQueue:` before the new set plays (`queue: clear …` lines).
- **Playlists, albums, Liked Songs**: the chat's new `play_context` tool plays them as Spotify's own context
  (`playContext:options:origin:`, with `SPTPlayerOptionOverrides.shufflingContext` for shuffle). Your playlists are found by
  name in your library (spclient `GET /playlist/v2/user/<you>/rootlist?decorate=…`), then by search. Liked Songs is
  `spotify:user:<you>:collection`, then `spotify:collection:tracks`. The chat never tells you to tap something yourself.
- **Rate limits**: a provider's 429 that says how long to wait ("Please try again in 7.5s", Groq's tokens-per-minute
  limit, which was the red chat bubble) is retried after that wait, twice at most; chats keep fewer old messages and cut
  long tool results.
- **Voice presets and finer controls** (AI DJ → Voice): Soft & Soothing, Hype Radio DJ, Late Night, Chill Narrator, Classic
  Spotify DJ. A preset sets speed, pitch, warmth, breathiness, pauses, a voice style, a voice for every engine and the
  persona (a new "Soft & soothing" persona). Warmth, breathiness, pitch and the free-text Voice style go to OpenAI
  (gpt-4o-mini-tts `instructions`) and Gemini as speaking instructions; iPhone voices use speed, pitch and sentence
  pauses; ElevenLabs gets stability, similarity, style and `<break>` pauses; xAI speed; Groq and xAI pauses as ellipses.

## What's new in 0.4.0

- **Artist requests are that artist.** "play some yvl", "only pz", "stuff like clairo": Mirage finds the artist on Spotify
  (artist search as typed and in capitals, the closest name or matching initials, then a track search, then a combined
  search, then your provider is asked to expand the abbreviation and Spotify is searched again), fetches their tracks
  (top-tracks, or an `artist:"Name"` search) and related artists, and the set has to be theirs: at least 7 of 15 by them
  (all for "only", 2-3 for "like"); when the model's picks fall short, their own tracks are woven in.
- **Taste from what you play**: on repeat (last 4 weeks of Mirage's recording), top artists lately and all time, and
  throwbacks (well played, not for 4 months) go into every set and the chat. With no request it mixes like Spotify's DJ.
- **Talks like you** (AI DJ → Talk like me, on by default): your last 30 chat messages, kept on the phone, are given to
  the model as samples of how you write.
- **Chat**: tool calls a model writes as text (Harmony, `<tool_call>`, JSON, `name(args)`, `name: key: value`) are run as
  calls and never shown; Groq's `tool_use_failed` answers are recovered from `failed_generation`; invalid arguments are
  sent back for a retry; up to 9 steps. New tools: play_artist, dj_segment (throwbacks, on repeat, discover, favorites),
  switch_it_up, player_control (next, previous, pause, resume), like_track, taste_profile.
- **Playlists** go through Spotify's playlist v2 API on its spclient host with the app's own headers first
  (`POST /playlist/v2/playlist`, `POST /playlist/v2/user/<you>/rootlist/changes`, `POST /playlist/v2/playlist/<id>/changes`),
  and the Esperanto calls as the fallback. Every request and answer is in the DJ log (`playlists:` lines).
- **Playback**: when the set's first track is loaded but paused, Mirage presses play (up to twice) before giving up.
- **Matching**: fuzzy titles and artists (edit distance, "feat."/"&"/"x" splits, "&" = "and"), and a third, title-only search.
- **Settings**: every DJ setting is on its own AI DJ page; Mirage's settings keep one AI DJ row, and the DJ sheet and the
  chat have a settings button.

## Using it

1. Go to **Mirage settings → AI DJ → API key** and paste a key. Mirage works out the provider from the key, reads that provider's model list, picks a fast, cheap chat model (marked ✦) and checks that the key works. If it can't tell (Mistral keys have no prefix) or guesses wrong, pick it under **Provider**; with a key already saved, that re-checks the saved key as the provider you picked. Errors show the provider's HTTP status and its own message.
2. If you want a different model, choose it under **Model** (the provider's live model list).
3. Open the DJ from any of these places:
   - **Home:** the **✦ DJ** chip at the end of Home's filter chips (All, Music, Podcasts…). With Vitrine's redesign, which swaps the chips for a title, the chip sits in the title row immediately left of the glass menu/avatar pill, as tall as it and centered on it. It is re-placed on every layout pass and every move of that pill, and stays hidden until the pill is laid out below the status bar (0.2.2 could show it at the top-left over the status bar on first launch). If the chips are hidden by Vitrine's setting, it sits where they would start.
   - **Now Playing:** the **✦** button in the top bar, 8 pt left of the ⋯, in a glass circle the same size as the ⋯'s (the same glass effect when Vitrine gives the ⋯ one). Its glyph is white, in the accent only while a set is on. It sits outside the header stack, so Spotify's title stays centered; the title gets a width cap so it never runs under the button. **Long-press** it to open the chat.
   - **Settings:** **Open Mirage DJ**, or **Chat with your DJ**.

   The chip and the button's glyph take the accent color while a set is on. On Now Playing, the line also shows in a small glass "DJ" caption under the top bar while the DJ talks.

   In the sheet:
   - Use **Switch it up** for a new set in a clearly different direction (the last plan is sent along with "don't repeat that direction"; the hard constraints of your last request, like "underground", are kept), or type a request ("90s r&b for a rainy night") and send it with the accent send button.
   - The chat button in the sheet's title row opens the chat.
   - The set is listed with covers. Tap a song to jump to it; Spotify Free may refuse.
   - **DJ chip on Home** and **DJ button on Now Playing** in settings turn each one off.
4. **Voice** (its own page):
   - **iPhone voice**: every installed English voice (and your phone's language), best first: Personal Voice (after you allow it on the page), Premium, Enhanced, Default, each with its quality. Tap one to hear it. Better voices download in iOS Settings → Accessibility → Spoken Content → Voices.
   - **AI provider voice**: OpenAI (`gpt-4o-mini-tts`; alloy, ash, ballad, coral, echo, fable, nova, onyx, sage, shimmer, verse, marin, cedar), Gemini (`gemini-*-flash-*-tts`, 30 prebuilt voices such as Puck, Kore, Zephyr), xAI (`POST /v1/tts`, voices listed live from `GET /v1/tts/voices`), Groq (`canopylabs/orpheus-v1-english`: troy, austin, daniel, autumn, diana, hannah; lines cut to 200 characters). Tap to preview.
   - **ElevenLabs**: paste an ElevenLabs key on the page; Mirage checks it with `GET /v1/voices` (header `xi-api-key`), lists your voices, and speaks with `POST /v1/text-to-speech/{voice}` (`eleven_flash_v2_5`, falling back to `eleven_multilingual_v2`). The key goes in the keychain under its own entry.
   - **Off**: captions only.
   - **Speed** (0.7–1.5×, every engine; ElevenLabs is capped at 1.2) and **Pitch** (iPhone voices only), with a **Preview** row. If a network voice fails, the iPhone voice speaks instead and the debug log says why.
5. **Vibe** (its own page):
   - Persona: Classic, Chill radio host, Hype, Underground curator, Storyteller, Minimal. Each changes how the DJ talks and how long its lines are (from 8 words for Minimal to 40 for Storyteller). Underground curator also caps picks at Spotify popularity 65.
   - How often it talks: Auto (follows the persona), Every track, Every few tracks (the first and then every third), Only on switches (the first track of a set).
   - Your instructions: free text appended to the base prompt for picks and the chat.
6. **Lower music while talking** turns Spotify's own audio down to about 30 % while the DJ speaks, then brings it back up. The music keeps playing underneath.

## What leaves the phone

The keys (AI provider, ElevenLabs) are kept in the iOS keychain. If the sideloaded app has no keychain access, they go in files only the app can read.

Mirage sends your AI provider only:
- track and artist names: what's playing, what Mirage saw you play recently, and what's around it in Spotify's queue
- what you type (requests, chat messages, your Vibe instructions)
- in the chat, the answers a question needs from your listening history (for "when did I first play X": that artist's first date, track, play count and minutes; for "top artists of 2023": that list), and the date range the history covers

ElevenLabs (if you add a key) gets only the lines the DJ says. Your account, your device and your full listening history are never sent.

## Listening history (for the chat)

Spotify's app keeps no full listening history that Mirage can read, so the chat answers from what is on the phone, and says so when it doesn't know:
- **Mirage's own recording**, from the moment 0.3.0 runs: every track that starts (timestamp, title, artist, URI), with the time until the next track as time played, capped at the track's length (a long pause inside a track overcounts it). A play counts at 30 s, like Spotify's exports. Stored in `Library/Mirage/history.plist`.
- **Imported Spotify data**: Settings → Mirage → AI DJ → **Listening history** → Import. Pick the *Extended streaming history* ZIP or its `Streaming_History_Audio_*.json` files (fields `ts`, `master_metadata_track_name`, `master_metadata_album_artist_name`, `spotify_track_uri`, `ms_played`; `ts` is when a stream ended, so the start is `ts − ms_played`), or the shorter *Account data* `StreamingHistory_music_*.json` files (`endTime`, `artistName`, `trackName`, `msPlayed`). ZIPs are read from their central directory (stored or deflated entries; ZIP64 isn't supported). Podcast and audiobook rows are skipped. A file already imported (same name and size) is skipped, and imported plays from after Mirage started recording are skipped, so nothing counts twice.
- The page shows what the history covers and can remove imports or everything.

## The chat

Settings → **Chat with your DJ**, the sheet's chat button, or a long-press on Now Playing's ✦. The provider gets tools in its own function-calling format (OpenAI-compatible `tools`/`tool_calls` for OpenAI, OpenRouter, Groq, xAI, Mistral, DeepSeek, Cerebras, Fireworks and Together; Anthropic `tool_use`/`tool_result`; Gemini `functionDeclarations`/`functionCall`/`functionResponse`, with the model's parts, thought signatures included, echoed back). Perplexity has no function calling there, so it chats without actions. At most 6 tool rounds per message.

| Tool | What it does |
|---|---|
| `search` | Web API search (tracks, artists, albums, playlists), with popularity |
| `play_tracks` / `queue_tracks` | play as a DJ set / add to Spotify's queue (internal player) |
| `start_dj_set` | a full DJ set from a request |
| `now_playing` | the current track, context and DJ set |
| `first_played`, `track_stats`, `top_listening`, `history_overview` | answers from the history above |
| `create_playlist`, `add_to_playlist`, `remove_from_playlist` | Spotify's playlist engine (below) |
| `delete_playlist` | only shows a **Delete** / **Cancel** card; nothing is deleted until you tap Delete |
| `list_playlists` | playlists Mirage made, and the one playing |

Cards: **First played** (the artist's picture in a circle, the date, the first track with a play button, plays and minutes since), track lists with covers and play buttons, playlist results, the delete confirmation, and top lists.

## Playlists

Changes go through Spotify's own playlist engine, the way the app makes them, never the Web API:
- the transport is `SPTEsperantoTransportBridgeImpl` (`-callSingle:method:payload:onResponse:`, the ObjC bridge every `ESP*ClientImpl` uses). Mirage keeps the instance Spotify itself calls, and records the playlist service methods Spotify uses (logged once each).
- **Create**: `spotify.playlist_esperanto.proto.RootlistModificationService` / `Modify` with a `RootlistModificationRequest { request: ModificationRequest { operation: "create", before: "start", name, playlist: true, create_item_kind: PLAYLIST } }`, retried without a position; the answer's `ModificationResponse.uri` is the new playlist.
- **Add tracks**: `spotify.playlist_esperanto.proto.PlaylistService` / `Modify` with `PlaylistModificationRequest { uri, request: { operation: "add", after: "end", uris } }`.
- **Remove tracks**: their rows first (`PlaylistService` / `Find`, `PlaylistFindRequest { playlist_uri, item_uris }` → `ItemUriToRowIds`), then `Modify` with `operation: "remove"`, `uris` and `rows`.
- **Delete**: `RootlistModificationService` / `Modify` with `operation: "remove"`, `uris: [playlist]`: removes it from your library (for your own playlist that's Spotify's delete, recoverable at spotify.com/account/recover-playlists; for someone else's, an unfollow).
- Payloads are hand-encoded protobuf from the schemas embedded in the app (`rootlist_modification_request.proto`, `playlist_modification_request.proto`, `modification_request.proto`, `playlist_find_request.proto`). The method names `Modify` and `Find` follow the app's ESP naming (PascalCase rpc names such as `GetImage`); Swift keeps names this short inline, so they couldn't be read from the binary, and the names Spotify is seen using are preferred at runtime.
- Mirage can't list your whole library (that needs the rootlist's own format); it knows the playlists it made, the one playing, and any you give by link. Every attempt and answer is in the debug log.


## Provider detection

| Key prefix | Provider | Base URL | Model list |
|---|---|---|---|
| `AQ.` / `AIza` | Google Gemini (AI Studio) | generativelanguage.googleapis.com/v1beta | `GET /models` (`generateContent` capable); key in `x-goog-api-key`, retried once as `?key=` |
| `sk-ant-` | Anthropic | api.anthropic.com/v1 | `GET /models` |
| `sk-or-` | OpenRouter | openrouter.ai/api/v1 | `GET /models`; key checked with `GET /key` |
| `gsk_` | Groq | api.groq.com/openai/v1 | `GET /models` |
| `xai-` | xAI | api.x.ai/v1 | `GET /models` |
| `pplx-` | Perplexity | api.perplexity.ai/v1 | `GET /models` (public); key checked with a 1-token `POST /agent` |
| `csk-` | Cerebras | api.cerebras.ai/v1 | `GET /models` |
| `fw_` / `fw-` | Fireworks | api.fireworks.ai/inference/v1 | `GET /models` |
| `tgp_v1_` / `tgp_v1-` | Together | api.together.xyz/v1 | `GET /models` (bare array, `type: chat`) |
| `sk-` + 32 hex | DeepSeek | api.deepseek.com | `GET /models` |
| `sk-proj-` / `sk-svcacct-` / `sk-` | OpenAI | api.openai.com/v1 | `GET /models` |
| none (32 chars), chosen by hand | Mistral | api.mistral.ai/v1 | `GET /models` |

Google AI Studio has issued `AQ.…` keys by default since May 2026 and is phasing out the older `AIza…` keys; 0.2.x didn't recognise `AQ.` and called the key invalid. Pasted keys are cleaned of spaces, line breaks and invisible characters first.

The recommended model is the first match, in order, against each provider's preference list below.
- Embeddings, speech, image, search, realtime and "thinking" models are left out.
- Among matches, stable models beat previews, newer versions beat older ones, and aliases beat dated snapshots.

| Provider | Preference order (Nov 2026) |
|---|---|
| OpenAI | gpt-4.1-mini, gpt-6-luna, gpt-5.x-mini, gpt-4o-mini, gpt-5-nano … |
| Gemini | newest gemini-*-flash-lite, then gemini-*-flash |
| Anthropic | newest claude-haiku-*, then sonnet |
| OpenRouter | google/gemini-*-flash-lite, openai/gpt-4.1-mini, anthropic/claude-haiku-* … |
| Groq | openai/gpt-oss-120b, openai/gpt-oss-20b, qwen/qwen3* (llama-3.3-70b and 3.1-8b were shut down 2026-08-16) |
| xAI | grok-4.3 (reasoning_effort none), grok-4.20-*-non-reasoning, then other grok-4 models (grok-4-fast and 4-1-fast were retired 2026-05-15) |
| Perplexity | perplexity/glm-*-flash, openai/gpt-6-luna, google/gemini-*-flash, perplexity/sonar, through the Agent API (`POST /v1/agent`, Responses shape) |
| Cerebras | gpt-oss-120b, llama-3.3-70b, qwen-3-* |
| Fireworks | accounts/fireworks/models/gpt-oss-120b / 20b … |
| Together | openai/gpt-oss-120b, Llama-3.3-70B-Instruct-Turbo … |
| DeepSeek | deepseek-chat, deepseek-flash* |
| Mistral | mistral-small-latest, mistral-medium-latest, ministral-8b-latest … |

Chat requests use these APIs:
- OpenAI-compatible `chat/completions` with `response_format: json_object`. If the provider returns HTTP 400, Mirage retries once with a plain request.
- Gemini `generateContent` with `responseMimeType: application/json`.
- Anthropic `messages`.
- Perplexity `agent`.

Reasoning models (gpt-5/6, o-series, gpt-oss) get `reasoning_effort: low`.

Errors are shown in plain words, always with the HTTP status and the provider's own message when it sends one:
- key refused (401/403)
- out of credit (402)
- rate limited (429, try again in a minute)
- provider down (5xx)
- offline

Sources (checked November 2026):
- OpenAI: [models](https://platform.openai.com/docs/api-reference/models/list), [speech](https://platform.openai.com/docs/api-reference/audio/createSpeech)
- Google: [Gemini models](https://ai.google.dev/api/models), [Gemini TTS](https://ai.google.dev/gemini-api/docs/speech-generation)
- Anthropic: [models](https://docs.anthropic.com/en/api/models-list), [messages](https://docs.anthropic.com/en/api/messages)
- OpenRouter: [models](https://openrouter.ai/docs/api-reference/list-available-models), [key](https://openrouter.ai/docs/api-reference/limits)
- Groq: [models](https://console.groq.com/docs/models), [deprecations](https://console.groq.com/docs/deprecations)
- xAI: [models](https://docs.x.ai/docs/models)
- Perplexity: [Agent API](https://docs.perplexity.ai/)
- Cerebras: [models](https://inference-docs.cerebras.ai/api-reference/models)
- Fireworks: [API](https://docs.fireworks.ai/api-reference)
- Together: [models](https://docs.together.ai/reference/models-1)
- DeepSeek: [API](https://api-docs.deepseek.com/)
- Mistral: [API](https://docs.mistral.ai/api/)
- xAI speech: [TTS](https://docs.x.ai/docs/guides/text-to-speech); Groq speech: [TTS](https://console.groq.com/docs/text-to-speech); ElevenLabs: [voices](https://elevenlabs.io/docs/api-reference/voices/search), [TTS](https://elevenlabs.io/docs/api-reference/text-to-speech/convert)

## How a set plays

1. **Taste.** As of 0.2.3 it comes from Spotify's own player only, names only:
   - the current track (`SPTPlayerState.track`)
   - the tracks Mirage saw play (kept on the device, `mirage.dj.history`)
   - what's before and after it in the queue (`SPTPlayerState.reverse` / `future`)

   The Web API's user endpoints (`/me`, `/me/top`, `/me/tracks`, recently-played, `/me/playlists`) answer 404 to the app's token, so Mirage no longer calls them.
2. **Model.** The prompt treats every constraint in the request (genre, scene, era, mood, energy, "underground", "no hits", "like X") as a hard rule, anchors on what you play, avoids the obvious (no artist's biggest hits, at most 2 songs per artist), and appends your Vibe instructions. The model returns JSON: a `plan` first (the set's direction), `intro`, then 15 `tracks[{title, artist, line, why}]`.
3. **Resolve.** Each pick is looked up with the Web API's track search (the one Web API call that works with the app's token): first a strict `track:"…" artist:"…"` query, then a loose one, matched on normalized names. The debug log says which query found it. Picks that don't resolve are dropped.
   - **Underground filter.** When the request asks for underground, obscure, deep cuts, hidden gems, no hits and the like, picks with a search popularity above 50 are dropped (65 for the Underground curator persona). If fewer than 8 are left, the model is asked once more for replacements in the same plan, told what was kept and what was thrown out. If the search doesn't give a popularity, the pick is kept and the log says so.
4. **Play.** As of 0.2.3, entirely through Spotify's internal player (`SPTEsperantoPlayer`):
   1. The first track plays as its own context: `SPTPlayerContext contextForURI:` on its `spotify:track:` URI, sent with `playContext:options:origin:` and the origin the player builds for itself (`playOriginWithViewURIOverride:externalReferrer:`). The 0.2.2 log showed this path reaching the track.
   2. Mirage watches the player's state for up to 8 s until that track is actually playing (`isPlaying`, not `isPaused`).
   3. Only then is the rest queued with `SPTPlayerQueueWrapperImpl initWithPlayer:` + `queueMultipleTracks:loggingParams:`, tried up to 3 times a second apart. In 0.2.2 the queue was sent straight after the play command and the player answered 409 Conflict.
   4. If the queue still refuses, Mirage steps through the set itself: when a set track runs out and something else starts, the next set track plays as its own context. If a set track is cut short by something you picked, the DJ steps back.
   5. The player used is the app's music player, never a DJ, preview or video feature's player (`com.spotify.service.endless.djmusic`, `aidjinteractivity_…`). The log names the feature it picked and sums up the players found once.

   0.2.2 crashed on every Start: it read `-[SPTPlayerState paused]`, a selector that doesn't exist (the getter is `isPaused`). Every message Mirage sends to a Spotify object now checks `respondsToSelector:` first and logs a missing selector once instead of crashing; the playback check runs inside `@try`.
5. **Tracks are real.** A pick only counts when Spotify's search returns a track whose title and artist both match. Made-up songs are dropped, and the set shows Spotify's own spelling.
6. **Talk.** A line is spoken about 0.8 s after its track starts, as often as the talk setting says, only while that track is actually playing (not paused, not an ad). The voice uses the system's speech session, never Spotify's audio session.
7. **Keep going.** When the last track starts, the next set is prepared. Once Spotify's autoplay takes over, the next set starts.

## Spotify Free

- Free accounts can't always play exact tracks on demand or queue tracks. Mirage only speaks lines for tracks that are actually playing.
- Spotify's skip limit (about 6 an hour) still applies. **Switch it up** starts a new set, which can count as a skip.
- Ads play as normal. The DJ stays quiet during ads and doesn't lower the volume for them.
- Mirage doesn't add Premium features. It doesn't block ads.

## Debug log

Settings → Mirage → AI DJ → **DJ debug log** shows the last 200 lines. **Copy** puts them on the clipboard so they can be sent along with a bug report. The log covers:
- Web API search calls and which query found each track
- a summary of the players found, and the feature of the one used
- any selector Spotify's objects didn't answer
- every play path tried and what the player said
- what the player was doing when verification gave up
- skipped voice lines

Since 0.3.0 it also has the set's plan, popularity drops and refills, voice fallbacks, chat tool calls, playlist calls (service, method, answer) and history imports (counts only).

It never contains keys, tokens or your listening history.

## Verified vs not yet verified

Verified:
- Every source file compiles into the 0.3.0 IPA.
- Model-picking logic was tested against sample model lists.
- Endpoint shapes and model names were taken from the provider docs above.

Not yet verified on a device:
- Direct `playContext` on Free vs Premium
- 0.2.3's track-context + queue-after-verify flow and the step fallback
- ducking on every output route (Bluetooth/AirPlay)
- keychain access under Ksign signing
- provider TTS playback (OpenAI, Gemini, xAI, Groq) and ElevenLabs
- the Esperanto playlist calls (method names `Modify`/`Find` and the request shapes are inferred from the embedded schemas and the app's naming)
- the chat's tool calling with each provider (request shapes follow each provider's docs)
- history import of a real export ZIP
- the Now Playing ✦ placement next to Vitrine's ⋯ glass, and the profile Playlists section cleared from creation
