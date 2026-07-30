#' Compute a one-row tibble of spectral AND temporal features from a Wave
#' object
#'
#' Extracts a documented, inspectable feature set rather than a black-box
#' embedding, so results can be explained rather than just trusted.
#'
#' **Spectral** (original feature set): `peak_freq_hz`,
#' `spectral_centroid_hz`, `spectral_flatness`, `spectral_entropy`,
#' `spectral_rolloff85_hz` (frequency below which 85% of spectral energy
#' lies), `dominant_freq_sd_hz` (stability of the dominant frequency
#' contour over time -- low means tonal/steady, high means erratic),
#' `harmonic_energy_ratio` (a simple heuristic, see Details), and 12 MFCCs
#' (mean over frames).
#'
#' **Temporal** (added Prompt 9, see Details): `pulse_rate_hz`,
#' `ipi_mean_s`/`ipi_sd_s`/`ipi_cv`, `envelope_mod_freq_hz`/
#' `envelope_mod_peak_ratio`, `temporal_entropy`, `duty_cycle`,
#' `phrase_duration_s`, `n_phrase_bouts`, `phrase_duty_cycle`. Added
#' because *Chorthippus biguttulus* and *C. brunneus* -- two of this
#' project's three real target classes -- are sympatric congeners whose
#' species boundary is maintained by TEMPORAL song structure (syllable
#' pattern, phrase duration), not spectral content (von Helversen & von
#' Helversen 1997, J Comp Physiol A 180:373-386; Gottsberger & Mayer 2007,
#' J Comp Physiol A 193:703-714). A feature set that is almost entirely
#' spectral is asking a classifier to separate these two species along
#' the dimension where they are most alike. See `docs/methodology.md` for
#' the full biological reasoning and whether these features actually
#' helped.
#'
#' @details
#' `harmonic_energy_ratio` is the fraction of total spectral energy that
#' falls within a narrow band around the first 5 integer multiples of the
#' peak frequency. It is a lightweight, transparent heuristic for "how
#' harmonic does this sound look", not a validated harmonicity/HNR index --
#' report it as such.
#'
#' Temporal features are all derived from the Hilbert amplitude envelope
#' (`seewave::env()`) at two smoothing scales:
#' - A FINE scale (~2ms smoothing, chosen so the resulting envelope's
#'   effective sample rate, ~500Hz, comfortably resolves both the ~10Hz
#'   syllable repetition rate and the ~70Hz within-syllable pulse rate
#'   reported for these species) for `pulse_rate_hz` (peaks/second, via a
#'   local-maxima detector with a relative height threshold and a 10ms
#'   minimum-distance non-max-suppression pass -- a refractory period
#'   below which two peaks are almost certainly the same pulse's ripple,
#'   not two pulses), `ipi_*` (inter-peak-interval mean/sd/coefficient of
#'   variation), `envelope_mod_freq_hz`/`envelope_mod_peak_ratio` (the
#'   dominant frequency and prominence of the envelope's OWN modulation
#'   spectrum -- an FFT of the envelope itself, not the audio -- searched
#'   over 2-100Hz to avoid slow non-rhythmic trends near DC while still
#'   covering both the syllable and pulse rate), and `duty_cycle`
#'   (fraction of the window above 10% of its own envelope peak).
#' - A COARSE scale (~30ms smoothing) for phrase/bout-level on-off
#'   structure: `phrase_duration_s` (the longest continuous above-15%-
#'   threshold run in the window -- a proxy for "how long is one bout of
#'   song here"), `n_phrase_bouts` (how many separate bouts), and
#'   `phrase_duty_cycle`.
#'
#' All temporal features return 0 (not NA) on a degenerate window
#' (silence, or too short to compute an envelope) -- 0 is a legitimate
#' "no measurable temporal structure" reading here, for the same reason
#' `harmonic_energy_ratio_from_spectrum()` returns 0 rather than NA: an NA
#' would silently drop the whole window from any `complete.cases()`-based
#' training filter downstream, which is exactly the bug class the
#' Session 3 `harmonic_energy_ratio` confound came from.
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

  temporal <- wa_temporal_features(wave)

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
    as.list(mfcc_means),
    temporal
  ))
}

# ---- Temporal features (Prompt 9) -------------------------------------------

#' Local maxima of a normalized envelope, with a relative height threshold
#' and a minimum-distance non-max-suppression pass (greedy, highest peaks
#' kept first) so a pulse's own ripple isn't counted as several pulses.
#' @noRd
envelope_peaks <- function(env_norm, min_dist_samples, height_thresh = 0.2) {
  n <- length(env_norm)
  if (n < 3) return(integer(0))
  is_max <- c(FALSE, env_norm[2:(n - 1)] > env_norm[1:(n - 2)] & env_norm[2:(n - 1)] >= env_norm[3:n], FALSE)
  cand <- which(is_max & env_norm > height_thresh)
  if (length(cand) == 0) return(integer(0))
  ord <- cand[order(env_norm[cand], decreasing = TRUE)]
  kept <- integer(0)
  for (idx in ord) {
    if (length(kept) == 0 || all(abs(idx - kept) >= min_dist_samples)) kept <- c(kept, idx)
  }
  sort(kept)
}

#' Fine-scale (pulse/syllable) + coarse-scale (phrase/bout) temporal
#' features from a Wave's amplitude envelope. See wa_features()'s Details
#' for the full reasoning and parameter choices. Returns a plain named
#' list (not a tibble) -- wa_features() splices it into its own tibble.
#' @noRd
wa_temporal_features <- function(wave) {
  sr <- wave@samp.rate
  dur_s <- length(wave@left) / sr
  zero_result <- list(
    pulse_rate_hz = 0, ipi_mean_s = 0, ipi_sd_s = 0, ipi_cv = 0,
    envelope_mod_freq_hz = 0, envelope_mod_peak_ratio = 0, duty_cycle = 0,
    temporal_entropy = 0, phrase_duration_s = 0, n_phrase_bouts = 0,
    phrase_duty_cycle = 0
  )
  if (dur_s <= 0) return(zero_result)

  e_fine <- tryCatch(
    seewave::env(wave, f = sr, envt = "hil", msmooth = c(max(2, round(sr * 0.002)), 0), plot = FALSE),
    error = function(e) NULL
  )
  if (is.null(e_fine) || length(e_fine) < 3 || max(e_fine) <= 0) return(zero_result)
  e_fine <- as.numeric(e_fine)
  e_norm <- e_fine / max(e_fine)
  env_sr <- length(e_fine) / dur_s

  min_dist_samples <- max(1, round(0.01 * env_sr))  # 10ms refractory period
  peaks <- envelope_peaks(e_norm, min_dist_samples)
  n_peaks <- length(peaks)
  pulse_rate_hz <- n_peaks / dur_s

  if (n_peaks >= 3) {
    # >= 3 peaks needed, not >= 2: exactly 2 peaks gives exactly one
    # inter-pulse interval, and stats::sd() of a length-1 vector is NA
    # (not an error) -- found as a real bug via 9 non-finite feature rows
    # silently dropped from a training run (Prompt 9). "No measurable
    # spread from a single interval" is a legitimate 0, not an unknown.
    ipi <- diff(sort(peaks) / env_sr)
    ipi_mean_s <- mean(ipi)
    ipi_sd_s <- stats::sd(ipi)
    ipi_cv <- if (ipi_mean_s > 0) ipi_sd_s / ipi_mean_s else 0
  } else if (n_peaks == 2) {
    ipi_mean_s <- diff(sort(peaks) / env_sr)
    ipi_sd_s <- 0
    ipi_cv <- 0
  } else {
    ipi_mean_s <- 0; ipi_sd_s <- 0; ipi_cv <- 0
  }

  # Envelope modulation spectrum: FFT of the envelope itself (not the
  # audio), searched over 2-100Hz to cover both the syllable (~10Hz) and
  # within-syllable pulse (~70Hz) rates reported for these species while
  # avoiding slow, non-rhythmic envelope drift near DC.
  e_centered <- e_norm - mean(e_norm)
  mod_spec <- Mod(stats::fft(e_centered))[seq_len(floor(length(e_centered) / 2))]
  mod_freqs <- (seq_along(mod_spec) - 1) * env_sr / length(e_centered)
  band <- mod_freqs >= 2 & mod_freqs <= 100
  if (any(band) && sum(mod_spec[band]) > 0) {
    envelope_mod_freq_hz <- mod_freqs[band][which.max(mod_spec[band])]
    envelope_mod_peak_ratio <- max(mod_spec[band]) / mean(mod_spec[band])
  } else {
    envelope_mod_freq_hz <- 0; envelope_mod_peak_ratio <- 0
  }

  duty_cycle <- mean(e_norm > 0.1)
  temporal_entropy <- tryCatch(seewave::H(wave, f = sr), error = function(e) 0)
  if (!is.finite(temporal_entropy)) temporal_entropy <- 0

  # Coarse (phrase/bout) scale: a wider smoothing window collapses
  # within-syllable/pulse detail so on/off structure reflects bouts of
  # song, not individual syllables.
  e_coarse <- tryCatch(
    seewave::env(wave, f = sr, envt = "hil", msmooth = c(max(2, round(sr * 0.03)), 0), plot = FALSE),
    error = function(e) NULL
  )
  if (is.null(e_coarse) || length(e_coarse) < 2 || max(e_coarse) <= 0) {
    phrase_duration_s <- 0; n_phrase_bouts <- 0; phrase_duty_cycle <- 0
  } else {
    e_coarse <- as.numeric(e_coarse)
    e_coarse_norm <- e_coarse / max(e_coarse)
    coarse_env_sr <- length(e_coarse) / dur_s
    above <- e_coarse_norm > 0.15
    r <- rle(above)
    bout_lens_s <- r$lengths[r$values] / coarse_env_sr
    phrase_duration_s <- if (length(bout_lens_s) > 0) max(bout_lens_s) else 0
    n_phrase_bouts <- length(bout_lens_s)
    phrase_duty_cycle <- mean(above)
  }

  list(pulse_rate_hz = pulse_rate_hz, ipi_mean_s = ipi_mean_s, ipi_sd_s = ipi_sd_s, ipi_cv = ipi_cv,
       envelope_mod_freq_hz = envelope_mod_freq_hz, envelope_mod_peak_ratio = envelope_mod_peak_ratio,
       duty_cycle = duty_cycle, temporal_entropy = temporal_entropy,
       phrase_duration_s = phrase_duration_s, n_phrase_bouts = n_phrase_bouts,
       phrase_duty_cycle = phrase_duty_cycle)
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
