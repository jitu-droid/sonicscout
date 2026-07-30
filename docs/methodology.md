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
fresh by `R/05_train.R`): 109 source files (up from an initial 40 after a
deeper download pass), 1251 windows, split 61 train / 19 val / 23 test
source files.

- **86.9% overall test accuracy. 8.7% false-positive rate against real
  ambient audio** -- roughly 1 in 11 true-ambient test windows would
  trigger a false pest alert.
- *C. brunneus* separates cleanly (precision 0.991, recall 0.917).
  *C. biguttulus* is weaker (precision 0.667, recall 0.875), confused
  mainly with *C. brunneus* -- the two congeneric grasshoppers are not
  cleanly separable by the current feature set, only distinguishable from
  coarser categories. *Cicada orni* has low recall (0.462, often read as
  ambient) but perfect precision (1.000).
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

**Sample-size caveat:** some classes have as few as 1-2 test source
recordings. Treat 86.9%/8.7% as real and meaningfully harder than the
synthetic-vs-real number, not as precise-to-the-decimal ground truth.

## The compression delta (the single most interesting number this project produces)

`R/07_compression_delta.R` trains and evaluates a second model on the
*same* source recordings and the *same* grouped train/val/test split,
differing only in whether the audio went through WhatsApp's Opus/Ogg
compression before feature extraction. **Result: 86.9% (compressed) vs.
86.6% (uncompressed) test accuracy -- a -0.4% delta, i.e. no detectable
accuracy cost from using WhatsApp as the transport**, for these classes,
on this classifier.

**This number was wrong by a wide margin on the first attempt, and getting
it right required finding and fixing a real bug, not just reporting
whatever came out.** The first run showed a striking -15.9% delta
(uncompressed at only 71.0%), which turned out to be an artifact:
`wa_features()`'s `harmonic_energy_ratio` returned `NA` for any window with
no well-defined peak frequency (near-silent windows), silently dropping
those windows from `complete.cases()`-based training/evaluation filters.
Two long real recordings had far more such windows in the uncompressed
condition specifically -- genuine silence stays silent in uncompressed
audio, while WhatsApp's own lossy noise-shaping incidentally raises the
noise floor just enough to avoid a literal zero-Hz peak in the compressed
version. Net effect: the uncompressed model's test accuracy was computed
on 100 usable windows out of ~217, versus 221 of ~222 for compressed -- not
a fair comparison, just very different amounts of usable data. Fixed
`harmonic_energy_ratio` to return 0 (a legitimate "no measurable harmonic
structure" value, not "unknown") in `pkg/whatsappaudioR/R/wa_features.R`,
added a regression test, and re-ran: the delta collapsed to -0.4%. Full
account in `docs/compression_delta.md`.

**What this does and doesn't say:** consistent with, and adding a
classifier-level data point to, the codec experiment's finding that real
Orthoptera stridulation survives the compression well. Does **not** extend
to chewing-sound classes (excluded from this comparison) or to any
condition not covered by the classifier above (field noise, distance,
phone microphone variability, species outside the trained set).

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
- **Small sample sizes throughout.** Some classifier classes have as few
  as 1-2 test source recordings; treat all precision/recall/accuracy
  figures as real but noisy, not precise ground truth.
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
