# whatsappaudioR

Convert compressed mobile voice notes (`.opus`/`.ogg`, the format WhatsApp
and similar apps use) directly into tidy spectrogram data frames, ready for
analysis. Built for the SonicScout bioacoustic pest-detection project, but
has no dependency on it or on anything pest/insect-related.

## Quickstart

```r
# Install from R-universe:
install.packages("whatsappaudioR",
                 repos = c("https://jitu-droid.r-universe.dev",
                           "https://cloud.r-project.org"))

library(whatsappaudioR)

w <- wa_read("voice_note.opus")           # -> tuneR::Wave
spec_df <- wa_spectrogram(w, wl = 1024)   # -> tidy time/freq/amplitude tibble
feats <- wa_features(w)                   # -> one-row tibble of spectral features
```

Requires a system `ffmpeg` build with `libopus` support for decoding
(`wa_read()`) and for `wa_simulate_compression()`. This package decodes via a
system `ffmpeg` binary rather than the `av` package -- `av::av_audio_convert()`
segfaulted on the reference machine this was built on (see `BLOCKERS.md` in
the parent repo); `wa_spectrogram()`/`wa_features()` operate on an
already-read `Wave` and don't need ffmpeg themselves.

See `vignette("whatsappaudioR-intro")` for a full walkthrough.

## API

| Function | Purpose |
|---|---|
| `wa_read(path)` | `.opus`/`.ogg`/`.wav`/`.mp3`/`.m4a` -> `tuneR::Wave` |
| `wa_spectrogram(wave, wl, ovlp)` | `Wave` -> tidy `time`/`freq`/`amplitude` tibble |
| `wa_features(wave, wl)` | `Wave` -> one-row tibble of spectral features |
| `wa_simulate_compression(wave, bitrate, sr)` | Round-trip a `Wave` through Opus/Ogg compression |
| `wa_batch(dir, fn, ...)` | Vectorise any of the above over a directory |

## Licence

MIT — see `LICENSE.md`.
