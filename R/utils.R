# Shared config and helpers used across R/*.R pipeline stages.
# Sourced by every stage script so constants (sample rate, bands) can't drift
# between the codec experiment, preprocessing, and feature extraction.

WHATSAPP_SAMPLE_RATE  <- 16000L  # Hz -- WhatsApp voice note sample rate
WHATSAPP_BITRATE_KBPS <- 16      # kbps -- WhatsApp's Opus target bitrate (~16 kbps)
FFT_WINDOW            <- 2048    # long window: frequency resolution for low-freq insect sound

FREQ_BANDS <- list(
  c(0,     500),
  c(500,   2000),
  c(2000,  4000),
  c(4000,  8000),
  c(8000,  Inf)
)
FREQ_BAND_LABELS <- c("0-500Hz", "500Hz-2kHz", "2-4kHz", "4-8kHz", ">8kHz")

#' Create a directory (recursively) if it doesn't already exist.
ensure_dir <- function(path) {
  if (!dir.exists(path)) dir.create(path, recursive = TRUE)
  invisible(path)
}

#' Append a structured JSON-lines log entry with a timestamp.
#' Used by the plumber webhook (Deliverable E) to satisfy the "log every
#' inbound request" requirement; kept here so any stage can log consistently.
log_event <- function(log_path, ...) {
  ensure_dir(dirname(log_path))
  entry <- c(list(timestamp = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z")), list(...))
  cat(jsonlite::toJSON(entry, auto_unbox = TRUE), "\n", file = log_path, append = TRUE, sep = "")
  invisible(entry)
}
