# Meta WhatsApp Cloud API smoke test -- the Meta counterpart of
# R/11_twilio_smoke_test.R. Checks, without needing an inbound message:
#   1. the META_* variables are set (loaded from .env if present),
#   2. the access token is accepted by the Graph API, by fetching the
#      configured phone number ID (catches an expired temporary token, a
#      wrong phone number ID, or a token for a different app),
#   3. the local /meta-webhook answers a correct verification request the
#      way Meta's "Verify and save" button will (and refuses a wrong token).
# The token itself is never printed.
#
# Usage (from the repo root; start the webhook first for check 3):
#   Rscript R/start_webhook.R            # in one terminal
#   Rscript R/12_meta_smoke_test.R       # in another
#   Rscript R/12_meta_smoke_test.R --port 8000

library(httr2)

META_GRAPH_VERSION_DEFAULT <- "v26.0"  # keep in step with api/plumber.R

#' Minimal .env loader (KEY=VALUE lines, '#' comments) -- an already-set
#' environment variable wins over .env, as in R/11_twilio_smoke_test.R.
load_dot_env <- function(path = ".env") {
  if (!file.exists(path)) return(invisible(FALSE))
  for (line in readLines(path, warn = FALSE)) {
    line <- trimws(line)
    if (!nzchar(line) || startsWith(line, "#") || !grepl("=", line, fixed = TRUE)) next
    key <- trimws(sub("=.*$", "", line))
    value <- gsub("^['\"]|['\"]$", "", trimws(sub("^[^=]*=", "", line)))
    if (Sys.getenv(key) == "") do.call(Sys.setenv, stats::setNames(list(value), key))
  }
  invisible(TRUE)
}

result_line <- function(label, ok, detail = "") {
  cat(sprintf("[%s] %s%s\n", if (ok) "PASS" else "FAIL", label, if (nzchar(detail)) paste0(" -- ", detail) else ""))
  ok
}

main <- function(port = 8000) {
  cat("=== Meta WhatsApp Cloud API smoke test ===\n\n")
  cat(if (load_dot_env()) "Loaded .env from repo root.\n\n" else "No .env file in repo root (using already-set environment variables).\n\n")
  all_ok <- TRUE

  # ---- 1. Configuration --------------------------------------------------------
  token <- Sys.getenv("META_ACCESS_TOKEN")
  phone_id <- Sys.getenv("META_PHONE_NUMBER_ID")
  verify_token <- Sys.getenv("META_VERIFY_TOKEN")
  version <- Sys.getenv("META_GRAPH_VERSION")
  if (!nzchar(version)) version <- META_GRAPH_VERSION_DEFAULT

  all_ok <- result_line("META_ACCESS_TOKEN is set", nzchar(token), if (nzchar(token)) "(hidden)" else "not set") && all_ok
  all_ok <- result_line("META_PHONE_NUMBER_ID is set", nzchar(phone_id), if (nzchar(phone_id)) phone_id else "not set") && all_ok
  all_ok <- result_line("META_VERIFY_TOKEN is set", nzchar(verify_token), if (nzchar(verify_token)) "(hidden)" else "not set") && all_ok
  cat(if (nzchar(Sys.getenv("META_APP_SECRET"))) "[INFO] META_APP_SECRET is set -- (hidden), deliveries will be signature-checked\n"
      else "[INFO] META_APP_SECRET not set (optional) -- deliveries will NOT be signature-checked\n")
  cat(sprintf("Graph API version: %s\n\n", version))

  # ---- 2. Token accepted, phone number ID valid ---------------------------------
  if (nzchar(token) && nzchar(phone_id)) {
    resp <- tryCatch(
      httr2::request(sprintf("https://graph.facebook.com/%s/%s", version, phone_id)) |>
        httr2::req_url_query(fields = "display_phone_number,verified_name") |>
        httr2::req_auth_bearer_token(token) |>
        httr2::req_timeout(15) |>
        httr2::req_error(is_error = function(resp) FALSE) |>
        httr2::req_perform(),
      error = function(e) e
    )
    if (inherits(resp, "error")) {
      all_ok <- result_line("Graph API reachable", FALSE, gsub(token, "[REDACTED]", conditionMessage(resp), fixed = TRUE)) && all_ok
    } else if (httr2::resp_status(resp) == 200) {
      info <- httr2::resp_body_json(resp)
      all_ok <- result_line("Access token accepted and phone number ID found", TRUE,
                            sprintf("%s (%s)", info$display_phone_number %||% "?", info$verified_name %||% "?")) && all_ok
    } else {
      err <- tryCatch(httr2::resp_body_json(resp)$error, error = function(e) NULL)
      hint <- if (identical(err$code, 190L) || identical(err$code, 190)) " -- the token is invalid or has expired (temporary tokens last ~24h)"
              else if (httr2::resp_status(resp) %in% c(400, 404)) " -- check META_PHONE_NUMBER_ID (the ID, not the phone number)"
              else ""
      detail <- sprintf("HTTP %d: %s%s", httr2::resp_status(resp), err$message %||% "no error message", hint)
      all_ok <- result_line("Access token accepted and phone number ID found", FALSE,
                            gsub(token, "[REDACTED]", detail, fixed = TRUE)) && all_ok
    }
  } else {
    cat("Skipping the Graph API check -- token and phone number ID are both needed.\n")
  }
  cat("\n")

  # ---- 3. Local /meta-webhook answers verification ------------------------------
  if (nzchar(verify_token)) {
    challenge <- as.character(sample(100000000:999999999, 1))
    verify <- function(token_to_send) {
      httr2::request(sprintf("http://127.0.0.1:%d/meta-webhook", port)) |>
        httr2::req_url_query(`hub.mode` = "subscribe", `hub.verify_token` = token_to_send,
                             `hub.challenge` = challenge) |>
        httr2::req_timeout(5) |>
        httr2::req_error(is_error = function(resp) FALSE) |>
        httr2::req_perform()
    }
    ok_resp <- tryCatch(verify(verify_token), error = function(e) e)
    if (inherits(ok_resp, "error")) {
      result_line(sprintf("Local /meta-webhook verification (port %d)", port), FALSE,
                  "not reachable -- start it first: Rscript R/start_webhook.R")
      cat("(Not counted against the overall result -- the server not running yet is expected before a live test.)\n")
    } else {
      answered <- httr2::resp_status(ok_resp) == 200 && identical(httr2::resp_body_string(ok_resp), challenge)
      all_ok <- result_line("Local /meta-webhook echoes the challenge for the right verify token", answered,
                            sprintf("HTTP %d", httr2::resp_status(ok_resp))) && all_ok
      bad_status <- httr2::resp_status(verify(paste0(verify_token, "-wrong")))
      all_ok <- result_line("Local /meta-webhook refuses a wrong verify token", bad_status == 403,
                            sprintf("HTTP %d", bad_status)) && all_ok
    }
  }
  cat("\n")

  cat(if (all_ok) "=== Overall: PASS ===\n" else "=== Overall: FAIL -- fix the items above before a live test ===\n")
  invisible(all_ok)
}

if (sys.nframe() == 0) {
  cli_args <- commandArgs(trailingOnly = TRUE)
  port <- 8000
  port_idx <- which(cli_args == "--port")
  if (length(port_idx) == 1 && length(cli_args) >= port_idx + 1) {
    port <- suppressWarnings(as.integer(cli_args[port_idx + 1]))
    if (is.na(port)) port <- 8000
  }
  if (!isTRUE(main(port = port))) quit(status = 1)
}
