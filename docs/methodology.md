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

Real numbers from **repeated grouped k-fold cross-validation** (5 folds x
10 repeats, 50 fold-evaluations total) on **real Orthoptera/Cicadidae
audio vs. real ESC-50 ambient audio**, both passed through the same
WhatsApp compression simulation (`docs/classifier_results.md`, regenerated
fresh by `R/05_train.R`). This is the Prompt 8 replacement for a single
train/test split -- see "The corpus-expansion, window-cap, and k-fold fix"
below for why a single split was never defensible here.

- **66.8% mean overall test accuracy (sd 5.4pp, 95% range 55.7% to
  74.7%). 22.3% mean false-positive rate against real ambient audio (sd
  7.1pp, range 8.3% to 35.8%).** *Cicada orni* is the strongest real class
  (90.1% mean recall, 92.2% pooled precision). The two *Chorthippus*
  species are frequently confused with EACH OTHER (not with ambient) --
  unsurprising for congeneric grasshoppers with similar stridulation
  mechanics. *C. brunneus* is notably the weakest class (34% mean recall)
  despite having the same number of source recordings as *C. biguttulus*
  (63.6% mean recall) -- worth investigating specifically in any follow-up
  (see PROGRESS.md's forward-looking note), not just attributed to sample
  size. See `docs/classifier_results.md` for the full pooled confusion
  matrix and per-class recall-stability table.
- Chewing-sound classes are **deliberately excluded** from this classifier
  (a documented judgement call, not an oversight): the codec experiment
  already answers the chewing question at the signal level more directly,
  every recording is a contact-sensor capture (so a classifier trained on
  them would still only measure a ceiling, not real-world viability), and
  chewing/Fall Armyworm is explicitly out of the current MVP scope (see
  below).

**This is a real, harder, and far more honestly-measured result than any
earlier report from this project, and that progression is deliberate, not
a regression.** This project's headline classifier number has gone through
three stages: (1) an original "0% false-positive rate," measured by
separating synthetic tone stacks from real ambient audio -- a trivial
task, not a real one; (2) 86.9% accuracy / 8.7% FPR from a single grouped
split on a 5-recordings-per-species corpus, later shown (Prompt 7) to be
one lucky draw from a distribution ranging roughly 10-92%; (3) this run:
repeated grouped k-fold CV on an expanded ~45-recordings-per-species
corpus with a cap on windows per recording. Each stage is a harder number
than the one before it, and each is more honest -- the flattering earlier
figures were never actually true, just measured badly. All three are kept
in `PROGRESS.md`'s history, clearly labelled, for anyone auditing how the
project's own numbers evolved.

**Source-recording counts per real target class (the number that actually
bounds every claim above):** *C. biguttulus* 45, *C. brunneus* 45, *Cicada
orni* 45, ambient 145 (up from 5/5/5/69 before Prompt 8 -- see below for
how much that alone changed the reliability of these numbers).

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
picked arbitrarily -- at -35dB relative, it drops roughly 1-2% of windows
project-wide (1.0-1.2% in the current corpus), originally found to be
concentrated almost entirely in one long recording responsible for the
`harmonic_energy_ratio` NA confound below.

**This also resolved a previously-unexplained feature-extraction failure.**
19 of 1251 windows used to fail feature extraction outright (a
`missing value where TRUE/FALSE needed` error inside `wa_features()`'s
spectral-property code). Root-caused: every one of those 19 windows was
independently flagged as near-silent by the same gate -- same underlying
cause as the `harmonic_energy_ratio` confound below (degenerate spectra
from near-empty audio break more than one downstream calculation, not
just the one already fixed). The gate removes these windows before
feature extraction is attempted, so the failure no longer occurs (0
feature-extraction failures across all three arms in every run since).

**A second window-population fix (Prompt 8, Step 3): windows per source
recording are now capped, not just gated.** Even after silence-gating,
one long recording could still contribute far more windows than any
other (max=411 windows from a single file, in the pre-expansion corpus) --
enough to dominate whichever fold it landed in, and a direct contributor
to the ~10-92% per-arm accuracy swing Prompt 7 found. `R/03_preprocess.R`
now caps windows per recording at `MAX_WINDOWS_PER_SOURCE = 20`, sampled
evenly across the recording's timeline (not its first 20 windows, which
would bias every capped recording toward its opening seconds). In the
current corpus this brings the windows-per-recording distribution to
min=1, p25=4, median=4, p75=13, max=20 (299 recordings) -- no single
recording can be more than a small, bounded share of any fold.

**Inference-time consequence:** if an entire incoming voice note is gated
(uniformly near its own noise floor -- e.g. background silence, a muted
recording), `predict_pest()` returns `gated_silent = TRUE` rather than
guessing on noise, and the webhook routes this through the existing
low-confidence reply path with a message asking for a louder or longer
recording -- not an error, and not a spurious class guess.

## The compression delta: codec damage vs. total transport cost

**Prompt 7 found the original single-seed, single-condition version of
this analysis was not yet a reportable number, for three separate reasons.
Prompt 8 fixed the underlying cause of the instability itself (more source
recordings, a per-recording window cap) rather than just re-measuring the
same small corpus more carefully. Full numbers, methodology, and the "why"
behind each one live in `docs/compression_delta.md`, regenerated fresh by
`R/07_compression_delta.R`; summarised here, not restated in full, so the
two documents can't drift apart.**

1. **"Uncompressed" was ambiguous** (Prompt 7). The original uncompressed
   arm resampled to WhatsApp's own 16kHz sample rate and skipped only the
   Opus round-trip -- it isolated codec quantization damage with
   bandwidth held constant, and said nothing about the bandwidth
   WhatsApp's 16kHz sample rate itself discards (the same 8kHz ceiling
   `docs/codec_findings.md` already establishes destroys content above
   it). Built as two separate, clearly-named controls: **codec-only**
   (still 16kHz, no Opus) and **full-fidelity** (resampled to a common
   48kHz, no Opus -- the raw-upload-path comparison). The gap between the
   two deltas decomposes total transport cost into a codec component and
   a bandwidth component.
2. **A bare point estimate is indefensible at this sample size**
   (Prompt 7's finding; Prompt 8's fix). With only 4-5 source recordings
   per real target class, which seed a single train/val/test split
   happened to use could swing overall test accuracy from roughly 10% to
   92% on its own. Prompt 8 expanded the corpus to ~45 source recordings
   per species (see "The corpus-expansion, window-cap, and k-fold fix"
   below) and replaced random grouped splits with **repeated grouped
   k-fold cross-validation** (5 folds x 10 repeats, the SAME fold
   assignment shared across all three arms) -- every recording serves as
   test data across folds by construction, not left to chance.
3. **Near-silent windows were mislabelled data**, addressed by the energy
   gate above, applied identically to every arm.

### The corpus-expansion, window-cap, and k-fold fix (Prompt 8)

Real per-species source recordings went from 5 (an artificial cap on
already-downloaded data) to 22/17/20 (cap removed, Step 1) to 45/45/45
(corpus expansion, Step 2) -- see PROGRESS.md for the isolated
before/after measurement of Step 1 alone: removing the cap dropped
per-arm accuracy SD from ~25.8pp to ~15.0pp on its own, before any other
change. Step 3 added a cap on windows per source recording (20, sampled
evenly across each recording's timeline) so no single long recording can
dominate a fold, and switched evaluation from random grouped splits to
repeated grouped k-fold CV.

**Combined result: per-arm accuracy SD dropped from ~25-27 points
(Prompt 7) to ~4.4-5.4 points -- roughly a 5x tighter spread** (mean
accuracy: compressed 66.8%, codec-only 67.7%, full-fidelity 70.4%, each
with a 95% range of about 10-20 points instead of ~80). **This narrowing
is itself a result**, not just cleanup: it demonstrates the earlier
instability was substantially a sampling artifact -- too few source
recordings, no bound on how much one long recording could dominate a
fold -- not an inherent property of the classification task.

**Deltas (paired per fold-iteration, mean across 50 fold-evaluations):
codec-only +0.9% (95% range -4.2% to +5.8%), full-fidelity +3.6% (95%
range -4.5% to +12.7%), bandwidth component +2.7% (95% range -5.8% to
+11.1%).**

**Both deltas' 95% ranges still include zero, so neither is
distinguishable from zero at conventional confidence -- but that range is
now roughly half as wide as before expansion**, which is a materially
stronger statement than the pre-expansion result repeated with smaller
numbers. Applying the same bar consistently (a range that excludes zero
counts as "distinguishable," one that doesn't, doesn't): the **codec-only
delta remains squarely indistinguishable from zero** -- the Opus codec in
isolation cannot be shown to cost this classifier anything measurable.
The **full-fidelity delta is more ambiguous**: its point estimate (+3.6%)
is meaningfully positive and most of its range sits above zero, at least
suggestive of a real bandwidth cost consistent with the codec experiment's
finding that content above 8kHz is destroyed outright -- but the range's
lower edge still touches slightly negative territory, so this corpus
cannot yet confirm that cost at 95%. The honest read: this is the first
run where a real bandwidth cost looks plausible rather than purely noise,
not a confirmed finding.

**What this does and doesn't say:** compatible with, and not
contradicting, the codec experiment's signal-level finding that real
Orthoptera stridulation survives the compression well -- but this corpus
still cannot put a precision tighter than roughly +/-5 to +/-9 percentage
points on that claim at the classifier level. What would narrow it
further is more distinct source recordings per target species, not more
folds/repeats of the same ~45. Does **not** extend to chewing-sound
classes (excluded from this comparison) or to any condition not covered
by the classifier above (field noise, distance, phone microphone
variability, species outside the trained set).

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
- **Small sample sizes, quantified and measurably improved, but not
  solved.** Each real target class now has 45 distinct source recordings
  (up from 5, then 22/17/20, across Prompt 7 and Prompt 8's Steps 1-2).
  Repeated grouped k-fold CV (`docs/compression_delta.md`,
  `docs/classifier_results.md`) shows this expansion cut per-arm accuracy
  SD roughly 5x (from ~26pp to ~5pp) and both compression deltas' 95%
  ranges roughly in half -- real, substantial progress -- but both deltas
  still cannot be distinguished from zero at a precision better than
  roughly +/-5 to +/-9 percentage points, and per-class recall for the
  smallest classes (`synthetic_tone_plus_noise`, 4 source files) still
  spans its entire possible range across folds. No number in this project
  is a single-split point estimate anymore; every headline figure is a
  mean with an explicit interval, and every table states the source-
  recording count behind it. More source recordings per class is what
  would narrow the remaining intervals further, not more folds or repeats
  of the same corpus.
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
