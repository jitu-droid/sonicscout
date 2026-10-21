# Mock tests for the Meta WhatsApp Cloud API webhook (api/plumber.R,
# /meta-webhook). Two local servers: a mock Graph API (media lookup, media
# download, message send -- each checks the Bearer token, and every reply is
# recorded to a file) and the real webhook, configured Meta-only (no Twilio
# variables), logging to a temporary folder -- never the real log.

skip_if_not_installed("plumber")
skip_if_not_installed("callr")
skip_if_not_installed("openssl")
skip_if_not(nzchar(Sys.which("ffmpeg")), "ffmpeg not available")

project_root <- normalizePath(file.path(testthat::test_path(), "..", ".."))
skip_if_not(file.exists(file.path(project_root, "models", "classifier.rds")), "no trained model")
skip_if_not(file.exists(file.path(project_root, "demo_clips", "cicada_orni.wav")), "demo clip not present")

META_PORT <- 8995
GRAPH_PORT <- 8994
WEBHOOK <- sprintf("http://127.0.0.1:%d/meta-webhook", META_PORT)
ACCESS_TOKEN <- "test-access-token"
VERIFY_TOKEN <- "test-verify-token"
APP_SECRET <- "test-app-secret"
GRAPH_VERSION <- "v99.0"
PHONE_NUMBER_ID <- "PHONE-NUMBER-ID"

real_log <- file.path(project_root, "logs", "requests.jsonl")
real_log_before <- if (file.exists(real_log)) unname(tools::md5sum(real_log)) else NA_character_

work_dir <- tempfile("meta_webhook_test")
dir.create(work_dir)
log_dir <- file.path(work_dir, "logs")
replies_path <- file.path(work_dir, "replies.jsonl")
lookups_path <- file.path(work_dir, "lookups.txt")

# A real 48 kHz Opus voice note of the held-out cicada demo clip.
voice_note <- file.path(work_dir, "voice_note.ogg")
system2(Sys.which("ffmpeg"), c("-y", "-loglevel", "error", "-i",
                               shQuote(file.path(project_root, "demo_clips", "cicada_orni.wav")),
                               "-ar", "48000", "-ac", "1", "-c:a", "libopus", "-b:a", "24k", shQuote(voice_note)))

graph_runner <- callr::r_bg(function(port, version, token, audio_path, replies_path, lookups_path) {
  authorised <- function(req) identical(req$HTTP_AUTHORIZATION, paste("Bearer", token))
  deny <- function(res) {
    res$status <- 401
    res$setHeader("Content-Type", "application/json")
    res$body <- '{"error":{"message":"Invalid OAuth access token.","type":"OAuthException","code":190}}'
    res
  }
  pr <- plumber::pr()
  pr$handle("GET", "/ping", function() "pong")
  pr$handle("GET", paste0("/", version, "/<media_id>"), function(req, res, media_id) {
    if (!authorised(req)) return(deny(res))
    cat(media_id, "\n", file = lookups_path, append = TRUE, sep = "")
    res$setHeader("Content-Type", "application/json")
    res$body <- jsonlite::toJSON(list(
      url = sprintf("http://127.0.0.1:%d/media/%s", port, media_id),
      mime_type = "audio/ogg; codecs=opus", id = media_id, messaging_product = "whatsapp"
    ), auto_unbox = TRUE)
    res
  })
  pr$handle("GET", "/media/<media_id>", function(req, res, media_id) {
    if (!authorised(req)) return(deny(res))
    res$setHeader("Content-Type", "audio/ogg")
    res$body <- readBin(audio_path, "raw", file.info(audio_path)$size)
    res
  })
  pr$handle("POST", paste0("/", version, "/<phone_id>/messages"), function(req, res, phone_id) {
    if (!authorised(req)) return(deny(res))
    cat(rawToChar(req$bodyRaw), "\n", file = replies_path, append = TRUE, sep = "")
    res$setHeader("Content-Type", "application/json")
    res$body <- '{"messaging_product":"whatsapp","messages":[{"id":"wamid.reply"}]}'
    res
  })
  plumber::pr_run(pr, port = port)
}, args = list(port = GRAPH_PORT, version = GRAPH_VERSION, token = ACCESS_TOKEN, audio_path = voice_note,
               replies_path = replies_path, lookups_path = lookups_path))
withr::defer(graph_runner$kill(), testthat::teardown_env())

webhook_runner <- callr::r_bg(function(root, port, env) {
  setwd(root)
  Sys.unsetenv(c("TWILIO_ACCOUNT_SID", "TWILIO_AUTH_TOKEN"))  # Meta-only configuration
  do.call(Sys.setenv, env)
  plumber::pr_run(plumber::pr(file.path(root, "api", "plumber.R")), port = port)
}, args = list(root = project_root, port = META_PORT, env = list(
  META_ACCESS_TOKEN = ACCESS_TOKEN, META_PHONE_NUMBER_ID = PHONE_NUMBER_ID,
  META_VERIFY_TOKEN = VERIFY_TOKEN, META_APP_SECRET = APP_SECRET,
  META_GRAPH_VERSION = GRAPH_VERSION, META_GRAPH_BASE_URL = sprintf("http://127.0.0.1:%d", GRAPH_PORT),
  SONICSCOUT_LOG_DIR = log_dir
)))
withr::defer(webhook_runner$kill(), testthat::teardown_env())

wait_for <- function(condition, timeout = 90) {
  deadline <- Sys.time() + timeout
  while (Sys.time() < deadline) {
    if (isTRUE(tryCatch(condition(), error = function(e) FALSE))) return(TRUE)
    Sys.sleep(0.5)
  }
  FALSE
}
responds <- function(url) httr2::resp_status(httr2::req_perform(httr2::req_timeout(httr2::request(url), 2))) == 200
servers_up <- wait_for(function() responds(sprintf("http://127.0.0.1:%d/ping", GRAPH_PORT)) &&
                         responds(sprintf("http://127.0.0.1:%d/health", META_PORT)), timeout = 60)
if (!servers_up) {
  cat("=== webhook stderr ===\n", webhook_runner$read_all_error(), "\n")
  stop("Mock Graph API or Meta webhook did not start")
}

# ---- helpers ------------------------------------------------------------------

meta_payload <- function(messages = list(), statuses = list()) {
  value <- list(messaging_product = "whatsapp",
                metadata = list(display_phone_number = "15550000000", phone_number_id = PHONE_NUMBER_ID))
  if (length(messages)) value$messages <- messages
  if (length(statuses)) value$statuses <- statuses
  list(object = "whatsapp_business_account",
       entry = list(list(id = "WABA-ID", changes = list(list(field = "messages", value = value)))))
}

post_meta <- function(payload, signature = "valid") {
  body <- charToRaw(as.character(jsonlite::toJSON(payload, auto_unbox = TRUE)))
  req <- httr2::request(WEBHOOK) |>
    httr2::req_body_raw(body, type = "application/json") |>
    httr2::req_error(is_error = function(resp) FALSE)
  if (identical(signature, "valid")) {
    signature <- paste0("sha256=", as.character(openssl::sha256(body, key = APP_SECRET)))
  }
  if (!is.null(signature)) req <- httr2::req_headers(req, `X-Hub-Signature-256` = signature)
  httr2::req_perform(req)
}

replies_to <- function(to) {
  if (!file.exists(replies_path)) return(list())
  all <- lapply(readLines(replies_path, warn = FALSE), jsonlite::fromJSON)
  Filter(function(r) identical(r$to, to), all)
}

log_entries_from <- function(from) {
  path <- file.path(log_dir, "requests.jsonl")
  if (!file.exists(path)) return(list())
  all <- lapply(readLines(path, warn = FALSE), jsonlite::fromJSON)
  Filter(function(e) identical(e$from, from), all)
}

text_message <- function(id, from, body = "hello") {
  list(from = from, id = id, timestamp = "1760000000", type = "text", text = list(body = body))
}

# ---- tests --------------------------------------------------------------------

test_that("verification echoes hub.challenge for the right token and refuses otherwise", {
  verify <- function(mode, token) {
    httr2::request(WEBHOOK) |>
      httr2::req_url_query(`hub.mode` = mode, `hub.verify_token` = token, `hub.challenge` = "1158201444") |>
      httr2::req_error(is_error = function(resp) FALSE) |>
      httr2::req_perform()
  }
  ok <- verify("subscribe", VERIFY_TOKEN)
  expect_equal(httr2::resp_status(ok), 200)
  expect_equal(httr2::resp_body_string(ok), "1158201444")

  expect_equal(httr2::resp_status(verify("subscribe", "wrong-token")), 403)
  expect_equal(httr2::resp_status(verify("unsubscribe", VERIFY_TOKEN)), 403)
})

test_that("deliveries with a missing or wrong signature are rejected with 403", {
  payload <- meta_payload(messages = list(text_message("wamid.SIG", "910000000001")))
  expect_equal(httr2::resp_status(post_meta(payload, signature = NULL)), 403)
  expect_equal(httr2::resp_status(post_meta(payload, signature = paste0("sha256=", strrep("0", 64)))), 403)
  Sys.sleep(2)
  expect_length(replies_to("910000000001"), 0)
  expect_length(log_entries_from("whatsapp:+910000000001"), 0)
})

test_that("an audio message is acknowledged at once, then downloaded, predicted, logged and answered", {
  from <- "911111111111"
  message <- list(from = from, id = "wamid.AUDIO1", timestamp = "1760000000", type = "audio",
                  audio = list(id = "MEDIA-CICADA", mime_type = "audio/ogg; codecs=opus", voice = TRUE))
  resp <- post_meta(meta_payload(messages = list(message)))
  expect_equal(httr2::resp_status(resp), 200)
  # Acknowledged before the slow work: the reply can't have been sent yet.
  expect_length(replies_to(from), 0)

  expect_true(wait_for(function() length(replies_to(from)) == 1))
  reply <- replies_to(from)[[1]]
  expect_equal(reply$messaging_product, "whatsapp")
  expect_equal(reply$type, "text")
  expect_match(reply$text$body, "cicada_orni")

  expect_true(readLines(lookups_path)[1] == "MEDIA-CICADA")  # no url in the webhook -> media lookup
  entries <- log_entries_from(paste0("whatsapp:+", from))
  expect_length(entries, 1)
  expect_equal(entries[[1]]$source, "meta")
  expect_equal(entries[[1]]$message_id, "wamid.AUDIO1")
  expect_true(entries[[1]]$outcome %in% c("predicted", "low_confidence"))
  expect_equal(strsplit(entries[[1]]$top_classes, "\\|")[[1]][1], "cicada_orni")
  expect_true(file.exists(entries[[1]]$audio_path))
})

test_that("an audio message that already carries a url is downloaded without a media lookup", {
  from <- "911111111112"
  lookups_before <- length(readLines(lookups_path))
  message <- list(from = from, id = "wamid.AUDIO2", timestamp = "1760000000", type = "audio",
                  audio = list(id = "MEDIA-CICADA-2", mime_type = "audio/ogg; codecs=opus",
                               url = sprintf("http://127.0.0.1:%d/media/MEDIA-CICADA-2", GRAPH_PORT)))
  expect_equal(httr2::resp_status(post_meta(meta_payload(messages = list(message)))), 200)
  expect_true(wait_for(function() length(replies_to(from)) == 1))
  expect_match(replies_to(from)[[1]]$text$body, "cicada_orni")
  expect_equal(length(readLines(lookups_path)), lookups_before)
})

test_that("text and image messages get the same replies as the Twilio path", {
  text_from <- "912222222222"
  expect_equal(httr2::resp_status(post_meta(meta_payload(messages = list(text_message("wamid.TEXT1", text_from))))), 200)
  expect_true(wait_for(function() length(replies_to(text_from)) == 1))
  expect_equal(replies_to(text_from)[[1]]$text$body,
               "Please send a voice note recording of the field (10-30 seconds).")
  expect_equal(log_entries_from(paste0("whatsapp:+", text_from))[[1]]$outcome, "no_media")

  image_from <- "912222222223"
  image <- list(from = image_from, id = "wamid.IMAGE1", timestamp = "1760000000", type = "image",
                image = list(id = "MEDIA-IMAGE", mime_type = "image/jpeg"))
  expect_equal(httr2::resp_status(post_meta(meta_payload(messages = list(image)))), 200)
  expect_true(wait_for(function() length(replies_to(image_from)) == 1))
  expect_match(replies_to(image_from)[[1]]$text$body, "doesn't look like an audio file")
  entry <- log_entries_from(paste0("whatsapp:+", image_from))[[1]]
  expect_equal(entry$outcome, "non_audio_attachment")
  expect_equal(entry$content_type, "image/jpeg")
})

test_that("a re-delivered message is answered only once", {
  from <- "913333333333"
  payload <- meta_payload(messages = list(text_message("wamid.DUP1", from)))
  expect_equal(httr2::resp_status(post_meta(payload)), 200)
  expect_equal(httr2::resp_status(post_meta(payload)), 200)
  expect_true(wait_for(function() length(replies_to(from)) >= 1))
  Sys.sleep(3)
  expect_length(replies_to(from), 1)
  expect_length(log_entries_from(paste0("whatsapp:+", from)), 1)
})

test_that("delivery-status events are acknowledged and ignored", {
  status <- list(id = "wamid.reply", status = "delivered", timestamp = "1760000000",
                 recipient_id = "914444444444")
  expect_equal(httr2::resp_status(post_meta(meta_payload(statuses = list(status)))), 200)
  Sys.sleep(3)
  expect_length(replies_to("914444444444"), 0)
  expect_length(log_entries_from("whatsapp:+914444444444"), 0)
})

test_that("the access token never appears in the test log, and the real log is untouched", {
  test_log <- file.path(log_dir, "requests.jsonl")
  expect_true(file.exists(test_log))
  expect_false(any(grepl(ACCESS_TOKEN, readLines(test_log), fixed = TRUE)))
  now <- if (file.exists(real_log)) unname(tools::md5sum(real_log)) else NA_character_
  expect_identical(now, real_log_before)
})

test_that("startup accepts Meta-only config but refuses no provider or a half-filled one", {
  start <- function(env) {
    callr::r(function(root, env) {
      setwd(root)
      Sys.unsetenv(c("TWILIO_ACCOUNT_SID", "TWILIO_AUTH_TOKEN", "META_ACCESS_TOKEN",
                     "META_PHONE_NUMBER_ID", "META_VERIFY_TOKEN"))
      if (length(env)) do.call(Sys.setenv, env)
      tryCatch({ plumber::pr(file.path(root, "api", "plumber.R")); "started" },
               error = function(e) conditionMessage(e))
    }, args = list(root = project_root, env = env))
  }
  expect_match(start(list()), "No WhatsApp provider configured")
  expect_match(start(list(META_ACCESS_TOKEN = "x")), "Meta is partly configured")
  expect_equal(start(list(META_ACCESS_TOKEN = "x", META_PHONE_NUMBER_ID = "y", META_VERIFY_TOKEN = "z")), "started")
})
