# Shared config and helpers used across R/*.R pipeline stages.
# Sourced by every stage script so constants (sample rate, bands) can't drift
# between the codec experiment, preprocessing, and feature extraction.

WHATSAPP_SAMPLE_RATE  <- 16000L  # Hz -- WhatsApp voice note sample rate
WHATSAPP_BITRATE_KBPS <- 16      # kbps -- WhatsApp's Opus target bitrate (~16 kbps)
FFT_WINDOW            <- 2048    # long window: frequency resolution for low-freq insect sound

# FULL_FIDELITY_SAMPLE_RATE (Prompt 7, Issue 1): a "raw upload" control condition,
# standardised to one common high sample rate rather than left at native rates.
# 48kHz, not 44.1kHz: an ffprobe survey of the real corpus (data/raw/insectset459)
# found a heterogeneous mix of 44.1kHz and 48kHz source files (ESC-50 is 44.1kHz
# throughout) -- 48kHz was picked so no already-48kHz recording is downsampled,
# at the cost of upsampling the 44.1kHz files (no information gained, but no
# information lost either, and it's a single documented, consistent choice
# rather than leaving native rates in place, which would confound the
# comparison with heterogeneous bandwidth across files).
FULL_FIDELITY_SAMPLE_RATE <- 48000L

# WINDOW_SECONDS/HOP_SECONDS/SILENCE_THRESHOLD_DB: shared between
# 03_preprocess.R (training-side windowing) and 06_predict.R (inference-side
# windowing), so a voice note is split into windows the same way whether it's
# training data or a live incoming WhatsApp recording -- see gate_silent_windows().
WINDOW_SECONDS       <- 2.0
HOP_SECONDS          <- 1.0
SILENCE_THRESHOLD_DB <- -35  # edge-silence trim, relative to a clip's own peak frame

# ENERGY_GATE_DB (Prompt 7, Issue 3): drops windows/frames that are near-silent
# RELATIVE TO THE LOUDEST WINDOW FROM THE SAME RECORDING (or, at inference,
# the same incoming clip) -- deliberately NOT an absolute loudness floor. An
# absolute dBFS threshold would unfairly gate whole real species classes: an
# empirical survey of the existing real corpus found chorthippus_biguttulus/
# brunneus windows with an absolute median RMS below -60 dBFS simply because
# those recordings were captured at low gain, not because they're silent.
# Measured relative to each recording's own peak window instead, -35dB
# (matching SILENCE_THRESHOLD_DB, same physical intuition, one fewer
# arbitrary constant) drops ~2% of windows project-wide, concentrated
# almost entirely in the one long chorthippus_brunneus recording responsible
# for the original harmonic_energy_ratio NA confound (R/07_compression_delta.R,
# docs/compression_delta.md) -- i.e. it targets exactly the "technically
# labelled, acoustically empty" windows the confound investigation surfaced,
# without touching quiet-but-genuine recordings. See PROGRESS.md for the
# calibration survey this threshold was chosen from.
ENERGY_GATE_DB <- -35

FREQ_BANDS <- list(
  c(0,     500),
  c(500,   2000),
  c(2000,  4000),
  c(4000,  8000),
  c(8000,  Inf)
)
FREQ_BAND_LABELS <- c("0-500Hz", "500Hz-2kHz", "2-4kHz", "4-8kHz", ">8kHz")

#' Create a directory (recursively) if it doesn't already exist.
ensure_dir <- function(path) {
  if (!dir.exists(path)) dir.create(path, recursive = TRUE)
  invisible(path)
}

#' Append a structured JSON-lines log entry with a timestamp.
#' Used by the plumber webhook (Deliverable E) to satisfy the "log every
#' inbound request" requirement; kept here so any stage can log consistently.
log_event <- function(log_path, ...) {
  ensure_dir(dirname(log_path))
  entry <- c(list(timestamp = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z")), list(...))
  cat(jsonlite::toJSON(entry, auto_unbox = TRUE), "\n", file = log_path, append = TRUE, sep = "")
  invisible(entry)
}

# ---- Shared windowing/silence helpers ---------------------------------------
# Used by both R/03_preprocess.R (training-side) and R/06_predict.R
# (inference-side) so a voice note is windowed and gated identically
# regardless of whether it's training data or a live incoming recording
# (Prompt 7, Issue 3 -- "training and serving see the same window population").

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

#' RMS level in dBFS (relative to 16-bit full scale) of an integer PCM sample
#' vector. Returns -Inf for digital silence (rms == 0) rather than NaN/error.
rms_dbfs <- function(x, full_scale = 32768) {
  rms <- sqrt(mean((x / full_scale)^2))
  if (!is.finite(rms) || rms <= 0) return(-Inf)
  20 * log10(rms)
}

#' Which windows in a list (all from the SAME source recording / incoming
#' clip) carry enough energy to keep -- see ENERGY_GATE_DB above for why this
#' is relative to the loudest window in the set, not an absolute floor.
#'
#' @return Logical vector, same length as `windows`; TRUE = keep. All FALSE
#'   if the entire set is at or below digital silence (no usable peak at all).
gate_silent_windows <- function(windows, threshold_db = ENERGY_GATE_DB) {
  levels_db <- vapply(windows, rms_dbfs, numeric(1))
  peak_db <- suppressWarnings(max(levels_db))
  if (!is.finite(peak_db)) return(rep(FALSE, length(windows)))
  (levels_db - peak_db) > threshold_db
}

# ---- Distribution summary (shared: R/05_train.R, R/07_compression_delta.R) --
# Prompt 7/8: never report a single point estimate from one split/seed/fold
# on a corpus this small -- always the distribution across repeats.

#' Mean/sd/95%-range summary of a numeric vector across repeated
#' folds/seeds -- the honest quantity, not a bare point estimate.
distribution_summary <- function(x) {
  x <- x[is.finite(x)]
  if (length(x) == 0) {
    return(list(mean = NA_real_, sd = NA_real_, lo95 = NA_real_, hi95 = NA_real_, n = 0L))
  }
  list(mean = mean(x), sd = stats::sd(x),
       lo95 = unname(stats::quantile(x, 0.025)), hi95 = unname(stats::quantile(x, 0.975)),
       n = length(x))
}

fmt_pct <- function(x) if (is.na(x)) "N/A" else paste0(round(x * 100, 1), "%")

#' `distribution_summary()` rendered as "mean% (sd Xpp, range Y% to Z%)".
fmt_distribution <- function(s) {
  if (s$n == 0) return("N/A")
  sprintf("%s (sd %s, range %s to %s, n=%d)", fmt_pct(s$mean),
          if (is.na(s$sd)) "N/A" else paste0(round(s$sd * 100, 1), "pp"),
          fmt_pct(s$lo95), fmt_pct(s$hi95), s$n)
}
