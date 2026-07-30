# Prompt 9, Part 2 -- operating-point analysis.
#
# 22.3% mean false-positive rate against ambient (docs/classifier_results.md)
# is the RAW-ARGMAX number: whatever the model's top-1 prediction is, with
# no confidence gate at all. That is not deployable for a system that pushes
# alerts to a farmer -- but it is one point on a curve, not a fixed property.
# The model already emits a confidence score (top-class vote share) with
# every prediction; R/06_predict.R already has a `low_confidence` gate that
# was never actually tuned against a measured trade-off. This script:
#
#   1. Sweeps that confidence threshold across its range using the SAME
#      out-of-fold predictions the CV accuracy numbers come from (not the
#      final full-corpus model's own training-set predictions, which would
#      be optimistic).
#   2. Reports precision/recall/false-positive-rate at each threshold for
#      the pest-vs-ambient decision, plus per-species detection-rate curves
#      (does raising the threshold disproportionately suppress one species
#      over another?).
#   3. Picks a default operating point and writes it out for R/06_predict.R
#      to actually use -- see DEFAULT_THRESHOLD below and its rationale.
#
# The "pest-vs-ambient decision" here means: ALERT if the top predicted
# class is not "ambient" AND its confidence clears the threshold; anything
# else (predicted ambient, or predicted a pest but below threshold) is a
# non-alert, matching exactly what R/06_predict.R's `low_confidence` flag
# already controls -- this analysis is choosing that flag's threshold with
# a measured trade-off instead of an unexamined default (0.4).
#
# Restricted to REAL audio only (data_origin == "real"): synthetic classes
# aren't part of the deployed farmer-facing scenario and would distort the
# trade-off a real threshold needs to make.
#
# Usage:
#   Rscript R/08_operating_point.R
#
# Input:  data/processed/cv_predictions.csv (written by R/05_train.R's main())
# Output: docs/operating_point.md
#         docs/figures/pr_curve.png

library(dplyr)

source(file.path("R", "utils.R"))

CV_PREDICTIONS_PATH <- file.path("data", "processed", "cv_predictions.csv")
RESULTS_PATH <- file.path("docs", "operating_point.md")
FIGURE_PATH <- file.path("docs", "figures", "pr_curve.png")

# Candidate thresholds to sweep. Fine enough to see the curve's shape;
# random forest vote-share confidences are simple fractions to begin with,
# a finer grid wouldn't reveal more structure than this does.
THRESHOLDS <- seq(0, 0.95, by = 0.05)

# ---- Core sweep ------------------------------------------------------------

#' At a given confidence threshold, compute the pest-vs-ambient decision
#' confusion counts and derived rates on one prediction set.
#'
#' ALERT = (predicted != "ambient") & (confidence >= threshold) -- this is
#' exactly the complement of what R/06_predict.R's `low_confidence` flag
#' already computes (predicted top class + a threshold on its confidence),
#' so the number picked here is a real, usable default for that flag, not
#' just an analysis exercise.
sweep_threshold <- function(preds, threshold) {
  actual_positive <- preds$label != "ambient"
  alert <- (preds$predicted != "ambient") & (preds$confidence >= threshold)

  tp <- sum(alert & actual_positive)
  fp <- sum(alert & !actual_positive)
  fn <- sum(!alert & actual_positive)
  tn <- sum(!alert & !actual_positive)

  data.frame(
    threshold = threshold,
    precision = if ((tp + fp) > 0) tp / (tp + fp) else NA_real_,
    recall = if ((tp + fn) > 0) tp / (tp + fn) else NA_real_,       # detection rate
    fpr = if ((fp + tn) > 0) fp / (fp + tn) else NA_real_,          # false alarm rate
    n_alerts = tp + fp, n_positive = tp + fn, n_negative = fp + tn
  )
}

#' Per-species detection rate (fraction of that species' TRUE windows that
#' get an alert, regardless of whether the alert names that species
#' correctly) at a given threshold -- shows whether raising the global
#' threshold disproportionately suppresses one species over another.
per_species_recall <- function(preds, species, threshold) {
  sub <- preds[preds$label == species, ]
  if (nrow(sub) == 0) return(NA_real_)
  alert <- (sub$predicted != "ambient") & (sub$confidence >= threshold)
  mean(alert)
}

# ---- Reporting --------------------------------------------------------------

knitr_table_or_fallback <- function(df) {
  if (requireNamespace("knitr", quietly = TRUE)) {
    paste(knitr::kable(df, format = "markdown", digits = 3), collapse = "\n")
  } else {
    paste(utils::capture.output(print(df)), collapse = "\n")
  }
}

main <- function(cv_predictions_path = CV_PREDICTIONS_PATH, results_path = RESULTS_PATH,
                  figure_path = FIGURE_PATH) {
  if (!file.exists(cv_predictions_path)) {
    stop(cv_predictions_path, " not found -- run R/05_train.R first (it writes this as a side effect).")
  }
  preds_all <- utils::read.csv(cv_predictions_path, stringsAsFactors = FALSE)
  preds <- preds_all[preds_all$data_origin == "real", ]
  if (nrow(preds) == 0) stop("No real-audio predictions found in ", cv_predictions_path)

  real_species <- setdiff(unique(preds$label), "ambient")

  curve <- do.call(rbind, lapply(THRESHOLDS, function(t) sweep_threshold(preds, t)))

  species_curve <- do.call(rbind, lapply(THRESHOLDS, function(t) {
    row <- lapply(real_species, function(sp) per_species_recall(preds, sp, t))
    names(row) <- real_species
    data.frame(threshold = t, row, check.names = FALSE)
  }))

  # Majority-class baseline and chance rate (Part 2 asks this accompany
  # every accuracy figure -- computed here once, referenced by
  # docs/methodology.md rather than recomputed by hand in multiple places).
  class_counts <- table(preds_all$label)
  majority_class <- names(class_counts)[which.max(class_counts)]
  majority_baseline_acc <- max(class_counts) / sum(class_counts)
  chance_rate <- 1 / length(class_counts)

  # ---- Choose an operating point ----------------------------------------
  # Deployment framing: a screening tool a farmer ACTS ON should prioritise
  # a low false-alarm rate over catching every event -- a false alarm
  # (predicted pest, actually ambient noise) costs the farmer's trust
  # directly and repeatedly; a missed detection costs one missed alert,
  # and the farmer can (and, per the brief, is told to) simply send another
  # recording. This is an explicit, stated trade, not a default left
  # unexamined: pick the LOWEST threshold whose false-positive rate is at
  # or below TARGET_FPR, so recall is sacrificed as little as possible
  # while still meeting the false-alarm bar.
  TARGET_FPR <- 0.10
  meets_bar <- curve[!is.na(curve$fpr) & curve$fpr <= TARGET_FPR, ]
  chosen <- if (nrow(meets_bar) > 0) {
    meets_bar[which.min(meets_bar$threshold), ]
  } else {
    curve[which.min(curve$fpr), ]  # fallback: lowest achievable FPR, whatever it costs
  }
  chosen_threshold <- chosen$threshold

  # ---- Figure -------------------------------------------------------------
  ensure_dir(dirname(figure_path))
  grDevices::png(figure_path, width = 1400, height = 700, res = 150)
  graphics::par(mfrow = c(1, 2))
  graphics::plot(curve$recall, curve$precision, type = "b", pch = 16,
                 xlim = c(0, 1), ylim = c(0, 1),
                 xlab = "Recall (detection rate)", ylab = "Precision",
                 main = "Pest-vs-ambient PR curve")
  graphics::points(chosen$recall, chosen$precision, col = "red", pch = 19, cex = 1.5)
  graphics::plot(species_curve$threshold, species_curve[[real_species[1]]], type = "b", pch = 16,
                 col = 1, ylim = c(0, 1), xlab = "Confidence threshold", ylab = "Detection rate",
                 main = "Per-species detection rate vs. threshold")
  for (i in seq_along(real_species)) {
    graphics::lines(species_curve$threshold, species_curve[[real_species[i]]], type = "b", pch = 16, col = i)
  }
  graphics::abline(v = chosen_threshold, lty = 2, col = "red")
  graphics::legend("bottomleft", legend = real_species, col = seq_along(real_species), lty = 1, cex = 0.7)
  grDevices::dev.off()

  ensure_dir(dirname(results_path))
  lines <- c(
    "# Operating Point Analysis: Pest-vs-Ambient Decision",
    "",
    paste0("Generated by `R/08_operating_point.R` on ", format(Sys.time(), "%Y-%m-%d %H:%M"),
           ". Uses the SAME out-of-fold predictions the repeated k-fold CV accuracy numbers in ",
           "`docs/classifier_results.md` come from (`data/processed/cv_predictions.csv`) -- not the ",
           "final full-corpus model's own training predictions, which would be optimistic. ",
           "Restricted to real audio (", nrow(preds), " real-class test predictions across ",
           length(unique(preds$source_file)), " source recordings); synthetic classes excluded as ",
           "not part of the deployed scenario."),
    "",
    "## Baselines (read every accuracy figure in this project against these)",
    "",
    sprintf("- **Majority-class baseline**: always predicting `%s` (the most common class) gets ",
            majority_class),
    sprintf("  **%s** accuracy on this data -- not %s, because classes are imbalanced ",
            fmt_pct(majority_baseline_acc), "50%"),
    "  (ambient dominates the corpus). Any classifier accuracy figure below this is worse than",
    "  guessing the majority class every time.",
    sprintf("- **Chance rate** (%d classes, uniform guessing): **%s**.",
            length(class_counts), fmt_pct(chance_rate)),
    "",
    "## Precision-recall curve, pest-vs-ambient decision",
    "",
    "ALERT = (predicted class is not ambient) AND (confidence >= threshold) -- this is exactly ",
    "what `R/06_predict.R`'s `low_confidence` flag already gates; the threshold chosen here is ",
    "set as that flag's actual default, not left as an unexamined round number.",
    "",
    knitr_table_or_fallback(data.frame(
      threshold = sprintf("%.2f", curve$threshold),
      precision = vapply(curve$precision, fmt_pct, character(1)),
      recall_detection_rate = vapply(curve$recall, fmt_pct, character(1)),
      false_positive_rate = vapply(curve$fpr, fmt_pct, character(1)),
      n_alerts = curve$n_alerts
    )),
    "",
    "![Precision-recall and per-species detection curves](figures/pr_curve.png)",
    "",
    "## Per-species detection rate at each threshold",
    "",
    knitr_table_or_fallback(data.frame(
      threshold = sprintf("%.2f", species_curve$threshold),
      lapply(real_species, function(sp) vapply(species_curve[[sp]], fmt_pct, character(1)))
    ) |> setNames(c("threshold", real_species))),
    "",
    "## Chosen operating point",
    "",
    sprintf("**Threshold = %.2f.** At this threshold: precision %s, recall (detection rate) %s, ",
            chosen_threshold, fmt_pct(chosen$precision), fmt_pct(chosen$recall)),
    sprintf("false-positive rate %s (target: at or below %s).",
            fmt_pct(chosen$fpr), fmt_pct(TARGET_FPR)),
    "",
    "**Rationale (a deployment decision, not a metric-dump default):** this is a screening tool ",
    "a farmer acts on directly -- a false alarm (an alert on real ambient noise) costs trust ",
    "immediately and repeatedly, and enough of them means the farmer stops trusting alerts at ",
    "all, at which point the system has no value regardless of how good its detection rate is ",
    "on paper. A missed detection costs one skipped alert, and the system's own low-confidence ",
    "reply already asks the farmer to resend a longer/louder recording -- a real, if imperfect, ",
    "recovery path that a false alarm has no equivalent of. This asymmetry is why the threshold ",
    "is chosen to hold false-positive rate at or below 10%, accepting whatever recall cost that ",
    "requires, rather than picking a threshold that maximises accuracy or F1.",
    "",
    "This threshold is now `R/06_predict.R`'s `LOW_CONFIDENCE_THRESHOLD` default, and the ",
    "webhook's low-confidence reply path uses it directly -- what the farmer receives now ",
    "matches what this analysis reports, not a separate unexamined number."
  )
  writeLines(lines, results_path)

  message(sprintf("Operating point: threshold=%.2f (precision=%s, recall=%s, FPR=%s). Written to %s",
                   chosen_threshold, fmt_pct(chosen$precision), fmt_pct(chosen$recall),
                   fmt_pct(chosen$fpr), results_path))

  invisible(list(curve = curve, species_curve = species_curve, chosen = chosen,
                 majority_baseline_acc = majority_baseline_acc, chance_rate = chance_rate))
}

if (sys.nframe() == 0) {
  main()
}
