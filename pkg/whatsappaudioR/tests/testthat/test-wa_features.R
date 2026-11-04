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

test_that("wa_temporal_features returns 0, not NA, on pure digital silence", {
  # Same discipline as harmonic_energy_ratio above: an NA here would
  # silently drop the whole window from complete.cases()-based training
  # filters. Tested directly against the internal function,
  # not through the full wa_features() pipeline, because pure digital
  # silence separately crashes seewave::specprop() for unrelated reasons
  # (an existing, documented, out-of-scope limitation -- see this file's
  # git history) that would obscure what's actually being tested here.
  sr <- 16000
  w <- tuneR::Wave(left = integer(sr * 2), samp.rate = sr, bit = 16)
  f <- whatsappaudioR:::wa_temporal_features(w)

  expect_false(any(is.na(unlist(f))))
  expect_equal(f$pulse_rate_hz, 0)
  expect_equal(f$ipi_cv, 0)
  expect_equal(f$envelope_mod_freq_hz, 0)
  expect_equal(f$duty_cycle, 0)
  expect_equal(f$temporal_entropy, 0)
  expect_equal(f$phrase_duration_s, 0)
  expect_equal(f$n_phrase_bouts, 0)
})

test_that("wa_temporal_features returns 0, not NA, for ipi_sd/ipi_cv with exactly 2 peaks", {
  # Regression test: exactly 2 detected peaks gives exactly ONE inter-pulse
  # interval, and stats::sd() of a length-1 vector is NA (not an error) --
  # found via 9 real training rows silently dropped for non-finite
  # features in a real k-fold run, same NA-leak bug class as
  # the harmonic_energy_ratio confound above. "No measurable spread from a
  # single interval" is a legitimate 0, not "unknown".
  sr <- 16000
  dur <- 2
  x <- numeric(sr * dur)
  # two isolated, well-separated pulses -- far apart, nothing else above
  # the peak-detection threshold in between
  pulse_len <- round(0.02 * sr)
  x[round(0.3 * sr):(round(0.3 * sr) + pulse_len)] <- sin(2 * pi * 2000 * seq(0, 0.02, length.out = pulse_len + 1))
  x[round(1.3 * sr):(round(1.3 * sr) + pulse_len)] <- sin(2 * pi * 2000 * seq(0, 0.02, length.out = pulse_len + 1))
  w <- tuneR::Wave(left = as.integer(x * 32767 * 0.9), samp.rate = sr, bit = 16)

  f <- whatsappaudioR:::wa_temporal_features(w)
  expect_false(any(is.na(unlist(f))))
  expect_equal(f$ipi_sd_s, 0)
  expect_equal(f$ipi_cv, 0)
  expect_gt(f$ipi_mean_s, 0)  # the one real interval should still be reported
})

test_that("wa_temporal_features detects a known pulse rate on a synthetic pulse train", {
  # A synthetic amplitude-modulated tone at a known rate is a ground-truth
  # check that the peak detector isn't wildly wrong -- not a claim that
  # this matches real grasshopper song (that's validated empirically on
  # real audio in the classifier results, not asserted in a unit test).
  sr <- 16000
  dur <- 2
  t <- seq(0, dur, by = 1 / sr)
  pulse_hz <- 20
  carrier <- sin(2 * pi * 2000 * t)
  envelope_mod <- (sin(2 * pi * pulse_hz * t) > 0.7)  # sharp, well-separated pulses
  x <- carrier * envelope_mod
  w <- tuneR::Wave(left = as.integer(x * 32767 * 0.9), samp.rate = sr, bit = 16)

  f <- whatsappaudioR:::wa_temporal_features(w)
  expect_false(any(is.na(unlist(f))))
  # Allow generous tolerance -- this checks the detector finds pulses in
  # the right ballpark, not exact agreement with the synthesis parameter.
  expect_gt(f$pulse_rate_hz, pulse_hz * 0.5)
  expect_lt(f$pulse_rate_hz, pulse_hz * 2)
})
