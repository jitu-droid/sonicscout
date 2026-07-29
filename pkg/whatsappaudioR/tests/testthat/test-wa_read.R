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
  fixture <- test_path("fixtures", "sample.opus")
  skip_if_not(file.exists(fixture), "fixture sample.opus not present")

  result <- wa_read(fixture)
  expect_s4_class(result, "Wave")
  expect_gt(length(result@left), 0)
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
