test_that("wa_features returns one row with the documented columns", {
  sr <- 16000
  x <- sin(2 * pi * 440 * seq(0, 1, by = 1 / sr))
  w <- tuneR::Wave(left = as.integer(x * 32767), samp.rate = sr, bit = 16)

  feats <- wa_features(w)

  expect_equal(nrow(feats), 1)
  expect_true(all(c("duration_s", "peak_freq_hz", "spectral_centroid_hz",
                     "spectral_flatness", "spectral_entropy",
                     "spectral_rolloff85_hz", "dominant_freq_sd_hz",
                     "harmonic_energy_ratio", "mfcc_1") %in% names(feats)))
})

test_that("wa_features finds the peak frequency of a pure tone within a couple FFT bins", {
  sr <- 16000
  f0 <- 440
  x <- sin(2 * pi * f0 * seq(0, 1, by = 1 / sr))
  w <- tuneR::Wave(left = as.integer(x * 32767), samp.rate = sr, bit = 16)

  feats <- wa_features(w, wl = 1024)
  bin_width_hz <- sr / 1024
  expect_lt(abs(feats$peak_freq_hz - f0), bin_width_hz * 2)
})

test_that("harmonic_energy_ratio_from_spectrum returns 0, not NA, with no well-defined peak", {
  # Regression test: a window with peak_freq_hz <= 0 (no well-defined
  # non-DC peak -- typical of a near-silent window) used to return NA here,
  # which silently drops the whole window from any complete.cases()-based
  # training filter downstream. Found via a real confound comparing
  # compressed vs. uncompressed classifier accuracy: a long, quiet real
  # recording dropped far more windows in one condition than the other
  # purely because of this NA branch. 0 (no measurable harmonic structure)
  # is the correct, honest value here, not "unknown".
  spec <- cbind(freq = seq(0, 8, length.out = 100), amp = rep(1, 100))

  fn <- whatsappaudioR:::harmonic_energy_ratio_from_spectrum
  expect_equal(fn(spec, f0_hz = 0), 0)
  expect_equal(fn(spec, f0_hz = NA_real_), 0)
  expect_equal(fn(cbind(freq = spec[, 1], amp = rep(0, 100)), f0_hz = 100), 0)
})
