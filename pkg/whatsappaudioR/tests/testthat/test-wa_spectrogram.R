test_that("wa_spectrogram returns a tidy time/freq/amplitude tibble", {
  sr <- 16000
  x <- sin(2 * pi * 440 * seq(0, 1, by = 1 / sr))
  w <- tuneR::Wave(left = as.integer(x * 32767), samp.rate = sr, bit = 16)

  spec_df <- wa_spectrogram(w, wl = 512)

  expect_s3_class(spec_df, "tbl_df")
  expect_setequal(names(spec_df), c("time", "freq", "amplitude"))
  expect_gt(nrow(spec_df), 0)
})
