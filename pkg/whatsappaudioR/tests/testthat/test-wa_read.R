test_that("wa_read reads a wav file directly", {
  tmp <- tempfile(fileext = ".wav")
  on.exit(unlink(tmp))
  sr <- 16000
  x <- sin(2 * pi * 440 * seq(0, 0.5, by = 1 / sr))
  w <- tuneR::Wave(left = as.integer(x * 32767), samp.rate = sr, bit = 16)
  tuneR::writeWave(w, tmp)

  result <- wa_read(tmp)
  expect_s4_class(result, "Wave")
  expect_equal(result@samp.rate, sr)
})

test_that("wa_read decodes the committed .opus fixture", {
  skip_if_not(nzchar(Sys.which("ffmpeg")), "ffmpeg not available")
  fixture <- test_path("fixtures", "sample.opus")
  skip_if_not(file.exists(fixture), "fixture sample.opus not present")

  result <- wa_read(fixture)
  expect_s4_class(result, "Wave")
  expect_gt(length(result@left), 0)
})

test_that("wa_read resamples to a requested rate and downmixes to mono", {
  skip_if_not(nzchar(Sys.which("ffmpeg")), "ffmpeg not available")
  tmp <- tempfile(fileext = ".wav")
  on.exit(unlink(tmp))
  sr <- 48000
  t <- seq(0, 1, by = 1 / sr)
  x <- as.integer(sin(2 * pi * 440 * t) * 16000)
  tuneR::writeWave(tuneR::Wave(left = x, right = x, samp.rate = sr, bit = 16), tmp)

  native <- wa_read(tmp)
  expect_equal(native@samp.rate, 48000)
  expect_true(native@stereo)

  result <- wa_read(tmp, sample_rate = 16000, mono = TRUE)
  expect_equal(result@samp.rate, 16000)
  expect_false(result@stereo)
  expect_equal(length(result@left), round(length(x) / 3), tolerance = 0.01)

  fixture <- test_path("fixtures", "sample.opus")
  skip_if_not(file.exists(fixture), "fixture sample.opus not present")
  opus16 <- wa_read(fixture, sample_rate = 16000, mono = TRUE)
  expect_equal(opus16@samp.rate, 16000)
  expect_false(opus16@stereo)
})

test_that("wa_read leaves a wav already at the requested rate untouched", {
  tmp <- tempfile(fileext = ".wav")
  on.exit(unlink(tmp))
  x <- as.integer(sin(2 * pi * 440 * seq(0, 0.5, by = 1 / 16000)) * 16000)
  tuneR::writeWave(tuneR::Wave(left = x, samp.rate = 16000, bit = 16), tmp)
  expect_identical(wa_read(tmp, sample_rate = 16000, mono = TRUE)@left, x)
})

test_that("wa_read rejects a nonsensical sample_rate", {
  tmp <- tempfile(fileext = ".wav")
  on.exit(unlink(tmp))
  tuneR::writeWave(tuneR::Wave(left = integer(160), samp.rate = 16000, bit = 16), tmp)
  expect_error(wa_read(tmp, sample_rate = -1), "positive")
})

test_that("wa_read errors clearly on an unsupported extension", {
  tmp <- tempfile(fileext = ".xyz")
  file.create(tmp)
  on.exit(unlink(tmp))
  expect_error(wa_read(tmp), "Unsupported audio format")
})

test_that("wa_read errors clearly on a missing file", {
  expect_error(wa_read(tempfile(fileext = ".wav")), "not found")
})
