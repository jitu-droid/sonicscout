# Deliverable E -- Twilio WhatsApp Sandbox webhook.
#
# Receives Twilio's inbound-message webhook (form-encoded POST), downloads
# the attached media (Twilio media URLs require HTTP Basic Auth with the
# account SID/token), runs it through the SonicScout prediction pipeline
# (R/06_predict.R), logs the request, and replies via TwiML.
#
# Run locally:
#   Rscript -e "plumber::pr_run(plumber::pr('api/plumber.R'), port = 8000)"
#
# Credentials come from environment variables (see .env.example) -- never
# hardcode, never commit a real .env. See docs/twilio_setup.md for the full
# sandbox setup + how to expose this locally to Twilio via a tunnel.

library(plumber)
library(httr2)
library(jsonlite)
library(whatsappaudioR)

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
REQUEST_LOG_PATH <- file.path(.repo_root, "logs", "requests.jsonl")
REQUEST_AUDIO_DIR <- file.path(.repo_root, "logs", "audio")
MODEL_PATH_ABS <- file.path(.repo_root, "models", "classifier.rds")

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
