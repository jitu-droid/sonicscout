# SonicScout — Blockers

Ordered most-urgent first. Each entry: what was tried, the exact error, what
the fix is believed to be, and what Jitu specifically needs to do.

## 1. RESOLVED: real pest audio acquired -- xeno-canto's API was abandoned, not fixed

**Original problem:** `R/01_download_data.R` queried xeno-canto's API for
Desert Locust, Migratory Locust, and *Culex* mosquito recordings; all three
queries returned `HTTP 404 Not Found` (xeno-canto's public API v2 has been
deprecated in favour of v3, which requires a registered key).

**Resolution:** per explicit instruction, the xeno-canto-API approach was
abandoned rather than fixed -- not worth registering for a v3 key over.
`R/01_download_data.R` was rewritten to download InsectSet459's small
annotation CSV (instead of its 16-51GB distribution zips) and fetch
individual recordings directly from their original source URLs (mostly
`static.inaturalist.org`). This yielded **59 real recordings across 3
species** (*Chorthippus biguttulus*, *Chorthippus brunneus*, *Cicada
orni* -- Orthoptera/Cicadidae acoustic proxies for locust/grasshopper
pests, not locusts themselves) plus 15 real chewing/feeding recordings
from USDA-ARS (`R/fetch_chewing_sounds.R`) for the codec experiment.
`docs/classifier_results.md` and `docs/codec_findings.md` are now real,
measured numbers from this real audio, not synthetic-only. No real
*Culex* mosquito recording has been obtained -- that class remains
synthetic-only, flagged explicitly wherever it's cited.

**What Jitu needs to do:** Nothing further for target-species real audio.
If mosquito wingbeat detection matters for a future iteration, a real
recording source for *Culex* (or another mosquito genus) is still needed.

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
