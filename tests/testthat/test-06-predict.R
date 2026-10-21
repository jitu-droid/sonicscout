# Regression test for a train/serve sample-rate bug: predict_pest() used to
# feature-extract at whatever rate wa_read() decoded to (48 kHz for Opus/MP3,
# 44.1 kHz for most WAVs), while the model is trained on 16 kHz mono
# windows. A real WhatsApp voice note of a cicada was read as "ambient 46%";
# the same file resampled to 16 kHz read as "cicada_orni 90%". predict_pest()
# now resamples every input to the training rate first, so the container and
# native rate of the input must not change the answer.

test_that("predict_pest gives the same answer for a 48 kHz Opus file and its 16 kHz WAV copy", {
  skip_if_not(nzchar(Sys.which("ffmpeg")), "ffmpeg not available")
  root <- normalizePath(file.path(testthat::test_path(), "..", ".."))
  model <- file.path(root, "models", "classifier.rds")
  src <- file.path(root, "demo_clips", "cicada_orni.wav")
  skip_if_not(file.exists(model), "no trained model")
  skip_if_not(file.exists(src), "demo clip not present")
  if (!exists("predict_pest", mode = "function")) source(file.path(root, "R", "06_predict.R"))

  opus48 <- tempfile(fileext = ".ogg")
  wav16 <- tempfile(fileext = ".wav")
  on.exit(unlink(c(opus48, wav16)), add = TRUE)
  ffmpeg <- Sys.which("ffmpeg")
  # shQuote: system2() doesn't quote, and the repo path may contain spaces.
  expect_equal(system2(ffmpeg, c("-y", "-loglevel", "error", "-i", shQuote(src),
                                 "-ar", "48000", "-ac", "1", "-c:a", "libopus", "-b:a", "24k", shQuote(opus48))), 0)
  expect_equal(system2(ffmpeg, c("-y", "-loglevel", "error", "-i", shQuote(opus48),
                                 "-ar", "16000", "-ac", "1", shQuote(wav16))), 0)

  # The Opus file really does decode at 48 kHz natively -- the case that broke.
  expect_equal(whatsappaudioR::wa_read(opus48)@samp.rate, 48000)

  from_opus <- predict_pest(opus48, model_path = model)
  from_wav <- predict_pest(wav16, model_path = model)

  expect_equal(from_opus$top_classes[1], from_wav$top_classes[1])
  classes <- names(from_wav$all_probabilities)
  expect_lt(max(abs(from_opus$all_probabilities[classes] - from_wav$all_probabilities[classes])), 0.02)
})
