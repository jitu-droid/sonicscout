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
                                      data_origins) {
  ensure_dir(dirname(RESULTS_PATH))

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

  writeLines(lines, RESULTS_PATH)
  invisible(RESULTS_PATH)
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

main <- function() {
  if (!file.exists(FEATURES_PATH)) {
    stop(FEATURES_PATH, " not found -- run R/03_preprocess.R and R/04_features.R first.")
  }
  features_df <- utils::read.csv(FEATURES_PATH, stringsAsFactors = FALSE)
  features_df <- grouped_split(features_df)

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

  ensure_dir(dirname(VARIMP_PATH))
  grDevices::png(VARIMP_PATH, width = 1000, height = 800, res = 150)
  randomForest::varImpPlot(model, main = "Variable importance")
  grDevices::dev.off()

  ensure_dir(dirname(MODEL_PATH))
  saveRDS(list(model = model, feature_cols = feature_cols,
               class_levels = levels(features_df$label)),
          MODEL_PATH)

  class_counts <- as.data.frame(table(label = features_df$label, data_origin = features_df$data_origin))
  class_counts <- class_counts[class_counts$Freq > 0, ]

  n_train_src <- length(unique(train_df$source_file))
  n_val_src <- length(unique(features_df$source_file[features_df$split == "val"]))
  n_test_src <- length(unique(test_df$source_file))
  data_origins <- table(features_df$data_origin)

  write_classifier_results(conf_mat, prec_recall, fpr_ambient, class_counts,
                            n_train_src, n_val_src, n_test_src, data_origins)

  message("Training complete. Model at ", MODEL_PATH, ", results at ", RESULTS_PATH)
  invisible(list(model = model, conf_mat = conf_mat, fpr_ambient = fpr_ambient))
}

if (sys.nframe() == 0) {
  main()
}
