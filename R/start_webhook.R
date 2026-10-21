# Start the SonicScout webhooks on port 8000 -- Twilio at /webhook and Meta's
# WhatsApp Cloud API at /meta-webhook -- loading credentials from .env.
# api/plumber.R reads TWILIO_* / META_* from environment variables only, so this
# launcher loads .env first (without overriding anything already set in the
# environment).
# Usage, from the repo root:  Rscript R/start_webhook.R
if (file.exists(".env")) {
  for (line in readLines(".env", warn = FALSE)) {
    line <- trimws(line)
    if (!nzchar(line) || startsWith(line, "#") || !grepl("=", line, fixed = TRUE)) next
    key <- trimws(sub("=.*$", "", line))
    value <- gsub("^['\"]|['\"]$", "", trimws(sub("^[^=]*=", "", line)))
    if (Sys.getenv(key) == "") do.call(Sys.setenv, stats::setNames(list(value), key))
  }
} else {
  message("No .env file in the repo root -- relying on environment variables already set.")
}
plumber::pr_run(plumber::pr("api/plumber.R"), port = 8000)
