#' Compute a one-row tibble of spectral features from a Wave object
#'
#' Extracts a documented, inspectable feature set rather than a black-box
#' embedding, so results can be explained rather than just trusted:
#' `peak_freq_hz`, `spectral_centroid_hz`, `spectral_flatness`,
#' `spectral_entropy`, `spectral_rolloff85_hz` (frequency below which 85% of
#' spectral energy lies), `dominant_freq_sd_hz` (stability of the dominant
#' frequency contour over time -- low means tonal/steady, high means
#' erratic), `harmonic_energy_ratio` (a simple heuristic, see Details), and
#' 12 MFCCs (mean over frames).
#'
#' @details
#' `harmonic_energy_ratio` is the fraction of total spectral energy that
#' falls within a narrow band around the first 5 integer multiples of the
#' peak frequency. It is a lightweight, transparent heuristic for "how
#' harmonic does this sound look", not a validated harmonicity/HNR index --
#' report it as such.
#'
#' @param wave A [tuneR::Wave-class] object, e.g. from [wa_read()].
#' @param wl Window length (samples) used for the underlying STFT/mean
#'   spectrum. See [wa_spectrogram()] for the same parameter.
#'
#' @return A one-row tibble.
#'
#' @examples
#' \dontrun{
#' w <- wa_read("voice_note.opus")
#' wa_features(w)
#' }
#'
#' @export
wa_features <- function(wave, wl = 1024) {
  spec <- seewave::meanspec(wave, wl = wl, plot = FALSE)
  props <- seewave::specprop(spec, f = wave@samp.rate, plot = FALSE)

  peak_freq_hz <- spec[which.max(spec[, 2]), 1] * 1000

  total_energy <- sum(spec[, 2])
  cum_energy <- cumsum(spec[, 2]) / total_energy
  rolloff_idx <- which(cum_energy >= 0.85)[1]
  rolloff_hz <- if (length(rolloff_idx) == 0 || is.na(rolloff_idx)) {
    NA_real_
  } else {
    spec[rolloff_idx, 1] * 1000
  }

  dom_freq_khz <- tryCatch(
    seewave::dfreq(wave, wl = wl, plot = FALSE)[, 2],
    error = function(e) NA_real_
  )
  dominant_freq_sd_hz <- stats::sd(dom_freq_khz, na.rm = TRUE) * 1000

  harmonic_energy_ratio <- harmonic_energy_ratio_from_spectrum(spec, peak_freq_hz)

  mfcc_matrix <- tryCatch(
    tuneR::melfcc(wave, numcep = 12),
    error = function(e) matrix(NA_real_, nrow = 1, ncol = 12)
  )
  mfcc_means <- colMeans(mfcc_matrix, na.rm = TRUE)
  names(mfcc_means) <- paste0("mfcc_", seq_along(mfcc_means))

  samples <- wave@left
  tibble::as_tibble(c(
    list(
      duration_s = length(samples) / wave@samp.rate,
      rms_amplitude = sqrt(mean((samples / max(abs(samples), 1))^2)),
      peak_freq_hz = peak_freq_hz,
      spectral_centroid_hz = props$cent * 1000,
      spectral_flatness = props$sfm,
      spectral_entropy = props$sh,
      spectral_rolloff85_hz = rolloff_hz,
      dominant_freq_sd_hz = dominant_freq_sd_hz,
      harmonic_energy_ratio = harmonic_energy_ratio
    ),
    as.list(mfcc_means)
  ))
}

#' Fraction of spectral energy near the first `n_harmonics` integer
#' multiples of `f0_hz`. See "Details" on [wa_features()] for caveats.
#'
#' Returns 0 (not NA) when there's no well-defined peak frequency to anchor
#' harmonics to (a DC-dominant/near-silent window) or no spectral energy at
#' all -- both are legitimate "no measurable harmonic structure" readings,
#' not failures to compute. This matters in practice: returning NA here
#' silently drops the whole window from `complete.cases()`-based training
#' filters downstream, and near-silent windows are common in real (as
#' opposed to hand-trimmed) field recordings with quiet gaps between call
#' bouts. Found via a real confound while comparing compressed vs.
#' uncompressed classifier accuracy (R/07_compression_delta.R): a couple of
#' long, quiet real recordings were dropping >100 windows' worth of test
#' data in the uncompressed condition (where genuine silence stays silent)
#' but far fewer in the compressed condition (where the codec's own
#' noise-shaping incidentally raises the noise floor just enough to avoid
#' a literal zero-Hz peak) -- an artifact of this function's NA branch, not
#' a real property of compression.
#' @noRd
harmonic_energy_ratio_from_spectrum <- function(spec, f0_hz, n_harmonics = 5, tol_hz = 50) {
  if (is.na(f0_hz) || f0_hz <= 0) return(0)
  freq_hz <- spec[, 1] * 1000
  amp <- spec[, 2]
  total <- sum(amp)
  if (total == 0) return(0)

  harmonic_energy <- 0
  for (h in seq_len(n_harmonics)) {
    target <- f0_hz * h
    in_band <- abs(freq_hz - target) <= tol_hz
    harmonic_energy <- harmonic_energy + sum(amp[in_band])
  }
  harmonic_energy / total
}
