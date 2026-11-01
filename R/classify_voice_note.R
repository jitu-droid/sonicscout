# Classify a real WhatsApp voice note on this laptop and show it on the dashboard.
# Fallback demo path while the live WhatsApp reply (Twilio/Meta) is unavailable:
# record a voice note on the phone, download it from WhatsApp Web, then run:
#   Rscript R/classify_voice_note.R                  # newest voice note in Downloads
#   Rscript R/classify_voice_note.R path\to\file.ogg # a specific file
source(file.path("R", "utils.R"))
source(file.path("R", "06_predict.R"))

args <- commandArgs(trailingOnly = TRUE)
if (length(args) >= 1) {
  path <- args[1]
} else {
  downloads <- file.path(Sys.getenv("USERPROFILE"), "Downloads")
  cands <- list.files(downloads, pattern = "\\.(ogg|opus|m4a|mp3)$",
                      full.names = TRUE, ignore.case = TRUE)
  if (length(cands) == 0) stop("No .ogg/.opus/.m4a/.mp3 file found in ", downloads)
  path <- cands[which.max(file.mtime(cands))]
}
if (!file.exists(path)) stop("File not found: ", path)
cat("Voice note:", basename(path), "\n\n")

result <- predict_pest(path)
reply <- format_reply(result)

# Archive a 16 kHz mono WAV copy so the dashboard can draw it, and log the request.
log_dir <- Sys.getenv("SONICSCOUT_LOG_DIR", file.path(.repo_root, "logs"))
audio_dir <- file.path(log_dir, "audio")
dir.create(audio_dir, recursive = TRUE, showWarnings = FALSE)
audio_hash <- unname(tools::md5sum(path))
wave16 <- whatsappaudioR::wa_read(path, sample_rate = 16000, mono = TRUE)
tuneR::writeWave(wave16, file.path(audio_dir, paste0(audio_hash, ".wav")))
duration_s <- round(length(wave16@left) / wave16@samp.rate, 2)

outcome <- if (isTRUE(result$gated_silent)) "gated_silent" else
  if (isTRUE(result$low_confidence)) "low_confidence" else "predicted"
log_event(file.path(log_dir, "requests.jsonl"),
          from = "whatsapp voice note (classified locally)", outcome = outcome,
          audio_hash = audio_hash,
          audio_path = file.path("logs", "audio", paste0(audio_hash, ".wav")),
          duration_s = duration_s,
          top_classes = paste(result$top_classes, collapse = "|"),
          confidences = paste(round(result$confidences, 3), collapse = "|"))

if (length(result$top_classes) > 0) {
  cat("Top guesses:\n")
  for (i in seq_along(result$top_classes)) {
    cat(sprintf("  %d. %-24s %3.0f%%\n", i, result$top_classes[i], 100 * result$confidences[i]))
  }
}
cat("\nReply the farmer would get:\n  ", reply, "\n", sep = "")
