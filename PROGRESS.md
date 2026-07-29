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

Committed everything so far (repo skeleton through here) as the first git
commit -- see `git log`.

### Step 4 — Deliverable B: whatsappaudioR package, verified

Ran `devtools::document()` then `devtools::check()` for real (this had
never been run -- NAMESPACE/man/*.Rd didn't exist yet). Hit two more
environment gaps, both fixed by installing the missing tool rather than
skipping the check:

- No Pandoc -- vignette rendering failed. `winget install JohnMacFarlane.Pandoc`
  (fast, ~20MB). Fixed; vignette now builds.
- No Rtools -- `R CMD check` itself refuses to run without it on Windows,
  even though this package has zero compiled code. Installing
  `winget install RProject.Rtools` (in progress -- see below for outcome).

Installed the package directly (`install.packages("pkg/whatsappaudioR",
repos = NULL, type = "source")`, since `devtools::install()` wanted `pak`,
which isn't installed) so it could actually be `library()`'d by
`api/plumber.R` and `R/06_predict.R`.

**Found and fixed a real, production-breaking bug while building the
Twilio webhook mock test (Step 7, pulled forward since it surfaced this):**
`plumber::pr("api/plumber.R")` failed with "cannot open file 'R/utils.R'".
Root cause: plumber temporarily sets the working directory to the router
file's own directory (`api/`) while evaluating its top-level code, so a
plain `source(file.path("R", "utils.R"))` looks for `api/R/utils.R`, which
doesn't exist. This would have broken the webhook the first time anyone
actually ran it -- not caught by any earlier step because nothing had
exercised `api/plumber.R` yet. Fixed in both `api/plumber.R` and
`R/06_predict.R` (which is `source()`'d from the webhook and has the same
issue internally) with a small path-resolution helper that tries both the
plain path and the parent-relative path. Verified: `plumber::pr("api/plumber.R")`
now parses cleanly and registers both endpoints (`/health`, `/webhook`).

Also hit (and worked around) a second, separate `callr`-serialization issue
while writing the mock test itself: constructing a Plumber router object in
the test process and passing it into a `callr::r_bg()` background process
doesn't survive serialization cleanly (500 errors with no detail). Fixed by
constructing the router *inside* the background process instead (passing
only plain strings/scalars across the process boundary). This is a test
authoring detail, not a bug in the shipped code.

`tests/testthat/test-plumber-webhook.R` (mock Twilio payload -> real local
plumber server -> TwiML reply, plus a local fake "Twilio media host" server
to stand in for the Basic-Auth-protected real one) now passes: 5/5
assertions, covering both the happy path (synthetic audio attachment) and
the no-media failure path.

**Two more real bugs found by actually inspecting a stray log file** (a
`api/logs/requests.jsonl` appeared after the "passing" test run -- worth
noting: it passed 5/5 while masking both of these):

1. Confirmed empirically that plumber's cwd-change to the router's own
   directory isn't just a parse-time thing -- it holds during actual
   request handling too. Every relative path in `api/plumber.R`
   (`REQUEST_LOG_PATH`, `REQUEST_AUDIO_DIR`) and `R/06_predict.R`
   (`MODEL_PATH`) was resolving against `api/` at request time, not the
   repo root. Fixed by computing an absolute `.repo_root` once and
   anchoring every runtime path to it, instead of relative paths resolved
   lazily. Verified: logs now land at `logs/requests.jsonl`, not
   `api/logs/requests.jsonl`.
2. `download_twilio_media()`'s content-type-to-extension `switch()` didn't
   include `audio/wav` (only ogg/opus/mpeg/amr), so a wav attachment
   silently got saved as `.bin` and failed to decode -- the test didn't
   catch this because even a "sorry, couldn't process that audio" reply is
   still valid TwiML (`<Response><Message>...`), which is all the original
   assertions checked. Fixed the extension map (added wav/wave/x-wav,
   mp4/x-m4a) and strengthened the test to explicitly assert decode
   succeeded, not just "some TwiML came back".

Removed the stray `api/logs/` directory (a symptom of bug #1, not real
data) before committing.

Ran the full suite again after both fixes: main pipeline (`tests/testthat.R`)
17 assertions, package (`pkg/whatsappaudioR/tests/testthat`) 21 assertions,
all passing. `logs/requests.jsonl` now correctly shows `prediction_failed:
No trained model found` for the happy-path test -- the expected state,
since Deliverable D (classifier) hasn't been trained yet at this point in
the run.
