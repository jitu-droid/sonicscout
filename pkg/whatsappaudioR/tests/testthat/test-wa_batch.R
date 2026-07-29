test_that("wa_batch applies fn across every audio file in a directory", {
  dir <- tempfile()
  dir.create(dir)
  on.exit(unlink(dir, recursive = TRUE))

  sr <- 16000
  for (f0 in c(300, 600)) {
    x <- sin(2 * pi * f0 * seq(0, 0.5, by = 1 / sr))
    w <- tuneR::Wave(left = as.integer(x * 32767), samp.rate = sr, bit = 16)
    tuneR::writeWave(w, file.path(dir, paste0("tone_", f0, ".wav")))
  }

  result <- wa_batch(dir, wa_features)

  expect_equal(nrow(result), 2)
  expect_true("file" %in% names(result))
  expect_true("peak_freq_hz" %in% names(result))
})

test_that("wa_batch warns and returns an empty tibble when no files match", {
  dir <- tempfile()
  dir.create(dir)
  on.exit(unlink(dir, recursive = TRUE))

  expect_warning(result <- wa_batch(dir), "No matching audio files")
  expect_equal(nrow(result), 0)
})
