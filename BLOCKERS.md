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

## 2. Live WhatsApp round trip: moved from Twilio to Meta's WhatsApp Cloud API (needs your Meta account)

**What was tried:** the Twilio WhatsApp sandbox, live, on 2026-10-21. Twilio
delivered the incoming voice note to the webhook, but **downloading its
media returned `HTTP 401 Unauthorized`** (`logs/requests.jsonl`, 13:45 entry,
outcome `download_failed`), and **custom replies were never delivered** to
the phone. Both look like Twilio trial-account restrictions rather than a
webhook bug; not pursued further.

**What changed:** `api/plumber.R` now also serves Meta's WhatsApp Cloud API
at `/meta-webhook` (verification, signature check, immediate acknowledgement,
de-duplication, Graph API media download and replies). The Twilio endpoint
is unchanged and still works with a Twilio account that allows media. Both
are verified against local mocks (`tests/testthat/test-meta-webhook.R`,
`tests/testthat/test-plumber-webhook.R`); neither has yet answered a real
phone end to end.

**What Jitu needs to do:** follow `docs/meta_whatsapp_setup.md` -- create the
Meta app, add your number as a test recipient, fill in `META_ACCESS_TOKEN`,
`META_PHONE_NUMBER_ID`, `META_VERIFY_TOKEN` (and ideally `META_APP_SECRET`)
in `.env`, run `Rscript R/12_meta_smoke_test.R`, start a tunnel, set the
callback URL to `https://<tunnel>/meta-webhook`, subscribe to `messages`,
and send a voice note. Remember the temporary access token expires after
about 24 hours.

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
