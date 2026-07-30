# Methodology

## Pipeline overview

1. **Ingest.** A WhatsApp voice note (Opus/Ogg, 16kHz, ~16kbps, mono) arrives
   at `api/plumber.R`'s `/webhook` endpoint via Twilio's WhatsApp Sandbox.
2. **Decode.** `whatsappaudioR::wa_read()` shells out to a system `ffmpeg`
   (with `libopus`) to decode to PCM.
3. **Validate.** Reject non-audio attachments and clips under 3 seconds,
   with an explicit farmer-facing message for each (never a silent failure).
4. **Window, gate, extract features.** `R/06_predict.R` splits the incoming
   clip into the same 2-second windows training data is built from,
   drops any window too quiet relative to the clip's own loudest moment
   (`gate_silent_windows()`, R/utils.R -- see below), then runs
   `whatsappaudioR::wa_features()` on each surviving window: peak
   frequency, spectral centroid, flatness, entropy, rolloff85,
   dominant-frequency stability, a harmonic-energy heuristic, and 12 MFCCs.
5. **Classify.** `R/06_predict.R` loads `models/classifier.rds` (a random
   forest trained by `R/05_train.R`), predicts a class-probability vector
   per surviving window, and averages them into one final call: top-3
   classes, confidence scores, and an explicit `low_confidence` flag below
   a tunable threshold (0.4 by default). If every window in the clip was
   gated (no signal anywhere in the recording), returns `gated_silent =
   TRUE` instead of guessing on noise.
6. **Log.** Every request is logged to `logs/requests.jsonl` with its audio
   hash, outcome, and (on success) top classes/confidences -- for debugging
   and for the dashboard's replay mode.
7. **Reply.** A TwiML response with the pest ID + confidence, or an honest
   "no confident match, please resend a longer recording" message.

Training data flows through a parallel pipeline
(`00_synthetic_corpus.R`/`01_download_data.R`/`fetch_chewing_sounds.R` ->
`03_preprocess.R` -> `04_features.R` -> `05_train.R`) that applies the
*same* WhatsApp compression simulation to training audio that the webhook
applies to real incoming voice notes -- otherwise the model would be
trained on clean audio and served on 16kbps Opus, a silent train/serve
skew that would invalidate every reported number. `R/07_compression_delta.R`
additionally trains a second model on uncompressed audio (same sources,
same split) specifically to measure that skew's actual cost -- see below.

## Data sources actually used

**InsectSet459** (Faiss et al., 2025 -- see citation in `README.md`) is
this project's real-audio source for target species, but not via its own
distribution: the dataset's Zenodo record only ships as three monolithic
zips (Train/Validation/Test, 51.2GB/16.4GB/16.0GB -- even the *smallest*
split is over 8x this project's 2GB download budget, and there's no
per-species download option). Instead, `R/01_download_data.R` downloads
only the dataset's small (~7MB) annotation CSV, which carries a direct
source URL for every recording (iNaturalist, and for some rows,
xeno-canto), and fetches individual files straight from their original
public source -- bypassing the zips entirely, fully respecting the
dataset's own per-file CC licence and provenance metadata (recorded in
`data/raw/manifest.csv`).

**Target species: *Chorthippus biguttulus*, *Chorthippus brunneus*
(European field grasshoppers, family Acrididae), and *Cicada orni*
(Mediterranean cicada).** None of these are locusts. Acrididae stridulation
mechanics are genuinely representative of the family that includes true
locusts, so these are defensible acoustic proxies -- but the accurate claim
throughout this project is **"validated on Orthoptera stridulation using
European grasshoppers as acoustic proxies,"** never "validated on locusts."
InsectSet459 does not include *Schistocerca* or *Locusta* at all. 59 real
recordings were downloaded across the 3 species (22 / 17 / 20).

**Ambient/negative class: ESC-50** (Piczak, 2015), 560 real clips across 14
categories relevant to a farm-at-night setting (wind, rain, crickets, frog,
dog, cow, engine, footsteps, door-knock, clock-tick, crackling fire,
chirping birds, car horn, airplane) -- deliberately includes "crickets" as
a hard negative: a real Orthoptera sound that is *not* one of the target
species, to check the classifier discriminates species, not just
"insect vs. not." CC BY-NC 3.0 -- the **NC (non-commercial)** term is fine
for this hackathon/research context but would need revisiting before any
commercial deployment.

**Larval chewing/feeding sounds: USDA-ARS Reference Library of Digitized
Insect Sounds** (`R/fetch_chewing_sounds.R`) -- 15 real recordings across 5
species, fetched because InsectSet459 contains *only* Orthoptera and
Cicadidae and cannot answer the chewing-sound question at all (Fall
Armyworm is a lepidopteran larva; the dataset has no lepidopterans). Used
exclusively in the codec experiment (Deliverable A) -- **deliberately
excluded from the classifier's training set**, see below. Licence: US
federal government work, presumed public domain under 17 U.S.C. sec 105,
though the source page carries no explicit CC statement.

**Mosquito wingbeat: no real recording obtained.** Every mosquito-wingbeat
result in this project (survivability 0.800 in the original codec
experiment) is from a synthetic tone analogue, never validated against a
real recording. Flagged explicitly wherever this number is cited.

## The codec finding (Deliverable A)

**The risk:** WhatsApp voice notes are Opus-encoded at 16kHz/~16kbps. The
16kHz sample rate imposes a hard 8kHz Nyquist ceiling -- content above 8kHz
is not attenuated, it is physically absent from the encoded signal.

**Real Orthoptera/Cicadidae survivability, measured on real recordings**
(`docs/codec_findings.md`, regenerated fresh by `R/02_codec_experiment.R`):
*C. biguttulus* 0.986, *Cicada orni* 0.972, *C. brunneus* 0.956 -- all
comfortably inside the surviving band, directly confirming real Orthoptera
stridulation retains enough discriminative structure after the WhatsApp
round-trip to remain classifiable. A synthetic 10kHz ground-truth control
tone confirms the simulation genuinely destroys content above 8kHz
(survivability 0.101, >8kHz band retention 0) -- not just in theory.

**Real chewing/feeding sound survivability is poor-to-moderate, and was
measured under a best-case capture condition, not a realistic one.**
*Diaprepes abbreviatus* (root weevil, 0.892) and *Phyllophaga* (white grub,
0.823) survive reasonably; *Plodia interpunctella* (Indian meal moth, the
closest real Lepidoptera proxy to Fall Armyworm, 0.570) and *Sitophilus
oryzae* (rice weevil, 0.342, Pearson correlation only 0.080) survive
poorly. **Critically, every one of these recordings was captured with a
contact/vibration sensor** (Bruel & Kjaer accelerometer, piezoelectric
disk, PVDF film, 30/40kHz ultrasonic contact sensor, or soil microphone --
confirmed against the USDA-ARS source documentation, not inferred) --
never an open-air microphone. These numbers are therefore a **ceiling**:
best-case survivability given a clean, direct, no-air-path capture. A real
farmer's phone microphone, at unknown distance, through open air, with
farm background noise, would only be expected to do *worse*, never better.
This makes the case against WhatsApp-voice-note chewing detection stronger,
not weaker, than the raw numbers alone suggest.

**Round-trip sanity check against a real WhatsApp export: still not run.**
The manual procedure (`compare_real_vs_simulated()` in
`R/02_codec_experiment.R`) has been documented and ready since the first
session of this project; no genuine WhatsApp-exported `.opus` file has
ever been provided. The FFmpeg-based local simulation used for every number
in this document is unverified against WhatsApp's actual client-side
encoder.

## Classifier results (Deliverable D)

Real numbers from an actual train/test run on **real Orthoptera/Cicadidae
audio vs. real ESC-50 ambient audio**, both passed through the same
WhatsApp compression simulation (`docs/classifier_results.md`, regenerated
fresh by `R/05_train.R`): 109 source files, split 61 train / 19 val / 23
test source files on the default seed, after an energy gate (below) drops
near-silent windows.

- **88.5% overall test accuracy on the default seed.** *C. brunneus*
  separates cleanly; *C. biguttulus* is confused mainly with *C. brunneus*
  (the two congeneric grasshoppers are not cleanly separable by the
  current feature set); *Cicada orni*'s recall is the weakest of the three
  real classes. See `docs/classifier_results.md` for the full confusion
  matrix and precision/recall table for this specific seed.
- **This single-seed number is NOT a stable estimate -- see the next
  section.** Prompt 7 found that re-splitting this same data with
  different random seeds swings overall test accuracy from roughly 10% to
  92%, because only 4-5 source recordings back each real target species,
  and a handful of those recordings are far longer than the others. Read
  `docs/compression_delta.md`'s per-class recall table and its "why
  per-arm accuracy swings so much" section before treating 88.5% as
  precise-to-the-decimal ground truth for this classifier's real-world
  performance -- it is one honestly-reported draw from a wide distribution,
  not a converged estimate.
- Chewing-sound classes are **deliberately excluded** from this classifier
  (a documented judgement call, not an oversight): the codec experiment
  already answers the chewing question at the signal level more directly,
  every recording is a contact-sensor capture (so a classifier trained on
  them would still only measure a ceiling, not real-world viability), and
  chewing/Fall Armyworm is explicitly out of the current MVP scope (see
  below).

**This is a real, substantially harder result than an earlier run's
headline number, and that's the point.** An earlier version of this
document reported a "0% false-positive rate," measured by separating
**synthetic, parametrically-generated harmonic tone stacks** from real
ESC-50 ambient audio -- a trivial task (noiseless synthetic tones vs. real
microphone recordings), almost certainly reflecting recording-condition
differences rather than the acoustic pest signature. That number should
never have been read as "the system can tell a real pest from real
ambient noise"; it had not been tested on that question. It is retained in
`PROGRESS.md`'s history, clearly labelled as a trivial-separation artifact,
for anyone auditing how the project's own numbers evolved.

**Source-recording counts per real target class (the number that actually
bounds every claim above):** *C. biguttulus* 5, *C. brunneus* 5, *Cicada
orni* 5, ambient 69. A competent judge will ask about this before anything
else -- see `docs/compression_delta.md` for how directly it explains the
instability above.

## Near-silent windows are gated, not kept and mislabelled

A 2-second training window inherits its whole source recording's label
regardless of whether that specific window actually contains any of the
source's signal -- a long recording with quiet gaps between call bouts
produces windows that are technically correctly labelled but acoustically
empty. `R/utils.R`'s `gate_silent_windows()` drops any window more than
`ENERGY_GATE_DB` (-35dB) quieter than the loudest window from the **same**
source recording, applied identically during training
(`R/03_preprocess.R`) and at inference (`R/06_predict.R` now windows and
gates an incoming voice note the same way, rather than treating the whole
clip as one feature vector -- see below). Deliberately relative to each
recording's own peak, not an absolute loudness floor: an absolute-dBFS
threshold would have unfairly gated whole real species classes, since some
real recordings in this corpus (e.g. several *C. biguttulus*/*C. brunneus*
files) were captured at low gain and have an absolute median window RMS
below -60dBFS despite containing real signal throughout. Calibrated
empirically against the existing corpus (see `PROGRESS.md`) rather than
picked arbitrarily -- at -35dB relative, it drops ~2% of windows
project-wide, concentrated almost entirely in the one long recording
responsible for the `harmonic_energy_ratio` NA confound below.

**This also resolved a previously-unexplained feature-extraction failure.**
19 of 1251 windows used to fail feature extraction outright (a
`missing value where TRUE/FALSE needed` error inside `wa_features()`'s
spectral-property code). Root-caused: every one of those 19 windows is
independently flagged as near-silent by the same gate -- same underlying
cause as the `harmonic_energy_ratio` confound below (degenerate spectra
from near-empty audio break more than one downstream calculation, not
just the one already fixed). The gate removes these windows before
feature extraction is attempted, so the failure no longer occurs (0 of
1225/1224/1224 windows failed across all three arms in the current run).

**Inference-time consequence:** if an entire incoming voice note is gated
(uniformly near its own noise floor -- e.g. background silence, a muted
recording), `predict_pest()` returns `gated_silent = TRUE` rather than
guessing on noise, and the webhook routes this through the existing
low-confidence reply path with a message asking for a louder or longer
recording -- not an error, and not a spurious class guess.

## The compression delta: codec damage vs. total transport cost

**Prompt 7 found the original single-seed, single-condition version of
this analysis was not yet a reportable number, for three separate reasons
-- all now fixed. Full numbers, methodology, and the "why" behind each
one live in `docs/compression_delta.md`, regenerated fresh by
`R/07_compression_delta.R`; summarised here, not restated in full, so the
two documents can't drift apart.**

1. **"Uncompressed" was ambiguous.** The original uncompressed arm
   resampled to WhatsApp's own 16kHz sample rate and skipped only the Opus
   round-trip -- it isolated codec quantization damage with bandwidth held
   constant, and said nothing about the bandwidth WhatsApp's 16kHz sample
   rate itself discards (the same 8kHz ceiling `docs/codec_findings.md`
   already establishes destroys content above it). The original "-0.4%,
   no cost from using WhatsApp as the transport" framing overstated what
   had actually been measured. Now built as two separate, clearly-named
   controls: **codec-only** (still 16kHz, no Opus) and **full-fidelity**
   (resampled to a common 48kHz, no Opus -- the raw-upload-path
   comparison). The gap between the two deltas decomposes total transport
   cost into a codec component and a bandwidth component.
2. **A bare point estimate is indefensible at this sample size.** Only
   4-5 source recordings back each real target class, and their durations
   vary enormously, so which seed a single train/val/test split happens to
   use can swing overall test accuracy from roughly 10% to 92% on its own
   -- almost independent of anything the classifier is actually good or
   bad at (a handful of unusually long recordings can each become 60-90%
   of an entire test split if they land there). `R/07_compression_delta.R`
   now runs 50 different grouped-split seeds for every arm and reports the
   full seed distribution, not one draw from it.
3. **Near-silent windows were mislabelled data**, addressed by the energy
   gate above, applied identically to every arm.

**Result (mean across 50 seeds): compressed 56.8%, codec-only 55.3%,
full-fidelity 55.7% -- codec-only delta -1.4% (95% seed range -9.6% to
+6.4%), full-fidelity delta -1.1% (95% seed range -13.4% to +9.4%).**
**Both deltas are indistinguishable from zero at this sample size** -- a
different, weaker claim than "compression is free," and a materially more
honest one than the original single-seed "-0.4%" framing. The paired
per-seed delta is far more stable than either arm's raw accuracy (delta SD
~4.5-6.4 points vs. ~25-27 points for raw per-arm accuracy) because the
same lucky-or-unlucky long recording lands in the same split position for
all three arms on a given seed and cancels out of the difference -- which
is exactly why the delta, not raw accuracy, is the number to trust here.

**What this does and doesn't say:** compatible with, and not contradicting,
the codec experiment's signal-level finding that real Orthoptera
stridulation survives the compression well -- but at this sample size
neither delta can be shown to be non-zero with a precision better than
roughly +/-10 percentage points. What would actually narrow this is more
distinct source recordings per target species, not more re-splitting or
re-windowing of the same ~5 files. Does **not** extend to chewing-sound
classes (excluded from this comparison) or to any condition not covered by
the classifier above (field noise, distance, phone microphone variability,
species outside the trained set).

## The chewing-sound / Fall Armyworm scope decision

InsectSet459 contains only Orthoptera and Cicadidae -- it cannot speak to
Fall Armyworm (Lepidoptera) at all. A time-boxed search found the
USDA-ARS chewing-sound library (above), which does include a Lepidoptera
larva (*Plodia interpunctella*, Indian meal moth) as the closest available
proxy. Having found real chewing-sound data, the honest reading of the
codec results is: (1) survivability is poor-to-moderate even under
best-case contact-sensor capture, and (2) that capture method itself means
these numbers cannot speak to real-world open-air/phone-microphone
viability at all.

**Decision: the current MVP is scoped to stridulation/wingbeat pests
only.** Chewing-sound detection, including Fall Armyworm specifically, is
a stated **phase-2 target requiring a fundamentally different capture
method** -- a contact/vibration sensor design, not a WhatsApp voice note
from an open-air phone microphone. This is reflected in `README.md`'s
framing: Fall Armyworm is not presented as a current capability anywhere
in this project.

## Limitations (read this before quoting any number above)

- **The single biggest open gap: no genuine WhatsApp-exported audio has
  ever been tested against the local compression simulation**, despite the
  manual procedure for doing so being documented since the first session.
  Every "real audio" number in this project used real *source* recordings
  run through a local FFmpeg simulation of WhatsApp's encoder -- not
  verified against what a real phone/WhatsApp client actually produces.
- **The 8kHz Nyquist ceiling is real and permanent.** Any pest signature
  whose discriminative energy lives above 8kHz cannot be recovered from a
  WhatsApp voice note. Pests whose calls depend on higher-frequency content
  would need raw file upload, not a compressed voice note.
- **No real mosquito wingbeat recording has been obtained or tested** --
  that number remains synthetic-only.
- **Chewing-sound survivability numbers are a best-case ceiling** (contact-
  sensor capture), not evidence of open-air/phone-microphone viability --
  see above.
- **Species coverage is 3 real species (2 grasshoppers, 1 cicada) plus
  untested-in-reality mosquito wingbeat.** No coverage of any other
  agriculturally significant pest.
- **Untested in real field-noise conditions.** ESC-50 is curated
  environmental audio, not real farm-at-night background noise at unknown
  distance through a real phone microphone.
- **Small sample sizes throughout, quantified, not just asserted.** Each
  real target class has only 4-5 distinct source recordings. Prompt 7's
  50-seed re-split analysis (`docs/compression_delta.md`) shows exactly
  what that costs: overall test accuracy on this classifier swings from
  roughly 10% to 92% depending only on which seed is used, and the
  compression deltas are not distinguishable from zero at a precision
  better than about +/-10 percentage points. Treat any single-seed
  accuracy/precision/recall figure in this project (including the 88.5%
  headline above) as one honest draw from that wide distribution, not a
  converged estimate -- more source recordings per class is what would
  actually narrow it, not more re-splitting of the same ~5 files.
- **Single-microphone, no localisation.** The system identifies *what*
  might be present, not *where* on the farm, and cannot estimate distance
  or direction.
- **Confidence scores are random forest vote proportions**, not formally
  calibrated (e.g. Platt-scaled) probabilities.
- **Live Twilio round trip untested** -- the webhook is verified against a
  mock payload and the real trained model, never an actual WhatsApp Sandbox
  message (needs a Twilio account; see `docs/twilio_setup.md` and
  `BLOCKERS.md`).

See `BLOCKERS.md` for open engineering items and `PROGRESS.md` for the
full, timestamped build log, including a "What we can and cannot claim"
section with the same claims broken out by evidence strength.
