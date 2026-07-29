# Deliverable C -- Data pipeline, step 3: extract a documented, inspectable
# feature vector per preprocessed window.
#
# Uses the whatsappaudioR package (Deliverable B) rather than duplicating
# feature-extraction logic in the main pipeline -- see wa_features() for the
# exact, named feature definitions (peak frequency, spectral centroid,
# flatness, entropy, rolloff, dominant-frequency stability, a harmonic-energy
# heuristic, and 12 MFCCs).
#
# Usage:
#   Rscript R/04_features.R
#
# Input:  data/processed/windows_manifest.csv (from 03_preprocess.R)
# Output: data/processed/features.csv

library(whatsappaudioR)

source(file.path("R", "utils.R"))

WINDOWS_MANIFEST <- file.path("data", "processed", "windows_manifest.csv")
FEATURES_PATH    <- file.path("data", "processed", "features.csv")

#' @param windows_manifest_path,features_path Overridable so
#'   R/07_compression_delta.R can run this against the "uncompressed"
#'   condition's windows without touching the default compressed paths.
main <- function(windows_manifest_path = WINDOWS_MANIFEST, features_path = FEATURES_PATH) {
  if (!file.exists(windows_manifest_path)) {
    stop(windows_manifest_path, " not found -- run R/03_preprocess.R first.")
  }
  windows <- utils::read.csv(windows_manifest_path, stringsAsFactors = FALSE)

  rows <- lapply(seq_len(nrow(windows)), function(i) {
    w <- windows[i, ]
    feats <- tryCatch({
      wave <- whatsappaudioR::wa_read(w$path)
      whatsappaudioR::wa_features(wave)
    }, error = function(e) {
      message("Feature extraction failed for ", w$path, ": ", conditionMessage(e))
      NULL
    })
    if (is.null(feats)) return(NULL)

    cbind(
      data.frame(path = w$path, label = w$label, subcategory = w$subcategory,
                 data_origin = w$data_origin, source_file = w$source_file,
                 window_index = w$window_index, stringsAsFactors = FALSE),
      feats
    )
  })

  features_df <- do.call(rbind, rows[!vapply(rows, is.null, logical(1))])

  ensure_dir(dirname(features_path))
  utils::write.csv(features_df, features_path, row.names = FALSE)

  message("Extracted features for ", nrow(features_df), " of ", nrow(windows),
          " windows. Written to ", features_path)
  invisible(features_df)
}

if (sys.nframe() == 0) {
  main()
}
