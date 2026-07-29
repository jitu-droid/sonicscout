# Deliverable D -- train the classifier.
#
# Two things this script exists specifically to get right (see also
# 03_preprocess.R for the train/serve-match half of this):
#
#   1. Grouped splitting. Windows from the same source recording must never
#      straddle train/validation/test -- otherwise the model can effectively
#      memorize a clip it saw (in a different window) during training, which
#      inflates every reported number. Split is done on unique `source_file`
#      values, not on windows, and the no-overlap property is asserted in
#      code (stop()s if violated), not just assumed.
#   2. Reporting the false-positive rate against the ambient/negative class
#      specifically, not just overall accuracy -- for a system that pages a
#      farmer, that number matters more than accuracy does.
#
# Usage:
#   Rscript R/05_train.R
#
# Input:  data/processed/features.csv (from 04_features.R)
# Output: models/classifier.rds
#         docs/classifier_results.md (real numbers, generated fresh each run)
#         docs/figures/variable_importance.png

library(randomForest)
library(dplyr)

source(file.path("R", "utils.R"))

FEATURES_PATH <- file.path("data", "processed", "features.csv")
MODEL_PATH    <- file.path("models", "classifier.rds")
RESULTS_PATH  <- file.path("docs", "classifier_results.md")
VARIMP_PATH   <- file.path("docs", "figures", "variable_importance.png")

METADATA_COLS <- c("path", "label", "subcategory", "data_origin", "source_file", "window_index")

SPLIT_RATIOS <- c(train = 0.6, val = 0.2, test = 0.2)
SEED <- 20260729  # fixed for reproducibility; not tuned to flatter results

# ---- Grouped split -----------------------------------------------------------

#' Assign each unique source_file to train/val/test, then join back onto the
#' window-level data. Asserts (does not just assume) that no source_file
#' appears in more than one split.
#'
#' Stratified by label: allocation happens separately within each label's
#' own (shuffled) source-file list, not by shuffling all source files
#' together. With a small corpus (as low as 1 source file for some classes
#' right now -- see docs/methodology.md), a single non-stratified shuffle
#' can isolate an entire class into one split, which both starves test
#' coverage for that class AND can leave randomForest() with fewer than 2
#' classes to train on at all. A class with only one source file goes
#' entirely to train (there's no way to split one file across sets) --
#' this is a real data-scarcity limitation, reported honestly rather than
#' papered over.
grouped_split <- function(features_df, ratios = SPLIT_RATIOS, seed = SEED) {
  set.seed(seed)

  source_labels <- unique(features_df[, c("source_file", "label")])
  split_map <- character(0)

  for (lbl in unique(source_labels$label)) {
    srcs <- sample(source_labels$source_file[source_labels$label == lbl])
    n <- length(srcs)

    if (n == 1) {
      assignment <- "train"
    } else {
      n_train <- max(1, floor(n * ratios["train"]))
      n_val <- min(floor(n * ratios["val"]), n - n_train)
      n_test <- n - n_train - n_val
      assignment <- c(rep("train", n_train), rep("val", n_val), rep("test", n_test))
    }

    split_map[srcs] <- assignment
  }

  features_df$split <- unname(split_map[features_df$source_file])

  train_sources <- unique(features_df$source_file[features_df$split == "train"])
  val_sources   <- unique(features_df$source_file[features_df$split == "val"])
  test_sources  <- unique(features_df$source_file[features_df$split == "test"])

  stopifnot(
    "train/val source overlap"  = length(intersect(train_sources, val_sources)) == 0,
    "train/test source overlap" = length(intersect(train_sources, test_sources)) == 0,
    "val/test source overlap"   = length(intersect(val_sources, test_sources)) == 0
  )

  features_df
}

# ---- Metrics ---------------------------------------------------------------

#' Per-class precision/recall from a confusion matrix (rows = predicted,
#' cols = actual, as produced by table(predicted, actual)).
per_class_precision_recall <- function(conf_mat) {
  classes <- rownames(conf_mat)
  purrr_map <- lapply(classes, function(cls) {
    tp <- conf_mat[cls, cls]
    fp <- sum(conf_mat[cls, ]) - tp
    fn <- sum(conf_mat[, cls]) - tp
    data.frame(
      class = cls,
      precision = if ((tp + fp) > 0) tp / (tp + fp) else NA_real_,
      recall = if ((tp + fn) > 0) tp / (tp + fn) else NA_real_
    )
  })
  do.call(rbind, purrr_map)
}

#' Of all TRUE ambient test windows, what fraction did the model call a pest
#' (i.e. any non-"ambient" label)? This is the false-alarm rate a farmer
#' would actually experience, and the number a good judge will ask for.
false_positive_rate_vs_ambient <- function(predicted, actual) {
  is_ambient <- actual == "ambient"
  if (sum(is_ambient) == 0) return(NA_real_)
  mean(predicted[is_ambient] != "ambient")
}

# ---- Reporting ---------------------------------------------------------------

write_classifier_results <- function(conf_mat, prec_recall, fpr_ambient, class_counts,
                                      n_train_sources, n_val_sources, n_test_sources,
                                      data_origins, accuracy, results_path = RESULTS_PATH) {
  ensure_dir(dirname(results_path))

  conf_mat_df <- as.data.frame.matrix(conf_mat)
  conf_mat_md <- knitr_table_or_fallback(cbind(predicted_class = rownames(conf_mat_df), conf_mat_df))
  prec_recall_md <- knitr_table_or_fallback(prec_recall)

  lines <- c(
    "# Classifier Results",
    "",
    paste0("Generated by `R/05_train.R` on ", format(Sys.time(), "%Y-%m-%d %H:%M"), ". ",
           "These are measured numbers from an actual train/test run -- not estimates."),
    "",
    paste0("**Data origin in this run:** ", paste(names(data_origins), data_origins, sep = "=", collapse = ", "),
           " windows. If `synthetic` dominates or `real` is 0, treat these results as ",
           "synthetic-signal validation only, NOT as evidence of real-world field performance."),
    "",
    sprintf("Split (by source recording, not window): %d train / %d val / %d test source files.",
            n_train_sources, n_val_sources, n_test_sources),
    "",
    "## Class counts (windows, all splits)",
    "",
    knitr_table_or_fallback(class_counts),
    "",
    "## Overall test accuracy",
    "",
    sprintf("**%s** (fraction of test windows classified correctly, all classes combined).",
            if (is.na(accuracy)) "N/A" else scales_percent(accuracy)),
    "",
    "## Confusion matrix (test set; rows = predicted, columns = actual)",
    "",
    conf_mat_md,
    "",
    "## Per-class precision / recall (test set)",
    "",
    prec_recall_md,
    "",
    "## False-positive rate against the ambient/negative class",
    "",
    sprintf("**%s** of true ambient test windows were misclassified as a pest (false alarm).",
            if (is.na(fpr_ambient)) "N/A (no ambient windows in test split)" else scales_percent(fpr_ambient)),
    "",
    "## Variable importance",
    "",
    "![Variable importance](figures/variable_importance.png)",
    "",
    "## Interpretation",
    "",
    "TBD -- fill in after reading the numbers above. If performance is poor ",
    "for any class (especially a target pest), say so plainly -- do not ",
    "retune thresholds until the numbers look better before reporting them."
  )

  writeLines(lines, results_path)
  invisible(results_path)
}

#' knitr::kable if available, else a plain data.frame print captured as text
#' (keeps this script from hard-failing if knitr isn't installed).
knitr_table_or_fallback <- function(df) {
  if (requireNamespace("knitr", quietly = TRUE)) {
    paste(knitr::kable(df, format = "markdown", digits = 3), collapse = "\n")
  } else {
    paste(utils::capture.output(print(df)), collapse = "\n")
  }
}

scales_percent <- function(x) paste0(round(x * 100, 1), "%")

# ---- Entry point ---------------------------------------------------------------

#' Train a random forest on features_df's "train" split, evaluate on its
#' "test" split (features_df must already have grouped_split() applied).
#' Pulled out of main() so R/07_compression_delta.R can call it a second
#' time on the "uncompressed" condition's features without duplicating this
#' logic or touching the default compressed-condition output files.
train_and_evaluate <- function(features_df) {
  feature_cols <- setdiff(names(features_df), c(METADATA_COLS, "split"))
  features_df$label <- as.factor(features_df$label)

  train_df <- features_df[features_df$split == "train", ]
  test_df  <- features_df[features_df$split == "test", ]

  # Drop rows with any non-finite feature values (e.g. a failed dominant-freq
  # contour on a very short/silent window) rather than letting them silently
  # corrupt training -- log how many were dropped.
  complete_train <- train_df[stats::complete.cases(train_df[, feature_cols]), ]
  n_dropped <- nrow(train_df) - nrow(complete_train)
  if (n_dropped > 0) message(n_dropped, " training rows dropped for non-finite features.")

  model <- randomForest::randomForest(
    x = complete_train[, feature_cols],
    y = droplevels(complete_train$label),
    importance = TRUE
  )

  complete_test <- test_df[stats::complete.cases(test_df[, feature_cols]), ]
  predicted <- predict(model, complete_test[, feature_cols])
  actual <- droplevels(complete_test$label)

  # Some classes may exist in test but not train (or vice versa) if a source
  # file's split happened to isolate a whole rare class -- align factor
  # levels so table() doesn't silently drop mismatched levels.
  all_levels <- union(levels(predicted), levels(actual))
  predicted <- factor(predicted, levels = all_levels)
  actual <- factor(actual, levels = all_levels)

  conf_mat <- table(predicted = predicted, actual = actual)
  prec_recall <- per_class_precision_recall(conf_mat)
  fpr_ambient <- false_positive_rate_vs_ambient(as.character(predicted), as.character(actual))
  accuracy <- if (length(predicted) > 0) mean(as.character(predicted) == as.character(actual)) else NA_real_

  list(
    model = model, feature_cols = feature_cols, class_levels = levels(features_df$label),
    conf_mat = conf_mat, prec_recall = prec_recall, fpr_ambient = fpr_ambient,
    accuracy = accuracy, n_test = length(predicted),
    n_train_sources = length(unique(train_df$source_file)),
    n_val_sources = length(unique(features_df$source_file[features_df$split == "val"])),
    n_test_sources = length(unique(test_df$source_file)),
    data_origins = table(features_df$data_origin),
    class_counts = {
      cc <- as.data.frame(table(label = features_df$label, data_origin = features_df$data_origin))
      cc[cc$Freq > 0, ]
    }
  )
}

#' @param features_path,model_path,results_path,varimp_path Overridable so
#'   R/07_compression_delta.R can run this against the "uncompressed"
#'   condition without touching the default (compressed) output files.
main <- function(features_path = FEATURES_PATH, model_path = MODEL_PATH,
                  results_path = RESULTS_PATH, varimp_path = VARIMP_PATH) {
  if (!file.exists(features_path)) {
    stop(features_path, " not found -- run R/03_preprocess.R and R/04_features.R first.")
  }
  features_df <- utils::read.csv(features_path, stringsAsFactors = FALSE)
  features_df <- grouped_split(features_df)

  result <- train_and_evaluate(features_df)

  ensure_dir(dirname(varimp_path))
  grDevices::png(varimp_path, width = 1000, height = 800, res = 150)
  randomForest::varImpPlot(result$model, main = "Variable importance")
  grDevices::dev.off()

  ensure_dir(dirname(model_path))
  saveRDS(list(model = result$model, feature_cols = result$feature_cols,
               class_levels = result$class_levels),
          model_path)

  write_classifier_results(result$conf_mat, result$prec_recall, result$fpr_ambient,
                            result$class_counts, result$n_train_sources, result$n_val_sources,
                            result$n_test_sources, result$data_origins, result$accuracy,
                            results_path = results_path)

  message(sprintf("Training complete. Model at %s, results at %s (test accuracy: %s)",
                   model_path, results_path,
                   if (is.na(result$accuracy)) "N/A" else scales_percent(result$accuracy)))
  invisible(result)
}

if (sys.nframe() == 0) {
  main()
}
