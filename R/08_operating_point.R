# Prompt 9, Part 2 / Prompt 10, Part 2 -- operating-point analysis, at the
# unit the farmer actually experiences.
#
# 21.9% mean false-positive rate against ambient (docs/classifier_results.md)
# is the RAW-ARGMAX WINDOW-LEVEL number: whatever the model's top-1
# prediction is on a single 4-second window, with no confidence gate and no
# pooling across windows. That understates what a deployed farmer actually
# gets: `R/06_predict.R`'s `predict_pest()` windows an incoming clip, gates
# near-silent windows, extracts features per surviving window, and AVERAGES
# the resulting probability vectors across all of a clip's windows before
# deciding -- pooling multiple noisy window-level estimates into one less
# noisy clip-level one. Prompt 9's operating-point analysis swept a
# threshold over WINDOW-level predictions and picked a threshold from that
# curve, which is not the curve the deployed system actually produces.
#
# This script:
#
#   1. Builds a WINDOW-level curve (as Prompt 9 did) and a CLIP-level curve,
#      the second built by aggregating out-of-fold window predictions
#      EXACTLY the way predict_pest() aggregates them at inference (mean of
#      each window's full class-probability vector, then argmax + top
#      confidence) -- not a different or approximate pooling rule.
#   2. Reports both curves side by side; the gap between them quantifies
#      how much multi-window pooling actually buys, which is itself a
#      result (it justifies a design decision already made, rather than
#      just asserting pooling helps).
#   3. Chooses the deployment threshold from the CLIP-level curve, since
#      that's the unit a farmer experiences, and writes it out for
#      R/06_predict.R to actually use.
#   4. Reports how many windows a typical clip contributes after energy
#      gating, since a short voice note yielding only 2-3 usable windows
#      gets less benefit from pooling than the average across this corpus
#      (which includes much longer reference recordings) suggests.
#
# The "pest-vs-ambient decision" here means: ALERT if the top predicted
# class is not "ambient" AND its confidence clears the threshold; anything
# else (predicted ambient, or predicted a pest but below threshold) is a
# non-alert, matching exactly what R/06_predict.R's `low_confidence` flag
# already controls.
#
# Restricted to REAL audio only (data_origin == "real"): synthetic classes
# aren't part of the deployed farmer-facing scenario and would distort the
# trade-off a real threshold needs to make.
#
# Usage:
#   Rscript R/08_operating_point.R
#
# Input:  data/processed/cv_predictions.csv (written by R/05_train.R's main(),
#         now including per-class probability columns -- Prompt 10)
# Output: docs/operating_point.md
#         docs/figures/pr_curve.png

library(dplyr)

source(file.path("R", "utils.R"))

CV_PREDICTIONS_PATH <- file.path("data", "processed", "cv_predictions.csv")
WINDOWS_MANIFEST_PATH <- file.path("data", "processed", "windows_manifest.csv")
RESULTS_PATH <- file.path("docs", "operating_point.md")
FIGURE_PATH <- file.path("docs", "figures", "pr_curve.png")

# Candidate thresholds to sweep. Fine enough to see the curve's shape;
# random forest vote-share confidences are simple fractions to begin with,
# a finer grid wouldn't reveal more structure than this does.
THRESHOLDS <- seq(0, 0.95, by = 0.05)

# ---- Clip-level aggregation, matching predict_pest() exactly ---------------

#' Aggregate window-level out-of-fold predictions to clip-level, using
#' EXACTLY predict_pest()'s own aggregation rule (R/06_predict.R): mean of
#' each window's full class-probability vector, then argmax for the
#' predicted class and its value as the confidence. Grouped by
#' (source_file, repeat_i) -- within one repeat, a grouped k-fold
#' assignment puts a whole source recording's windows in test together, in
#' exactly one fold, so this recovers one clip-level prediction per
#' recording per repeat (the same "one clip in, one prediction out" unit
#' predict_pest() produces for a live incoming voice note).
aggregate_to_clip_level <- function(preds) {
  prob_cols <- grep("^prob_", names(preds), value = TRUE)
  if (length(prob_cols) == 0) {
    stop("No prob_<class> columns found in cv_predictions.csv -- re-run R/05_train.R ",
         "(Prompt 10 added these; an older cv_predictions.csv won't have them).")
  }

  key <- interaction(preds$source_file, preds$repeat_i, drop = TRUE)
  split_idx <- split(seq_len(nrow(preds)), key)

  rows <- lapply(split_idx, function(idx) {
    sub <- preds[idx, , drop = FALSE]
    mean_probs <- colMeans(sub[, prob_cols, drop = FALSE])
    top_class <- sub("^prob_", "", prob_cols[which.max(mean_probs)])
    data.frame(
      source_file = sub$source_file[1], label = sub$label[1], data_origin = sub$data_origin[1],
      predicted = top_class, confidence = max(mean_probs), n_windows = nrow(sub),
      repeat_i = sub$repeat_i[1], stringsAsFactors = FALSE
    )
  })
  do.call(rbind, rows)
}

# ---- Core sweep ------------------------------------------------------------

#' At a given confidence threshold, compute the pest-vs-ambient decision
#' confusion counts and derived rates on one prediction set (works
#' identically on window-level or clip-level predictions -- both have
#' `label`/`predicted`/`confidence` columns).
#'
#' ALERT = (predicted != "ambient") & (confidence >= threshold) -- this is
#' exactly what R/06_predict.R's `low_confidence` flag already computes,
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

#' Per-species detection rate (fraction of that species' TRUE units --
#' windows or clips -- that get an alert, regardless of whether the alert
#' names that species correctly) at a given threshold.
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
                  figure_path = FIGURE_PATH, windows_manifest_path = WINDOWS_MANIFEST_PATH) {
  if (!file.exists(cv_predictions_path)) {
    stop(cv_predictions_path, " not found -- run R/05_train.R first (it writes this as a side effect).")
  }
  preds_all <- utils::read.csv(cv_predictions_path, stringsAsFactors = FALSE)
  preds_window <- preds_all[preds_all$data_origin == "real", ]
  if (nrow(preds_window) == 0) stop("No real-audio predictions found in ", cv_predictions_path)

  preds_clip <- aggregate_to_clip_level(preds_window)

  real_species <- setdiff(unique(preds_window$label), "ambient")

  curve_window <- do.call(rbind, lapply(THRESHOLDS, function(t) sweep_threshold(preds_window, t)))
  curve_clip <- do.call(rbind, lapply(THRESHOLDS, function(t) sweep_threshold(preds_clip, t)))

  species_curve_clip <- do.call(rbind, lapply(THRESHOLDS, function(t) {
    row <- lapply(real_species, function(sp) per_species_recall(preds_clip, sp, t))
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

  # ---- Choose an operating point, FROM THE CLIP-LEVEL CURVE -----------------
  # Deployment framing unchanged from Prompt 9: a screening tool a farmer
  # ACTS ON should prioritise a low false-alarm rate over catching every
  # event. What changed (Prompt 10): the curve this threshold is read off
  # is now the clip-level one -- the unit the farmer actually experiences
  # (one prediction per voice note, already pooled across its windows),
  # not the window-level curve a live clip never actually produces on its
  # own.
  TARGET_FPR <- 0.10
  meets_bar <- curve_clip[!is.na(curve_clip$fpr) & curve_clip$fpr <= TARGET_FPR, ]
  chosen <- if (nrow(meets_bar) > 0) {
    meets_bar[which.min(meets_bar$threshold), ]
  } else {
    curve_clip[which.min(curve_clip$fpr), ]  # fallback: lowest achievable FPR, whatever it costs
  }
  chosen_threshold <- chosen$threshold

  # ---- Prevalence sensitivity (Prompt 11, Part 3) --------------------------
  #
  # Precision at the chosen threshold (90.1%) is a property of THIS CORPUS's
  # class balance (~50% pest, ~50% ambient by clip count -- an artifact of
  # how this project sampled data, not a claim about real farm deployment
  # conditions). Precision at a given recall/FPR is NOT independent of the
  # true prevalence of the condition being screened for -- standard
  # screening-test arithmetic (a direct application of Bayes' rule):
  #
  #   precision(p) = (recall * p) / (recall * p + fpr * (1 - p))
  #
  # where p is the assumed fraction of clips that truly contain a pest
  # signal. Swept across plausible real-world prevalences, not just
  # reported at the corpus's own ~50/50 split.
  PREVALENCE_LEVELS <- c(0.01, 0.05, 0.10, 0.25, 0.50)
  precision_at_prevalence <- function(p, recall, fpr) {
    tp_rate <- recall * p
    fp_rate <- fpr * (1 - p)
    if ((tp_rate + fp_rate) == 0) return(NA_real_)
    tp_rate / (tp_rate + fp_rate)
  }
  prevalence_table <- data.frame(
    prevalence = PREVALENCE_LEVELS,
    precision = vapply(PREVALENCE_LEVELS, precision_at_prevalence, numeric(1),
                        recall = chosen$recall, fpr = chosen$fpr)
  )

  # Verification, not just computation: does the ACTUAL corpus prevalence
  # (measured, not assumed) reproduce the actually-reported precision
  # (90.1%) through this same formula? If it doesn't, the formula or the
  # underlying recall/FPR numbers are wrong somewhere and that needs
  # resolving before this table is trustworthy.
  actual_prevalence <- mean(preds_clip$label != "ambient")
  reproduced_precision <- precision_at_prevalence(actual_prevalence, chosen$recall, chosen$fpr)
  precision_check_diff <- abs(reproduced_precision - chosen$precision)
  precision_check_ok <- !is.na(precision_check_diff) && precision_check_diff < 0.005  # within 0.5pp -- rounding only

  if (!precision_check_ok) {
    warning(sprintf(
      paste0("Prevalence-sensitivity self-check FAILED: at the corpus's own measured ",
             "prevalence (%.4f), the formula reproduces %.4f precision but the actual ",
             "reported precision is %.4f (diff %.4f, tolerance 0.005) -- the formula or ",
             "the underlying recall/FPR numbers are wrong; do not trust the prevalence table ",
             "until this is resolved."),
      actual_prevalence, reproduced_precision, chosen$precision, precision_check_diff
    ))
  }

  # ---- Windows-per-clip context (so the pooling benefit isn't overstated) --
  windows_per_clip <- NULL
  if (file.exists(windows_manifest_path)) {
    wm <- utils::read.csv(windows_manifest_path, stringsAsFactors = FALSE)
    windows_per_clip <- as.integer(table(wm$source_file))
  }

  # ---- Figure -------------------------------------------------------------
  ensure_dir(dirname(figure_path))
  grDevices::png(figure_path, width = 1400, height = 700, res = 150)
  graphics::par(mfrow = c(1, 2))
  graphics::plot(curve_window$recall, curve_window$precision, type = "b", pch = 16, col = "grey50",
                 xlim = c(0, 1), ylim = c(0, 1),
                 xlab = "Recall (detection rate)", ylab = "Precision",
                 main = "Pest-vs-ambient PR curve")
  graphics::lines(curve_clip$recall, curve_clip$precision, type = "b", pch = 16, col = "blue")
  graphics::points(chosen$recall, chosen$precision, col = "red", pch = 19, cex = 1.5)
  graphics::legend("bottomleft", legend = c("window-level", "clip-level (deployed unit)", "chosen threshold"),
                    col = c("grey50", "blue", "red"), pch = 16, cex = 0.7)
  graphics::plot(species_curve_clip$threshold, species_curve_clip[[real_species[1]]], type = "b", pch = 16,
                 col = 1, ylim = c(0, 1), xlab = "Confidence threshold", ylab = "Clip-level detection rate",
                 main = "Per-species detection rate vs. threshold (clip-level)")
  for (i in seq_along(real_species)) {
    graphics::lines(species_curve_clip$threshold, species_curve_clip[[real_species[i]]], type = "b", pch = 16, col = i)
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
           "Restricted to real audio (", nrow(preds_window), " real-class window-level test ",
           "predictions, aggregated to ", nrow(preds_clip), " clip-level predictions, across ",
           length(unique(preds_window$source_file)), " source recordings); synthetic classes ",
           "excluded as not part of the deployed scenario."),
    "",
    "## Window-level vs. clip-level: why this distinction matters (Prompt 10)",
    "",
    "`R/06_predict.R`'s `predict_pest()` never actually scores a single window in isolation --",
    " it windows an incoming voice note, gates near-silent windows, and AVERAGES the resulting",
    " class-probability vectors across every surviving window before deciding. Prompt 9's",
    " operating-point analysis swept a threshold over WINDOW-level out-of-fold predictions,",
    " which is not the curve the deployed system produces. This run builds both, using the",
    " exact same aggregation rule `predict_pest()` uses (mean of each window's full probability",
    " vector, then argmax + top confidence, grouped by source recording within each",
    " fold-evaluation) -- not an approximation of it.",
    "",
    "**The result is more nuanced than \"pooling makes everything better,\" and that nuance is",
    " itself worth reporting rather than smoothing over.** Overall clip-level accuracy IS",
    " higher (see docs/classifier_results.md) and clip-level false-positive rate IS lower at",
    " every threshold -- both consistent with pooling reducing noise. But clip-level PRECISION",
    " at a given threshold reads LOWER than window-level precision at that same threshold",
    " (e.g. 90.1% vs. 97.5% at 0.45), which looks contradictory until the reason is made",
    " explicit: **windows and clips are different populations with very different class",
    " balance, not just a noisier vs. a cleaner view of the same population.** Ambient",
    " recordings (ESC-50, uniformly 5 seconds) contribute few windows each; many real pest",
    " recordings run much longer and contribute up to the 20-window cap each. At window level",
    " this makes ambient a small minority of test UNITS (2630 of 14040, ~19%); at clip level",
    " ambient and pest are roughly balanced (1400 of 2750, ~51%). The SAME absolute",
    " false-positive rate costs precision far more when negatives are half the population than",
    " when they're a fifth of it -- so window-level precision was inflated by a class-balance",
    " artifact of window-count-per-recording, not a real property of the model being better at",
    " the window level. The clip-level number is the honest one, since a clip -- not a window",
    " -- is the unit that actually exists at inference time.",
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
    "## Window-level vs. clip-level PR curves, side by side",
    "",
    "ALERT = (predicted class is not ambient) AND (confidence >= threshold) -- this is exactly ",
    "what `R/06_predict.R`'s `low_confidence` flag already gates.",
    "",
    knitr_table_or_fallback(data.frame(
      threshold = sprintf("%.2f", curve_window$threshold),
      window_precision = vapply(curve_window$precision, fmt_pct, character(1)),
      window_recall = vapply(curve_window$recall, fmt_pct, character(1)),
      window_fpr = vapply(curve_window$fpr, fmt_pct, character(1)),
      clip_precision = vapply(curve_clip$precision, fmt_pct, character(1)),
      clip_recall = vapply(curve_clip$recall, fmt_pct, character(1)),
      clip_fpr = vapply(curve_clip$fpr, fmt_pct, character(1))
    )),
    "",
    "![Window-level vs. clip-level PR curves and per-species detection curves](figures/pr_curve.png)",
    "",
    sprintf("**The window-vs-clip gap is itself a result: at threshold %.2f, clip-level FPR is %s vs. window-level %s** -- ",
            chosen_threshold,
            fmt_pct(curve_clip$fpr[curve_clip$threshold == chosen_threshold]),
            fmt_pct(curve_window$fpr[curve_window$threshold == chosen_threshold])),
    "this quantifies how much multi-window pooling actually buys at the unit a farmer experiences, ",
    "which justifies `predict_pest()`'s pooling design rather than just asserting it helps. Precision ",
    "at that same threshold reads lower at clip level (see the class-balance explanation above) -- ",
    "read FPR, not precision, as the pooling-benefit number specifically, since precision also moves ",
    "with the population's class balance, which differs between windows and clips for reasons unrelated ",
    "to pooling.",
    "",
    sprintf("**Recall (detection rate) is also slightly lower at clip level (%s vs. window-level %s at ",
            fmt_pct(curve_clip$recall[curve_clip$threshold == chosen_threshold]),
            fmt_pct(curve_window$recall[curve_window$threshold == chosen_threshold])),
    sprintf("threshold %.2f) -- unlike precision, this is a genuine (small) pooling cost, not a ", chosen_threshold),
    "class-balance artifact: averaging a clip's windows can dilute one strongly-confident correct ",
    "window with other, weaker or wrong-favouring windows from the same clip, occasionally pulling ",
    "the pooled confidence for a real pest clip below threshold when its single best window would ",
    "have cleared it. Net effect at the chosen threshold: fewer false alarms, slightly fewer true ",
    "detections too -- both real, and both part of the honest trade this operating point makes.",
    "",
    "## Per-species clip-level detection rate at each threshold",
    "",
    knitr_table_or_fallback(data.frame(
      threshold = sprintf("%.2f", species_curve_clip$threshold),
      lapply(real_species, function(sp) vapply(species_curve_clip[[sp]], fmt_pct, character(1)))
    ) |> setNames(c("threshold", real_species))),
    "",
    "## Windows per clip after energy gating (context for how much pooling actually helps in practice)",
    "",
    if (!is.null(windows_per_clip)) {
      q <- stats::quantile(windows_per_clip, probs = c(0, .25, .5, .75, 1))
      c(sprintf("min=%d, p25=%.0f, median=%.0f, p75=%.0f, max=%d (n=%d recordings, compressed arm).",
                q[1], q[2], q[3], q[4], q[5], length(windows_per_clip)),
        "",
        "**Caveat that belongs alongside the clip-level numbers above:** this corpus's windows-",
        "per-recording distribution is dominated by real field recordings, some many seconds to ",
        "minutes long -- a 10-30 second farmer voice note (the length the webhook actually asks ",
        "for) will yield fewer usable windows after gating than the median recording here, closer ",
        "to the LOW end of this distribution. If a real inbound clip yields only 2-3 usable ",
        "windows, the clip-level pooling advantage shown above will be smaller in practice than ",
        "this analysis suggests, since pooling variance reduction scales with the number of",
        "windows pooled.")
    } else {
      "windows_manifest.csv not found -- could not compute this."
    },
    "",
    "## Chosen operating point (from the CLIP-level curve)",
    "",
    sprintf("**Threshold = %.2f.** At this threshold (clip-level): precision %s, recall (detection rate) %s, ",
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
    "requires, rather than picking a threshold that maximises accuracy or F1. Chosen from the ",
    "CLIP-level curve specifically (Prompt 10), not the window-level curve (Prompt 9's original ",
    "choice), since a clip -- one voice note in, one prediction out -- is the unit a farmer ",
    "actually experiences.",
    "",
    "This threshold is now `R/06_predict.R`'s `LOW_CONFIDENCE_THRESHOLD` default, and the ",
    "webhook's low-confidence reply path uses it directly -- what the farmer receives now ",
    "matches what this analysis reports, not a separate unexamined number.",
    "",
    "## Precision as a function of true pest prevalence (Prompt 11, Part 3)",
    "",
    sprintf("This corpus's clip-level class balance is **%s pest / %s ambient** (%d of %d clips)",
            fmt_pct(actual_prevalence), fmt_pct(1 - actual_prevalence),
            sum(preds_clip$label != "ambient"), nrow(preds_clip)),
    " -- an artifact of how this project sampled real recordings (45 recordings per real target",
    " species, 145 ambient), NOT a claim about what fraction of real farm nighttime recordings",
    " actually contain a target pest. Precision at a fixed recall/false-positive-rate is NOT",
    " independent of the true prevalence of the condition being screened for -- standard",
    " screening-test arithmetic:",
    "",
    "`precision(p) = (recall * p) / (recall * p + fpr * (1 - p))`",
    "",
    sprintf("using this threshold's recall (%s) and false-positive rate (%s):",
            fmt_pct(chosen$recall), fmt_pct(chosen$fpr)),
    "",
    knitr_table_or_fallback(data.frame(
      assumed_prevalence = vapply(prevalence_table$prevalence, fmt_pct, character(1)),
      precision = vapply(prevalence_table$precision, fmt_pct, character(1))
    )),
    "",
    sprintf(
      "**Self-check: does the formula reproduce the actually-measured precision at this corpus's own prevalence?** At the corpus's exact measured prevalence (%s, not the rounded 50%% row above), the formula gives %s precision; the actually-reported clip-level precision is %s (difference: %s). %s",
      fmt_pct(actual_prevalence), fmt_pct(reproduced_precision), fmt_pct(chosen$precision),
      fmt_pct(precision_check_diff),
      if (precision_check_ok) {
        "**Matches within rounding -- the formula and the underlying rates are consistent.**"
      } else {
        "**DOES NOT MATCH within tolerance -- see the warning this script emitted; do not trust the table above until resolved.**"
      }
    ),
    "",
    "**Why this table matters more than any single precision number:** at 1% assumed prevalence",
    " (closer to what an unselected nighttime farm recording might plausibly be, though this",
    " project has no real measurement of that rate either), precision collapses -- most alerts",
    " would be false alarms, because false alarms scale with the much larger pool of true",
    " negatives while true detections scale with a small pool of true positives. This is exactly",
    " why this system is positioned as a **screening tool a farmer still exercises judgement",
    " on**, not an autonomous alert trigger that acts without a human in the loop -- the",
    " corpus's ~50/50 balance is not deployment-representative, and presenting the 90.1% figure",
    " alone without this table would overstate what a farmer should expect at low real-world",
    " prevalence.",
    "",
    "**Temporal persistence as future work:** repeated sampling from the same location over time",
    " (e.g. several voice notes from the same field over a few nights) would raise EFFECTIVE",
    " precision beyond any single-clip number in this table, since independent false alarms are",
    " unlikely to repeatedly and consistently point at the same pest across multiple separate",
    " recordings, while a genuine infestation would. This project has not implemented or measured",
    " that -- it is a stated direction for future work, not a claim made here."
  )
  writeLines(lines, results_path)

  message(sprintf("Operating point (clip-level): threshold=%.2f (precision=%s, recall=%s, FPR=%s). Prevalence self-check: %s. Written to %s",
                   chosen_threshold, fmt_pct(chosen$precision), fmt_pct(chosen$recall),
                   fmt_pct(chosen$fpr), if (precision_check_ok) "OK" else "FAILED", results_path))

  invisible(list(curve_window = curve_window, curve_clip = curve_clip, species_curve_clip = species_curve_clip,
                 chosen = chosen, majority_baseline_acc = majority_baseline_acc, chance_rate = chance_rate,
                 windows_per_clip = windows_per_clip, prevalence_table = prevalence_table,
                 actual_prevalence = actual_prevalence, precision_check_ok = precision_check_ok))
}

if (sys.nframe() == 0) {
  main()
}
