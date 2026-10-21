# Deliverable E -- WhatsApp webhooks: Twilio Sandbox (/webhook) and Meta's
# WhatsApp Cloud API (/meta-webhook), side by side.
#
# Twilio: receives Twilio's inbound-message webhook (form-encoded POST),
# downloads the attached media (Twilio media URLs require HTTP Basic Auth
# with the account SID/token), runs it through the SonicScout prediction
# pipeline (R/06_predict.R), logs the request, and replies via TwiML.
#
# Meta: verifies the webhook subscription (GET), acknowledges each delivery
# immediately (POST), then downloads the voice note from the Graph API,
# predicts, logs, and replies by POSTing to the Graph API -- see the Meta
# section at the bottom of this file. Added because the Twilio trial could
# receive messages but not download media (HTTP 401) or deliver replies.
#
# Run locally (loads .env first):
#   Rscript R/start_webhook.R
#
# Credentials come from environment variables (see .env.example) -- never
# hardcode, never commit a real .env. See docs/twilio_setup.md and
# docs/meta_whatsapp_setup.md for setup + exposing this locally via a tunnel.

library(plumber)
library(httr2)
library(jsonlite)
library(whatsappaudioR)
library(later)    # Meta: process a message AFTER acknowledging the delivery
library(openssl)  # Meta: HMAC-SHA256 signature check

# WORKAROUND: plumber runs both this top-level parse block AND every actual
# request handler with the working directory set to this file's own
# directory (api/), regardless of where Rscript was invoked from or what
# cwd was at pr_run() call time -- confirmed empirically (a stray
# api/logs/requests.jsonl appeared during testing; see BLOCKERS.md). A plain
# relative path like file.path("logs", "requests.jsonl") therefore resolves
# to api/logs/requests.jsonl at REQUEST time, not just parse time. Anchor
# every runtime path to an absolute repo root computed once here, instead
# of relying on relative paths anywhere below.
.repo_root <- normalizePath(
  if (file.exists(file.path("R", "utils.R"))) "." else ".."
)
.locate_repo_file <- function(relative_path) file.path(.repo_root, relative_path)

source(.locate_repo_file(file.path("R", "utils.R")))
source(.locate_repo_file(file.path("R", "06_predict.R")))  # brings in predict_pest(), format_reply()

MIN_CLIP_SECONDS <- 3
# SONICSCOUT_LOG_DIR lets the test suite log somewhere disposable instead of
# the real logs/requests.jsonl that the dashboard and a live demo read --
# mock test requests used to pile up there. Unset in normal use.
.log_dir <- Sys.getenv("SONICSCOUT_LOG_DIR", file.path(.repo_root, "logs"))
REQUEST_LOG_PATH <- file.path(.log_dir, "requests.jsonl")
REQUEST_AUDIO_DIR <- file.path(.log_dir, "audio")
MODEL_PATH_ABS <- file.path(.repo_root, "models", "classifier.rds")

# ---- Startup validation (Prompt 11, Part 2a) --------------------------------
#
# Runs at PARSE time (plumber::pr() sources this whole file before pr_run()
# ever starts serving), not inside a request handler -- a misconfigured
# deployment (missing Twilio credentials, no trained model) fails loudly
# and immediately when the server is started, instead of appearing to boot
# fine and only failing on the first real inbound message, which is a much
# worse failure mode to discover live during a demo. Only checks presence
# here (cheap, instant) -- whether the credentials are actually VALID
# against Twilio's API is what R/11_twilio_smoke_test.R checks separately,
# since that needs a network round trip and shouldn't block every server
# start.
#
# Either WhatsApp provider may be configured on its own (Twilio-only or
# Meta-only), or both. A provider whose variables are only PARTLY set is an
# error, so a typo'd or missing value fails at startup, not on a live message.
TWILIO_REQUIRED_VARS <- c("TWILIO_ACCOUNT_SID", "TWILIO_AUTH_TOKEN")
META_REQUIRED_VARS <- c("META_ACCESS_TOKEN", "META_PHONE_NUMBER_ID", "META_VERIFY_TOKEN")

validate_startup <- function() {
  problems <- character(0)
  is_set <- function(vars) vapply(vars, function(v) nzchar(Sys.getenv(v)), logical(1))
  providers <- list(Twilio = TWILIO_REQUIRED_VARS, Meta = META_REQUIRED_VARS)
  complete <- FALSE
  for (name in names(providers)) {
    set <- is_set(providers[[name]])
    if (all(set)) complete <- TRUE
    if (any(set) && !all(set)) {
      problems <- c(problems, paste0(name, " is partly configured -- missing: ",
                                      paste(providers[[name]][!set], collapse = ", ")))
    }
  }
  if (!complete && length(problems) == 0) {
    problems <- c(problems, paste0(
      "No WhatsApp provider configured -- set ", paste(TWILIO_REQUIRED_VARS, collapse = " and "),
      " (Twilio), and/or ", paste(META_REQUIRED_VARS, collapse = ", "), " (Meta WhatsApp Cloud API)"))
  }
  if (!file.exists(MODEL_PATH_ABS)) {
    problems <- c(problems, paste0("No trained model at ", MODEL_PATH_ABS,
                                    " -- run R/05_train.R first"))
  }
  if (length(problems) > 0) {
    stop("Startup validation failed -- fix before the server can run:\n  - ",
         paste(problems, collapse = "\n  - "),
         "\nSee .env.example, docs/twilio_setup.md and docs/meta_whatsapp_setup.md.", call. = FALSE)
  }
  invisible(TRUE)
}
validate_startup()

# ---- Helpers ----------------------------------------------------------------

xml_escape <- function(x) {
  x <- gsub("&", "&amp;", x, fixed = TRUE)
  x <- gsub("<", "&lt;", x, fixed = TRUE)
  x <- gsub(">", "&gt;", x, fixed = TRUE)
  x
}

twiml_reply <- function(message) {
  paste0('<?xml version="1.0" encoding="UTF-8"?>',
         "<Response><Message>", xml_escape(message), "</Message></Response>")
}

log_request <- function(from, outcome, ...) {
  log_event(REQUEST_LOG_PATH, from = if (is.null(from)) NA_character_ else from,
             outcome = outcome, ...)
}

#' Download a Twilio media attachment. Twilio media URLs require HTTP Basic
#' Auth using the account's SID/auth token (not a public URL).
download_twilio_media <- function(media_url, content_type) {
  sid <- Sys.getenv("TWILIO_ACCOUNT_SID")
  token <- Sys.getenv("TWILIO_AUTH_TOKEN")
  if (sid == "" || token == "") {
    stop("TWILIO_ACCOUNT_SID / TWILIO_AUTH_TOKEN not set -- see .env.example and docs/twilio_setup.md")
  }

  ext <- switch(content_type,
    "audio/ogg" = ".ogg", "audio/opus" = ".opus", "audio/mpeg" = ".mp3",
    "audio/amr" = ".amr",
    "audio/wav" = , "audio/wave" = , "audio/x-wav" = ".wav",
    "audio/mp4" = , "audio/x-m4a" = ".m4a",
    ".bin"
  )
  dest <- tempfile(fileext = ext)

  resp <- httr2::request(media_url) |>
    httr2::req_auth_basic(sid, token) |>
    httr2::req_timeout(30) |>
    httr2::req_perform(path = dest)

  if (httr2::resp_status(resp) >= 400) {
    unlink(dest)
    stop("Twilio media download returned HTTP ", httr2::resp_status(resp))
  }
  dest
}

# ---- Endpoints ----------------------------------------------------------------

#* Health check
#* @get /health
function() {
  list(status = "ok", model_present = file.exists(MODEL_PATH_ABS))
}

#* Twilio WhatsApp Sandbox inbound-message webhook.
#* Handles the failure paths explicitly: non-audio attachment, clip too
#* short, media download failure, decode failure, and no confident match.
#* @post /webhook
function(req, res, From = NA, NumMedia = "0", MediaUrl0 = NULL, MediaContentType0 = NULL) {
  res$setHeader("Content-Type", "application/xml")

  n_media <- suppressWarnings(as.integer(NumMedia))
  if (is.na(n_media) || n_media < 1 || is.null(MediaUrl0)) {
    log_request(From, "no_media")
    return(twiml_reply("Please send a voice note recording of the field (10-30 seconds)."))
  }

  if (is.null(MediaContentType0) || !grepl("^audio/", MediaContentType0)) {
    log_request(From, "non_audio_attachment", content_type = MediaContentType0)
    return(twiml_reply("That doesn't look like an audio file -- please send a voice note, not a photo/video/document."))
  }

  tmp_audio <- tryCatch(download_twilio_media(MediaUrl0, MediaContentType0), error = function(e) e)
  if (inherits(tmp_audio, "error")) {
    log_request(From, "download_failed", error = conditionMessage(tmp_audio))
    return(twiml_reply("Sorry, we couldn't download your recording. Please try sending it again."))
  }
  on.exit(unlink(tmp_audio), add = TRUE)

  wave <- tryCatch(whatsappaudioR::wa_read(tmp_audio), error = function(e) e)
  if (inherits(wave, "error")) {
    log_request(From, "decode_failed", error = conditionMessage(wave))
    return(twiml_reply("Sorry, we couldn't process that audio file."))
  }

  duration_s <- length(wave@left) / wave@samp.rate
  if (duration_s < MIN_CLIP_SECONDS) {
    log_request(From, "clip_too_short", duration_s = duration_s)
    return(twiml_reply(sprintf(
      "That recording is only %.1fs -- please send at least %ds so we have enough signal to work with.",
      duration_s, MIN_CLIP_SECONDS
    )))
  }

  result <- tryCatch(predict_pest(tmp_audio), error = function(e) e)
  if (inherits(result, "error")) {
    log_request(From, "prediction_failed", error = conditionMessage(result))
    return(twiml_reply("Sorry, something went wrong analysing your recording. Our team has been notified."))
  }

  audio_hash <- unname(tools::md5sum(tmp_audio))

  # Keep a copy of the audio alongside the log entry so the Shiny dashboard's
  # replay mode (Deliverable F) can show a real waveform/spectrogram for this
  # request without a live connection.
  ensure_dir(REQUEST_AUDIO_DIR)
  archived_audio_path <- file.path(REQUEST_AUDIO_DIR, paste0(audio_hash, ".", tools::file_ext(tmp_audio)))
  file.copy(tmp_audio, archived_audio_path, overwrite = TRUE)

  log_request(From, if (isTRUE(result$low_confidence)) "low_confidence" else "predicted",
              audio_hash = audio_hash, audio_path = archived_audio_path, duration_s = duration_s,
              top_classes = paste(result$top_classes, collapse = "|"),
              confidences = paste(round(result$confidences, 3), collapse = "|"))

  twiml_reply(format_reply(result))
}

# ---- Meta WhatsApp Cloud API --------------------------------------------------
#
# GET  /meta-webhook  -- Meta's subscription check: echo hub.challenge back
#                        when hub.verify_token matches META_VERIFY_TOKEN.
# POST /meta-webhook  -- one delivery may carry several messages and/or
#                        delivery-status events. Acknowledge with 200 straight
#                        away and do the slow work (download, predict, reply)
#                        afterwards via later::later(): Meta retries any
#                        delivery it doesn't see acknowledged quickly, which
#                        would otherwise mean duplicate predictions and replies.
#
# Replies reuse the Twilio path's wording, so a farmer gets the same answers
# whichever provider carried the message. The Twilio handler above is left
# as it was; the shared steps (duration check, predict_pest(), format_reply(),
# logging) are called the same way here.

META_GRAPH_VERSION_DEFAULT <- "v26.0"  # latest Graph API version as of 2026-10

REPLY_NO_MEDIA <- "Please send a voice note recording of the field (10-30 seconds)."
REPLY_NOT_AUDIO <- "That doesn't look like an audio file -- please send a voice note, not a photo/video/document."
REPLY_DOWNLOAD_FAILED <- "Sorry, we couldn't download your recording. Please try sending it again."
REPLY_DECODE_FAILED <- "Sorry, we couldn't process that audio file."
REPLY_PREDICTION_FAILED <- "Sorry, something went wrong analysing your recording. Our team has been notified."

#' Graph API URL for a path. META_GRAPH_BASE_URL exists only so the test
#' suite can point this at a local mock; leave it unset in real use.
meta_graph_url <- function(...) {
  base <- sub("/+$", "", Sys.getenv("META_GRAPH_BASE_URL", "https://graph.facebook.com"))
  version <- Sys.getenv("META_GRAPH_VERSION")
  if (!nzchar(version)) version <- META_GRAPH_VERSION_DEFAULT
  paste(c(base, version, ...), collapse = "/")
}

#' Strip the access token from any text before it is logged.
meta_redact <- function(text) {
  token <- Sys.getenv("META_ACCESS_TOKEN")
  text <- as.character(text)
  if (nzchar(token)) text <- gsub(token, "[REDACTED]", text, fixed = TRUE)
  text
}

#' Human-readable Graph API error from a failed response (Meta returns
#' {"error": {"message", "type", "code", ...}}).
meta_graph_error <- function(resp) {
  status <- httr2::resp_status(resp)
  err <- tryCatch(httr2::resp_body_json(resp)$error, error = function(e) NULL)
  if (is.null(err)) return(sprintf("Graph API HTTP %d", status))
  meta_redact(sprintf("Graph API HTTP %d: %s (type %s, code %s)", status,
                      err$message %||% "?", err$type %||% "?", err$code %||% "?"))
}

meta_request <- function(url) {
  httr2::request(url) |>
    httr2::req_auth_bearer_token(Sys.getenv("META_ACCESS_TOKEN")) |>
    httr2::req_error(is_error = function(resp) FALSE)
}

#' Valid X-Hub-Signature-256 ("sha256=<hex HMAC-SHA256 of the raw body,
#' keyed with the app secret>")?
meta_signature_valid <- function(raw_body, header, secret) {
  if (is.null(header) || length(header) != 1 || !nzchar(header)) return(FALSE)
  expected <- paste0("sha256=", as.character(openssl::sha256(raw_body, key = secret)))
  received <- tolower(header)
  # Compare every character, not just up to the first mismatch.
  nchar(received) == nchar(expected) &&
    sum(utf8ToInt(received) != utf8ToInt(expected)) == 0
}

#' File extension wa_read() can decode, from a WhatsApp audio MIME type.
#' Voice notes arrive as "audio/ogg; codecs=opus". ffmpeg detects the real
#' container from the bytes, so AAC is given wa_read()'s ".m4a" route.
meta_audio_ext <- function(mime_type) {
  base <- tolower(trimws(sub(";.*$", "", mime_type %||% "")))
  switch(base,
    "audio/ogg" = ".ogg", "audio/opus" = ".opus", "audio/mpeg" = ".mp3",
    "audio/wav" = , "audio/wave" = , "audio/x-wav" = ".wav",
    "audio/mp4" = , "audio/x-m4a" = , "audio/aac" = ".m4a",
    ".bin"
  )
}

#' Download a WhatsApp audio attachment. Uses `audio$url` when the webhook
#' includes one, otherwise asks the Graph API for it via the media ID. Both
#' requests need the Bearer token; media URLs expire after 5 minutes.
download_meta_media <- function(audio) {
  if (!nzchar(Sys.getenv("META_ACCESS_TOKEN"))) stop("META_ACCESS_TOKEN not set")
  url <- audio$url
  mime_type <- audio$mime_type
  if (is.null(url) || !nzchar(url)) {
    if (is.null(audio$id)) stop("audio message has neither a url nor an id")
    resp <- meta_request(meta_graph_url(audio$id)) |> httr2::req_timeout(30) |> httr2::req_perform()
    if (httr2::resp_status(resp) >= 400) stop("media lookup failed: ", meta_graph_error(resp))
    info <- httr2::resp_body_json(resp)
    url <- info$url
    mime_type <- mime_type %||% info$mime_type
    if (is.null(url)) stop("media lookup returned no url")
  }
  dest <- tempfile(fileext = meta_audio_ext(mime_type))
  resp <- meta_request(url) |> httr2::req_timeout(60) |> httr2::req_perform(path = dest)
  if (httr2::resp_status(resp) >= 400) {
    unlink(dest)
    stop("media download failed: Graph API HTTP ", httr2::resp_status(resp))
  }
  dest
}

#' Send a WhatsApp text reply. Failures are logged (token redacted), never raised.
meta_send_reply <- function(to, body, log_from, message_id) {
  resp <- tryCatch(
    meta_request(meta_graph_url(Sys.getenv("META_PHONE_NUMBER_ID"), "messages")) |>
      httr2::req_body_json(list(messaging_product = "whatsapp", to = to,
                                type = "text", text = list(body = body))) |>
      httr2::req_timeout(30) |>
      httr2::req_perform(),
    error = function(e) e
  )
  failure <- if (inherits(resp, "error")) meta_redact(conditionMessage(resp))
             else if (httr2::resp_status(resp) >= 400) meta_graph_error(resp)
  if (!is.null(failure)) {
    log_request(log_from, "reply_failed", source = "meta", message_id = message_id, error = failure)
  }
  invisible(is.null(failure))
}

#' Voice note -> reply text: download, duration check, predict, log. Mirrors
#' the Twilio handler's steps and log fields.
meta_process_audio <- function(message, log_from) {
  log_meta <- function(outcome, ...) {
    log_request(log_from, outcome, source = "meta", message_id = message$id, ...)
  }
  tmp_audio <- tryCatch(download_meta_media(message$audio), error = function(e) e)
  if (inherits(tmp_audio, "error")) {
    log_meta("download_failed", error = meta_redact(conditionMessage(tmp_audio)))
    return(REPLY_DOWNLOAD_FAILED)
  }
  on.exit(unlink(tmp_audio), add = TRUE)

  wave <- tryCatch(whatsappaudioR::wa_read(tmp_audio), error = function(e) e)
  if (inherits(wave, "error")) {
    log_meta("decode_failed", error = conditionMessage(wave))
    return(REPLY_DECODE_FAILED)
  }

  duration_s <- length(wave@left) / wave@samp.rate
  if (duration_s < MIN_CLIP_SECONDS) {
    log_meta("clip_too_short", duration_s = duration_s)
    return(sprintf(
      "That recording is only %.1fs -- please send at least %ds so we have enough signal to work with.",
      duration_s, MIN_CLIP_SECONDS
    ))
  }

  result <- tryCatch(predict_pest(tmp_audio), error = function(e) e)
  if (inherits(result, "error")) {
    log_meta("prediction_failed", error = conditionMessage(result))
    return(REPLY_PREDICTION_FAILED)
  }

  audio_hash <- unname(tools::md5sum(tmp_audio))
  ensure_dir(REQUEST_AUDIO_DIR)
  archived_audio_path <- file.path(REQUEST_AUDIO_DIR, paste0(audio_hash, ".", tools::file_ext(tmp_audio)))
  file.copy(tmp_audio, archived_audio_path, overwrite = TRUE)

  log_meta(if (isTRUE(result$low_confidence)) "low_confidence" else "predicted",
           audio_hash = audio_hash, audio_path = archived_audio_path, duration_s = duration_s,
           top_classes = paste(result$top_classes, collapse = "|"),
           confidences = paste(round(result$confidences, 3), collapse = "|"))
  format_reply(result)
}

#' Handle one inbound message end to end, including the reply. Never raises:
#' it runs from later::later(), after the delivery was acknowledged.
meta_handle_message <- function(message) {
  log_from <- paste0("whatsapp:+", message$from %||% "unknown")
  tryCatch({
    type <- message$type %||% "unknown"
    reply <- if (identical(type, "audio")) {
      meta_process_audio(message, log_from)
    } else if (identical(type, "text")) {
      log_request(log_from, "no_media", source = "meta", message_id = message$id)
      REPLY_NO_MEDIA
    } else {
      log_request(log_from, "non_audio_attachment", source = "meta", message_id = message$id,
                  content_type = message[[type]]$mime_type %||% type)
      REPLY_NOT_AUDIO
    }
    if (!is.null(message$from)) meta_send_reply(message$from, reply, log_from, message$id)
  }, error = function(e) {
    log_request(log_from, "processing_failed", source = "meta", message_id = message$id,
                error = meta_redact(conditionMessage(e)))
  })
  invisible(NULL)
}

# Message IDs already accepted, so a re-delivered message is answered once.
# In memory: a server restart forgets them (see docs/meta_whatsapp_setup.md).
.meta_seen_ids <- new.env(parent = emptyenv())

#' TRUE the first time an ID is seen, FALSE afterwards. Entries older than a
#' day are dropped; Meta stops retrying well before that.
meta_first_delivery <- function(id) {
  now <- Sys.time()
  stale <- Filter(function(k) difftime(now, .meta_seen_ids[[k]], units = "hours") > 24, ls(.meta_seen_ids))
  if (length(stale)) rm(list = stale, envir = .meta_seen_ids)
  if (exists(id, envir = .meta_seen_ids, inherits = FALSE)) return(FALSE)
  assign(id, now, envir = .meta_seen_ids)
  TRUE
}

#' Every message in a webhook payload (entry[].changes[].value.messages[]).
#' Delivery-status events (value.statuses) are ignored.
meta_extract_messages <- function(payload) {
  out <- list()
  for (entry in payload$entry %||% list()) {
    for (change in entry$changes %||% list()) {
      out <- c(out, change$value$messages %||% list())
    }
  }
  out
}

#* Meta WhatsApp Cloud API webhook verification
#* @get /meta-webhook
#* @serializer text
function(req, res) {
  query <- req$argsQuery
  expected <- Sys.getenv("META_VERIFY_TOKEN")
  if (identical(query[["hub.mode"]], "subscribe") && nzchar(expected) &&
      identical(query[["hub.verify_token"]], expected) && !is.null(query[["hub.challenge"]])) {
    return(as.character(query[["hub.challenge"]]))
  }
  res$status <- 403
  "Forbidden"
}

#* Meta WhatsApp Cloud API inbound-message webhook
#* @post /meta-webhook
#* @serializer text
function(req, res) {
  raw_body <- req$bodyRaw %||% raw(0)
  secret <- Sys.getenv("META_APP_SECRET")
  if (nzchar(secret) && !meta_signature_valid(raw_body, req$HTTP_X_HUB_SIGNATURE_256, secret)) {
    res$status <- 403
    return("Invalid signature")
  }

  payload <- tryCatch(jsonlite::fromJSON(rawToChar(raw_body), simplifyVector = FALSE),
                      error = function(e) NULL)
  if (!is.list(payload)) {
    res$status <- 400
    return("Invalid JSON")
  }

  messages <- Filter(function(m) !is.null(m$id) && meta_first_delivery(m$id),
                     meta_extract_messages(payload))
  if (length(messages) > 0) {
    later::later(function() for (m in messages) meta_handle_message(m), delay = 0)
  }
  "OK"
}
