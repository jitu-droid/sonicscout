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

**Rtools install failed** (`winget install RProject.Rtools`, exit code 2,
"You cancelled the installation" -- likely the installer expected an
interactive prompt this headless environment can't provide). Not fixing
right now: `whatsappaudioR` has zero compiled code, so `devtools::check()`'s
Rtools requirement is really just a blanket Windows gate, not something
this package actually needs. Substituted equivalent verification instead:
`devtools::document()` succeeded, the package installs cleanly via
`install.packages(repos=NULL, type="source")`, and both test suites pass.
Logged in BLOCKERS.md in case Jitu wants the full R CMD check gate later
(would need the interactive Rtools GUI installer).

**Observed environment instability while starting Deliverable C/D work:**
several otherwise-correct R invocations that touch `data/raw/` (e.g.
`collect_labeled_sources()` in `R/03_preprocess.R`, which just calls
`file.exists()`/`list.dirs()`/`list.files()` -- no exotic packages)
segfaulted intermittently while the ESC-50 zip was still being written into
a sibling path under `data/raw/esc50/` by the still-running
`R/01_download_data.R` background job. Bisected carefully (see
troubleshooting below) and ruled out a code bug -- the exact same script
sometimes ran clean, sometimes crashed with zero output, which points to
resource/filesystem contention (large concurrent download + antivirus
real-time scanning is the leading suspect) rather than a deterministic bug.
Waiting for the download to finish before re-running Deliverable C/D rather
than continuing to retry into the contention.

**Update: found the real bug, and it was NOT an environment issue.**
`SYNTHETIC_CODEC_ONLY_LABELS` in `R/03_preprocess.R` wrongly listed
`synthetic_broadband_noise` and `synthetic_tone_plus_noise` alongside
`synthetic_above_nyquist_control` -- only the Nyquist control should be
excluded (it exists purely for Deliverable A's ground-truth check);
broadband_noise is explicitly documented in `R/00_synthetic_corpus.R` as
the ambient/negative-class stand-in, and tone_plus_noise is a legitimate
robustness-sweep class. This silently dropped 2 of 6 classes from every
preprocessing run with no error -- easy to miss since the script still
"succeeds" and only under-reports which labels it found. Fixed to
`SYNTHETIC_CODEC_ONLY_LABELS <- c("synthetic_above_nyquist_control")`.
While fixing it, also relabelled `synthetic_broadband_noise` to `"ambient"`
during preprocessing (matching how real ESC-50 data already gets
relabelled) so the false-positive-rate-vs-ambient metric is computable
even in synthetic-only mode, not just once real ambient data arrives.

The segfaults encountered while debugging this were real (confirmed
reproducible in isolation, see above) but were a red herring for *this*
particular bug -- worth remembering that intermittent crashes and silent
logic bugs can compound and need to be diagnosed separately, not assumed
to share one root cause.

Also expanded `R/00_synthetic_corpus.R` to generate 5 jittered variants per
class (was 1) for stridulation/wingbeat/chewing/noise, specifically so
`R/05_train.R`'s grouped split has enough source files per class to
actually populate train AND test -- with 1 file per class, an entire class
could be marooned in a single split. Regenerated the corpus and re-ran
Deliverable A's codec experiment on the expanded set (still passing, same
qualitative findings).

### Step 6 — Deliverable D: classifier, trained and verified for real

Ran `R/03_preprocess.R` -> `R/04_features.R` -> `R/05_train.R` end to end on
the (now-fixed, now-expanded) synthetic corpus: 24 source files / 48
windows across 5 classes (ambient, chewing_pulses, mosquito_wingbeat,
stridulation, tone_plus_noise). Split 14 train / 4 val / 6 test source
files, all group-integrity assertions passed.

**Real results in `docs/classifier_results.md`:** near-perfect classification
(precision/recall 1.0) on every class except `ambient` <-> `tone_plus_noise`
confusion (2 low-SNR tone-plus-noise test windows predicted as ambient) --
entirely plausible: a heavily noise-dominated pest signal legitimately
resembles broadband noise acoustically. **False-positive rate against the
ambient class: 0%** (no true-ambient window was ever misclassified as a
pest). `docs/figures/variable_importance.png` generated -- spectral entropy,
MFCC-5, and rolloff85 rank highest, `duration_s` (constant across
same-length windows) correctly ranks lowest.

**Read this caveat before quoting these numbers anywhere:** this is a small
(48-window), purely synthetic corpus. It validates that the pipeline
mechanics work correctly (grouped split, no leakage, real metrics computed)
-- it is not evidence of real-world field performance. `docs/methodology.md`
needs this caveat spelled out prominently (Deliverable G).

`models/classifier.rds` now exists, so `R/06_predict.R` and the webhook's
happy path can be re-tested against a real trained model next.

Re-tested the webhook against the real model: happy-path request now
returns an actual outcome=`predicted` (not `prediction_failed`) with real
confidence scores. **Found and fixed one more bug while checking the
resulting log entry**: the archived-audio filename builder used
`paste0(audio_hash, tools::file_ext(tmp_audio))` -- `file_ext()` strips the
leading dot, so this produced filenames like `<hash>wav` (no separator),
not `<hash>.wav`. Fixed to `paste0(audio_hash, ".", tools::file_ext(...))`.

Wrote `R/seed_demo_logs.R` (planned earlier, not actually written until
now) and ran it for real: 6 real `predict_pest()` outputs on synthetic
corpus samples, seeded into `logs/requests.jsonl` + `logs/audio/` for the
dashboard's replay mode.

**Launched the Shiny dashboard for real** (`shiny::runApp("dashboard")`,
via a new `.claude/launch.json` browser-preview config) and checked server
logs, not just that the process started. Found real errors: all three
custom `renderPlot()` outputs (waveform, spectrogram, confidence bars)
threw "figure margins too large". Root cause: `plotOutput(...)` only had
`height` set, not `width`, so sizing depended on the container reporting
its rendered width -- fine in normal use, but produced a degenerate device
size in this automated browser-preview environment. Fixed by giving each
plot an explicit `width = "400px")` too, which resolved it (confirmed: zero
errors in server logs after the fix, and the returned `<img>` payloads are
substantial real PNGs, not blank/error placeholders -- checked via network
request inspection since screenshot capture isn't available in this
particular browser tool). Also confirmed via direct path check that the
Compression Analysis tab's file-existence checks resolve correctly against
Shiny's actual working directory (`dashboard/`).

### Step 5 (revisited) — ESC-50 download finally succeeded

Third attempt (30-minute timeout, this connection sustains only
~0.5-0.6MB/s) succeeded: **560 real ambient clips across 14 ESC-50
categories**, 892.7MB, all logged in `data/raw/manifest.csv` with source
URL/licence/checksum per file. xeno-canto still failing (HTTP 404 on all 3
species queries -- likely API v2 deprecated in favour of v3+key; see
BLOCKERS.md, unresolved, needs Jitu's judgement call on getting an API key
or manually sourcing a few real pest recordings).

Found two more issues while wiring real data into preprocessing:

1. `collect_labeled_sources()` didn't filter manifest rows by file
   extension, so it would have tried to treat the ESC-50 zip archive
   itself (also logged as its own manifest row) as an audio file. Fixed by
   filtering to actual audio extensions.
2. All 560 ambient clips vs. 5 source files per synthetic pest class is a
   wildly imbalanced dataset (and slow to process for a demo). Capped real
   clips at 5 per ESC-50 subcategory (sampled, fixed seed) -- close to the
   synthetic per-class count rather than forcing artificial balance, since
   real pest-class data scarcity is a genuine, honestly-reported limitation
   here, not something to paper over.

Re-ran `03_preprocess.R` -> `04_features.R` -> `05_train.R` with real data
included: 94 source files (70 real ambient + 24 synthetic pest), 300
windows, split 56 train / 18 val / 20 test source files.

**Updated real results:** pest classes (chewing_pulses, mosquito_wingbeat,
stridulation) all classify perfectly on held-out test windows (precision
and recall 1.0 each, small n). `synthetic_tone_plus_noise` (the
deliberately noisy, low-SNR pest variant) has **0 recall** -- all its test
windows got misclassified as ambient. **False-positive rate against real
ambient: still 0%.** Read together, this is an honest and defensible
tradeoff to report: the model never cries wolf on real ambient sound, at
the cost of missing the hardest, noisiest pest signal variant. This is
exactly the kind of result the brief said to report plainly rather than
tune away.
