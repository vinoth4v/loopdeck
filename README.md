# LOOPDECK

> A 4-track live audio looper that runs entirely in the browser. Zero dependencies, zero build step, one file.

**Live:** https://loopdeck-zeta.vercel.app
**Entry point:** `index.html` (self-contained: HTML + CSS + JS inline)
**Runtime:** Browser only. No server, no npm, no framework.
**License:** Use freely.

---

## AGENT ORIENTATION

If you are an AI assistant modifying this project, read this section first.

| Question | Answer |
|---|---|
| How many source files? | One: `index.html`. Everything is inline. |
| Build step? | None. Open the file or serve the directory. |
| Dependencies? | None at runtime. Two Google Fonts loaded via `<link>` (cosmetic; app works without them). |
| Where is the audio logic? | Inside the single `<script>` tag, in class `Track` and the song-recorder block. |
| Where is the layout? | Inside the single `<style>` tag. |
| Persistent state? | Only `localStorage["ld_intro"]` (whether the help strip is dismissed). Audio is never persisted. |
| Test command? | None exists. See "Verification" below for how to check changes. |

**Editing rule:** because everything lives in one file, prefer surgical string replacements over rewriting the file. The `<script>` block is ~450 lines; the `<style>` block is ~200.

**Hard constraints — do not break these:**
1. Microphone capture requires a **secure context** (HTTPS or `localhost`). On plain `http://` over a network, `getUserMedia` fails and recording silently disables.
2. `AudioContext` may only start after a **user gesture**. Every entry path calls `audio()` from inside a click/keydown handler. Do not create the context at page load.
3. The mic must **never** be routed to `ctx.destination` at non-zero gain — that causes feedback howl. Recording nodes connect to a muted sink instead.

---

## ARCHITECTURE

### Audio graph

```
                       ┌─────────────┐
  mic ──> micSource ──>│  recNode    │──> silent sink (gain 0) ──> destination
   │                   │ (per track) │     [capture only, inaudible]
   │                   └─────────────┘
   │
   │                   ┌─────────────┐
   └──> songMicGain ──>│  songNode   │──> songSink (gain 0) ──> destination
                       │  (capture)  │     [capture only, inaudible]
                       └─────────────┘
                              ▲
  Track.buffer ──> source ──> gain ──> masterGain ──> destination  [audible]
   (looping)     (per track) (fader)      │
                                          └──────────┘
```

Two capture points, both muted so they never reach the speakers:
- **`recNode`** (one per track, transient) captures mic input for a loop or overdub.
- **`songNode`** (one global, transient) captures `masterGain` + mic to produce the downloadable WAV.

`ScriptProcessorNode` is used instead of `MediaRecorder` deliberately: it yields raw `Float32Array` PCM, which allows sample-exact loop lengths and arithmetic overdub mixing. `MediaRecorder` would emit compressed chunks with container padding, producing audible gaps at the loop seam. `ScriptProcessorNode` is deprecated in favour of `AudioWorklet`; it still works in all current browsers. Migrating to `AudioWorklet` is the main modernisation task (see "Known limitations").

### Track state machine

Each of the 4 tracks is an instance of `class Track` holding one mono `AudioBuffer`. One pad button drives the whole lifecycle:

```
  empty ──tap──> recording ──tap──> playing ──tap──> overdub ──tap──┐
    ▲                                  ▲                            │
    │                                  └────────────────────────────┘
    │                                  │
  clear                              stop ──> stopped ──tap──> playing
```

| State | Pad label | Status text | Meaning |
|---|---|---|---|
| `empty` | REC | empty | No buffer. Tap starts recording. |
| `recording` | SET | recording | Capturing first layer. Tap closes the loop. |
| `playing` | DUB | looping | Loop is cycling. Tap begins an overdub. |
| `overdub` | MERGE | overdub | Capturing a layer over the cycling loop. Tap merges it. |
| `stopped` | PLAY | ready | Buffer exists, silent. Tap resumes. |

**Loop length is set by the first recording** and never changes. Overdubs wrap modulo the buffer length and are summed sample-by-sample with hard clipping to ±1. This is why layer 5 sounds louder than layer 1 — there is no normalisation or headroom management (see "Known limitations").

### Key functions

| Function | Location | Responsibility |
|---|---|---|
| `audio()` | top of script | Lazily creates `AudioContext` + `masterGain`; resumes if suspended. Call before any audio work. |
| `getMic()` | top of script | Requests mic once, caches the stream. Sets `micDenied` and reveals the warning banner on failure. Returns `null` if unavailable — callers must handle this. |
| `Track.tap()` | `Track` | The state machine dispatcher. All pad behaviour flows through here. |
| `Track.finishRecording()` | `Track` | Concatenates PCM chunks into an `AudioBuffer`. Discards takes under 150 ms. |
| `Track.finishOverdub()` | `Track` | Sums captured PCM into the existing buffer at `dubOffset`, wrapping modulo loop length. |
| `Track.play(offset)` | `Track` | Starts a looping `BufferSource` at `offset` seconds; records `startTime` for playhead math. |
| `Track.loopPos()` | `Track` | `(currentTime - startTime) % duration`. Drives the playhead. |
| `Track.computePeaks()` | `Track` | Downsamples the buffer to 128 normalised bins for the circular waveform. |
| `Track.draw()` | `Track` | Renders one canvas frame. Called for all tracks from a single global `requestAnimationFrame` loop. |
| `toggleSong()` | song block | Starts/stops whole-song capture. |
| `finishSong()` | song block | Assembles PCM, encodes WAV, triggers download. Discards takes under 200 ms. |
| `encodeWav(samples, rate)` | song block | Float32 → 16-bit mono PCM WAV `Blob`. Writes a 44-byte RIFF header. |

### Rendering

One global `requestAnimationFrame` loop calls `draw()` on all four tracks. Each canvas is resized for `devicePixelRatio` on the first frame that detects a mismatch. The circular waveform starts at 12 o'clock (`rot = -PI/2`) and advances clockwise. Played bins render at full colour, unplayed bins dimmed.

---

## USER-FACING BEHAVIOUR

- **Pad tap** — record → loop → overdub, per the state machine above.
- **Stop / Load sound / Clear** — per track. "Load sound" and drag-and-drop accept any browser-decodable audio (wav, mp3, ogg, m4a, aac, flac, webm); files are mixed to mono and resampled to the context rate via `OfflineAudioContext` if needed.
- **Play all / Stop all** — master transport. "Play all" only restarts tracks in `stopped` state.
- **Record song** — captures master mix + live mic, downloads `loopdeck-song.wav` on stop. Works without mic (instrumental only).
- **Keys** — `1`–`4` tap the corresponding pad; `Space` stops all. Suppressed while an `<input>` has focus.
- **Faders** — per-track and master, applied via `setTargetAtTime` for click-free changes.

---

## VERIFICATION

There is no test suite. To check a change:

**Static (no browser needed):**
```bash
# Confirm the script still parses
node -e "const h=require('fs').readFileSync('index.html','utf8'); \
  new Function(h.split('<script>')[1].split('</script>')[0]); \
  console.log('JS OK')"
```

**Pure logic** (overdub summing, `loopPos`, `encodeWav`) can be extracted and unit-tested in Node — these functions have no DOM or Web Audio dependency. `encodeWav` is worth asserting byte-wise: offsets 0/8/36 are the ASCII tags `RIFF`/`WAVE`/`data`, offset 24 is the sample rate, and samples begin at offset 44.

**Anything involving `AudioContext`, `getUserMedia`, or canvas requires a real browser** — timing feel, feedback, and mic behaviour cannot be verified statically. Do not claim these work based on static checks alone.

**Manual smoke test:** serve over HTTPS or localhost, allow mic, then: record a loop → confirm it cycles seamlessly → overdub → confirm layers stack → Record song → confirm the WAV downloads and plays.

---

## DEPLOYMENT

Static hosting. No build, no config file needed.

```bash
npx vercel --prod        # from this directory
```

Or drop `index.html` on any static host (Netlify, GitHub Pages, S3, nginx). **The host must serve HTTPS** or the microphone will not work.

Local development:
```bash
python3 -m http.server 8000   # then open http://localhost:8000
```
`localhost` counts as a secure context, so mic works. Opening the file via `file://` also works in most browsers.

---

## KNOWN LIMITATIONS

Honest list — these are real, not hypothetical.

1. **Input latency.** Browser audio round-trip means overdubs land a few milliseconds late relative to the loop. Fine for texture and jamming; a hardware looper is tighter for precise rhythmic work. Fixing this properly requires a measured latency offset applied when writing overdub samples.
2. **No headroom management.** Overdubs sum with hard clipping at ±1. Many layers will distort. A limiter or per-layer gain reduction would fix this.
3. **Tracks are not sync-locked.** Each track has an independent length and phase. Recording track 2 at an unrelated length produces polyrhythm, not alignment. A "sync to track 1 length" mode does not exist.
4. **Mono throughout.** Input, buffers, and WAV export are all single-channel.
5. **Nothing persists.** Refreshing the page loses all loops. There is no save/load.
6. **`ScriptProcessorNode` is deprecated.** It works everywhere today but should eventually become `AudioWorklet`.
7. **Long song recordings are memory-bound.** Captured PCM is held in RAM as Float32 (~4 bytes/sample ≈ 11 MB/minute at 48 kHz) and only freed after the WAV is written.
8. **iOS Safari** is stricter about audio-context resumption and mic permissions than desktop browsers; behaviour there is less tested.

---

## LIKELY EXTENSIONS

Ordered roughly by value-to-effort:

- **Track sync** — quantise new recordings to a multiple of track 1's length.
- **Latency compensation** — a calibration control that offsets overdub write position.
- **Undo overdub** — snapshot the buffer before merging so a layer can be removed.
- **Stereo** — widen buffers and the WAV encoder to 2 channels.
- **More tracks** — extend the `HUES` array; the grid and keyboard handler need matching updates (the key handler currently hardcodes the 1–4 range).
- **Per-track effects** — insert filter/delay nodes between `source` and `gain`.
- **Metronome / tempo** — a click track and BPM-derived loop lengths.
