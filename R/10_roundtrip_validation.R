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
# ---- TOLERANCE, STATED BEFORE ANY REAL DATA WAS COLLECTED -----------------
# (Prompt 11 explicitly requires this decided up front, not fit to whatever
# the results turn out to be. Written into this file before
# data/codec_experiment/real_roundtrip/received/ contains anything.)
#
#   Encoding parameters (informational, always reported): sample rate is
#   expected at 16000Hz, channels at 1 (mono). Bitrate is expected in the
#   12-24kbps range (WhatsApp's Opus VOIP profile targets ~16kbps but is
#   VBR, so some spread around the target is normal, not a red flag).
#
#   Verdict per file, based on two numbers:
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
# ---- Manual procedure ------------------------------------------------------
# See docs/roundtrip_procedure.md for the full, exact steps. Summary: play
# each file in data/codec_experiment/real_roundtrip/sent/ near a phone's
# microphone (or route directly), send it as a real WhatsApp voice note,
# export the chat with media from the receiving device, and place the
# received audio file in data/codec_experiment/real_roundtrip/received/
# with a matching numeric prefix (sent_01_*.wav <-> received_01_*.<ext>,
# any container/extension -- this script probes and decodes whatever
# ffmpeg can read).
#
# Usage:
#   Rscript R/10_roundtrip_validation.R
#
# Input:  data/codec_experiment/real_roundtrip/sent/sent_NN_*.wav
#         data/codec_experiment/real_roundtrip/received/received_NN_*.*
# Output: docs/roundtrip_validation.md
#         docs/figures/roundtrip_<NN>_<label>.png (one 3-panel figure per file)

library(tuneR)
library(seewave)
library(purrr)
library(dplyr)
library(tibble)

source(file.path("R", "utils.R"))
source(file.path("R", "02_codec_experiment.R"))  # compute_mean_spectrum, band_retention_ratios,
                                                   # spectral_similarity, survivability_score,
                                                   # simulate_whatsapp_compression

SENT_DIR      <- file.path("data", "codec_experiment", "real_roundtrip", "sent")
RECEIVED_DIR  <- file.path("data", "codec_experiment", "real_roundtrip", "received")
SIMULATED_DIR <- file.path("data", "codec_experiment", "real_roundtrip", "simulated")
FIGURES_DIR2  <- file.path("docs", "figures")
RESULTS_PATH  <- file.path("docs", "roundtrip_validation.md")

CORR_PASS_THRESHOLD    <- 0.90
CORR_CAUTION_THRESHOLD <- 0.75
BAND_PASS_THRESHOLD    <- 0.10
BAND_CAUTION_THRESHOLD <- 0.20

# ---- File matching -----------------------------------------------------------

#' Match sent_NN_<label>.wav files to received_NN_*.* files by their shared
#' numeric prefix. Received files may be any container ffmpeg can read
#' (.opus/.ogg/.m4a/...) since WhatsApp's export format isn't fully within
#' our control.
match_sent_received <- function(sent_dir = SENT_DIR, received_dir = RECEIVED_DIR) {
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
#' read directly from the received file via ffprobe -- not assumed.
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

#' Decode any audio file (any container) to a temp WAV via ffmpeg, matching
#' how wa_read()/the rest of this pipeline handles non-WAV input.
decode_to_wav <- function(path, out_path = tempfile(fileext = ".wav")) {
  ffmpeg_bin <- Sys.which("ffmpeg")
  if (ffmpeg_bin == "") stop("ffmpeg not found on PATH")
  status <- system2(ffmpeg_bin, args = c("-y", "-loglevel", "error", "-i", path, out_path))
  if (status != 0) stop("ffmpeg failed to decode ", path)
  out_path
}

analyze_one_pair <- function(row, simulated_dir = SIMULATED_DIR) {
  if (is.na(row$received_path)) {
    return(list(id = row$id, label = row$label, status = "no_received_file"))
  }

  ensure_dir(simulated_dir)
  simulated_path <- file.path(simulated_dir, paste0("simulated_", row$id, "_", row$label, ".wav"))
  simulate_whatsapp_compression(row$sent_path, simulated_path)

  received_wav_tmp <- decode_to_wav(row$received_path)
  on.exit(unlink(received_wav_tmp), add = TRUE)

  params <- probe_encoding_params(row$received_path)

  orig_spec <- compute_mean_spectrum(row$sent_path)
  real_spec <- compute_mean_spectrum(received_wav_tmp)
  sim_spec  <- compute_mean_spectrum(simulated_path)

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
  mean_band_divergence <- mean(band_compare$abs_divergence, na.rm = TRUE)

  verdict <- if (fidelity_similarity$pearson_correlation >= CORR_PASS_THRESHOLD &&
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

#' One 3-panel spectrogram figure per file: original (clean source),
#' simulated (our local FFmpeg round-trip), real (actual WhatsApp
#' round-trip) -- side by side so the divergence (or lack of it) is visible
#' at a glance, not just in a table.
render_roundtrip_panel <- function(result, figures_dir = FIGURES_DIR2, fft_window = FFT_WINDOW) {
  out_path <- file.path(figures_dir, sprintf("roundtrip_%s_%s.png", result$id, result$label))
  ensure_dir(figures_dir)

  w_orig <- tuneR::readWave(result$sent_path)
  w_sim  <- tuneR::readWave(result$simulated_path)
  real_wav_tmp <- decode_to_wav(result$received_path)
  w_real <- tuneR::readWave(real_wav_tmp)

  grDevices::png(out_path, width = 2100, height = 650, res = 150)
  on.exit(grDevices::dev.off(), add = TRUE)
  graphics::par(mfrow = c(1, 3), mar = c(4.5, 4.5, 3.5, 1.5), cex.main = 1.05, cex.lab = 1, cex.axis = 0.9)

  seewave::spectro(w_orig, wl = fft_window, scale = FALSE, main = paste(result$label, "- original"))
  graphics::abline(h = 8, col = "red", lty = 2, lwd = 1.5)
  graphics::text(x = 0.05, y = 8, labels = "8kHz ceiling", col = "red", pos = 4, offset = 0.3, cex = 0.8)

  seewave::spectro(w_sim, wl = fft_window, scale = FALSE, main = paste(result$label, "- simulated (FFmpeg)"))
  graphics::abline(h = 8, col = "red", lty = 2, lwd = 1.5)

  seewave::spectro(w_real, wl = fft_window, scale = FALSE, main = paste(result$label, "- real WhatsApp"))
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

main <- function() {
  matched <- match_sent_received()

  n_missing <- sum(is.na(matched$received_path))
  if (n_missing == nrow(matched)) {
    message("No received files found under ", RECEIVED_DIR, " for any of the ",
            nrow(matched), " sent files -- nothing to validate yet. See ",
            "docs/roundtrip_procedure.md for how to produce them, then re-run ",
            "this script. Not writing docs/roundtrip_validation.md over a real ",
            "prior result (if any) with an empty one.")
    if (!file.exists(RESULTS_PATH)) {
      ensure_dir(dirname(RESULTS_PATH))
      writeLines(c(
        "# Real WhatsApp Round-Trip Validation",
        "",
        paste0("No `received_NN_*` files are present under `", RECEIVED_DIR, "` yet. ",
               "This document will be generated for real once they are -- see ",
               "`docs/roundtrip_procedure.md` for the manual steps."),
        "",
        "## Tolerance, stated before any real data was collected",
        "",
        sprintf("- PASS: real-vs-simulated spectral correlation >= %.2f AND mean per-band retention divergence <= %.2f",
                CORR_PASS_THRESHOLD, BAND_PASS_THRESHOLD),
        sprintf("- CAUTION: correlation >= %.2f AND divergence <= %.2f (and not PASS)",
                CORR_CAUTION_THRESHOLD, BAND_CAUTION_THRESHOLD),
        "- FAIL: anything worse than CAUTION",
        "",
        "See `R/10_roundtrip_validation.R`'s header for the full reasoning behind these numbers."
      ), RESULTS_PATH)
    }
    return(invisible(NULL))
  }

  results <- lapply(seq_len(nrow(matched)), function(i) analyze_one_pair(matched[i, ]))

  ok_results <- Filter(function(r) r$status == "ok", results)
  missing_results <- Filter(function(r) r$status != "ok", results)

  for (r in ok_results) render_roundtrip_panel(r)

  ensure_dir(dirname(RESULTS_PATH))
  lines <- c(
    "# Real WhatsApp Round-Trip Validation",
    "",
    paste0("Generated by `R/10_roundtrip_validation.R` on ", format(Sys.time(), "%Y-%m-%d %H:%M"),
           ". Compares our local FFmpeg simulation of WhatsApp's Opus/Ogg compression against a REAL ",
           "WhatsApp round-trip on the same source clips (`docs/roundtrip_procedure.md` for exactly ",
           "how the real files were produced)."),
    "",
    "## Tolerance, stated before any real data was collected",
    "",
    sprintf("- **PASS**: real-vs-simulated spectral correlation >= %.2f AND mean per-band retention divergence <= %.2f",
            CORR_PASS_THRESHOLD, BAND_PASS_THRESHOLD),
    sprintf("- **CAUTION**: correlation >= %.2f AND divergence <= %.2f (and not PASS)",
            CORR_CAUTION_THRESHOLD, BAND_CAUTION_THRESHOLD),
    "- **FAIL**: anything worse than CAUTION",
    "",
    "These thresholds are copied verbatim from this script's own header comment, written before ",
    "any received file existed -- not adjusted after seeing the numbers below.",
    "",
    if (length(missing_results) > 0) paste0(
      "**", length(missing_results), " of ", nrow(matched), " files had no matching received file** ",
      "(", paste(vapply(missing_results, function(r) paste0(r$id, "_", r$label), character(1)), collapse = ", "),
      ") -- reported as missing, not silently skipped."
    ) else "All sent files had a matching received file.",
    "",
    "## Actual encoding parameters (from the received file, via ffprobe)",
    "",
    knitr_table_or_fallback(dplyr::bind_rows(lapply(ok_results, function(r) tibble::tibble(
      id = r$id, label = r$label,
      codec = r$params$codec_name,
      sample_rate_hz = r$params$sample_rate_hz,
      channels = r$params$channels,
      bitrate_kbps = round(r$params$bitrate_kbps, 1),
      assumed_sample_rate_hz = WHATSAPP_SAMPLE_RATE,
      assumed_bitrate_kbps = WHATSAPP_BITRATE_KBPS
    )))),
    "",
    "## Per-file results",
    "",
    paste(unlist(lapply(ok_results, function(r) c(
      sprintf("### %s_%s", r$id, r$label),
      "",
      sprintf("- Real round-trip survivability: %.3f (Pearson %.3f, cosine %.3f)",
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
      sprintf("![Original / simulated / real spectrograms](figures/roundtrip_%s_%s.png)", r$id, r$label),
      ""
    ))), collapse = "\n"),
    "",
    "## Overall verdict",
    "",
    "TBD -- filled in by hand after reading the per-file verdicts above. State plainly whether the ",
    "simulation is validated (in which case every prior codec/compression-delta/classifier result ",
    "stands as measured) or diverges (in which case quantify it, name which prior conclusions are ",
    "affected, and re-run the compression delta / classifier evaluation using real-round-trip ",
    "parameters if the real round-trip is more destructive than simulated -- that result supersedes ",
    "the simulated one)."
  )
  writeLines(lines, RESULTS_PATH)

  message(sprintf("Round-trip validation: %d/%d files matched and analysed. Verdicts: %s. Written to %s",
                   length(ok_results), nrow(matched),
                   paste(vapply(ok_results, function(r) paste0(r$id, "=", r$verdict), character(1)), collapse = ", "),
                   RESULTS_PATH))

  invisible(list(matched = matched, results = results))
}

if (sys.nframe() == 0) {
  main()
}
