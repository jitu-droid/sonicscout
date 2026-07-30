# Deliverable D -- single entry point for prediction.
#
# Takes a path to an audio file (any format wa_read() supports), returns the
# top-3 candidate classes with their probabilities and an explicit
# low_confidence flag. Kept as one small, independently-callable function so
# the Twilio webhook (Deliverable E) and the Shiny dashboard (Deliverable F)
# can both call it directly rather than duplicating prediction logic.
#
# Usage (CLI):
#   Rscript R/06_predict.R path/to/voice_note.opus
#
# Usage (from R):
#   source("R/06_predict.R"); predict_pest("path/to/voice_note.opus")

library(whatsappaudioR)
library(randomForest)
library(jsonlite)

# WORKAROUND: when this file is source()'d from api/plumber.R, the working
# directory is plumber's "api/" cwd -- confirmed to hold not just at parse
# time but during actual request handling too (see BLOCKERS.md). Compute an
# absolute repo root once, and anchor every path (utils.R, the model file)
# to it, rather than using plain relative paths that would break depending
# on which context this file is loaded/called from.
.repo_root <- normalizePath(
  if (file.exists(file.path("R", "utils.R"))) "." else ".."
)

if (!exists("ensure_dir", mode = "function")) {
  source(file.path(.repo_root, "R", "utils.R"))
}

MODEL_PATH <- file.path(.repo_root, "models", "classifier.rds")

# LOW_CONFIDENCE_THRESHOLD: set from a measured precision/recall/false-
# positive-rate sweep (R/08_operating_point.R, docs/operating_point.md),
# not left as an unexamined round number. Chosen from the CLIP-level curve
# (Prompt 10, Part 2) -- the unit a farmer actually experiences (one voice
# note in, one pooled prediction out, exactly what predict_pest() below
# produces), not the window-level curve Prompt 9 originally used. At 0.45:
# 90.1% precision, 72.7% recall (detection rate), 7.7% false-positive rate
# against real ambient audio -- chosen as the lowest threshold whose
# false-positive rate clears a 10% deployment bar. Rationale: a screening
# tool a farmer acts on directly loses more value from repeated false
# alarms (which destroy trust in the alert) than from a missed detection
# (for which the low-confidence path below already offers a recovery: ask
# for a longer/louder recording). See docs/operating_point.md for the full
# threshold-sweep table (window-level AND clip-level, side by side) and
# the trade stated explicitly.
LOW_CONFIDENCE_THRESHOLD <- 0.45

#' Predict the top-3 pest/ambient classes for one audio file.
#'
#' Windows and energy-gates the incoming clip exactly as R/03_preprocess.R
#' does for training data (same WINDOW_SECONDS/HOP_SECONDS/ENERGY_GATE_DB,
#' R/utils.R) -- deliberately NOT a single feature vector over the whole
#' clip. Before Prompt 7 this function extracted one feature vector from the
#' entire incoming recording, while training extracted one per 2-second
#' window; a long recording with quiet gaps would dilute that single
#' whole-clip vector with content the training pipeline would have gated
#' out, a train/serve mismatch nobody had checked for. Predictions from
#' surviving windows are averaged (mean of each window's class-probability
#' vector) into one final call.
#'
#' @param file_path Path to an audio file (`.opus`, `.ogg`, `.wav`, ...).
#' @param model_path Path to the serialised model bundle from `R/05_train.R`.
#' @param threshold Confidence below which `low_confidence` is set `TRUE`.
#'
#' @return A list: `top_classes` (character, length <= 3, most confident
#'   first; length 0 if the whole clip was gated as silent), `confidences`
#'   (numeric, same length/order), `low_confidence` (logical, always TRUE
#'   when gated), `gated_silent` (logical -- TRUE means every window in the
#'   clip was below the energy gate, i.e. no predictable content at all, as
#'   distinct from an ordinary low-confidence call on real content),
#'   `n_windows_used`/`n_windows_total` (gate bookkeeping), and
#'   `all_probabilities` (named numeric vector, every class; length 0 if
#'   gated).
#'
#' NOTE ON "confidences": these are random forest vote proportions
#' (fraction of trees voting for each class), not formally calibrated
#' (e.g. Platt-scaled / isotonic) probabilities. They are a reasonable
#' confidence proxy but should not be read as literal well-calibrated
#' probabilities -- see docs/methodology.md limitations.
predict_pest <- function(file_path, model_path = MODEL_PATH, threshold = LOW_CONFIDENCE_THRESHOLD) {
  if (!file.exists(model_path)) {
    stop("No trained model found at ", model_path, " -- run R/05_train.R first.")
  }
  bundle <- readRDS(model_path)

  wave <- whatsappaudioR::wa_read(file_path)
  trimmed <- trim_silence(wave@left, wave@samp.rate)
  windows <- window_signal(trimmed, wave@samp.rate)
  keep <- gate_silent_windows(windows)
  n_total <- length(windows)
  n_used <- sum(keep)

  if (n_used == 0) {
    return(list(
      top_classes = character(0), confidences = numeric(0),
      low_confidence = TRUE, gated_silent = TRUE,
      n_windows_used = 0L, n_windows_total = n_total,
      all_probabilities = stats::setNames(numeric(0), character(0))
    ))
  }

  prob_rows <- lapply(windows[keep], function(w) {
    win_wave <- tuneR::Wave(left = as.integer(w), samp.rate = wave@samp.rate, bit = 16)
    feats <- whatsappaudioR::wa_features(win_wave)

    missing_cols <- setdiff(bundle$feature_cols, names(feats))
    if (length(missing_cols) > 0) {
      stop("Extracted features are missing columns the model expects: ",
           paste(missing_cols, collapse = ", "),
           " -- was this model trained with a different whatsappaudioR version?")
    }
    predict(bundle$model, feats[, bundle$feature_cols, drop = FALSE], type = "prob")[1, ]
  })

  probs <- colMeans(do.call(rbind, prob_rows))
  probs <- sort(probs, decreasing = TRUE)

  top_n <- min(3, length(probs))
  top <- probs[seq_len(top_n)]

  list(
    top_classes = names(top),
    confidences = unname(top),
    low_confidence = unname(top[1]) < threshold,
    gated_silent = FALSE,
    n_windows_used = n_used, n_windows_total = n_total,
    all_probabilities = probs
  )
}

#' Format a predict_pest() result as the short farmer-facing WhatsApp reply
#' text described in the brief: a confidence score, never a bare alarm, with
#' an explicit low-confidence path.
format_reply <- function(result) {
  if (isTRUE(result$gated_silent)) {
    return(paste0(
      "That recording was too quiet for us to find any signal in it. ",
      "Please resend a louder or longer recording (15-30s) from closer to the source."
    ))
  }
  if (isTRUE(result$low_confidence)) {
    return(paste0(
      "No confident match (top guess: ", result$top_classes[1], " at ",
      round(result$confidences[1] * 100, 0), "%). ",
      "Please resend a longer recording (15-30s) from closer to the source."
    ))
  }
  sprintf("%d%% match -- %s", round(result$confidences[1] * 100, 0), result$top_classes[1])
}

main_cli <- function() {
  cli_args <- commandArgs(trailingOnly = TRUE)
  if (length(cli_args) < 1) {
    stop("Usage: Rscript R/06_predict.R <path-to-audio-file>")
  }
  result <- predict_pest(cli_args[1])
  cat(jsonlite::toJSON(result[c("top_classes", "confidences", "low_confidence")],
                        auto_unbox = FALSE, pretty = TRUE), "\n")
  cat(format_reply(result), "\n")
}

if (sys.nframe() == 0) {
  main_cli()
}
