# LOOPDECK

> A multi-track live audio looper that runs entirely in the browser. Starts with 4 tracks, expands to 12. Zero dependencies, zero build step, one file.

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
| Where is the audio logic? | Inside the single `<script>` tag, in class `Track`, `buildChain()`, and the song-recorder block. |
| Where is the layout? | Inside the single `<style>` tag. |
| Persistent state? | Only `localStorage["ld_intro"]` (whether the help strip is dismissed). Audio and FX settings are never persisted. |
| Test command? | None exists. See "Verification" below for how to check changes. |

**Editing rule:** because everything lives in one file, prefer surgical string replacements over rewriting the file. The `<script>` block is ~700 lines; the `<style>` block is ~300.

**Hard constraints — do not break these:**
1. Microphone capture requires a **secure context** (HTTPS or `localhost`). On plain `http://` over a network, `getUserMedia` fails and recording silently disables.
2. `AudioContext` may only start after a **user gesture**. Every entry path calls `audio()` from inside a click/keydown handler. Do not create the context at page load.
3. The mic must **never** be routed to `ctx.destination` at non-zero gain — that causes feedback howl. Recording nodes connect to a muted sink instead.
4. **The echo return must not feed the node its send taps from.** `delaySend` taps `postEq`; the delay returns to `masterGain`. Returning it to `postEq` makes the loop gain `mix + feedback`, which exceeds 1 and runs away into a howl. This was a real bug, caught by the offline render check in "Verification".

---

## ARCHITECTURE

### Audio graph

```
  CAPTURE (inaudible — both sinks sit at gain 0)

                       ┌─────────────┐
  mic ──> micSource ──>│  recNode    │──> silent sink (gain 0) ──> destination
   │                   │ (per track) │
   │                   └─────────────┘
   │                   ┌─────────────┐
   └──> songMicGain ──>│  songNode   │──> songSink (gain 0) ──> destination
                       │  (capture)  │
                       └─────────────┘
                              ▲
                              │ taps masterGain (post-FX: you record what you hear)

  PLAYBACK

  Track.buffer ─> source ─> gain ─┬──────────────────────────────────> busIn
   (looping)    (per track) (fader)│                                     │
                                   └> sendGain ─> reverbBus ─> convolver ─> reverbReturn
                                      (post-fader,   (shared by every track)
                                       per track)

  busIn ─> eqLo ─> eqMid ─> eqHi ─> postEq ─┬─> compNode ─> compOut ─┬─> masterGain ─> destination
          (lowshelf)(peaking)(highshelf)    └─> dryOut ──────────────┘        ▲
                                            │                                │
                                            └─> delaySend ─> delayNode ⇄ delayFb
                                                            └───────────────────┘
```

Two capture points, both muted so they never reach the speakers:
- **`recNode`** (one per track, transient) captures mic input for a loop or overdub.
- **`songNode`** (one global, transient) captures `masterGain` + mic to produce the downloadable WAV. Because it taps `masterGain`, the exported WAV includes EQ, reverb, echo and compression.

**Reverb is one shared convolver, not one per track.** Each track owns a cheap post-fader `sendGain` feeding the common `reverbBus`; the master "Size" control regenerates the single impulse response. N tracks cost N gain nodes, not N convolvers.

**The impulse response is synthesised, not loaded** (`makeIR`): exponentially decaying white noise (`(1-t)^2.6`) with a 12 ms fade-in so the tail blooms instead of clicking. This keeps the zero-dependency, single-file promise — no IR sample files to ship.

**Compressor bypass is a crossfade, not a rewire.** `compOut`/`dryOut` gains swap between 0 and 1 via `setTargetAtTime`, so toggling "Glue" never disconnects a live node mid-stream.

`ScriptProcessorNode` is used instead of `MediaRecorder` deliberately: it yields raw `Float32Array` PCM, which allows sample-exact loop lengths and arithmetic overdub mixing. `MediaRecorder` would emit compressed chunks with container padding, producing audible gaps at the loop seam. `ScriptProcessorNode` is deprecated in favour of `AudioWorklet`; it still works in all current browsers. Migrating to `AudioWorklet` is the main modernisation task (see "Known limitations").

### Track state machine

Each track is an instance of `class Track` holding one mono `AudioBuffer`. One pad button drives the whole lifecycle:

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
| `audio()` | top of script | Lazily creates `AudioContext`, calls `buildChain()`, replays every FX slider into the new nodes, resumes if suspended. Call before any audio work. |
| `buildChain()` | top of script | Builds the whole master FX graph once. Nothing else may connect to `ctx.destination` at audible gain. |
| `makeIR(seconds)` | top of script | Synthesises the reverb impulse response. Called on boot and whenever "Size" moves. |
| `setComp(on)` | top of script | Crossfades `compOut`/`dryOut` to bypass or engage the glue compressor. |
| `bindParam(el, valEl, fmt, apply)` | FX block | Wires one slider to its readout and its audio param. Skips `apply` while `ctx` is null, so pre-gesture moves are held and replayed by `audio()`. |
| `addTrack()` / `removeTrack(t)` | boot | Grow/shrink the deck (4 minimum, `MAX_TRACKS` = 12). Removal renumbers and recolours survivors via `relabel()`. |
| `Track.relabel(i)` | `Track` | Reassigns index, name, colour, key hint, remove-button visibility and CSS `order` after the array shifts. |
| `Track.applyReverb()` | `Track` | Pushes the track's send amount into `sendGain`. No-op before playback creates the node. |
| `layout()` | boot | Sets the hub's `grid-row` span so it stays centred as rows are added. |
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

One global `requestAnimationFrame` loop calls `draw()` on every track. Each canvas is resized for `devicePixelRatio` on the first frame that detects a mismatch. The circular waveform starts at 12 o'clock (`rot = -PI/2`) and advances clockwise. Played bins render at full colour, unplayed bins dimmed.

### Layout

The deck is a CSS grid of `2 tracks | hub | 2 tracks`. The hub is pinned to column 3 and its `grid-row` span is recomputed by `layout()` as tracks are added, so it stays vertically centred in the deck no matter how many rows exist. Tracks are auto-placed and simply flow around it.

Below 1140 px the grid collapses to 2 columns and the hub spans the full width. Because the hub is the first child in DOM order, each track carries an inline `order` (1 for the first two, 3 for the rest) so the hub still lands *between* tracks rather than above them. Below 460 px everything stacks to one column.

Track colours come from `colorFor(i)`: the first four are the original deck hues, beyond that they are generated on a 47° hue rotation via `hslToHex`. `Track.dimmed()` parses hex, so `colorFor` must always return hex — not `hsl()`.

---

## USER-FACING BEHAVIOUR

- **Pad tap** — record → loop → overdub, per the state machine above.
- **Stop / Load sound / Clear** — per track. "Load sound" and drag-and-drop accept any browser-decodable audio (wav, mp3, ogg, m4a, aac, flac, webm); files are mixed to mono and resampled to the context rate via `OfflineAudioContext` if needed.
- **Play / Stop** — master transport, in the centre hub. "Play" only restarts tracks in `stopped` state.
- **Record song** — the large dial at the centre of the deck. Captures master mix (post-FX) + live mic, downloads `loopdeck-song.wav` on stop. Works without mic (instrumental only). The progress ring sweeps once per minute as a length cue.
- **Add / remove track** — starts at 4, up to `MAX_TRACKS` (12). The first four cannot be removed; extras carry an `×`. Removing renumbers and recolours the rest.
- **Per-track reverb (`RVB`)** — post-fader send into the shared reverb bus. 0 % by default, so the deck sounds unchanged until you reach for it.
- **Sound shaping (hub)** — collapsible panel of master effects:
  - **Equaliser** — low shelf @ 220 Hz, peaking @ 1.1 kHz (Q 0.9), high shelf @ 4.2 kHz, ±15 dB each.
  - **Reverb** — `Size` (0.3–6 s, regenerates the IR) and `Level` (the shared return).
  - **Echo** — `Time` (50 ms–1.2 s), `Fdbk` (regeneration, capped at 0.85), `Mix` (send level, 0 % by default).
  - **Glue compressor** — bus compressor, off by default.
  - **Reset FX** — restores every master default *and* zeroes all per-track reverb sends.
- **Keys** — `1`–`9` tap the corresponding pad; `Space` stops all. Suppressed while an `<input>` or `<button>` has focus.
- **Faders** — per-track and master, applied via `setTargetAtTime` for click-free changes.

FX sliders moved before the first user gesture are held (there is no `AudioContext` yet) and replayed into the graph by `audio()` when it builds.

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

**FX topology can be verified numerically, and should be.** Rebuild the same graph in an `OfflineAudioContext` in the browser console, feed a short burst through it, render, and measure peak amplitude in successive windows. This is how the runaway-echo bug in constraint 4 was caught: the echoes measured 0.46 → 0.51 → 0.56 and climbed to 0.98 — *growing*, not decaying. After the fix they read 0.44 → 0.24 → 0.13 → ~0, and stay decaying even at maximum `Mix` and `Fdbk`. Any change to the send/return wiring should be re-checked this way, at extreme settings, before it is called done.

**Anything involving `getUserMedia`, canvas, or timing feel requires a real browser and a human ear** — latency, feedback and mic behaviour cannot be verified statically. Do not claim these work based on static checks alone.

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
9. **FX are master-only apart from reverb.** EQ, echo and compression act on the whole bus. Per-track EQ or echo would need those nodes inserted per track in `Track.play()`.
10. **Effects are not recorded into the loop buffer.** Reverb and echo are applied on playback only, so clearing a send removes them entirely — but an overdub captured through speakers will pick them up acoustically. Use headphones.
11. **Changing reverb "Size" mid-tail is abrupt.** `convolver.buffer` is swapped outright, which cuts the existing tail rather than crossfading.
12. **FX settings do not persist** across a refresh, unlike the intro dismissal.

---

## LIKELY EXTENSIONS

Ordered roughly by value-to-effort:

- **Track sync** — quantise new recordings to a multiple of track 1's length.
- **Latency compensation** — a calibration control that offsets overdub write position.
- **Undo overdub** — snapshot the buffer before merging so a layer can be removed.
- **Stereo** — widen buffers and the WAV encoder to 2 channels. Would also let per-track panning join the reverb send.
- **Persist FX** — store the master panel and per-track sends alongside `ld_intro` in `localStorage`.
- **Per-track EQ / echo** — insert nodes per track in `Track.play()`, following the existing shared-bus send pattern so cost stays linear.
- **Crossfade the reverb IR** — swap between two convolvers on "Size" change instead of cutting the tail.
- **Metronome / tempo** — a click track and BPM-derived loop lengths.
