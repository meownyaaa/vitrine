# Mirage DJ (AI DJ, bring your own key)

Mirage DJ, added in 0.2.0, picks 8–10 tracks that suit what you've been listening to and plays them in Spotify's own player. Between tracks it says a short line, the way a radio DJ would. The words come from an AI provider you choose, using your own API key.

## Using it

1. Go to **Mirage settings → AI DJ → API key** and paste a key. Mirage works out the provider from the key, reads that provider's model list, picks a fast, cheap chat model (marked ✦) and checks that the key works.
2. If you want a different model, choose it under **Model**.
3. To start a set, tap the **DJ** pill on Home or **Open Mirage DJ**. Use **Switch it up** for a new set, or type a request ("90s r&b for a rainy night") and send it.
4. Under **Voice** you can pick:
   - **Phone**: the best voice installed on the device, which is offline and free. Premium and Enhanced voices sound much better; add them in iOS Settings → Accessibility → Spoken Content → Voices.
   - **Provider**: OpenAI or Gemini speech, with Phone as the fallback.
   - **Off**: text only.
5. **Lower music while talking** turns Spotify's own audio down to about 30 % while the DJ speaks, then brings it back up. The music keeps playing underneath.

## What leaves the phone

The key is kept in the iOS keychain. If the sideloaded app has no keychain access, it goes in a file only the app can read.

Mirage sends your provider only:
- track and artist names: what's playing, what you played recently, your top and liked tracks
- the request you type

Your account, your device and your listening times are never sent.

## Provider detection

| Key prefix | Provider | Base URL | Model list |
|---|---|---|---|
| `AIza` | Google Gemini | generativelanguage.googleapis.com/v1beta | `GET /models` (`generateContent` capable) |
| `sk-ant-` | Anthropic | api.anthropic.com/v1 | `GET /models` |
| `sk-or-` | OpenRouter | openrouter.ai/api/v1 | `GET /models`; key checked with `GET /key` |
| `gsk_` | Groq | api.groq.com/openai/v1 | `GET /models` |
| `xai-` | xAI | api.x.ai/v1 | `GET /models` |
| `pplx-` | Perplexity | api.perplexity.ai/v1 | `GET /models` (public); key checked with a 1-token `POST /agent` |
| `csk-` | Cerebras | api.cerebras.ai/v1 | `GET /models` |
| `fw_` / `fw-` | Fireworks | api.fireworks.ai/inference/v1 | `GET /models` |
| `tgp_v1_` / `tgp_v1-` | Together | api.together.xyz/v1 | `GET /models` (bare array, `type: chat`) |
| `sk-` + 32 hex | DeepSeek | api.deepseek.com | `GET /models` |
| `sk-proj-` / `sk-` | OpenAI | api.openai.com/v1 | `GET /models` |

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

Chat requests use these APIs:
- OpenAI-compatible `chat/completions` with `response_format: json_object`. If the provider returns HTTP 400, Mirage retries once with a plain request.
- Gemini `generateContent` with `responseMimeType: application/json`.
- Anthropic `messages`.
- Perplexity `agent`.

Reasoning models (gpt-5/6, o-series, gpt-oss) get `reasoning_effort: low`.

Errors are shown in plain words:
- invalid key (401/403)
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

## How a set plays

1. **Taste.** Mirage gathers:
   - the current track
   - recently played tracks seen by Mirage, or the Web API's recently-played list
   - your top tracks and artists
   - your liked tracks
   - names only
2. **Model.** The model returns JSON: `intro`, then `tracks[{title, artist, line}]`. Each line is one or two casual sentences.
3. **Resolve.** Each pick is looked up with Spotify search: first a strict `track:"…" artist:"…"` query, then a loose one, matched on normalized names. Picks that don't resolve are dropped.
4. **Play.** Mirage first tries Spotify's own player directly, `SPTEsperantoPlayer playContext:` with a track-list context. If that is refused, it fills a private **Mirage DJ** playlist in your library and plays that.
5. **Talk.** Each line is spoken about 0.8 s after its track starts. Nothing is said over ads.
6. **Keep going.** When the last track starts, the next set is prepared. Once Spotify's autoplay takes over, the next set starts.

## Spotify Free

- Free accounts can't always play exact tracks on demand. If the direct play is refused, the Mirage DJ playlist is used instead, and Spotify may **shuffle** it. A line can then be spoken over a different track than the one it was written for, so Mirage only speaks lines for tracks that are actually playing.
- Spotify's skip limit (about 6 an hour) still applies. **Switch it up** starts a new set, which can count as a skip.
- Ads play as normal. The DJ stays quiet during ads and doesn't lower the volume for them.
- Mirage doesn't add Premium features. It doesn't block ads.

## Verified vs not yet verified

Verified:
- Every source file compiles into the 0.2.0 IPA.
- Model-picking logic was tested against sample model lists.
- Endpoint shapes and model names were taken from the provider docs above.

Not yet verified on a device:
- Direct `playContext` on Free vs Premium
- whether Spotify's in-app token is accepted by the Web API calls (search, playlist)
- ducking on every output route (Bluetooth/AirPlay)
- keychain access under Ksign signing
- provider TTS playback
