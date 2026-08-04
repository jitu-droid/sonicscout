test_that("band_energy_sum sums amplitude within [lo, hi)", {
  spec <- tibble::tibble(freq_hz = c(0, 250, 500, 750, 1000), amplitude = c(1, 1, 1, 1, 1))
  expect_equal(band_energy_sum(spec, 0, 500), 2)     # 0 and 250 Hz fall in [0, 500)
  expect_equal(band_energy_sum(spec, 500, 1000), 2)  # 500 and 750 Hz fall in [500, 1000)
})

test_that("band_energy_density averages amplitude within [lo, hi), invariant to bin count", {
  # Regression test (Prompt 11): band_energy_sum() (a raw sum) is NOT valid
  # for comparing a band ACROSS two spectra with different bin counts in
  # that range (e.g. different sample rates) -- summing more, finer bins
  # inflates the total even with identical per-bin values. band_energy_density()
  # must return the SAME value regardless of how many bins cover the band,
  # as long as their amplitudes are the same.
  coarse <- tibble::tibble(freq_hz = c(100, 300), amplitude = c(1, 1))
  fine   <- tibble::tibble(freq_hz = c(50, 150, 250, 350), amplitude = c(1, 1, 1, 1))
  expect_equal(band_energy_density(coarse, 0, 500), 1)
  expect_equal(band_energy_density(fine, 0, 500), 1)
  expect_equal(band_energy_sum(coarse, 0, 500), 2)
  expect_equal(band_energy_sum(fine, 0, 500), 4)  # sum DOES scale with bin count -- this is the bug this fix avoids
})

test_that("band_retention_ratios computes degraded/original per band, incl. the >8kHz wall", {
  orig <- tibble::tibble(freq_hz = c(100, 600, 3000, 6000, 9000), amplitude = c(1, 1, 1, 1, 1))
  deg  <- tibble::tibble(freq_hz = c(100, 600, 3000, 6000, 9000), amplitude = c(1, 1, 1, 1, 0))

  result <- band_retention_ratios(orig, deg)

  expect_equal(result$band, FREQ_BAND_LABELS)
  expect_equal(result$retention_ratio[result$band == "0-500Hz"], 1)
  expect_equal(result$retention_ratio[result$band == ">8kHz"], 0)
})

test_that("band_retention_ratios returns NA (not division error) when original band energy is zero", {
  orig <- tibble::tibble(freq_hz = c(600, 3000), amplitude = c(1, 1))
  deg  <- tibble::tibble(freq_hz = c(600, 3000), amplitude = c(1, 1))

  result <- band_retention_ratios(orig, deg)
  expect_true(is.na(result$retention_ratio[result$band == "0-500Hz"]))
})

test_that("spectral_similarity is 1 for identical spectra", {
  spec <- tibble::tibble(freq_hz = seq(0, 8000, length.out = 100), amplitude = stats::runif(100))
  sim <- spectral_similarity(spec, spec, max_freq = 8000)
  expect_equal(sim$pearson_correlation, 1, tolerance = 1e-8)
  expect_equal(sim$cosine_similarity, 1, tolerance = 1e-8)
})

test_that("survivability_score averages the two similarity components", {
  sim <- list(pearson_correlation = 0.8, cosine_similarity = 0.6)
  expect_equal(survivability_score(sim), 0.7)
})

test_that("simulate_whatsapp_compression resamples to 16kHz mono (requires ffmpeg)", {
  skip_if_not(nzchar(Sys.which("ffmpeg")), "ffmpeg not available on PATH")

  tmp_in <- tempfile(fileext = ".wav")
  tmp_out <- tempfile(fileext = ".wav")
  on.exit(unlink(c(tmp_in, tmp_out)))

  sr <- 44100
  sine <- sin(2 * pi * 440 * seq(0, 1, by = 1 / sr))
  w <- tuneR::Wave(left = as.integer(sine * 32767), samp.rate = sr, bit = 16)
  tuneR::writeWave(w, tmp_in)

  simulate_whatsapp_compression(tmp_in, tmp_out, sample_rate = 16000, bitrate_kbps = 16)

  out_wave <- tuneR::readWave(tmp_out)
  expect_equal(out_wave@samp.rate, 16000)
  expect_false(out_wave@stereo)
})
