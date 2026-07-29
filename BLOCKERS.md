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

## 3. `av` R package segfaults on this machine -- routed around, low urgency now

**What was tried:** Called `av::av_audio_convert()` (a basic wav-to-wav
conversion, no exotic arguments) and separately `av::av_media_info()`, both
on a freshly-generated test WAV and, to rule out an input-file issue, on
`av`'s own bundled sample file
(`system.file("samples", "Synapsis-Wonderland.mp3", package = "av")`).

**Error:** All three calls crash the R process outright --
`Segmentation fault` (exit code 139), not a catchable R error/warning.

**Believed fix:** `av` 0.9.6's CRAN Windows binary is very likely built
against a different R internals/ABI version than this machine's R 4.6.1
(an unusually new R release). Rebuilding from source
(`install.packages("av", type = "source")`, needs Rtools) against the
actual installed R/Rtools should fix it.

**Workaround applied (see `# WORKAROUND:` comments in code):** every
decode/encode path shells out to a system `ffmpeg` binary instead
(confirmed working, with `libopus`) -- `pkg/whatsappaudioR/R/wa_read.R`,
`pkg/whatsappaudioR/R/wa_simulate_compression.R`, and
`R/02_codec_experiment.R`'s `simulate_whatsapp_compression()`. This has
been extensively exercised since (the full pipeline runs on it) and works
reliably -- this is now an informational entry, not a live risk to the
demo.

**What Jitu needs to do:** Nothing urgent. If you want `av`'s marginal
speed benefit (no subprocess spawning) later, try
`install.packages("av", type = "source")` with Rtools installed, then
re-run both test suites to confirm it no longer segfaults before switching
the code back.

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
