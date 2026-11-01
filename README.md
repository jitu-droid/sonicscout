# SonicScout

A bioacoustic pest early-warning system that uses WhatsApp voice notes as the
sensor. A smallholder farmer records a 10-30 second voice note of their field
(typically at night) and sends it to a WhatsApp number. A backend decodes the
audio, extracts acoustic features, matches them against known pest acoustic
signatures, and replies with a pest identification plus a confidence score.
No app install, no IoT hardware, no literacy requirement.

Built in R for an international data science hackathon.

## What's actually novel here

Acoustic insect detection itself is not novel -- it goes back decades
(Mankin et al. and others were field-testing acoustic fruit-fly detection
prototypes in the mid-2000s), and FFT/spectrogram/CNN classification of
insect sounds is well-established. WhatsApp agriculture chatbots also
already exist, but they're speech-to-text + LLM agronomy advice -- the
farmer *describes* a problem in words; they don't treat the audio itself as
sensor data.

**The actual claim:** a method and system for recovering discriminative
bioacoustic pest signatures from lossy, speech-optimised, VoIP-compressed
consumer audio, using existing consumer messaging infrastructure as a
zero-hardware distributed acoustic sensor network. The novelty is in the
pipeline surviving the compression, and in the delivery mechanism -- not in
the signal processing math.

## Architecture

```
Farmer's phone --(WhatsApp voice note, Opus/Ogg, 16kHz, ~16kbps)--> Meta WhatsApp Cloud API
                                                                     (or Twilio Sandbox)
                                                                          |
                                                                          v
                                                   api/plumber.R webhook (/meta-webhook or /webhook)
                                                        (download, decode, log request)
                                                                          |
                                                                          v
                                                    whatsappaudioR::wa_read / wa_features
                                                                          |
                                                                          v
                                                      models/classifier.rds (random forest)
                                                                          |
                                                                          v
                                                    top-3 classes + confidence + low-confidence flag
                                                                          |
                                                                          v
                     WhatsApp reply (Graph API message or TwiML) <-- pest ID + confidence + action
                                                                          |
                                        dashboard/app.R (Shiny) <-- reads logs/requests.jsonl
                                          - live/replay view (waveform, spectrogram, confidence)
                                          - Compression Analysis tab (codec_before_after.png)
```

Pipeline stages (`R/`), each independently runnable:

| Script | Purpose |
|---|---|
| `00_synthetic_corpus.R` | Synthetic ground-truth audio (known frequencies/pests), unblocks everything below without needing real data |
| `01_download_data.R` | Real data: ESC-50 ambient corpus + real InsectSet459 recordings (fetched directly from their original source URLs), capped at 2GB, idempotent |
| `fetch_chewing_sounds.R` | Real chewing/feeding-sound recordings (USDA-ARS), used only in the codec experiment -- see `docs/methodology.md` for why these are excluded from the classifier |
| `02_codec_experiment.R` | **Deliverable A** -- measures what WhatsApp's Opus/Ogg compression actually does to pest signatures |
| `prepare_real_reference.R` | Builds the codec experiment's real-audio reference set from the raw downloads above |
| `03_preprocess.R` | Resample, trim silence, window, apply the WhatsApp compression simulation to training data (train/serve match) |
| `04_features.R` | Extract the documented feature set via `whatsappaudioR` |
| `05_train.R` | Train + evaluate a random forest, grouped by source recording |
| `06_predict.R` | Single entry point: audio file in, top-3 classes + confidence + low-confidence flag out |
| `07_compression_delta.R` | Trains a second model on uncompressed audio (same sources/split) to measure compression's actual accuracy cost |
| `seed_demo_logs.R` | Seed the dashboard's replay mode with real `predict_pest()` output |
| `start_webhook.R` | Load `.env` and start the webhook server (Meta at `/meta-webhook`, Twilio at `/webhook`) on port 8000 |
| `11_twilio_smoke_test.R` / `12_meta_smoke_test.R` | Check credentials against Twilio / Meta and that the local webhook answers, before a live test |

## Quickstart

```r
# 1. Install R packages (renv.lock not yet generated -- see docs/environment.md)
install.packages(c("tuneR", "seewave", "warbleR", "dplyr", "tidyr", "purrr",
                    "tibble", "knitr", "ggplot2", "randomForest", "caret",
                    "plumber", "httr2", "jsonlite", "shiny", "plotly",
                    "testthat", "roxygen2", "devtools", "zip"))

# 2. Install the whatsappaudioR package (see pkg/whatsappaudioR/)
install.packages("pkg/whatsappaudioR", repos = NULL, type = "source")
```

You'll also need a system **FFmpeg** build with `libopus` support on `PATH`.
Every decode/encode path shells out to system `ffmpeg` rather than using the
`av` R package -- not because `av` is broken (an earlier note claiming it
segfaults on this machine was re-tested and retracted, see `BLOCKERS.md`),
but because the project was already built around a shell-out and there was
no reason to add a dependency mid-build.

```bash
# 3. Run the pipeline end to end (from the repo root)
Rscript R/00_synthetic_corpus.R       # synthetic ground-truth corpus
Rscript R/01_download_data.R          # real data: ESC-50 + real InsectSet459 recordings
Rscript R/fetch_chewing_sounds.R      # real chewing/feeding sounds (codec experiment only)
Rscript R/02_codec_experiment.R       # Deliverable A: codec findings
Rscript R/03_preprocess.R
Rscript R/04_features.R
Rscript R/05_train.R                  # trains models/classifier.rds
Rscript R/07_compression_delta.R      # measures compression's actual accuracy cost
Rscript R/seed_demo_logs.R            # seed dashboard replay mode

# 4. Run the demo pieces
Rscript R/start_webhook.R              # loads .env; WhatsApp webhooks on port 8000
Rscript -e "shiny::runApp('dashboard', port = 3838)"
```

The live WhatsApp path uses **Meta's WhatsApp Cloud API** -- see
`docs/meta_whatsapp_setup.md` for the setup (app, test number, `.env`
values, tunnel, callback URL `https://<tunnel>/meta-webhook`). The Twilio
sandbox path (`docs/twilio_setup.md`) is still there, but the Twilio trial
couldn't download media or deliver replies (see `BLOCKERS.md`). The server
starts with either provider configured.

**Running the demo without the live WhatsApp reply.** Meta locked the
project's WhatsApp Business Account with error 131031 ("Business Account
locked") right after setup, so the live reply has not yet been tested on a
real phone. The same prediction code runs locally instead: record a real
WhatsApp voice note, download it from WhatsApp Web, and run

```bash
Rscript R/classify_voice_note.R                  # newest voice note in Downloads
Rscript R/classify_voice_note.R path/to/file.ogg # or a specific file
```

It prints the top three guesses and the reply a farmer would receive, and
logs the request so it appears on the dashboard.

## Data

**InsectSet459** -- 26,399 audio files across 459 species of Orthoptera and
Cicadidae, curated from xeno-canto, iNaturalist and BioAcoustica. CC-BY-4.0 /
CC0. Faiss, M. et al. (2025). *InsectSet459: an open dataset of insect
sounds for bioacoustic machine learning*. arXiv:2503.15074; also published
in *Scientific Data*. Zenodo: [10.5281/zenodo.18554693](https://zenodo.org/records/18554693).

This dataset's own distribution (three 16-51GB zips) is too large for this
project's 2GB data-download budget. `R/01_download_data.R` instead downloads
only the dataset's small annotation CSV and fetches individual recordings
directly from their original source URLs -- 45 real files each (135 total)
across 3 species: ***Chorthippus biguttulus***, ***Chorthippus brunneus***
(European field grasshoppers) and ***Cicada orni*** (Mediterranean cicada),
selected via a HEAD-probe size filter that prefers many short clips over a
few long ones (skips anything over ~20MB, or of unknown size). **None of
these are locusts.** This project's honest claim is "validated on Orthoptera
stridulation using European grasshoppers as acoustic proxies" -- never
"validated on locusts" -- since InsectSet459 contains no *Schistocerca* or
*Locusta* at all. See `docs/methodology.md` for why these species were
chosen and what that does and doesn't support.

**USDA-ARS Reference Library of Digitized Insect Sounds** -- 15 real
larval chewing/feeding recordings across 5 species (`R/fetch_chewing_sounds.R`),
filling the gap that InsectSet459 has no Lepidoptera and therefore can't
speak to Fall Armyworm at all. Presumed public domain (US federal
government work, 17 U.S.C. sec 105). **Used only in the codec experiment,
not the classifier** -- every one of these recordings was captured with a
contact/vibration sensor (accelerometer, piezoelectric disk, PVDF film, or
similar), never an open-air microphone, so results from this corpus are a
best-case ceiling, not evidence of real-world WhatsApp-voice-note viability.
See `docs/methodology.md` for the full reasoning and the chewing/Fall-Armyworm
scope decision.

**ESC-50** (ambient/negative class) -- Piczak, K. J. (2015). *ESC: Dataset
for Environmental Sound Classification*. CC BY-NC 3.0.
https://github.com/karolpiczak/ESC-50. Note the **NC** (non-commercial)
term -- fine for this hackathon/research use, but would need revisiting
before any commercial deployment.

## Measured results (real audio, not estimates)

Every number below is a **mean with an interval from repeated grouped
k-fold cross-validation (5 folds x 10 repeats)**, not a single split --
see `docs/methodology.md` for why a single split was never defensible on
a corpus this size, and for the full before/after story of fixing it.

- **Codec survivability:** real Orthoptera/Cicadidae stridulation survives
  the WhatsApp Opus/Ogg round-trip well (0.956-0.986 across the 3 real
  species). Real chewing-sound survivability is poor-to-moderate
  (0.342-0.892) and was measured under best-case contact-sensor capture,
  not realistic open-air conditions -- see `docs/codec_findings.md`.
- **Classifier (real audio only):** 68.2% mean test accuracy (sd 6.5pp,
  95% range 55.9-78.1%), 22.3% mean false-positive rate against real
  ambient audio (sd 8.2pp, range 8.1-39.3%), scored on the 3 real species
  and real ESC-50 ambient (45 source recordings per species, 140 ambient)
  -- see `docs/classifier_results.md`. Majority-class baseline is 27.6%
  (always guessing *C. biguttulus*), chance rate is 25% (4 classes) --
  read the accuracy figure against those, not against 50%. The model is
  also trained on 4 small synthetic classes; scoring those too gives
  68.5%, which earlier versions of this README reported as the headline.
- **Temporal features (syllable rate, inter-pulse intervals, envelope
  modulation spectrum, phrase structure) added to target the specific
  biological mechanism separating *C. biguttulus* from *C. brunneus*** --
  two sympatric congeners whose species boundary is maintained by song
  TIMING, not spectral content. Result: *C. brunneus* recall rose from 34%
  to 43.1%, while *C. biguttulus* stayed flat. An ablation (Prompt 10)
  isolated this from a simultaneous window-length change: most of the gain
  (~6.1pp of ~9pp) is attributable to temporal features specifically,
  corroborated at two window lengths independently, though neither effect
  alone fully clears 95% confidence -- see `docs/methodology.md` and
  `docs/ablation_results.md` for the biology, citations, and the full
  decomposition.
- **Operating point:** the raw 22.3% false-positive rate isn't deployable
  for a farmer-facing alert system, and it's also a WINDOW-level number --
  `predict_pest()` pools predictions across a clip's windows before
  deciding, and the operating point is chosen from that CLIP-level curve
  (Prompt 10), not the window-level one. A confidence threshold of 0.45
  (chosen from a measured precision/recall/false-alarm sweep) gets 90.1%
  precision / 72.7% recall / 7.7% false-positive rate at the clip level,
  and is now `R/06_predict.R`'s actual default -- see
  `docs/operating_point.md` for the window-vs-clip comparison in full.
- **Compression cost:** codec-only delta -1.1% (95% range -8.8% to +6.0%,
  indistinguishable from zero), full-fidelity delta +2.8% (95% range -6.2%
  to +13.0%, suggestive of a real bandwidth cost but not yet confirmed at
  95%) -- see `docs/compression_delta.md` for the codec-vs-bandwidth
  decomposition. Adding temporal features did NOT narrow these deltas
  (hypothesized that envelope structure would survive compression better
  than spectral detail; not supported by this run).
- **Real WhatsApp round trip:** a real voice note (played aloud and
  recorded in WhatsApp) confirms the 8 kHz ceiling, but the room, speaker
  and phone microphone change the spectrum far more than the codec
  simulation above models -- it fails the pre-registered fidelity bar, so
  the numbers above are codec measurements, not deployment accuracy. See
  `docs/roundtrip_validation.md`.

## Licence

MIT for this repository's own code (see the `whatsappaudioR` package's own
`LICENSE.md` for that package specifically). Third-party data retains its
own licence -- see above.

## Status and limitations

Read `docs/methodology.md` for the full pipeline write-up, measured
numbers, and a candid limitations section (the 8kHz ceiling, real-data
coverage, and more). Read `PROGRESS.md` and `BLOCKERS.md` for the full
build log, including what's verified by actual execution vs. still open.

## Acknowledgements

Special thanks to **Dr. Amrit Pal**, our mentor for this project, for the
guidance and support throughout.
