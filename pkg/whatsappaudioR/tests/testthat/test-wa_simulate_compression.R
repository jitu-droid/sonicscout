test_that("wa_simulate_compression resamples to the target rate and mono (requires ffmpeg)", {
  skip_if_not(nzchar(Sys.which("ffmpeg")), "ffmpeg not available")

  sr_in <- 44100
  x <- sin(2 * pi * 440 * seq(0, 1, by = 1 / sr_in))
  w <- tuneR::Wave(left = as.integer(x * 32767), samp.rate = sr_in, bit = 16)

  degraded <- wa_simulate_compression(w, bitrate = 16000, sr = 16000)

  expect_s4_class(degraded, "Wave")
  expect_equal(degraded@samp.rate, 16000)
  expect_false(degraded@stereo)
})

test_that("wa_simulate_compression destroys a signal above the target Nyquist (requires ffmpeg)", {
  skip_if_not(nzchar(Sys.which("ffmpeg")), "ffmpeg not available")

  sr_in <- 44100
  x <- sin(2 * pi * 10000 * seq(0, 1, by = 1 / sr_in))  # above 8kHz Nyquist at 16kHz
  w <- tuneR::Wave(left = as.integer(x * 32767), samp.rate = sr_in, bit = 16)

  degraded <- wa_simulate_compression(w, bitrate = 16000, sr = 16000)
  degraded_rms <- sqrt(mean((degraded@left / 32767)^2))

  # Ground-truth check: a 10kHz tone cannot survive a resample to 16kHz
  # (8kHz Nyquist). If this fails, the compression simulation itself is
  # wrong -- see docs/codec_findings.md in the SonicScout repository.
  expect_lt(degraded_rms, 0.05)
})
