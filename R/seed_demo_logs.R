# Deliverable F support -- seed logs/requests.jsonl + logs/audio/ with a
# handful of real predictions on the synthetic corpus, so the Shiny
# dashboard's replay mode has something to show without a live Twilio
# connection. Every entry here is a REAL predict_pest() output on real
# (synthetic) audio -- not fabricated numbers.
#
# Usage:
#   Rscript R/seed_demo_logs.R

library(whatsappaudioR)

source(file.path("R", "utils.R"))
source(file.path("R", "06_predict.R"))

REQUEST_LOG_PATH  <- file.path("logs", "requests.jsonl")
REQUEST_AUDIO_DIR <- file.path("logs", "audio")
SYNTHETIC_DIR     <- file.path("data", "codec_experiment", "reference")

main <- function(n_per_species = 1) {
  if (!file.exists(MODEL_PATH)) {
    stop("No trained model at ", MODEL_PATH, " -- run R/05_train.R first.")
  }

  species_dirs <- list.dirs(SYNTHETIC_DIR, recursive = FALSE)
  ensure_dir(REQUEST_AUDIO_DIR)
  n_seeded <- 0

  for (d in species_dirs) {
    files <- utils::head(list.files(d, pattern = "\\.wav$", full.names = TRUE), n_per_species)
    for (f in files) {
      result <- tryCatch(predict_pest(f), error = function(e) {
        message("Skipping ", f, ": ", conditionMessage(e))
        NULL
      })
      if (is.null(result)) next

      audio_hash <- unname(tools::md5sum(f))
      archived_path <- file.path(REQUEST_AUDIO_DIR, paste0(audio_hash, ".wav"))
      file.copy(f, archived_path, overwrite = TRUE)

      w <- tuneR::readWave(f)
      log_event(REQUEST_LOG_PATH,
                from = "demo-seed",
                outcome = if (isTRUE(result$low_confidence)) "low_confidence" else "predicted",
                audio_hash = audio_hash, audio_path = archived_path,
                duration_s = length(w@left) / w@samp.rate,
                top_classes = paste(result$top_classes, collapse = "|"),
                confidences = paste(round(result$confidences, 3), collapse = "|"))
      n_seeded <- n_seeded + 1
    }
  }

  message("Seeded ", n_seeded, " demo log entries into ", REQUEST_LOG_PATH)
  invisible(n_seeded)
}

if (sys.nframe() == 0) {
  main()
}
