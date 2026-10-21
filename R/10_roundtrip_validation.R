# Prompt 11, Part 1 -- validate the local FFmpeg WhatsApp-compression
# simulation against a REAL WhatsApp round-trip.
#
# Every codec/compression-delta/classifier number in this project so far
# rests on one unverified assumption: that `simulate_whatsapp_compression()`
# (R/02_codec_experiment.R -- encode to Opus/Ogg at 16kHz/16kbps mono via
# system ffmpeg, then decode) is a faithful stand-in for what WhatsApp's
# actual client-side encoder does to a voice note. This script is the check
# that assumption has never been put through.
#
# ---- TWO EXPERIMENTS, NOT ONE (added after review before any real data
# was sent) --------------------------------------------------------------
# WhatsApp voice notes can only be recorded in-app via the mic button --
# there is no way to hand WhatsApp a WAV file and have it become a voice
# note directly. Sending a WAV as a file/audio ATTACHMENT is a different
# send path and may not go through the same encoder WhatsApp's voice-note
# recorder uses (it may not be transcoded at all). Conflating the two would
# risk validating the wrong thing. So this script runs two independent
# experiments over the same 4 source clips:
#
#   "attachment" -- sent_NN_*.wav sent as a file/audio ATTACHMENT (not a
#     recorded voice note). Isolates whatever WhatsApp's attachment
#     transport does to the file, with NO acoustic capture step involved
#     (no speaker, no microphone, no room). This is the closest real-world
#     proxy to what `simulate_whatsapp_compression()` itself does (encode,
#     transmit, decode) -- IF WhatsApp actually transcodes attachments the
#     same way it transcodes voice notes. It might not (it might pass the
#     file through close to unchanged); this script measures rather than
#     assumes, and reports whichever turns out to be true.
#   "voicenote" -- sent_NN_*.wav played out loud and re-recorded as a real
#     WhatsApp voice note (mic button, in-app). This is the actual
#     deployment path: a farmer's phone recording a live sound. It bundles
#     TWO loss sources together -- acoustic capture (speaker frequency
#     response, room acoustics, phone mic frequency response) AND whatever
#     codec compression WhatsApp's voice-note recorder applies.
#
# Comparing the two arms is what actually separates codec loss from
# acoustic-path loss: if "attachment" turns out to closely track
# `simulate_whatsapp_compression()`'s output, it's a genuine codec-only
# isolation and (attachment fidelity) vs (voicenote fidelity) isolates the
# acoustic-capture cost specifically. If "attachment" instead turns out to
# closely track the clean original (near-lossless passthrough, no
# transcoding), that's itself an important finding -- it means the
# attachment arm is a transport-integrity control, not a codec isolation,
# and the voicenote arm's loss must be attributed to the combination of
# acoustic capture AND codec together, not decomposed further. This script
# detects which case actually holds from the numbers and states it
# explicitly rather than assuming either way going in.
#
# ---- TOLERANCE, STATED BEFORE ANY REAL DATA WAS COLLECTED -----------------
# (Prompt 11 explicitly requires this decided up front, not fit to whatever
# the results turn out to be. Written into this file before either
# received/attachment/ or received/voicenote/ contains anything. Applied
# identically to both experiment arms -- one pre-registered bar, not two.)
#
#   Encoding parameters (informational, always reported): channels expected
#   at 1 (mono), bitrate, when transcoded, in the 12-24kbps range (WhatsApp's
#   Opus VOIP profile targets ~16kbps but is VBR). The attachment arm may
#   instead show the original's own parameters, which is not itself a
#   failure, just evidence of a passthrough (see above). (Added after the
#   first real run: ffprobe reports 48000Hz for every Opus file, since Opus
#   always decodes at 48kHz, so the assumed 16kHz / 8kHz ceiling is checked
#   by measuring energy above 8kHz instead -- see energy_share_above_8k().)
#
#   Verdict per file per arm, based on two numbers:
#     - REAL-vs-SIMULATED spectral correlation (Pearson, on the two
#       DEGRADED outputs directly, not either against the clean original):
#         >= 0.90  -> simulation tracks reality closely
#         >= 0.75  -> simulation captures the broad shape, not fine detail
#         <  0.75  -> simulation diverges materially
#     - Mean ABSOLUTE per-band retention divergence
#       (|real_retention_ratio - simulated_retention_ratio|, averaged over
#       bands where the ORIGINAL had meaningful energy -- same 0.5%
#       threshold band_retention_ratios() already uses):
#         <= 0.10  -> bands degrade in step
#         <= 0.20  -> some bands diverge but not dramatically
#         >  0.20  -> bands degrade differently in reality than simulated
#
#   PASS  = correlation >= 0.90 AND mean band divergence <= 0.10
#   CAUTION = correlation >= 0.75 AND mean band divergence <= 0.20 (and not PASS)
#   FAIL  = anything worse than CAUTION
#
#   These thresholds were picked as round, defensible numbers consistent
#   with tolerances used elsewhere in this project (e.g. the +/-10
#   percentage-point bars used throughout the compression-delta write-ups),
#   not reverse-engineered from a result nobody has seen yet.
#
#   The "voicenote" arm's verdict is the headline one -- it's the actual
#   deployment path our classifier claims are made about. The "attachment"
#   arm's verdict is diagnostic (does our simulation track a codec-only
#   real round trip, if one even occurred), not the project's primary claim.
#
# ---- Manual procedure ------------------------------------------------------
# See docs/roundtrip_procedure.md for the full, exact steps.
#
# Usage:
#   Rscript R/10_roundtrip_validation.R
#
# Input:  data/codec_experiment/real_roundtrip/sent/sent_NN_*.wav
#         data/codec_experiment/real_roundtrip/received/attachment/received_NN_*.*
#         data/codec_experiment/real_roundtrip/received/voicenote/received_NN_*.*
# Output: docs/roundtrip_validation.md
#         docs/figures/roundtrip_<arm>_<NN>_<label>.png (one 3-panel figure per file per arm)

library(tuneR)
library(seewave)
library(purrr)
library(dplyr)
library(tibble)

source(file.path("R", "utils.R"))
source(file.path("R", "02_codec_experiment.R"))  # compute_mean_spectrum, band_retention_ratios,
                                                   # spectral_similarity, survivability_score,
                                                   # simulate_whatsapp_compression

ROUNDTRIP_DIR <- file.path("data", "codec_experiment", "real_roundtrip")
SENT_DIR      <- file.path(ROUNDTRIP_DIR, "sent")
SIMULATED_DIR <- file.path(ROUNDTRIP_DIR, "simulated")
FIGURES_DIR2  <- file.path("docs", "figures")
RESULTS_PATH  <- file.path("docs", "roundtrip_validation.md")

EXPERIMENTS <- list(
  attachment = list(
    key = "attachment",
    received_dir = file.path(ROUNDTRIP_DIR, "received", "attachment"),
    title = "Experiment 1: File-attachment round trip (codec isolation)",
    description = paste(
      "Each `sent_NN_*.wav` sent as a file/audio ATTACHMENT (not a recorded",
      "voice note) -- no speaker, no microphone, no room acoustics involved.",
      "Isolates whatever WhatsApp's attachment transport does to the file",
      "on its own."
    )
  ),
  voicenote = list(
    key = "voicenote",
    received_dir = file.path(ROUNDTRIP_DIR, "received", "voicenote"),
    title = "Experiment 2: Voice-note record round trip (deployment path)",
    description = paste(
      "Each `sent_NN_*.wav` played out loud and re-recorded as a real",
      "WhatsApp voice note (mic button, in-app). This is the actual",
      "deployment path and bundles acoustic-capture loss (speaker, room,",
      "phone mic) together with whatever codec compression WhatsApp",
      "applies to voice notes."
    )
  )
)

# Every spectral comparison happens at ONE sample rate: 16 kHz mono, the
# rate the classifier is trained and served at. Before this was added, the
# original was analysed at its own 44.1 kHz, the simulation at 16 kHz and the
# real voice note at 48 kHz (Opus decodes at 48 kHz) -- different bandwidths
# and FFT bin widths under per-spectrum peak normalisation, which produced
# meaningless per-band ratios (one band at 1282%). Found alongside the same
# class of bug in predict_pest() (R/06_predict.R).
ANALYSIS_SAMPLE_RATE <- WHATSAPP_SAMPLE_RATE

# A file with almost all its energy above 8 kHz (the 10 kHz control tone:
# ~0% below) has nothing left to compare at 16 kHz, so it gets no spectral
# verdict -- its job is answered by energy_share_above_8k() instead. (First
# set at 50%, which also excluded the broadband-noise control; that file
# still has ~39% of its energy below 8 kHz, plenty to compare, so the bar
# was lowered to target only the case it exists for.)
MIN_SHARE_BELOW_8K_FOR_VERDICT <- 0.1

CORR_PASS_THRESHOLD    <- 0.90
CORR_CAUTION_THRESHOLD <- 0.75
BAND_PASS_THRESHOLD    <- 0.10
BAND_CAUTION_THRESHOLD <- 0.20

# Used only to auto-label, in the comparison section, which real-world case
# the attachment arm turned out to be: near-lossless passthrough (no real
# transcoding) vs a genuine codec-comparable transcode. Not a pass/fail bar.
PASSTHROUGH_CORR_THRESHOLD <- 0.98

# ---- File matching -----------------------------------------------------------

#' Match sent_NN_<label>.wav files to received_NN_*.* files (for one
#' experiment arm's received directory) by their shared numeric prefix.
#' Received files may be any container ffmpeg can read (.opus/.ogg/.m4a/.wav/
#' ...) since WhatsApp's export format, and whether the attachment arm even
#' transcodes at all, aren't fully within our control.
match_sent_received <- function(sent_dir = SENT_DIR, received_dir) {
  sent_files <- list.files(sent_dir, pattern = "^sent_\\d+_.*\\.wav$", full.names = TRUE)
  if (length(sent_files) == 0) {
    stop("No sent_NN_*.wav files found in ", sent_dir, " -- run this script's ",
         "preparation step first (see docs/roundtrip_procedure.md).")
  }
  received_files <- list.files(received_dir, pattern = "^received_\\d+_", full.names = TRUE)

  purrr::map_dfr(sent_files, function(sp) {
    nn <- sub("^sent_(\\d+)_.*$", "\\1", basename(sp))
    label <- sub("^sent_\\d+_(.*)\\.wav$", "\\1", basename(sp))
    match_idx <- grep(paste0("^received_", nn, "_"), basename(received_files))
    tibble::tibble(
      id = nn, label = label, sent_path = sp,
      received_path = if (length(match_idx) > 0) received_files[match_idx[1]] else NA_character_
    )
  })
}

# ---- ffprobe: actual encoding parameters of the received file --------------

#' Real encoding parameters WhatsApp's server/client actually produced,
#' read directly from the received file via ffprobe -- not assumed. For the
#' attachment arm this may show the ORIGINAL's own parameters unchanged
#' (evidence of passthrough, not a bug in this function).
probe_encoding_params <- function(path) {
  ffprobe_bin <- Sys.which("ffprobe")
  if (ffprobe_bin == "") stop("ffprobe not found on PATH")
  json_lines <- system2(ffprobe_bin, args = c(
    "-v", "quiet", "-print_format", "json", "-show_format", "-show_streams", path
  ), stdout = TRUE)
  info <- jsonlite::fromJSON(paste(json_lines, collapse = "\n"))
  stream <- info$streams[1, ]
  list(
    codec_name = stream$codec_name,
    sample_rate_hz = as.integer(stream$sample_rate),
    channels = as.integer(stream$channels),
    bitrate_kbps = {
      br <- if (!is.null(stream$bit_rate) && !is.na(stream$bit_rate)) stream$bit_rate else info$format$bit_rate
      if (is.null(br) || is.na(br)) NA_real_ else as.numeric(br) / 1000
    }
  )
}

# ---- Core per-file analysis --------------------------------------------------

#' Decode any audio file (any container) to a temp WAV via ffmpeg. With
#' `sample_rate`, also resample (ffmpeg's filtered resampler) and downmix to
#' mono -- see ANALYSIS_SAMPLE_RATE below for why every comparison uses this.
decode_to_wav <- function(path, out_path = tempfile(fileext = ".wav"), sample_rate = NULL) {
  ffmpeg_bin <- Sys.which("ffmpeg")
  if (ffmpeg_bin == "") stop("ffmpeg not found on PATH")
  args <- c("-y", "-loglevel", "error", "-i", shQuote(path))
  if (!is.null(sample_rate)) args <- c(args, "-ar", as.character(sample_rate), "-ac", "1")
  status <- system2(ffmpeg_bin, args = c(args, shQuote(out_path)))
  if (status != 0) stop("ffmpeg failed to decode ", path)
  out_path
}

#' Share of a file's spectral power above 8 kHz, at its NATIVE decode rate.
#' This is the direct check of the "WhatsApp cuts everything above 8 kHz"
#' assumption -- ffprobe can't answer it, because Opus always decodes at
#' 48 kHz whatever bandwidth was actually encoded.
energy_share_above_8k <- function(path) {
  wav <- decode_to_wav(path)
  on.exit(unlink(wav), add = TRUE)
  w <- tuneR::readWave(wav)
  x <- as.numeric(if (w@stereo) (w@left + w@right) / 2 else w@left)
  power <- Mod(stats::fft(x - mean(x)))^2
  freq <- (seq_along(x) - 1) * w@samp.rate / length(x)
  half <- freq <= w@samp.rate / 2
  sum(power[half & freq > 8000]) / sum(power[half])
}

analyze_one_pair <- function(row, simulated_dir = SIMULATED_DIR) {
  if (is.na(row$received_path)) {
    return(list(id = row$id, label = row$label, status = "no_received_file"))
  }

  ensure_dir(simulated_dir)
  simulated_path <- file.path(simulated_dir, paste0("simulated_", row$id, "_", row$label, ".wav"))
  simulate_whatsapp_compression(row$sent_path, simulated_path)

  # All three at ANALYSIS_SAMPLE_RATE, mono -- see its definition.
  orig_wav_tmp <- decode_to_wav(row$sent_path, sample_rate = ANALYSIS_SAMPLE_RATE)
  received_wav_tmp <- decode_to_wav(row$received_path, sample_rate = ANALYSIS_SAMPLE_RATE)
  sim_wav_tmp <- decode_to_wav(simulated_path, sample_rate = ANALYSIS_SAMPLE_RATE)
  on.exit(unlink(c(orig_wav_tmp, received_wav_tmp, sim_wav_tmp)), add = TRUE)

  params <- probe_encoding_params(row$received_path)
  params$above_8k_original <- energy_share_above_8k(row$sent_path)
  params$above_8k_received <- energy_share_above_8k(row$received_path)

  orig_spec <- compute_mean_spectrum(orig_wav_tmp)
  real_spec <- compute_mean_spectrum(received_wav_tmp)
  sim_spec  <- compute_mean_spectrum(sim_wav_tmp)

  real_retention <- band_retention_ratios(orig_spec, real_spec)
  sim_retention  <- band_retention_ratios(orig_spec, sim_spec)

  real_similarity <- spectral_similarity(orig_spec, real_spec)
  sim_similarity  <- spectral_similarity(orig_spec, sim_spec)
  real_score <- survivability_score(real_similarity)
  sim_score  <- survivability_score(sim_similarity)

  # Simulation fidelity: compare the two DEGRADED outputs to each other
  # directly -- this is the number that actually answers "does the
  # simulation match reality", not how each compares to the clean original.
  fidelity_similarity <- spectral_similarity(real_spec, sim_spec)

  # NOTE: column names deliberately differ from the `real_retention`/
  # `sim_retention` variable names above -- dplyr::tibble() evaluates
  # columns sequentially and a column named identically to an outer
  # variable shadows it for every subsequent expression in the same call
  # (found the hard way: `abs_divergence` below silently saw the
  # just-created numeric column, not the outer data frame, and errored).
  band_compare <- dplyr::tibble(
    band = real_retention$band,
    real_retention_ratio = real_retention$retention_ratio,
    simulated_retention_ratio = sim_retention$retention_ratio,
    abs_divergence = abs(real_retention$retention_ratio - sim_retention$retention_ratio)
  )
  # Nothing above 8 kHz exists at the 16 kHz analysis rate.
  band_compare <- band_compare[band_compare$band != ">8kHz", ]
  mean_band_divergence <- mean(band_compare$abs_divergence, na.rm = TRUE)

  verdict <- if (1 - params$above_8k_original < MIN_SHARE_BELOW_8K_FOR_VERDICT) {
    "N/A (most of this file's energy is above 8 kHz; see the >8 kHz columns instead)"
  } else if (fidelity_similarity$pearson_correlation >= CORR_PASS_THRESHOLD &&
                 !is.na(mean_band_divergence) && mean_band_divergence <= BAND_PASS_THRESHOLD) {
    "PASS"
  } else if (fidelity_similarity$pearson_correlation >= CORR_CAUTION_THRESHOLD &&
             (is.na(mean_band_divergence) || mean_band_divergence <= BAND_CAUTION_THRESHOLD)) {
    "CAUTION"
  } else {
    "FAIL"
  }

  list(
    id = row$id, label = row$label, status = "ok",
    sent_path = row$sent_path, received_path = row$received_path, simulated_path = simulated_path,
    params = params, band_compare = band_compare, mean_band_divergence = mean_band_divergence,
    real_score = real_score, sim_score = sim_score,
    real_similarity = real_similarity, sim_similarity = sim_similarity,
    fidelity_similarity = fidelity_similarity, verdict = verdict
  )
}

# ---- Figure: 3-panel spectrogram (original / simulated / real) -------------

#' One 3-panel spectrogram figure per file per arm: original (clean source),
#' simulated (our local FFmpeg round-trip), real (actual WhatsApp round
#' trip, this arm) -- side by side so the divergence (or lack of it) is
#' visible at a glance, not just in a table.
render_roundtrip_panel <- function(result, experiment_key, figures_dir = FIGURES_DIR2, fft_window = FFT_WINDOW) {
  out_path <- file.path(figures_dir, sprintf("roundtrip_%s_%s_%s.png", experiment_key, result$id, result$label))
  ensure_dir(figures_dir)

  # Same 16 kHz mono view the numbers are computed from.
  tmp <- c(decode_to_wav(result$sent_path, sample_rate = ANALYSIS_SAMPLE_RATE),
           decode_to_wav(result$simulated_path, sample_rate = ANALYSIS_SAMPLE_RATE),
           decode_to_wav(result$received_path, sample_rate = ANALYSIS_SAMPLE_RATE))
  on.exit(unlink(tmp), add = TRUE)
  w_orig <- tuneR::readWave(tmp[1])
  w_sim  <- tuneR::readWave(tmp[2])
  w_real <- tuneR::readWave(tmp[3])

  grDevices::png(out_path, width = 2100, height = 650, res = 150)
  on.exit(grDevices::dev.off(), add = TRUE)
  graphics::par(mfrow = c(1, 3), mar = c(4.5, 4.5, 3.5, 1.5), cex.main = 1.05, cex.lab = 1, cex.axis = 0.9)

  seewave::spectro(w_orig, wl = fft_window, scale = FALSE, main = paste(result$label, "- original"))
  graphics::abline(h = 8, col = "red", lty = 2, lwd = 1.5)
  graphics::text(x = 0.05, y = 8, labels = "8kHz ceiling", col = "red", pos = 4, offset = 0.3, cex = 0.8)

  seewave::spectro(w_sim, wl = fft_window, scale = FALSE, main = paste(result$label, "- simulated (FFmpeg)"))
  graphics::abline(h = 8, col = "red", lty = 2, lwd = 1.5)

  seewave::spectro(w_real, wl = fft_window, scale = FALSE, main = paste(result$label, "- real WhatsApp,", experiment_key))
  graphics::abline(h = 8, col = "red", lty = 2, lwd = 1.5)

  invisible(out_path)
}

# ---- Reporting ---------------------------------------------------------------

knitr_table_or_fallback <- function(df) {
  if (requireNamespace("knitr", quietly = TRUE)) {
    paste(knitr::kable(df, format = "markdown", digits = 3), collapse = "\n")
  } else {
    paste(utils::capture.output(print(df)), collapse = "\n")
  }
}

fmt_pct2 <- function(x) if (is.na(x)) "N/A" else paste0(round(x * 100, 1), "%")

#' Run the full match/analyze/render pipeline for one experiment arm.
#' Never errors on a fully-empty arm -- returns a status so main() can
#' report "not run yet" per arm independently instead of failing outright.
run_one_experiment <- function(experiment) {
  matched <- match_sent_received(SENT_DIR, experiment$received_dir)
  n_missing <- sum(is.na(matched$received_path))

  if (n_missing == nrow(matched)) {
    return(list(experiment = experiment, matched = matched, ok_results = list(),
                missing_results = list(), status = "no_data"))
  }

  results <- lapply(seq_len(nrow(matched)), function(i) analyze_one_pair(matched[i, ]))
  ok_results <- Filter(function(r) r$status == "ok", results)
  missing_results <- Filter(function(r) r$status != "ok", results)
  for (r in ok_results) render_roundtrip_panel(r, experiment$key)

  list(experiment = experiment, matched = matched, ok_results = ok_results,
       missing_results = missing_results, status = "ok")
}

#' Render one experiment arm's section of the report (encoding params table,
#' per-file results, tolerance-based verdicts). Returns character lines.
render_experiment_section <- function(run) {
  exp <- run$experiment
  header <- c(paste0("## ", exp$title), "", exp$description, "")

  if (run$status == "no_data") {
    return(c(header,
      sprintf("No `received_NN_*` files are present under `%s` yet -- this arm has not run. See `docs/roundtrip_procedure.md`.", exp$received_dir),
      ""))
  }

  c(header,
    if (length(run$missing_results) > 0) paste0(
      "**", length(run$missing_results), " of ", nrow(run$matched), " files had no matching received file** ",
      "(", paste(vapply(run$missing_results, function(r) paste0(r$id, "_", r$label), character(1)), collapse = ", "),
      ") -- reported as missing, not silently skipped."
    ) else "All sent files had a matching received file for this arm.",
    "",
    "### Actual encoding parameters (from the received file, via ffprobe)",
    "",
    knitr_table_or_fallback(dplyr::bind_rows(lapply(run$ok_results, function(r) tibble::tibble(
      id = r$id, label = r$label,
      codec = r$params$codec_name,
      decoded_sample_rate_hz = r$params$sample_rate_hz,
      channels = r$params$channels,
      bitrate_kbps = round(r$params$bitrate_kbps, 1),
      energy_above_8kHz_original = fmt_pct2(r$params$above_8k_original),
      energy_above_8kHz_received = fmt_pct2(r$params$above_8k_received)
    )))),
    "",
    paste0("`decoded_sample_rate_hz` is what ffprobe reports; Opus always decodes at 48000 Hz whatever ",
           "bandwidth was encoded, so it can't show the assumed ", WHATSAPP_SAMPLE_RATE, " Hz / 8 kHz ",
           "ceiling. The two `energy_above_8kHz` columns measure that directly, at each file's native ",
           "rate. Assumed WhatsApp parameters: ", WHATSAPP_SAMPLE_RATE, " Hz, ", WHATSAPP_BITRATE_KBPS, " kbps."),
    "",
    paste0("Everything below is compared at ", ANALYSIS_SAMPLE_RATE, " Hz mono -- original, simulated ",
           "and real alike -- the rate the classifier is trained and served at."),
    "",
    "### Per-file results",
    "",
    unlist(lapply(run$ok_results, function(r) c(
      sprintf("#### %s_%s", r$id, r$label),
      "",
      sprintf("- Real round-trip survivability (this arm): %.3f (Pearson %.3f, cosine %.3f)",
              r$real_score, r$real_similarity$pearson_correlation, r$real_similarity$cosine_similarity),
      sprintf("- Simulated round-trip survivability: %.3f (Pearson %.3f, cosine %.3f)",
              r$sim_score, r$sim_similarity$pearson_correlation, r$sim_similarity$cosine_similarity),
      sprintf("- **Simulation fidelity (real vs. simulated, directly): Pearson %.3f, cosine %.3f**",
              r$fidelity_similarity$pearson_correlation, r$fidelity_similarity$cosine_similarity),
      sprintf("- Mean per-band retention divergence: %s",
              if (is.na(r$mean_band_divergence)) "N/A" else sprintf("%.3f", r$mean_band_divergence)),
      "",
      knitr_table_or_fallback(dplyr::transmute(r$band_compare,
        band = band,
        real_retention = vapply(real_retention_ratio, fmt_pct2, character(1)),
        simulated_retention = vapply(simulated_retention_ratio, fmt_pct2, character(1)),
        abs_divergence = vapply(abs_divergence, fmt_pct2, character(1)))),
      "",
      sprintf("**Verdict: %s**", r$verdict),
      "",
      sprintf("![Original / simulated / real spectrograms, all at %d Hz](figures/roundtrip_%s_%s_%s.png)",
              ANALYSIS_SAMPLE_RATE, exp$key, r$id, r$label),
      ""
    ))),
    ""
  )
}

#' Comparison section: for every id analysed in BOTH arms, isolate codec
#' loss from acoustic-path loss -- and auto-detect (from the numbers, not
#' assumed) whether the attachment arm was actually transcoded at all.
render_comparison_section <- function(attach_run, voice_run) {
  if (attach_run$status != "ok" || voice_run$status != "ok") {
    return(c(
      "## Isolating codec loss from acoustic-path loss",
      "",
      "Both arms need at least one matched, analysed file each before this ",
      "comparison can run -- not yet available.",
      ""
    ))
  }

  common_ids <- intersect(
    vapply(attach_run$ok_results, function(r) r$id, character(1)),
    vapply(voice_run$ok_results, function(r) r$id, character(1))
  )
  if (length(common_ids) == 0) {
    return(c(
      "## Isolating codec loss from acoustic-path loss",
      "",
      "No file id was successfully analysed in both arms -- nothing to compare yet.",
      ""
    ))
  }

  by_id <- function(run, id) Find(function(r) r$id == id, run$ok_results)

  rows <- purrr::map_dfr(common_ids, function(id) {
    a <- by_id(attach_run, id)
    v <- by_id(voice_run, id)
    tibble::tibble(
      id = id, label = a$label,
      attachment_survivability = a$real_score,
      attachment_vs_original_pearson = a$real_similarity$pearson_correlation,
      voicenote_survivability = v$real_score,
      voicenote_vs_original_pearson = v$real_similarity$pearson_correlation,
      delta_survivability = a$real_score - v$real_score
    )
  })

  passthrough_ids <- rows$id[rows$attachment_vs_original_pearson >= PASSTHROUGH_CORR_THRESHOLD]
  interpretation <- if (length(passthrough_ids) == nrow(rows)) {
    paste(
      "**Every file's attachment arm is near-lossless relative to the original**",
      sprintf("(Pearson >= %.2f for all %d matched files).", PASSTHROUGH_CORR_THRESHOLD, nrow(rows)),
      "This means WhatsApp did not perceptibly transcode these file attachments --",
      "the attachment arm is a TRANSPORT-INTEGRITY control, not a codec-only",
      "isolation. Under this reading, `delta_survivability` above approximates",
      "the TOTAL voice-note-path loss (acoustic capture AND whatever codec",
      "WhatsApp applies to voice notes, combined) -- it cannot be decomposed",
      "into acoustic-only vs codec-only from this data alone."
    )
  } else if (length(passthrough_ids) == 0) {
    paste(
      "**No file's attachment arm looks like a passthrough** -- every attachment",
      "shows real degradation relative to the original. This is consistent with",
      "WhatsApp applying comparable compression to file attachments and voice",
      "notes, which makes the attachment arm a genuine codec-only isolation:",
      "`delta_survivability` above (attachment minus voicenote) approximates the",
      "ACOUSTIC-CAPTURE-PATH cost specifically (speaker, room, phone mic),",
      "over and above codec loss common to both arms."
    )
  } else {
    paste0(
      "**Mixed result** -- ", length(passthrough_ids), " of ", nrow(rows),
      " files' attachment arm looks like a near-lossless passthrough and the ",
      "rest show real degradation. The codec-vs-acoustic decomposition below is ",
      "only reliable file-by-file, not as a single blanket statement -- read the ",
      "table, not just this paragraph."
    )
  }

  c(
    "## Isolating codec loss from acoustic-path loss",
    "",
    "Comparing the same source clip's attachment-arm and voice-note-arm survivability ",
    "directly answers what each transmission path actually costs.",
    "",
    knitr_table_or_fallback(rows),
    "",
    interpretation,
    ""
  )
}

main <- function() {
  attach_run <- run_one_experiment(EXPERIMENTS$attachment)
  voice_run  <- run_one_experiment(EXPERIMENTS$voicenote)

  ensure_dir(dirname(RESULTS_PATH))

  if (attach_run$status == "no_data" && voice_run$status == "no_data") {
    message("No received files found under either experiment arm -- nothing to validate yet. See ",
            "docs/roundtrip_procedure.md for how to produce them, then re-run this script. Not ",
            "writing docs/roundtrip_validation.md over a real prior result (if any) with an empty one.")
    if (!file.exists(RESULTS_PATH)) {
      writeLines(c(
        "# Real WhatsApp Round-Trip Validation",
        "",
        "No `received_NN_*` files are present under either `received/attachment/` or ",
        "`received/voicenote/` yet. This document will be generated for real once they are -- see ",
        "`docs/roundtrip_procedure.md` for the manual steps covering both experiments.",
        "",
        "## Tolerance, stated before any real data was collected",
        "",
        sprintf("- PASS: real-vs-simulated spectral correlation >= %.2f AND mean per-band retention divergence <= %.2f",
                CORR_PASS_THRESHOLD, BAND_PASS_THRESHOLD),
        sprintf("- CAUTION: correlation >= %.2f AND divergence <= %.2f (and not PASS)",
                CORR_CAUTION_THRESHOLD, BAND_CAUTION_THRESHOLD),
        "- FAIL: anything worse than CAUTION",
        "",
        "Applied identically to both the attachment and voice-note arms. See ",
        "`R/10_roundtrip_validation.R`'s header for the full reasoning behind these numbers and why ",
        "there are two arms."
      ), RESULTS_PATH)
    }
    return(invisible(NULL))
  }

  lines <- c(
    "# Real WhatsApp Round-Trip Validation",
    "",
    paste0("Generated by `R/10_roundtrip_validation.R` on ", format(Sys.time(), "%Y-%m-%d %H:%M"),
           ". Compares our local FFmpeg simulation of WhatsApp's Opus/Ogg compression against TWO real ",
           "WhatsApp round trips on the same source clips: a file-attachment send (codec isolation) and ",
           "a played-aloud-and-recorded voice note (the actual deployment path). See ",
           "`docs/roundtrip_procedure.md` for exactly how the real files were produced."),
    "",
    "## Tolerance, stated before any real data was collected",
    "",
    sprintf("- **PASS**: real-vs-simulated spectral correlation >= %.2f AND mean per-band retention divergence <= %.2f",
            CORR_PASS_THRESHOLD, BAND_PASS_THRESHOLD),
    sprintf("- **CAUTION**: correlation >= %.2f AND divergence <= %.2f (and not PASS)",
            CORR_CAUTION_THRESHOLD, BAND_CAUTION_THRESHOLD),
    "- **FAIL**: anything worse than CAUTION",
    "",
    "Applied identically to both arms below -- one pre-registered bar, not two. The **voice-note arm's ",
    "verdict is the headline one** (it's the actual deployment path); the attachment arm's verdict is ",
    "diagnostic. These thresholds are copied verbatim from this script's own header comment, written ",
    "before any received file existed -- not adjusted after seeing the numbers below.",
    "",
    render_experiment_section(attach_run),
    render_experiment_section(voice_run),
    render_comparison_section(attach_run, voice_run),
    "## Overall verdict",
    "",
    "TBD -- filled in by hand after reading both arms' per-file verdicts above, with the voice-note ",
    "arm as the headline claim. State plainly whether the simulation is validated for the deployment ",
    "path (in which case every prior codec/compression-delta/classifier result stands as measured) or ",
    "diverges (in which case quantify it, name which prior conclusions are affected, and re-run the ",
    "compression delta / classifier evaluation using real-round-trip parameters if the real round trip ",
    "is more destructive than simulated -- that result supersedes the simulated one)."
  )
  writeLines(lines, RESULTS_PATH)

  summarize_run <- function(run) {
    if (run$status == "no_data") return(sprintf("%s: not run yet", run$experiment$key))
    sprintf("%s: %d/%d matched (%s)", run$experiment$key, length(run$ok_results), nrow(run$matched),
            paste(vapply(run$ok_results, function(r) paste0(r$id, "=", r$verdict), character(1)), collapse = ", "))
  }
  message("Round-trip validation. ", summarize_run(attach_run), " | ", summarize_run(voice_run),
          ". Written to ", RESULTS_PATH)

  invisible(list(attach_run = attach_run, voice_run = voice_run))
}

if (sys.nframe() == 0) {
  main()
}
