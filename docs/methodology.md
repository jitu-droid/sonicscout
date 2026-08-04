# Methodology

## Pipeline overview

1. **Ingest.** A WhatsApp voice note (Opus/Ogg, 16kHz, ~16kbps, mono) arrives
   at `api/plumber.R`'s `/webhook` endpoint via Twilio's WhatsApp Sandbox.
2. **Decode.** `whatsappaudioR::wa_read()` shells out to a system `ffmpeg`
   (with `libopus`) to decode to PCM.
3. **Validate.** Reject non-audio attachments and clips under 3 seconds,
   with an explicit farmer-facing message for each (never a silent failure).
4. **Window, gate, extract features.** `R/06_predict.R` splits the incoming
   clip into the same 4-second windows training data is built from (raised
   from 2.0s in Prompt 9 -- see "Window length and temporal features"
   below), drops any window too quiet relative to the clip's own loudest
   moment (`gate_silent_windows()`, R/utils.R -- see below), then runs
   `whatsappaudioR::wa_features()` on each surviving window: the original
   spectral feature set (peak frequency, spectral centroid, flatness,
   entropy, rolloff85, dominant-frequency stability, a harmonic-energy
   heuristic, 12 MFCCs) plus 11 temporal features added in Prompt 9 (pulse/
   syllable rate, inter-pulse-interval statistics, an envelope modulation
   spectrum, temporal entropy, duty cycle, and phrase-level bout structure)
   -- see below for why.
5. **Classify.** `R/06_predict.R` loads `models/classifier.rds` (a random
   forest trained by `R/05_train.R`), predicts a class-probability vector
   per surviving window, and averages them into one final call: top-3
   classes, confidence scores, and an explicit `low_confidence` flag below
   a tunable threshold (0.45 -- set from a measured precision/recall/false-
   alarm trade-off, not a round-number default; see "Operating point"
   below). If every window in the clip was gated (no signal anywhere in
   the recording), returns `gated_silent = TRUE` instead of guessing on
   noise.
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

## Why C. biguttulus and C. brunneus are confused, and why that's biologically expected

*Chorthippus biguttulus* and *C. brunneus* are **sympatric congeners** --
they co-occur across much of Europe -- whose species boundary is not
maintained by anything visible or spectrally obvious; it is maintained
**acoustically**, by the female's response to the male's song, and
specifically by the song's **temporal** structure. Von Helversen & von
Helversen (1997, *J Comp Physiol A* 180:373-386) established that the
decisive cues for song recognition in *C. biguttulus* reside "in the
temporal pattern of amplitude modulations, i.e., in a song's envelope" --
syllables of 30-200ms with 7-40ms pauses between them, repeated at roughly
10Hz, organised into phrases of ~20 syllables lasting roughly 2-4 seconds
each. Gottsberger & Mayer (2007, *J Comp Physiol A* 193:703-714),
studying F1/F2/backcross hybrids between these two exact species, found
hybrid songs intermediate in phrase number and duration between the two
parental species, but with species-specific SYLLABLE structure within
phrases "largely lost in hybrids... produced, if at all, in an irregular
and imperfect manner" -- i.e. the temporal fine structure is precisely the
axis these two species diverge on, and precisely the axis that breaks
down first when their acoustic communication systems are mixed.

**This project's original feature set was almost entirely spectral**
(peak frequency, spectral centroid/flatness/entropy/rolloff, a harmonic-
energy heuristic, 12 MFCCs) -- asking a classifier to separate two species
along the dimension the literature says they are MOST alike on, while
never measuring the dimension that the literature says actually
distinguishes them. This is the motivation for Prompt 9's temporal
features, below -- not a generic "add more features and see" exercise,
but a feature-engineering decision aimed at a specific, cited, documented
biological mechanism.

## Window length and temporal features (Prompt 9, Part 1)

**Window length was checked against the literature before anything else.**
A full song phrase in these species runs ~2-4 seconds (~20 syllables at a
~10Hz repetition rate -- von Helversen & von Helversen 1997, above). The
project's original 2-second training window could not reliably contain
one full phrase. `WINDOW_SECONDS` was raised to 4.0 (HOP_SECONDS to 2.0,
same 50% overlap ratio as before) -- checked empirically first that this
doesn't just shrink the usable corpus: real per-species recordings have a
median duration of 14-17s, with only 0-9% under 6 seconds, so lengthening
the window barely changes how many windows most recordings can still
produce. `MAX_WINDOWS_PER_SOURCE` (the per-recording cap from Prompt 8)
was reconsidered, not silently left alone, and kept at 20 -- it still
bounds one recording's maximum fold-share to the same order of magnitude
as before, just over a longer absolute timeline span. See `R/utils.R` and
`R/03_preprocess.R` for the full reasoning.

**Eleven temporal features were added** to `whatsappaudioR::wa_features()`
(`pkg/whatsappaudioR/R/wa_features.R`), all derived from the Hilbert
amplitude envelope (`seewave::env()`) at two smoothing scales: pulse/
syllable rate, inter-pulse-interval mean/sd/coefficient-of-variation, an
envelope modulation spectrum (an FFT of the envelope itself, not the
audio -- its dominant frequency and prominence), temporal entropy, duty
cycle, and phrase-level bout structure (duration, count, duty cycle) from
a coarser envelope scale. All return 0 (not NA) on a degenerate window,
matching the discipline the `harmonic_energy_ratio` NA-leak fix (Session
3) established -- an NA here would silently drop the window from training,
which is exactly the bug class this project has repeatedly caught and
fixed (including once more this session: `stats::sd()` of a single
inter-pulse interval, i.e. exactly 2 detected peaks, returns NA rather
than erroring, and was found dropping real training rows before being
fixed the same way).

**Result: *C. brunneus* mean recall rose from 34% (Prompt 8, spectral-only
features, 2s window) to 43.1% (Prompt 9, temporal features added, 4s
window) -- a real gain in exactly the class this was aimed at**, while
*C. biguttulus* stayed essentially flat (63.6% -> 62.4%) and overall
accuracy moved only modestly (66.8% -> 68.5%). The two species remain
frequently confused with each other (pooled confusion matrix: 1708
*C. brunneus* windows called *C. biguttulus*, 1082 the other way) --
reduced, not resolved.

**But Prompt 9 changed window length (2s -> 4s) AND added temporal
features in the same run -- so which one actually produced the +9.1pp
gain was, at that point, an open question, not a settled one.** Prompt 10
ran a proper ablation to answer it: four arms (4s/spectral-only,
4s/spectral+temporal, 2s/spectral-only, 2s/spectral+temporal), all four
sharing the identical fold assignment, so every comparison is a clean
paired one (`docs/ablation_results.md`, `R/09_ablation.R`).

**Result: most of the gain is attributable to temporal features, not
window length -- corroborated twice, independently, though neither effect
individually clears this project's 95%-confidence bar taken alone.**
Overall accuracy is nearly identical at both window lengths within a
feature set (66.2% at 4s vs. 66.8% at 2s, spectral-only; 68.5% at 4s vs.
68.4% at 2s, with temporal features) -- window length barely moves overall
accuracy. Adding temporal features moves overall accuracy by roughly +2pp
at BOTH window lengths (paired deltas: +2.3pp at 4s, +1.7pp at 2s) -- two
independent, same-direction measurements. For *C. brunneus* recall
specifically: the temporal-feature effect is measured twice, independently,
at both window lengths, and comes out positive both times (+6.1pp at 4s,
95% range -5.1% to +23.8%; +3.9pp at 2s, 95% range -1.7% to +9.4%, a
noticeably tighter interval). The window-length-alone effect, now a clean
paired comparison (spectral-only, both window lengths, identical folds):
+3.5pp, 95% range -7.9% to +18%. Window-length-alone (+3.5pp) plus
temporal-feature-alone at 4s (+6.1pp) sum to +9.6pp, closely matching the
actual observed total change (+9pp) -- a reassuring consistency check on a
decomposition nothing forces to add up correctly.

**None of these individual paired deltas fully excludes zero at 95%
confidence taken alone, but two independent replications of the same
positive effect (at 4s and at 2s) is stronger evidence than either alone.**
This is reported as corroborated-but-not-fully-confirmed, not as "proven"
or "debunked" -- that is the honest state of the evidence. Concretely:
window length affects *C. brunneus* recall specifically, not overall
accuracy; temporal features affect both overall accuracy and *C. brunneus*
recall, at both window lengths tested. This is NOT the clean negative
result the confound raised as a live possibility ("most of it was window
length") -- the data points the other way.

**Do temporal features actually rank highly in variable importance? Mostly
no, and that's reported plainly rather than only reporting the accuracy
win -- and it turns out not to be contradictory.** Of the 11 temporal
features, only `envelope_mod_peak_ratio` (rank 11 of 32 by Gini importance)
and `temporal_entropy` (rank 19) place in the upper half; the rest rank in
the bottom third, below every MFCC and every original spectral feature.
MFCCs still dominate the top of the ranking outright. The honest reading,
now backed by the ablation above: these features contribute real,
twice-replicated value in combination without any single one being
individually as powerful a split as the existing spectral features --
plausible, since each is a compressed, low-dimensional summary (a rate, a
ratio, a count) competing against 12 MFCCs that already carry substantial
information. Whether temporal features "rank highly" was explicitly an
open question this prompt asked to report either way -- the answer is no,
individually, but yes, in combined effect on accuracy.

**Did the temporal features also make the classifier's accuracy less
sensitive to compression, as hypothesized?** No -- see "The compression
delta" below; report that plainly too.

## Classifier results (Deliverable D)

Real numbers from **repeated grouped k-fold cross-validation** (5 folds x
10 repeats, 50 fold-evaluations total) on **real Orthoptera/Cicadidae
audio vs. real ESC-50 ambient audio**, both passed through the same
WhatsApp compression simulation (`docs/classifier_results.md`, regenerated
fresh by `R/05_train.R`). This is the Prompt 8 replacement for a single
train/test split -- see "The corpus-expansion, window-cap, and k-fold fix"
below for why a single split was never defensible here.

- **68.5% mean overall test accuracy (sd 6.5pp, 95% range 56.2% to
  78.3%). 21.9% mean false-positive rate against real ambient audio (sd
  8pp, range 8.1% to 39.2%).** *Cicada orni* is the strongest real class
  (92.5% mean recall, 92.2% pooled precision). *C. brunneus* remains the
  weakest real class (43.1% mean recall, up from 34% pre-temporal-features
  -- see above) despite matching *C. biguttulus*'s source-recording count
  (62.4% mean recall). See `docs/classifier_results.md` for the full
  pooled confusion matrix and per-class recall-stability table.
- **Baselines, so 68.5% means something:** the majority-class baseline
  (always predicting the most common class) gets 27.1% accuracy on this
  data (not 50% -- classes are imbalanced, ambient dominates); chance rate
  across 8 classes is 12.5%. See `docs/operating_point.md`.
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
four stages: (1) an original "0% false-positive rate," measured by
separating synthetic tone stacks from real ambient audio -- a trivial
task, not a real one; (2) 86.9% accuracy / 8.7% FPR from a single grouped
split on a 5-recordings-per-species corpus, later shown (Prompt 7) to be
one lucky draw from a distribution ranging roughly 10-92%; (3) 66.8%/22.3%,
repeated grouped k-fold CV on an expanded ~45-recordings-per-species
corpus with a cap on windows per recording (Prompt 8); (4) 68.5%/21.9%,
this run, same corpus and method plus temporal features (Prompt 9). Each
stage is a harder or more nuanced number than the one before it, and each
is more honest -- the flattering earlier figures were never actually true,
just measured badly. All four are kept in `PROGRESS.md`'s history, clearly
labelled, for anyone auditing how the project's own numbers evolved.

**Source-recording counts per real target class (the number that actually
bounds every claim above):** *C. biguttulus* 45, *C. brunneus* 45, *Cicada
orni* 45, ambient 145.

## Operating point: what a farmer would actually experience (Prompt 9, Part 2; Prompt 10, Part 2)

**21.9% mean false-positive rate is the raw-argmax, WINDOW-level number --
whatever the model's top-1 prediction is on a single window, at any
confidence -- and it is not a fixed property of the model, nor even the
right unit to measure.** `R/06_predict.R`'s `predict_pest()` never scores
one window in isolation: it windows an incoming voice note, gates
near-silent windows, and averages the resulting probability vectors across
every surviving window before deciding. Prompt 9 first swept a threshold
over window-level predictions; Prompt 10 corrected this to sweep over
CLIP-level predictions, built by aggregating out-of-fold window
predictions with the EXACT SAME rule `predict_pest()` uses (mean
probability vector across a clip's windows, then argmax + top confidence)
-- the unit a farmer actually experiences (`docs/operating_point.md`,
`docs/figures/pr_curve.png`).

**The window-vs-clip comparison is itself a result, and it's more nuanced
than "pooling makes everything better."** Clip-level overall accuracy is
higher and clip-level false-positive rate is lower at every threshold than
window-level (both consistent with pooling reducing noise) -- but
clip-level PRECISION at a given threshold reads LOWER than window-level
precision at that threshold (90.1% vs. 97.5% at 0.45). This is not a
contradiction: windows and clips have very different class balance.
Ambient recordings (ESC-50, uniformly 5 seconds) contribute few windows
each; many real pest recordings run much longer and contribute up to the
20-window cap each. At window level this makes ambient a small minority of
test units (~19%); at clip level ambient and pest are roughly balanced
(~51%). The same absolute false-positive rate costs precision far more
when negatives are half the population than when they're a fifth of it --
window-level precision was inflated by a class-balance artifact of
window-count-per-recording, not a real model advantage at the window
level. Recall is also slightly lower at clip level (72.7% vs. 76.2%) for a
different, genuine reason: averaging a clip's windows can dilute one
strongly-confident correct window with weaker or wrong-favouring windows
from the same clip. Both effects are real; the clip-level numbers are the
honest ones to act on, since a clip -- not a window -- is what exists at
inference time.

**Chosen operating point (from the CLIP-level curve): threshold = 0.45.**
Precision 90.1%, recall (detection rate) 72.7%, false-positive rate 7.7%.
Chosen as the LOWEST threshold whose false-positive rate clears a 10%
deployment bar, sacrificing as little recall as possible while still
meeting it.

**The trade, stated explicitly, in deployment terms:** this is a screening
tool a farmer acts on directly. A false alarm (an alert on real ambient
noise) costs trust immediately and repeatedly -- enough of them and the
farmer stops trusting alerts at all, at which point the system has no
value regardless of its on-paper detection rate. A missed detection costs
one skipped alert, and the system's own low-confidence reply already asks
the farmer to resend a longer/louder recording -- a real, if imperfect,
recovery path a false alarm has no equivalent of. This asymmetry is why
the threshold prioritises holding false-positive rate down over
maximising accuracy or F1, and why it is now `R/06_predict.R`'s
`LOW_CONFIDENCE_THRESHOLD` default -- what a farmer receives now matches
what this analysis reports, not a separate unexamined number (the
original default, 0.4, was never validated against any measurement at
all).

**Per-species cost of this threshold (clip-level):** detection rate is
70.7% for *C. biguttulus*, 58.7% for *C. brunneus*, and 88.7% for *Cicada
orni* -- the threshold that protects against false alarms costs *C.
brunneus* (already the weakest class) the most detection rate
proportionally, a real trade worth naming rather than hiding behind the
single aggregate recall figure.

**Caveat on how much the clip-level advantage holds up for a real, short
voice note:** the windows-per-clip distribution behind these numbers
(min=1, p25=2, median=2, p75=6, max=20 across this corpus) is dominated by
real field recordings, many far longer than the 10-30 second clip the
webhook actually asks a farmer for. A short real voice note yielding only
2-3 usable windows after gating gets a smaller pooling benefit than the
median recording in this analysis -- the clip-level curve is a genuine
improvement over the window-level one, not an overstatement of it, but its
size in this analysis should not be read as the exact size a short farmer
recording will see in practice.

## Precision depends on real-world prevalence, not just the model (Prompt 11, Part 3)

**90.1% precision is a property of this corpus's class balance as much as**
**of the model.** This corpus is ~49.1% pest / ~50.9% ambient by clip count
-- an artifact of how real recordings were sampled (45 per real target
species, 145 ambient), not a claim about what fraction of real farm
nighttime recordings actually contain a target pest. Precision at a fixed
recall/false-positive-rate is not independent of the true prevalence of
the condition being screened for -- standard screening-test arithmetic:
`precision(p) = (recall * p) / (recall * p + fpr * (1 - p))`, using this
threshold's recall (72.7%) and false-positive rate (7.7%):

| Assumed prevalence | Precision |
|---|---|
| 1% | 8.7% |
| 5% | 33.1% |
| 10% | 51.1% |
| 25% | 75.8% |
| 50% | 90.4% |

**Verified, not just computed:** at the corpus's EXACT measured prevalence
(49.1%, not the rounded 50% row above), this formula reproduces 90.1%
precision exactly -- matching the actually-reported clip-level precision
to within rounding, confirming the formula and underlying recall/FPR
numbers are self-consistent. (`docs/operating_point.md` runs and reports
this check automatically on every regeneration; if the check ever fails,
that document says so explicitly and the table should not be trusted
until resolved.)

**This table is why the system is positioned as a screening tool a farmer**
**still exercises judgement on, not an autonomous alert trigger.** At 1%
assumed prevalence -- plausibly closer to an unselected nighttime farm
recording, though this project has no real measurement of that rate
either -- precision collapses to 8.7%: most alerts would be false alarms,
because false alarms scale with the much larger pool of true negatives
while true detections scale with a small pool of true positives. The
corpus's ~50/50 balance is not deployment-representative, and reporting
the 90.1% figure alone, without this table, would overstate what a farmer
should actually expect.

**Future work: temporal persistence.** Repeated sampling from the same
location over time (several voice notes from the same field across a few
nights) would raise EFFECTIVE precision beyond any single-clip number in
this table, since independent false alarms are unlikely to repeatedly and
consistently point at the same pest across multiple separate recordings,
while a genuine infestation would. Not implemented or measured in this
project -- a stated direction for future work, not a claim made here.

## Near-silent windows are gated, not kept and mislabelled

A training window inherits its whole source recording's label
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

**Combined result (Prompt 8): per-arm accuracy SD dropped from ~25-27
points (Prompt 7) to ~4.4-5.4 points -- roughly a 5x tighter spread. This
narrowing was itself a result**, not just cleanup: it demonstrated the
earlier instability was substantially a sampling artifact -- too few
source recordings, no bound on how much one long recording could dominate
a fold -- not an inherent property of the classification task.

### Did adding temporal features narrow the delta further? (Prompt 9)

**No -- reported plainly, as instructed, rather than only reporting a
shrink that didn't happen.** The specific hypothesis: amplitude-envelope/
temporal structure should survive low-bitrate Opus better than fine
spectral detail, so adding temporal features should make classifier
accuracy LESS sensitive to compression, narrowing the delta. Measured
result, this run (temporal features + 4s windows): codec-only delta -1.1%
(95% range -8.8% to +6.0%), full-fidelity delta +2.8% (range -6.2% to
+13.0%), bandwidth component +3.9% (range -6.5% to +13.1%) -- compare to
Prompt 8's pre-temporal-feature numbers just below. Both ranges WIDENED
slightly rather than narrowing.

**This comparison is not perfectly isolated, and that caveat matters as
much as the result.** Prompt 9 changed window length (2.0s/1.0s hop ->
4.0s/2.0s hop, to give phrase-level features enough context) AT THE SAME
TIME as adding temporal features, so any change in compression sensitivity
could reflect either change, not temporal features specifically. Given
both deltas remain squarely inside noise before and after, the honest
conclusion is: this run found no evidence that temporal features narrow
the compression delta. A clean test of that specific hypothesis would
need a run that changes ONLY the feature set, holding window length fixed
-- not done here, flagged as a real gap rather than glossed over.

**Deltas, both runs, for direct comparison:**

| | Pre-temporal (Prompt 8) | Post-temporal (Prompt 9) |
|---|---|---|
| Codec-only delta | +0.9% (range -4.2% to +5.8%) | -1.1% (range -8.8% to +6.0%) |
| Full-fidelity delta | +3.6% (range -4.5% to +12.7%) | +2.8% (range -6.2% to +13.0%) |
| Bandwidth component | +2.7% (range -5.8% to +11.1%) | +3.9% (range -6.5% to +13.1%) |

**Both deltas' 95% ranges include zero in both runs, so neither is
distinguishable from zero at conventional confidence, in either version.**
The codec-only delta remains squarely indistinguishable from zero
throughout -- the Opus codec in isolation cannot be shown to cost this
classifier anything measurable, with or without temporal features. The
full-fidelity delta stays the more ambiguous of the two: point estimate
positive in both runs and consistent with the codec experiment's finding
that content above 8kHz is destroyed outright, but the range comfortably
straddles zero in both, more so after adding temporal features than
before.

**What this does and doesn't say:** compatible with, and not
contradicting, the codec experiment's signal-level finding that real
Orthoptera stridulation survives the compression well -- but this corpus
still cannot put a precision tighter than roughly +/-7 to +/-10 percentage
points on that claim at the classifier level, and adding temporal features
did not change that. What would narrow it further is more distinct source
recordings per target species, not more folds/repeats of the same ~45, and
not more feature engineering on the same corpus. Does **not** extend to
chewing-sound classes (excluded from this comparison) or to any condition
not covered by the classifier above (field noise, distance, phone
microphone variability, species outside the trained set).

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
  SD roughly 5x (from ~26pp to ~5-6pp) and both compression deltas' 95%
  ranges roughly in half -- real, substantial progress -- but both deltas
  still cannot be distinguished from zero at a precision better than
  roughly +/-7 to +/-10 percentage points, and per-class recall for the
  smallest classes (`synthetic_tone_plus_noise`, 4 source files) still
  spans its entire possible range across folds. No number in this project
  is a single-split point estimate anymore; every headline figure is a
  mean with an explicit interval, and every table states the source-
  recording count behind it. More source recordings per class is what
  would narrow the remaining intervals further, not more folds or repeats
  of the same corpus.
- **The *C. brunneus* / *C. biguttulus* confusion is reduced, not
  resolved.** Prompt 9's temporal features raised *C. brunneus* recall
  from 34% to 43.1%, a real and biologically-motivated gain, but the two
  species are still frequently confused with each other (see above) and
  *C. brunneus* remains this project's weakest real class. Whatever is
  driving the residual gap (recording quality variance, a specific
  feature that doesn't discriminate this pair well, or genuinely harder
  individual recordings) has not been identified -- flagged as the most
  concrete open question in PROGRESS.md's forward-looking note, not just
  attributed to sample size.
- **Single-microphone, no localisation.** The system identifies *what*
  might be present, not *where* on the farm, and cannot estimate distance
  or direction.
- **Confidence scores are random forest vote proportions**, not formally
  calibrated (e.g. Platt-scaled) probabilities -- but they are now used
  for something concrete: `R/06_predict.R`'s `LOW_CONFIDENCE_THRESHOLD`
  (0.45) was set from a measured PR-curve sweep (`docs/operating_point.md`),
  not left as an unexamined default. Calibration would still improve how
  literally the confidence number itself can be read, independent of the
  threshold decision.
- **Live Twilio round trip untested** -- the webhook is verified against a
  mock payload and the real trained model, never an actual WhatsApp Sandbox
  message (needs a Twilio account; see `docs/twilio_setup.md` and
  `BLOCKERS.md`).

See `BLOCKERS.md` for open engineering items and `PROGRESS.md` for the
full, timestamped build log, including a "What we can and cannot claim"
section with the same claims broken out by evidence strength.
