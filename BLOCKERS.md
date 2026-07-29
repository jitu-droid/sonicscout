# SonicScout — Blockers

Ordered most-urgent first. Each entry: what was tried, the exact error, what
the fix is believed to be, and what Jitu specifically needs to do.

## URGENT: the `av` R package segfaults on this machine -- routed around, but needs attention

**What was tried:** Called `av::av_audio_convert()` (a basic wav-to-wav
conversion, no exotic arguments) and separately `av::av_media_info()`, both
on a freshly-generated test WAV and, to rule out an input-file issue, on
`av`'s own bundled sample file
(`system.file("samples", "Synapsis-Wonderland.mp3", package = "av")`).

**Error:** All three calls crash the R process outright --
`Segmentation fault` (exit code 139), not a catchable R error/warning. This
matters a lot: a segfault cannot be caught with `tryCatch()`, so any code
path that called into `av` for decode/encode would crash an entire running
plumber webhook or Shiny session, not just fail one request.

**Believed fix:** `av` 0.9.6's CRAN Windows binary is very likely built
against a different R internals/ABI version than this machine's R 4.6.1
(4.6.1 is an unusually new R release; binary package builds on CRAN can lag
behind and segfault when the native code's assumptions about R's C API
don't match). Rebuilding from source against the actual installed
R/Rtools should fix it: `install.packages("av", type = "source")` (needs
Rtools and FFmpeg dev headers/libs available to the build). Alternatively,
wait for CRAN to publish a binary explicitly built for R 4.6.1, or use an
older, more widely-supported R version for this project.

**Workaround applied (see `# WORKAROUND:` comments in code):** every place
that would have called `av::av_audio_convert()` for decoding/encoding now
shells out to the system `ffmpeg` binary instead (already installed, with
`libopus` confirmed working -- see `docs/environment.md`). This affects:
`pkg/whatsappaudioR/R/wa_read.R`, `pkg/whatsappaudioR/R/wa_simulate_compression.R`,
and `R/02_codec_experiment.R`'s `simulate_whatsapp_compression()`. Functionally
this should be equivalent or better (ffmpeg is the thing `av` wraps anyway),
but it does mean `av` is currently an unused dependency in practice --
consider dropping it from `DESCRIPTION`/`Imports` once the source-rebuild is
confirmed unnecessary, or keep it and revert to it once fixed (native `av`
would avoid the process-spawn overhead of shelling out).

**What Jitu needs to do:** Nothing urgent for the demo -- the ffmpeg
workaround is in place and should work. If you want to use `av` natively
(marginally faster, no subprocess spawning), try
`install.packages("av", type = "source")` when you have a spare few minutes
and Rtools installed, then re-run `tests/testthat.R` and
`pkg/whatsappaudioR`'s test suite to confirm it no longer segfaults before
switching the code back.

## Set up Twilio sandbox and run a live test (needs your Twilio account)

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
and phone.
