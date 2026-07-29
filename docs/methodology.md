# Methodology

## Pipeline overview

1. **Ingest.** A WhatsApp voice note (Opus/Ogg, 16kHz, ~16kbps, mono) arrives
   at `api/plumber.R`'s `/webhook` endpoint via Twilio's WhatsApp Sandbox.
2. **Decode.** `whatsappaudioR::wa_read()` shells out to a system `ffmpeg`
   (with `libopus`) to decode to PCM.
3. **Validate.** Reject non-audio attachments and clips under 3 seconds,
   with an explicit farmer-facing message for each (never a silent failure).
4. **Feature extraction.** `whatsappaudioR::wa_features()` computes a
   documented, inspectable feature vector: peak frequency, spectral
   centroid, flatness, entropy, rolloff85, dominant-frequency stability, a
   harmonic-energy heuristic, and 12 MFCCs.
5. **Classify.** `R/06_predict.R` loads `models/classifier.rds` (a random
   forest trained by `R/05_train.R`) and returns the top-3 classes with
   confidence scores and an explicit `low_confidence` flag below a tunable
   threshold (0.4 by default).
6. **Log.** Every request is logged to `logs/requests.jsonl` with its audio
   hash, outcome, and (on success) top classes/confidences -- for debugging
   and for the dashboard's replay mode.
7. **Reply.** A TwiML response with the pest ID + confidence, or an honest
   "no confident match, please resend a longer recording" message.

Training data flows through a parallel pipeline
(`00_synthetic_corpus.R`/`01_download_data.R` -> `03_preprocess.R` ->
`04_features.R` -> `05_train.R`) that applies the *same* WhatsApp
compression simulation to training audio that the webhook applies to real
incoming voice notes -- otherwise the model would be trained on clean audio
and served on 16kbps Opus, a silent train/serve skew that would invalidate
every reported number.

## The codec finding (Deliverable A)

**The risk:** WhatsApp voice notes are Opus-encoded at 16kHz/~16kbps. The
16kHz sample rate imposes a hard 8kHz Nyquist ceiling -- content above 8kHz
is not attenuated, it is physically absent from the encoded signal. Whether
our target pest signatures survive this, and the additional
speech-optimised (SILK, tuned for the 300Hz-3400Hz telephone band) noise
shaping, needed to be measured, not assumed.

**What we measured** (`R/02_codec_experiment.R`, full tables in
`docs/codec_findings.md`, regenerated fresh on every run -- these are
real numbers from an actual Opus/Ogg round-trip, not estimates):

- A synthetic ground-truth signal at 10kHz (above the 8kHz ceiling) shows
  survivability 0.101 and near-zero band retention above 8kHz -- confirming
  the simulation genuinely destroys content above Nyquist, not just in
  theory.
- Low-frequency, harmonic-rich signals survive well: a stridulation
  analogue (~250Hz fundamental + harmonics) scores 0.964 survivability; a
  mosquito-wingbeat analogue (~450Hz) scores 0.807. Both sit comfortably
  inside the surviving band, matching the brief's prediction for
  Orthoptera stridulation/wingbeat and mosquito wingbeat.
- A chewing-pulse-train analogue deliberately spanning across the 8kHz
  wall (broadband noise bursts, 2-12kHz) scores 0.924 overall but -- as
  expected by construction -- has essentially zero retention in its
  above-8kHz component specifically. **CORRECTION: this is not a chewing-
  sound finding.** It was measured on a synthetic amplitude-modulated noise
  pulse train built to resemble the general *shape* of a chewing signal
  (bursty, broadband) -- not on any actual recording of an insect chewing
  or feeding. Whether real larval chewing/feeding sounds survive the 8kHz
  ceiling was, as of the previous run, still completely unknown, and this
  bullet should never have been read as answering that question. See
  "Real chewing-sound findings" below for what's actually measured now.
- Broadband noise scores lower on Pearson correlation (0.249) than cosine
  similarity (0.967) -- expected for noise-like signals, where correlation
  is a poor shape descriptor but magnitude similarity still reads as
  "similar overall energy."

**Caveat: these are synthetic ground-truth signals, not real pest
recordings.** The round-trip sanity check against a real WhatsApp-recorded
`.opus` file (`compare_real_vs_simulated()`, procedure documented in
`R/02_codec_experiment.R`) has not been run -- no real WhatsApp export has
been provided yet. Until that happens, treat the FFmpeg-based simulation as
a reasonable but unverified proxy for WhatsApp's actual client-side
encoding pipeline (which may differ in codec version, VBR/CBR behaviour,
or client-side preprocessing like noise suppression/AGC).

## Data sources actually used

InsectSet459 (the dataset named in the original brief) only distributes as
three monolithic Zenodo zips (51.2GB/16.4GB/16.0GB, 83.7GB total) with no
per-species download option -- far over this project's 2GB download
budget. What was actually used instead:

- **A synthetic ground-truth corpus** (`R/00_synthetic_corpus.R`): tones
  and harmonic stacks at known frequencies matching target pests (a
  stridulation analogue, a mosquito-wingbeat analogue), an above-8kHz
  control signal, broadband noise, amplitude-modulated chewing-style pulse
  trains, and tone+noise mixtures at several SNRs -- 5 jittered variants
  per class so train/val/test splitting has enough source recordings to
  work with. This is what most of the numbers in this document are based
  on. **It is not real insect audio.**
- **ESC-50** (real, 560 clips across 14 categories: wind, rain, crickets,
  frog, dog, cow, engine, footsteps, door-knock, clock-tick, crackling
  fire, chirping birds, car horn, airplane) as the ambient/negative class.
  Deliberately includes "crickets" as a hard negative -- a real Orthoptera
  sound that is *not* one of our target pests, to check the classifier is
  discriminating species, not just "insect vs. not."
- **xeno-canto** (target pest species: Desert Locust, Migratory Locust,
  *Culex* mosquito) -- attempted, currently failing (HTTP 404 on all three
  queries; see `BLOCKERS.md`). **As a result, this build has zero real
  recordings of any actual target pest species.** Every pest-class number
  in `docs/classifier_results.md` is trained and tested on the synthetic
  corpus only; the ambient/negative class is the only real audio in the
  training set.

## Classifier results (Deliverable D) -- CORRECTED FRAMING, see below

**This section's headline number from the previous run was weaker than it
read, and is corrected here rather than quietly dropped.** The "0%
false-positive rate against ambient" reported previously was measured by
separating **synthetic, parametrically-generated harmonic tone stacks**
from **real ESC-50 ambient recordings**. Those two classes differ in far
more ways than "pest vs. not" -- synthetic tones are noiseless, perfectly
periodic, studio-clean signals; ESC-50 clips are real-world recordings with
real microphone noise floors, room tone, and recording-chain artifacts. A
classifier separating them is very likely picking up on *recording
conditions* (synthetic-generation artifacts vs. real-world recording
artifacts), not necessarily on the acoustic pest signature itself. **That 0% number
should not have been presented as evidence the system can tell a real pest
from real ambient noise -- it hadn't been tested on that question at all.**
This is exactly the kind of trivial-separation result that inflates
reported performance without being wrong on its own terms; it needed
naming, not just a caveat buried in limitations.

Real (InsectSet459) vs. real (ESC-50) results, which actually test the
question, are in `docs/classifier_results.md` (regenerated fresh by
`R/05_train.R`) -- see the numbers there, expected to be substantially
weaker than the synthetic-vs-real run, and reported as measured either way.
The synthetic-only numbers from the previous run are retained separately
in this document's history (see `PROGRESS.md`) for comparison, clearly
labelled as synthetic-vs-real and not a real-pest-detection result.

## Limitations (read this before quoting any number above)

- **No real pest audio.** Every pest-class result above comes from a
  synthetic, parametrically-generated ground-truth corpus, not real
  recordings of real insects. This validates that the *pipeline mechanics*
  work correctly (compression simulation, feature extraction, grouped
  splitting, honest metric computation) -- it is not evidence of
  real-world field performance. Getting real xeno-canto/iNaturalist
  recordings for the target species is the single most important next
  step before any performance claim can be made about actual pests.
- **The 8kHz Nyquist ceiling is real and permanent.** Any pest signature
  whose discriminative energy lives above 8kHz cannot be recovered from a
  WhatsApp voice note, full stop. This is a physical constraint, not an
  engineering gap -- pests whose calls depend on higher-frequency content
  would need a different data-collection channel entirely (raw file
  upload, not a compressed voice note).
- **Species coverage is currently limited to Orthoptera-style
  stridulation, mosquito wingbeat, and lepidopteran chewing analogues.**
  No coverage of other agriculturally important pest classes.
- **Untested in real field-noise conditions.** Wind, rain, human speech,
  livestock, and engine noise are represented via ESC-50 (studio-recorded
  environmental sounds), not real farm-at-night recordings with a phone
  microphone at unknown distance/orientation.
- **Single-microphone, no localisation.** The system identifies *what*
  might be present in a recording, not *where* on the farm, and cannot
  estimate distance or direction to the source.
- **The real-vs-simulated codec round-trip check has not been run** (see
  above) -- the compression simulation's fidelity to WhatsApp's actual
  client-side encoding is currently unverified against a real WhatsApp
  export.
- **Confidence scores are random forest vote proportions**, not formally
  calibrated (e.g. Platt-scaled) probabilities -- a reasonable confidence
  proxy, but shouldn't be read as a literal well-calibrated probability.
- **Small sample sizes throughout.** Test-set class counts are in the
  single digits per class; do not treat precision/recall of 1.0 as "solved"
  -- it reflects a small, clean, synthetic test set.

See `BLOCKERS.md` for open engineering items (xeno-canto access, the `av`
package segfault workaround, Rtools) and `PROGRESS.md` for the full,
timestamped build log.
