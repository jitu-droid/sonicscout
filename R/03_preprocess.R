# Deliverable C -- Data pipeline, step 2: preprocess raw audio into
# fixed-length, WhatsApp-compression-matched windows ready for feature
# extraction.
#
# Two things this script exists specifically to get right:
#
#   1. Train/serve match. The classifier will only ever see audio that has
#      already been through WhatsApp's Opus/Ogg compression (that's what
#      arrives via the webhook). Training on clean audio and serving on
#      16kbps Opus would be a silent train/serve skew bug that inflates
#      every reported number. So every window here is built from the
#      *compressed* version of its source clip, not the original.
#   2. Grouping. Every window keeps a `source_file` column recording which
#      original clip it came from, so 05_train.R can split train/val/test
#      by source recording and guarantee no clip straddles the split.
#
# Usage:
#   Rscript R/03_preprocess.R
#
# Inputs:
#   data/raw/manifest.csv                        (from 01_download_data.R)
#   data/codec_experiment/reference/<label>/*.wav (from 00_synthetic_corpus.R)
#
# Output:
#   data/processed/<label>/<source_stem>__win<NN>.wav
#   data/processed/windows_manifest.csv

library(tuneR)

source(file.path("R", "utils.R"))
source(file.path("R", "02_codec_experiment.R"))  # for simulate_whatsapp_compression()

RAW_MANIFEST_PATH <- file.path("data", "raw", "manifest.csv")
SYNTHETIC_DIR      <- file.path("data", "codec_experiment", "reference")
PROCESSED_DIR      <- file.path("data", "processed")
WINDOWS_MANIFEST   <- file.path(PROCESSED_DIR, "windows_manifest.csv")

# WINDOW_SECONDS, HOP_SECONDS, SILENCE_THRESHOLD_DB, ENERGY_GATE_DB,
# trim_silence(), window_signal(), gate_silent_windows() all live in
# R/utils.R now (Prompt 7) so R/06_predict.R can window/gate an incoming
# voice note identically to how training data is windowed/gated here --
# "same window population" between train and serve.

# Cap on windows contributed by any one source recording (Prompt 8, Step 3)
# -- see the comment at its use in process_one_file() for why. 20 windows
# at WINDOW_SECONDS=2.0/HOP_SECONDS=1.0 spans ~21s of a recording's timeline
# (with 50% overlap) -- enough to still capture real within-call variation
# for a short recording, while bounding a multi-minute recording's maximum
# possible share of any one fold to the same order of magnitude as every
# other recording, not two orders of magnitude more. Training-side only:
# not applied at inference (R/06_predict.R), where a real incoming voice
# note is expected to be a single short (10-30s) clip in the first place.
MAX_WINDOWS_PER_SOURCE <- 20

# Synthetic classes that exist purely to ground-truth-check the codec
# simulation (Deliverable A), not to represent a pest/ambient class -- these
# are excluded from the classifier's training set. See docs/methodology.md.
# NOTE: this must NOT include synthetic_broadband_noise (it's the ambient/
# negative-class stand-in -- see R/00_synthetic_corpus.R) or
# synthetic_tone_plus_noise (a legitimate robustness-sweep class); an
# earlier version of this list wrongly excluded both, silently dropping 2
# of 6 classes from every training run without any error or warning.
SYNTHETIC_CODEC_ONLY_LABELS <- c("synthetic_above_nyquist_control")

# ---- Source discovery -----------------------------------------------------

AUDIO_EXTENSIONS <- c("wav", "mp3", "ogg", "opus", "m4a")

# Cap real ESC-50 clips per subcategory: ESC-50 has 40 clips/category, and
# with 14 ambient categories that's 560 real ambient windows-worth. Capped
# so the ambient/negative class stays roughly matched in scale to the real
# pest corpus rather than swamping it, not because ESC-50 is scarce.
# Sampled (fixed seed), not first-N, to avoid any accidental ordering bias.
#
# Real PEST species get NO cap (Prompt 8, Step 1) -- every downloaded,
# valid recording enters the pipeline. The previous version of this
# constant (MAX_REAL_PER_SUBCATEGORY = 5, applied uniformly to every
# class including real pest species) was silently discarding the vast
# majority of already-downloaded InsectSet459 audio: 22/17/20 files on
# disk for the 3 real species, but only 5 of each were ever used. Prompt
# 7's 50-seed analysis found this classifier's accuracy swinging ~10-92%
# seed to seed; the root cause was traced to this cap -- with only 5
# source files per class and a grouped split, a class's entire test set
# is often ONE recording, so accuracy tracks which recording happened to
# land in test, not anything the model is good or bad at. Fixed at the
# source (use the whole corpus) rather than by re-splitting harder. See
# docs/methodology.md and PROGRESS.md for the before/after
# seed-distribution comparison this produced.
MAX_AMBIENT_PER_SUBCATEGORY <- 10  # up from 5 -- now that pest species use
# their full corpus (dozens of files each once Prompt 8 Step 2's expanded
# download lands) rather than 5 files each, 5-per-ambient-category would
# make ambient a small minority class; 10 (14 categories = up to 140
# ambient source files) keeps it in the same ballpark as a ~40-50-file-
# per-species pest corpus without needing exact numeric parity.

#' Collect every (path, label, data_origin) row we have labelled audio for.
#' `label` for ESC-50 ambient categories is coarsened to "ambient" for the
#' classifier target; the finer ESC-50 category is kept as `subcategory`.
collect_labeled_sources <- function() {
  rows <- list()

  if (file.exists(RAW_MANIFEST_PATH)) {
    raw_manifest <- utils::read.csv(RAW_MANIFEST_PATH, stringsAsFactors = FALSE)
    # Drop non-audio manifest rows (e.g. the ESC-50 zip archive itself is
    # logged as its own manifest entry alongside the individual clips it
    # was extracted from -- it's not something wa_read() can decode).
    raw_manifest <- raw_manifest[tolower(tools::file_ext(raw_manifest$file)) %in% AUDIO_EXTENSIONS, ]

    # USDA-ARS chewing/feeding recordings are deliberately excluded from the
    # classifier's training set. The codec experiment (docs/codec_findings.md)
    # already answered the chewing-sound question directly at the signal
    # level: every one of those recordings was captured with a contact/
    # vibration sensor (accelerometer, piezoelectric disk, PVDF film, soil
    # microphone), never an open-air microphone, so training a classifier on
    # them would still only be measuring a best-case ceiling, not real-world
    # viability -- and the MVP is explicitly scoped to stridulation/wingbeat
    # pests for now (chewing/Fall Armyworm is a stated phase-2 target
    # requiring a different capture method). Keeping them out of the
    # classifier's training data keeps this run focused on what's actually
    # in scope; they remain fully analysed in the codec experiment above.
    raw_manifest <- raw_manifest[raw_manifest$source != "USDA-ARS-soundlibrary", ]

    raw_manifest$is_ambient <- raw_manifest$source == "ESC-50"
    # Cap per LABEL (species), not per source -- grouping by `source` would
    # lump all InsectSet459 species into one shared cap (a real bug found
    # while retraining in Session 3: it silently capped 3 species combined
    # at 5 files instead of 5 each). ESC-50 groups by its finer ambient
    # category (`label`), same as before. Real pest species are uncapped
    # (Inf) as of Prompt 8 -- see MAX_AMBIENT_PER_SUBCATEGORY above.
    raw_manifest$subcat_key <- raw_manifest$label
    set.seed(20260729)
    for (key in unique(raw_manifest$subcat_key)) {
      subset_idx <- which(raw_manifest$subcat_key == key)
      cap <- if (raw_manifest$is_ambient[subset_idx[1]]) MAX_AMBIENT_PER_SUBCATEGORY else Inf
      keep_idx <- if (length(subset_idx) > cap) {
        sample(subset_idx, cap)
      } else {
        subset_idx
      }
      for (i in keep_idx) {
        r <- raw_manifest[i, ]
        if (!file.exists(r$file)) next
        rows[[length(rows) + 1]] <- data.frame(
          path = r$file,
          label = if (r$is_ambient) "ambient" else r$label,
          subcategory = if (r$is_ambient) r$label else NA_character_,
          data_origin = "real",
          stringsAsFactors = FALSE
        )
      }
    }
  } else {
    message(RAW_MANIFEST_PATH, " not found -- no real-data rows (run R/01_download_data.R first if you want real audio in the training set).")
  }

  if (dir.exists(SYNTHETIC_DIR)) {
    species_dirs <- list.dirs(SYNTHETIC_DIR, recursive = FALSE)
    for (d in species_dirs) {
      dir_label <- basename(d)
      if (dir_label %in% SYNTHETIC_CODEC_ONLY_LABELS) next
      # Only "synthetic_*" dirs feed the classifier from here. "real_*" dirs
      # (added by R/prepare_real_reference.R for Deliverable A's codec
      # experiment) are deliberately skipped -- real audio for the
      # classifier comes from data/raw/manifest.csv instead (a separate,
      # larger per-species sample). Without this filter the same real
      # species would be double-counted under two different data_origin
      # labels.
      if (!startsWith(dir_label, "synthetic_")) next
      files <- list.files(d, pattern = "\\.wav$", full.names = TRUE)
      if (length(files) == 0) next
      # synthetic_broadband_noise is documented (R/00_synthetic_corpus.R) as
      # the ambient/negative-class stand-in -- recognise it as "ambient" so
      # the false-positive-rate-vs-ambient metric is computable even when
      # running on synthetic data alone (no real ESC-50 data yet).
      is_ambient <- dir_label == "synthetic_broadband_noise"
      rows[[length(rows) + 1]] <- data.frame(
        path = files,
        label = if (is_ambient) "ambient" else dir_label,
        subcategory = if (is_ambient) dir_label else NA_character_,
        data_origin = "synthetic", stringsAsFactors = FALSE
      )
    }
  } else {
    message(SYNTHETIC_DIR, " not found -- run R/00_synthetic_corpus.R first.")
  }

  if (length(rows) == 0) {
    stop("No labelled audio sources found at all. Run R/00_synthetic_corpus.R ",
         "and/or R/01_download_data.R before preprocessing.")
  }

  do.call(rbind, rows)
}

# ---- Main per-file pipeline ---------------------------------------------------

#' Resample/downmix via ffmpeg WITHOUT the Opus round-trip -- the two
#' "uncompressed" control conditions for R/07_compression_delta.R.
#'
#' @param sample_rate WHATSAPP_SAMPLE_RATE (16kHz) isolates codec-quantization
#'   damage only, bandwidth held constant vs. the compressed arm ("codec-only"
#'   control). FULL_FIDELITY_SAMPLE_RATE (48kHz) additionally restores the
#'   bandwidth WhatsApp's 16kHz sample rate discards ("full-fidelity" control,
#'   i.e. the raw-upload-path comparison). Explicit `pcm_s16le` output format
#'   so bit depth stays identical across every arm -- otherwise RMS-dBFS-based
#'   energy gating (gate_silent_windows(), R/utils.R) would not be comparable
#'   between conditions.
resample_mono_only <- function(input_path, output_wav, sample_rate = WHATSAPP_SAMPLE_RATE) {
  ffmpeg_bin <- Sys.which("ffmpeg")
  if (ffmpeg_bin == "") stop("ffmpeg not found on PATH")
  ensure_dir(dirname(output_wav))
  status <- system2(ffmpeg_bin, args = c("-y", "-loglevel", "error", "-i", input_path,
                                          "-ar", as.character(sample_rate), "-ac", "1",
                                          "-c:a", "pcm_s16le", output_wav))
  if (status != 0) stop("ffmpeg failed to resample ", input_path)
  invisible(output_wav)
}

#' Process one source file end to end: read -> degrade (WhatsApp sim, or one
#' of the two uncompressed controls, per `mode`) -> trim silence -> window ->
#' gate near-silent windows -> write each surviving window as its own WAV.
#'
#' @param mode "compressed" (default pipeline: full WhatsApp Opus/Ogg
#'   simulation), "codec_only" (resampled to WHATSAPP_SAMPLE_RATE, no Opus --
#'   isolates codec damage), or "full_fidelity" (resampled to
#'   FULL_FIDELITY_SAMPLE_RATE, no Opus -- isolates total transport cost
#'   including bandwidth). See R/utils.R for why these are two different
#'   questions (Prompt 7, Issue 1).
#'
#' @return A list: `manifest` (data frame of window rows written; zero rows
#'   if the file couldn't be processed, logged rather than raised) and
#'   `n_windows_before_gate`/`n_windows_after_gate` (energy-gate bookkeeping,
#'   Prompt 7 Issue 3 -- so R/07_compression_delta.R can report how many
#'   windows each arm lost and confirm the counts stay comparable).
process_one_file <- function(path, label, subcategory, data_origin,
                              mode = c("compressed", "codec_only", "full_fidelity"),
                              processed_dir = PROCESSED_DIR) {
  mode <- match.arg(mode)
  empty_manifest <- function() data.frame(
    path = character(), label = character(), subcategory = character(),
    data_origin = character(), source_file = character(),
    window_index = integer(), duration_s = numeric(), stringsAsFactors = FALSE
  )

  result <- tryCatch({
    # simulate_whatsapp_compression() and resample_mono_only() both shell out
    # to ffmpeg with `-i path`, which is format-agnostic (mp3/ogg/wav/...), so
    # there's no need to read the original file in R first -- and for .mp3
    # sources, tuneR::readWave() would fail outright since it only parses WAV.
    tmp_degraded <- tempfile(fileext = ".wav")
    on.exit(unlink(tmp_degraded), add = TRUE)
    if (mode == "compressed") {
      simulate_whatsapp_compression(path, tmp_degraded)
    } else if (mode == "codec_only") {
      resample_mono_only(path, tmp_degraded, sample_rate = WHATSAPP_SAMPLE_RATE)
    } else {
      resample_mono_only(path, tmp_degraded, sample_rate = FULL_FIDELITY_SAMPLE_RATE)
    }
    degraded <- tuneR::readWave(tmp_degraded)

    windows <- window_signal(trim_silence(degraded@left, degraded@samp.rate), degraded@samp.rate)
    keep <- gate_silent_windows(windows)
    n_before <- length(windows)
    n_after <- sum(keep)
    kept_original_indices <- which(keep)
    windows <- windows[keep]

    # Cap windows contributed by any ONE source recording (Prompt 8, Step 3).
    # Recording durations vary by two orders of magnitude in this corpus (a
    # few seconds to several minutes); left uncapped, one long recording can
    # contribute hundreds of windows and dominate whichever grouped-split
    # fold it lands in -- this is what made Prompt 7's per-arm accuracy
    # swing ~10-92% seed to seed even after fixing the per-species file cap
    # (Step 1). Subsampled EVENLY ACROSS the recording's timeline (not the
    # first MAX_WINDOWS_PER_SOURCE, which would bias every capped recording
    # toward its opening seconds) so the capped set still represents the
    # whole recording, not just its start.
    if (length(windows) > MAX_WINDOWS_PER_SOURCE) {
      pick <- unique(round(seq(1, length(windows), length.out = MAX_WINDOWS_PER_SOURCE)))
      windows <- windows[pick]
      kept_original_indices <- kept_original_indices[pick]
    }

    stem <- tools::file_path_sans_ext(basename(path))
    out_dir <- file.path(processed_dir, label)
    ensure_dir(out_dir)

    manifest_rows <- vector("list", length(windows))
    for (i in seq_along(windows)) {
      out_path <- file.path(out_dir, sprintf("%s__win%02d.wav", stem, kept_original_indices[i]))
      out_wave <- tuneR::Wave(left = as.integer(windows[[i]]), samp.rate = degraded@samp.rate, bit = 16)
      tuneR::writeWave(out_wave, out_path)
      manifest_rows[[i]] <- data.frame(
        path = out_path, label = label, subcategory = subcategory,
        data_origin = data_origin, source_file = path, window_index = kept_original_indices[i],
        duration_s = length(windows[[i]]) / degraded@samp.rate,
        stringsAsFactors = FALSE
      )
    }
    list(manifest = if (length(manifest_rows) == 0) empty_manifest() else do.call(rbind, manifest_rows),
         n_windows_before_gate = n_before, n_windows_after_gate = n_after)
  }, error = function(e) {
    message("Failed to process ", path, ": ", conditionMessage(e))
    NULL
  })

  if (is.null(result)) {
    list(manifest = empty_manifest(), n_windows_before_gate = 0L, n_windows_after_gate = 0L)
  } else {
    result
  }
}

#' @param mode See process_one_file(). Always "compressed" for the default
#'   `Rscript R/03_preprocess.R` invocation; R/07_compression_delta.R calls
#'   this function directly with "codec_only" / "full_fidelity".
main <- function(mode = c("compressed", "codec_only", "full_fidelity"),
                  processed_dir = PROCESSED_DIR,
                  windows_manifest_path = WINDOWS_MANIFEST) {
  mode <- match.arg(mode)
  sources <- collect_labeled_sources()
  message("Preprocessing ", nrow(sources), " source files across ",
          length(unique(sources$label)), " labels: ",
          paste(unique(sources$label), collapse = ", "),
          if (mode != "compressed") paste0(" (", toupper(mode), " condition)") else "")

  per_file <- lapply(seq_len(nrow(sources)), function(i) {
    process_one_file(sources$path[i], sources$label[i], sources$subcategory[i], sources$data_origin[i],
                      mode = mode, processed_dir = processed_dir)
  })

  all_windows <- do.call(rbind, lapply(per_file, `[[`, "manifest"))
  n_before_gate <- sum(vapply(per_file, `[[`, integer(1), "n_windows_before_gate"))
  n_after_gate <- sum(vapply(per_file, `[[`, integer(1), "n_windows_after_gate"))

  ensure_dir(processed_dir)
  utils::write.csv(all_windows, windows_manifest_path, row.names = FALSE)

  message("Wrote ", nrow(all_windows), " windows from ", nrow(sources),
          " source files to ", processed_dir, ". Manifest: ", windows_manifest_path)
  message("Energy gate (", ENERGY_GATE_DB, "dB relative to each recording's own peak window): ",
          n_before_gate - n_after_gate, " of ", n_before_gate, " windows dropped as near-silent.")

  # Windows-per-recording distribution (Prompt 8, Step 3 asks this be
  # reported explicitly -- it's the direct evidence for whether the cap
  # above is doing anything).
  per_source_counts <- table(all_windows$source_file)
  if (length(per_source_counts) > 0) {
    q <- stats::quantile(as.integer(per_source_counts), probs = c(0, .25, .5, .75, 1))
    message(sprintf(
      "Windows per source recording (post-cap, n=%d recordings): min=%d, p25=%.0f, median=%.0f, p75=%.0f, max=%d.",
      length(per_source_counts), q[1], q[2], q[3], q[4], q[5]
    ))
  }

  attr(all_windows, "n_windows_before_gate") <- n_before_gate
  attr(all_windows, "n_windows_after_gate") <- n_after_gate
  attr(all_windows, "windows_per_source") <- per_source_counts
  invisible(all_windows)
}

if (sys.nframe() == 0) {
  main()
}
