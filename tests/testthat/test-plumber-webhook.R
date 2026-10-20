# Deliverable E -- mock integration test for the Twilio webhook.
#
# We can't test against live Twilio without real credentials (see
# BLOCKERS.md / docs/twilio_setup.md), so instead: start api/plumber.R as a
# real local server, POST a synthetic Twilio-shaped payload at it, and stub
# the "download from Twilio" step by pointing MediaUrl0 at a local file
# server instead of the real twilio.com media endpoint. This exercises the
# full webhook path (parse -> download -> decode -> predict -> log -> TwiML
# reply) for real, not mocked out.
#
# Routers are constructed INSIDE each callr background process (not built in
# the test process and passed across) -- a constructed Plumber router holds
# live closures/environments that don't reliably survive callr's
# serialization across the process boundary.

# Each test points the webhook's logging at a disposable temp directory
# (SONICSCOUT_LOG_DIR, read by api/plumber.R) so mock requests never land in
# the real logs/requests.jsonl that the dashboard and a live demo read.
real_log_fingerprint <- function(project_root) {
  p <- file.path(project_root, "logs", "requests.jsonl")
  if (file.exists(p)) unname(tools::md5sum(p)) else NA_character_
}

report_server_error_if_any <- function(resp, runner) {
  if (httr2::resp_status(resp) >= 400) {
    cat("=== background server stderr ===\n")
    cat(runner$read_all_error(), sep = "\n")
    cat("=== background server stdout ===\n")
    cat(runner$read_all_output(), sep = "\n")
  }
}

test_that("webhook returns a TwiML reply for a synthetic audio attachment", {
  skip_if_not_installed("plumber")
  skip_if_not(nzchar(Sys.which("ffmpeg")), "ffmpeg not available")

  project_root <- normalizePath(file.path(testthat::test_path(), "..", ".."))

  media_dir <- tempfile()
  dir.create(media_dir)
  sr <- 16000
  tone <- sin(2 * pi * 300 * seq(0, 4, by = 1 / sr))
  w <- tuneR::Wave(left = as.integer(tone * 32767), samp.rate = sr, bit = 16)
  media_wav_path <- file.path(media_dir, "sample.wav")
  tuneR::writeWave(w, media_wav_path)

  # Fake media host standing in for Twilio's media URL (which normally
  # requires Basic Auth -- download_twilio_media() doesn't care what server
  # it's hitting, only that the URL responds with 200 + audio bytes).
  media_runner <- callr::r_bg(function(wav_path) {
    pr <- plumber::pr()
    pr$handle("GET", "/sample.wav", function(res) {
      res$setHeader("Content-Type", "audio/wav")
      res$body <- readBin(wav_path, "raw", file.info(wav_path)$size)
      res
    })
    plumber::pr_run(pr, port = 8998)
  }, args = list(wav_path = media_wav_path))
  on.exit(media_runner$kill(), add = TRUE)

  log_dir <- tempfile("webhook_test_logs")
  real_log_before <- real_log_fingerprint(project_root)

  webhook_runner <- callr::r_bg(function(root, sid, token, log_dir) {
    setwd(root)
    Sys.setenv(TWILIO_ACCOUNT_SID = sid, TWILIO_AUTH_TOKEN = token, SONICSCOUT_LOG_DIR = log_dir)
    options(plumber.debug = TRUE)
    plumber::pr_run(plumber::pr(file.path(root, "api", "plumber.R")), port = 8999)
  }, args = list(root = project_root, sid = "test_sid", token = "test_token", log_dir = log_dir))
  on.exit(webhook_runner$kill(), add = TRUE)

  Sys.sleep(3)

  resp <- httr2::request("http://127.0.0.1:8999/webhook") |>
    httr2::req_body_form(
      From = "whatsapp:+15550001111",
      NumMedia = "1",
      MediaUrl0 = "http://127.0.0.1:8998/sample.wav",
      MediaContentType0 = "audio/wav"
    ) |>
    httr2::req_error(is_error = function(resp) FALSE) |>
    httr2::req_perform()

  report_server_error_if_any(resp, webhook_runner)

  expect_equal(httr2::resp_status(resp), 200)
  body <- httr2::resp_body_string(resp)
  expect_match(body, "<Response>")
  expect_match(body, "<Message>")
  # Specifically assert decode succeeded (not just "some TwiML came back") --
  # this exact wording regressed once already when audio/wav wasn't in
  # download_twilio_media()'s content-type-to-extension map (silently saved
  # as .bin, which wa_read() rejects). "no confident match"/a % figure are
  # both acceptable here since no model may be trained yet at this point in
  # the pipeline; "couldn't process that audio file" means decode failed.
  expect_no_match(body, "couldn't process that audio file")

  # Logged to the temp directory, not the real request log.
  expect_true(file.exists(file.path(log_dir, "requests.jsonl")))
  expect_identical(real_log_fingerprint(project_root), real_log_before)
})

test_that("webhook replies with a clear message when there's no media attached", {
  skip_if_not_installed("plumber")

  project_root <- normalizePath(file.path(testthat::test_path(), "..", ".."))

  log_dir <- tempfile("webhook_test_logs")
  real_log_before <- real_log_fingerprint(project_root)

  webhook_runner <- callr::r_bg(function(root, sid, token, log_dir) {
    setwd(root)
    Sys.setenv(TWILIO_ACCOUNT_SID = sid, TWILIO_AUTH_TOKEN = token, SONICSCOUT_LOG_DIR = log_dir)
    options(plumber.debug = TRUE)
    plumber::pr_run(plumber::pr(file.path(root, "api", "plumber.R")), port = 8997)
  }, args = list(root = project_root, sid = "test_sid", token = "test_token", log_dir = log_dir))
  on.exit(webhook_runner$kill(), add = TRUE)
  Sys.sleep(3)

  resp <- httr2::request("http://127.0.0.1:8997/webhook") |>
    httr2::req_body_form(From = "whatsapp:+15550001111", NumMedia = "0") |>
    httr2::req_error(is_error = function(resp) FALSE) |>
    httr2::req_perform()

  report_server_error_if_any(resp, webhook_runner)

  expect_equal(httr2::resp_status(resp), 200)
  expect_match(httr2::resp_body_string(resp), "send a voice note")

  expect_true(file.exists(file.path(log_dir, "requests.jsonl")))
  expect_identical(real_log_fingerprint(project_root), real_log_before)
})
