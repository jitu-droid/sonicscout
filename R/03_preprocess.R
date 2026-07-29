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

WINDOW_SECONDS <- 2.0
HOP_SECONDS    <- 1.0
SILENCE_THRESHOLD_DB <- -35

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
# with 14 ambient categories that's 560 real ambient windows-worth against
# a synthetic corpus of 5 source files per pest class -- wildly imbalanced
# and slow to process for a hackathon-scale demo. Capped near the synthetic
# per-class count instead of forcing exact balance (real data scarcity for
# pest classes is real and should be visible, not hidden). Sampled (fixed
# seed), not first-N, to avoid any accidental ordering bias.
MAX_REAL_PER_SUBCATEGORY <- 5

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

    raw_manifest$is_ambient <- raw_manifest$source == "ESC-50"
    raw_manifest$subcat_key <- ifelse(raw_manifest$is_ambient, raw_manifest$label, raw_manifest$source)
    set.seed(20260729)
    for (key in unique(raw_manifest$subcat_key)) {
      subset_idx <- which(raw_manifest$subcat_key == key)
      keep_idx <- if (length(subset_idx) > MAX_REAL_PER_SUBCATEGORY) {
        sample(subset_idx, MAX_REAL_PER_SUBCATEGORY)
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

# ---- Silence trimming -------------------------------------------------------

#' Trim leading/trailing near-silence via a simple frame-RMS threshold
#' (relative to the clip's own peak frame). Not a sophisticated VAD -- just
#' enough to drop dead air at the edges of a field recording. If every frame
#' falls below threshold (e.g. a very quiet or already-short clip), returns
#' the signal unchanged rather than emptying it.
trim_silence <- function(x, sr, threshold_db = SILENCE_THRESHOLD_DB, frame_ms = 20) {
  frame_len <- max(1, round(sr * frame_ms / 1000))
  n_frames <- floor(length(x) / frame_len)
  if (n_frames < 2) return(x)

  rms <- vapply(seq_len(n_frames), function(i) {
    seg <- x[((i - 1) * frame_len + 1):(i * frame_len)]
    sqrt(mean(seg^2))
  }, numeric(1))

  peak_rms <- max(rms, na.rm = TRUE)
  if (peak_rms <= 0) return(x)
  rms_db <- 20 * log10(pmax(rms, 1e-8) / peak_rms)

  active <- which(rms_db > threshold_db)
  if (length(active) == 0) return(x)

  start <- (min(active) - 1) * frame_len + 1
  end <- min(length(x), max(active) * frame_len)
  x[start:end]
}

# ---- Windowing ---------------------------------------------------------------

#' Split a signal into fixed-length windows (zero-padding the tail, and the
#' whole clip if it's shorter than one window).
window_signal <- function(x, sr, window_s = WINDOW_SECONDS, hop_s = HOP_SECONDS) {
  window_len <- round(window_s * sr)
  hop_len <- round(hop_s * sr)

  if (length(x) <= window_len) {
    return(list(c(x, rep(0, window_len - length(x)))))
  }

  starts <- seq(1, length(x) - window_len + 1, by = hop_len)
  last_start <- length(x) - window_len + 1
  if (length(starts) == 0 || utils::tail(starts, 1) < last_start) {
    starts <- c(starts, last_start)
  }
  lapply(unique(starts), function(s) x[s:(s + window_len - 1)])
}

# ---- Main per-file pipeline ---------------------------------------------------

#' Process one source file end to end: read -> compress (WhatsApp sim) ->
#' trim silence -> window -> write each window as its own WAV. Returns a
#' data frame of manifest rows for the windows it wrote (zero rows if the
#' file couldn't be processed, logged rather than raised).
process_one_file <- function(path, label, subcategory, data_origin) {
  result <- tryCatch({
    # simulate_whatsapp_compression() shells out to ffmpeg with `-i path`,
    # which is format-agnostic (mp3/ogg/wav/...), so there's no need to read
    # the original file in R first -- and for xeno-canto's .mp3 sources,
    # tuneR::readWave() would fail outright since it only parses WAV.
    tmp_degraded <- tempfile(fileext = ".wav")
    on.exit(unlink(tmp_degraded), add = TRUE)
    simulate_whatsapp_compression(path, tmp_degraded)
    degraded <- tuneR::readWave(tmp_degraded)

    windows <- window_signal(trim_silence(degraded@left, degraded@samp.rate), degraded@samp.rate)

    stem <- tools::file_path_sans_ext(basename(path))
    out_dir <- file.path(PROCESSED_DIR, label)
    ensure_dir(out_dir)

    manifest_rows <- vector("list", length(windows))
    for (i in seq_along(windows)) {
      out_path <- file.path(out_dir, sprintf("%s__win%02d.wav", stem, i))
      out_wave <- tuneR::Wave(left = as.integer(windows[[i]]), samp.rate = degraded@samp.rate, bit = 16)
      tuneR::writeWave(out_wave, out_path)
      manifest_rows[[i]] <- data.frame(
        path = out_path, label = label, subcategory = subcategory,
        data_origin = data_origin, source_file = path, window_index = i,
        duration_s = length(windows[[i]]) / degraded@samp.rate,
        stringsAsFactors = FALSE
      )
    }
    do.call(rbind, manifest_rows)
  }, error = function(e) {
    message("Failed to process ", path, ": ", conditionMessage(e))
    NULL
  })

  if (is.null(result)) {
    data.frame(path = character(), label = character(), subcategory = character(),
               data_origin = character(), source_file = character(),
               window_index = integer(), duration_s = numeric(),
               stringsAsFactors = FALSE)
  } else {
    result
  }
}

main <- function() {
  sources <- collect_labeled_sources()
  message("Preprocessing ", nrow(sources), " source files across ",
          length(unique(sources$label)), " labels: ",
          paste(unique(sources$label), collapse = ", "))

  all_windows <- do.call(rbind, lapply(seq_len(nrow(sources)), function(i) {
    process_one_file(sources$path[i], sources$label[i], sources$subcategory[i], sources$data_origin[i])
  }))

  ensure_dir(PROCESSED_DIR)
  utils::write.csv(all_windows, WINDOWS_MANIFEST, row.names = FALSE)

  message("Wrote ", nrow(all_windows), " windows from ", nrow(sources),
          " source files to ", PROCESSED_DIR, ". Manifest: ", WINDOWS_MANIFEST)
  invisible(all_windows)
}

if (sys.nframe() == 0) {
  main()
}
