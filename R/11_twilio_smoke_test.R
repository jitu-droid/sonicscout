# Prompt 11, Part 2a -- Twilio smoke test.
#
# The webhook (api/plumber.R) has only ever been tested against a mock
# payload with the media download stubbed (tests/testthat/test-plumber-webhook.R).
# This script checks everything that CAN be checked without an actual
# inbound WhatsApp message: that credentials load, that Twilio's own API
# is reachable and the credentials are valid against it (not just present),
# and that the local webhook endpoint responds. Run this before attempting
# a live end-to-end test (docs/twilio_setup.md) to catch a configuration
# problem in seconds instead of by trial and error with a real phone.
#
# Usage:
#   Rscript R/11_twilio_smoke_test.R
#   Rscript R/11_twilio_smoke_test.R --port 8000   # if the server is already running elsewhere

library(httr2)

#' Minimal, dependency-free .env loader (KEY=VALUE per line, '#' comments,
#' blank lines skipped) -- not a full dotenv implementation, just enough to
#' let this script (and a future server start) pick up .env without adding
#' a package dependency for it. Does not override variables already set in
#' the environment (a real env var takes precedence over .env, standard
#' dotenv convention).
load_dot_env <- function(path = ".env") {
  if (!file.exists(path)) return(invisible(FALSE))
  lines <- readLines(path, warn = FALSE)
  lines <- lines[!grepl("^\\s*#", lines) & nzchar(trimws(lines))]
  for (line in lines) {
    kv <- strsplit(line, "=", fixed = TRUE)[[1]]
    if (length(kv) < 2) next
    key <- trimws(kv[1])
    value <- trimws(paste(kv[-1], collapse = "="))
    value <- gsub("^['\"]|['\"]$", "", value)  # strip surrounding quotes if present
    if (Sys.getenv(key) == "") do.call(Sys.setenv, stats::setNames(list(value), key))
  }
  invisible(TRUE)
}

result_line <- function(label, ok, detail = "") {
  status <- if (ok) "PASS" else "FAIL"
  cat(sprintf("[%s] %s%s\n", status, label, if (nzchar(detail)) paste0(" -- ", detail) else ""))
  ok
}

main <- function(port = 8000) {
  cat("=== Twilio smoke test ===\n\n")
  all_ok <- TRUE

  loaded <- load_dot_env()
  cat(if (loaded) "Loaded .env from repo root.\n" else "No .env file found in repo root (relying on already-set environment variables).\n")
  cat("\n")

  # ---- 1. Credentials load -------------------------------------------------
  sid <- Sys.getenv("TWILIO_ACCOUNT_SID")
  token <- Sys.getenv("TWILIO_AUTH_TOKEN")
  from <- Sys.getenv("TWILIO_WHATSAPP_FROM")

  all_ok <- result_line("TWILIO_ACCOUNT_SID is set", sid != "",
                         if (sid != "") paste0(substr(sid, 1, 6), "...") else "not set") && all_ok
  all_ok <- result_line("TWILIO_AUTH_TOKEN is set", token != "",
                         if (token != "") "(hidden)" else "not set") && all_ok
  result_line("TWILIO_WHATSAPP_FROM is set", from != "", if (from != "") from else "not set (optional -- only needed for outbound-initiated messages, not webhook replies)")

  if (sid == "" || token == "") {
    cat("\nCannot proceed to API reachability check without both credentials. ",
        "See .env.example and docs/twilio_setup.md.\n", sep = "")
    return(invisible(FALSE))
  }
  cat("\n")

  # ---- 2. Twilio API reachable AND credentials valid -----------------------
  # GET /Accounts/{Sid}.json is the cheapest authenticated call Twilio's API
  # offers -- confirms both network reachability and that these specific
  # credentials are accepted, not just present.
  resp <- tryCatch(
    httr2::request(sprintf("https://api.twilio.com/2010-04-01/Accounts/%s.json", sid)) |>
      httr2::req_auth_basic(sid, token) |>
      httr2::req_timeout(15) |>
      httr2::req_error(is_error = function(resp) FALSE) |>  # inspect status ourselves, don't throw
      httr2::req_perform(),
    error = function(e) e
  )

  if (inherits(resp, "error")) {
    all_ok <- result_line("Twilio API reachable", FALSE, conditionMessage(resp)) && all_ok
  } else {
    status <- httr2::resp_status(resp)
    if (status == 200) {
      body <- tryCatch(httr2::resp_body_json(resp), error = function(e) NULL)
      account_status <- if (!is.null(body)) body$status else "unknown"
      all_ok <- result_line("Twilio API reachable and credentials valid", TRUE,
                             paste0("account status: ", account_status)) && all_ok
    } else if (status == 401) {
      all_ok <- result_line("Twilio API reachable and credentials valid", FALSE,
                             "HTTP 401 -- credentials rejected by Twilio (wrong SID/token, or trial account restrictions)") && all_ok
    } else {
      all_ok <- result_line("Twilio API reachable and credentials valid", FALSE,
                             paste0("unexpected HTTP ", status)) && all_ok
    }
  }
  cat("\n")

  # ---- 3. Local webhook endpoint responds ----------------------------------
  # Checks whatever is already listening on `port` -- start the server first
  # (see docs/twilio_setup.md) if this is what you want to verify; this
  # script does not start it itself, since a smoke test shouldn't have the
  # side effect of launching a long-running server process.
  health_resp <- tryCatch(
    httr2::request(sprintf("http://127.0.0.1:%d/health", port)) |>
      httr2::req_timeout(5) |>
      httr2::req_error(is_error = function(resp) FALSE) |>
      httr2::req_perform(),
    error = function(e) e
  )
  if (inherits(health_resp, "error")) {
    result_line(sprintf("Local webhook responds on port %d", port), FALSE,
                paste0("not reachable (", conditionMessage(health_resp), ") -- ",
                       "start it first: Rscript -e \"plumber::pr_run(plumber::pr('api/plumber.R'), port = ", port, ")\""))
    cat("(Not counted against overall PASS/FAIL -- the server not being started yet is expected before a live test.)\n")
  } else if (httr2::resp_status(health_resp) == 200) {
    body <- tryCatch(httr2::resp_body_json(health_resp), error = function(e) NULL)
    result_line(sprintf("Local webhook responds on port %d", port), TRUE,
                if (!is.null(body)) sprintf("model_present=%s", body$model_present) else "")
  } else {
    result_line(sprintf("Local webhook responds on port %d", port), FALSE,
                paste0("HTTP ", httr2::resp_status(health_resp)))
  }
  cat("\n")

  cat(if (all_ok) "=== Overall: PASS (credentials + Twilio API) ===\n"
      else "=== Overall: FAIL -- fix the items above before attempting a live test ===\n")
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
  ok <- main(port = port)
  if (!isTRUE(ok)) quit(status = 1)
}
