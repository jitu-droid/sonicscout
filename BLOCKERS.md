# SonicScout — Blockers

Ordered most-urgent first. Each entry: what was tried, the exact error, what
the fix is believed to be, and what Jitu specifically needs to do.

## 1. No real pest audio yet (needs your judgement call)

**What was tried:** `R/01_download_data.R` queries xeno-canto's API for
Desert Locust, Migratory Locust, and *Culex* mosquito recordings.

**Error:** All three queries return `HTTP 404 Not Found`. Most likely
xeno-canto's public API v2 (used here) has been deprecated in favour of v3,
which requires a registered API key.

**Believed fix:** Register for an xeno-canto API v3 key and update the
request in `R/01_download_data.R` to use it, or manually download a handful
of recordings per species from xeno-canto.org and place them under
`data/raw/xenocanto/<desert_locust|migratory_locust|culex_mosquito>/`.

**What Jitu needs to do:** This is the single biggest gap in the current
build -- every pest-class number in `docs/classifier_results.md` is
trained/tested on a **synthetic** ground-truth corpus, not real insect
recordings. Getting even a handful of real recordings per target species
(via an xeno-canto API key or manual download) and re-running
`R/01_download_data.R` -> `R/03_preprocess.R` -> `R/04_features.R` ->
`R/05_train.R` would be the highest-value next step before presenting any
performance number as representative of real pests.

## 2. Set up Twilio sandbox and run a live test (needs your Twilio account)

**What was tried:** N/A -- this fundamentally requires an account only you
can create.

**What's needed:** Follow `docs/twilio_setup.md` end to end: create a Twilio
account, join the WhatsApp sandbox from your phone, set `TWILIO_ACCOUNT_SID`
/ `TWILIO_AUTH_TOKEN` in a local `.env` (never commit it), expose
`api/plumber.R` via a tunnel (e.g. ngrok), point the sandbox webhook at it,
and send one real WhatsApp voice note through the full path.

**What Jitu needs to do:** Everything in `docs/twilio_setup.md` -- this is
the one part of the "definition of done" (a real WhatsApp voice note
returning a correct ID) that cannot be automated without your credentials
and phone. The webhook itself is verified working end-to-end against a
mock Twilio payload (`tests/testthat/test-plumber-webhook.R`, 6/6 passing)
and against the real trained model -- this item is specifically about the
live/real-Twilio round trip.

## 3. CORRECTED: `av` does NOT actually segfault -- earlier entry was wrong

**Original claim (now retracted):** an earlier session reported
`av::av_audio_convert()` and `av::av_media_info()` crashing the R process
outright (segfault, exit 139) on this machine, including on `av`'s own
bundled sample file, and concluded the installed binary was ABI-incompatible
with this R version.

**Re-tested and retracted.** `av` had since been dropped from every file
that used to `library(av)` (the codebase now routes decode/encode through
system `ffmpeg` instead), so it wasn't even installed in the current `renv`
project library. Reinstalled it (`install.packages("av")`) purely to
re-test Prompt 5's hypothesis, and ran the exact same calls
(`av::av_media_info()` on `av`'s own bundled sample file,
`av::av_audio_convert()` on a fresh test WAV) both from a script file and
via a single-line `Rscript -e "..."` call. **Both succeeded cleanly, every
time, no crash.** The original segfaults were most likely an artifact of
how a *multi-line* inline `-e` string was being passed from bash to
`Rscript.exe` in that earlier session (several other unrelated segfaults
in that same session also happened only with multi-line inline `-e`
scripts and disappeared when the identical logic was run from a `.R` file
or a single-line `-e` call) -- not a real `av`/R-ABI incompatibility.

**Correction:** `av` is not broken on this machine. The earlier "believed
fix" (rebuild from source against Rtools) was chasing a problem that
doesn't exist.

**What Jitu needs to do:** Nothing. The ffmpeg-based workaround already in
the code (`pkg/whatsappaudioR/R/wa_read.R`,
`pkg/whatsappaudioR/R/wa_simulate_compression.R`,
`R/02_codec_experiment.R`'s `simulate_whatsapp_compression()`) is still
reasonable to keep -- it works reliably and avoids `av` as a dependency for
the package/pipeline -- but there is no outstanding bug forcing that choice
if a future session ever wants to switch back to `av` for its marginal
speed benefit (no subprocess spawning). General lesson for future sessions
on this machine: avoid multi-line inline `Rscript -e "..."` calls for
anything non-trivial; write to a script file instead, or keep `-e` calls to
a single line.

## 4. Rtools install failed (winget), needed only for full `R CMD check`

**What was tried:** `winget install --id RProject.Rtools -e`.

**Error:** Exit code 2, "You cancelled the installation" -- likely the
installer wanted an interactive prompt this headless session can't supply.

**Believed fix:** Run the Rtools installer yourself interactively (download
from https://cran.r-project.org/bin/windows/Rtools/), or find the right
silent-install flags for winget in a terminal you can watch.

**What Jitu needs to do:** Nothing urgent -- `whatsappaudioR` has zero
compiled code, so this only gates a formality (`R CMD check`'s Windows
policy of requiring Rtools regardless of whether a package needs
compilation). The package installs fine via `install.packages(repos=NULL,
type="source")` and both test suites pass. Install Rtools yourself only if
you want the full `devtools::check()` "0 errors/warnings/notes" badge.
