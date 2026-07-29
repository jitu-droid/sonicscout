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
