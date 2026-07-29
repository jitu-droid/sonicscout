# SonicScout — Progress Log

Running log, most recent entry at the top of each session block. Times are
local machine time.

## Session 2 — autonomous run (Prompt 3)

Starting autonomous run per user's standing authorization (installs, downloads
up to 2GB, git commits, running/iterating on scripts, no push, no stopping to
ask). Work order: Step 0 (env) → 1 (verify A) → 2 (synthetic corpus) → 3 (run A
for real) → 4 (package B) → 5 (real data C) → 6 (classifier D) → 7 (webhook E)
→ 8 (dashboard F) → 9 (docs G).

### Step 0 — Environment bring-up (in progress)

- Found R 4.6.1 already installed at `C:\Program Files\R\R-4.6.1` (not on
  PATH; invoking via full path to `Rscript.exe`).
- Installed FFmpeg 8.1.2 via `winget install Gyan.FFmpeg` (full_build,
  confirmed `libopus` encoder present via `ffmpeg -encoders`). Symlinked at
  `%LOCALAPPDATA%\Microsoft\WinGet\Links\ffmpeg.exe`, on user PATH (new
  shells only -- current session PATH updated manually for now).
  **TODO before trusting the previous session's `av` bitrate note:** `av` is
  still installing as of this entry -- once it's in, run
  `args(av::av_audio_convert)` for real and confirm/refute the "no bitrate
  argument" claim empirically before relying on the system-ffmpeg fallback.
  Do not treat the earlier session's note as verified until this actually
  runs.
- R package install: first attempt used `install.packages(p, dependencies =
  TRUE)` in a loop, which recursively installs **Suggests** too -- this
  dragged in caret's and seewave's entire suggested-package universe (~150
  unrelated packages: car, DT, emmeans, forecast, rgl, rpanel, phonTools,
  FactoMineR, circlize, ...) and would have taken a very long time for no
  benefit. Killed it after only `tuneR` had finished installing. Restarted
  with `dependencies = c("Depends", "Imports", "LinkingTo")` (no Suggests) --
  this is the correct scope for actually being able to load and call these
  packages. Confirmed all 22 target packages installed successfully after
  one retry for `av`/`warbleR` (first pass hit a couple of CRAN download
  timeouts, not real errors).

- **Major finding: `av` package segfaults R on this machine.** Checked
  `args(av::av_audio_convert)` as instructed -- turns out it DOES have a
  `bit_rate` argument in this installed version (0.9.6), contradicting the
  previous session's note that bitrate wasn't controllable via `av`. But
  before relying on that, tried it empirically and `av::av_audio_convert()`
  segfaults R outright (exit 139), as does `av::av_media_info()`, even on
  `av`'s own bundled sample file. Full details and the workaround (route
  everything through system `ffmpeg` instead) are in `BLOCKERS.md` -- this
  is flagged there as the top urgent item since it's a real crash risk, not
  just an inconvenience. Rewriting `R/02_codec_experiment.R`,
  `pkg/whatsappaudioR/R/wa_read.R`, and
  `pkg/whatsappaudioR/R/wa_simulate_compression.R` now to use system ffmpeg
  for every decode/encode step instead of `av`. Done -- all `av::` calls
  replaced, `av` dropped from `pkg/whatsappaudioR/DESCRIPTION` Imports since
  it's genuinely unused now, docs/vignette/README updated to match.

### Step 1 — Verify and fix Deliverable A tests

Ran `tests/testthat.R` for real (`Rscript tests/testthat.R`, with the
WinGet ffmpeg symlink dir added to PATH for this shell). **All tests pass**,
including the ffmpeg-gated `simulate_whatsapp_compression` integration test
-- no fixes needed beyond the `av`->ffmpeg routing already done in Step 0.
The previous session's blind-written pure-math functions (band energy,
retention ratios, spectral similarity, survivability score) were all
correct as written.

### Step 2 — Synthetic audio corpus

Ran `R/00_synthetic_corpus.R` for real. First run produced 9 files but threw
"longer object length is not a multiple of shorter object length" warnings
in `mix_at_snr()` and `gen_chewing_pulses()`. Root cause: `gen_white_noise()`
generated `round(duration*sr)` samples while `gen_harmonic_tone()` generated
`length(seq(0, duration, by=1/sr))` samples -- off by one, for the same
`duration`. Fixed `gen_white_noise()` to use the same convention. Re-ran:
clean, no warnings, fixture `.opus` created at
`pkg/whatsappaudioR/tests/testthat/fixtures/sample.opus`.

### Step 3 — Run codec experiment for real (synthetic data)

Ran `R/02_codec_experiment.R` end to end. **Real measured numbers**, not
estimates, now live in `docs/codec_findings.md` (regenerated fresh each run
of the script). Ground-truth check passed: `synthetic_above_nyquist_control`
(a pure 10kHz tone) shows survivability 0.101, Pearson correlation -0.097,
and 0 retention in the >8kHz band -- i.e. the codec simulation genuinely
destroys content above the Nyquist ceiling, not just in theory.

Found and fixed a real bug while reading the output: several retention
ratios showed absurd values (millions) -- e.g. the 0-500Hz band for a pure
10kHz tone, where the original had ~zero energy, so tiny leakage / near-zero
blew up. Fixed `band_retention_ratios()` to require the original band have
>= 0.5% of the signal's total spectral energy before computing a ratio,
else `NA` -- documented in the generated report so it doesn't read as an
unexplained gap. This was a metric-soundness fix, not tuning results to look
better: it only affects bands where the source had no real signal to begin
with, and doesn't touch any of the meaningful (stridulation/wingbeat/chewing/
noise) results.

Also improved `docs/figures/codec_before_after.png` for slide use per the
brief: added an explicit red dashed 8kHz reference line on every panel (not
just relying on the "after" panel's axis happening to stop at 8kHz), bumped
font sizes, larger canvas. Visually confirms the ground-truth check above.

**Interpretation section in `docs/codec_findings.md` is still `TBD`** --
deliberately left for a human to write after reading the real numbers, not
auto-generated. Worth noting when writing it: `synthetic_chewing_pulses`
(deliberately spanning across the 8kHz wall) shows synthetic_stridulation
and synthetic_mosquito_wingbeat surviving well (comfortably inside the
surviving band, matching the brief's prediction), while
synthetic_broadband_noise's Pearson correlation (0.249) is much lower than
its cosine similarity (0.967) -- expected for noise-like signals where
Pearson correlation is a poor descriptor shape-wise but cosine similarity
(magnitude-focused) still reads as "similar energy overall".
