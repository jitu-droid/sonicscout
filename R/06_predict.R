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
LOW_CONFIDENCE_THRESHOLD <- 0.4  # tunable; see docs/methodology.md for how this was chosen (or TBD if not yet tuned)

#' Predict the top-3 pest/ambient classes for one audio file.
#'
#' @param file_path Path to an audio file (`.opus`, `.ogg`, `.wav`, ...).
#' @param model_path Path to the serialised model bundle from `R/05_train.R`.
#' @param threshold Confidence below which `low_confidence` is set `TRUE`.
#'
#' @return A list: `top_classes` (character, length <= 3, most confident
#'   first), `confidences` (numeric, same length/order), `low_confidence`
#'   (logical), and `all_probabilities` (named numeric vector, every class).
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
  feats <- whatsappaudioR::wa_features(wave)

  missing_cols <- setdiff(bundle$feature_cols, names(feats))
  if (length(missing_cols) > 0) {
    stop("Extracted features are missing columns the model expects: ",
         paste(missing_cols, collapse = ", "),
         " -- was this model trained with a different whatsappaudioR version?")
  }

  prob_matrix <- predict(bundle$model, feats[, bundle$feature_cols, drop = FALSE], type = "prob")
  probs <- prob_matrix[1, ]
  probs <- sort(probs, decreasing = TRUE)

  top_n <- min(3, length(probs))
  top <- probs[seq_len(top_n)]

  list(
    top_classes = names(top),
    confidences = unname(top),
    low_confidence = unname(top[1]) < threshold,
    all_probabilities = probs
  )
}

#' Format a predict_pest() result as the short farmer-facing WhatsApp reply
#' text described in the brief: a confidence score, never a bare alarm, with
#' an explicit low-confidence path.
format_reply <- function(result) {
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
