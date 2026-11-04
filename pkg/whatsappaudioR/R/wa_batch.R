#' Vectorise a function over every audio file in a directory
#'
#' Reads every supported audio file under `dir` (recursively) and applies
#' `fn` (default [wa_features()]) to each, row-binding the results with a
#' leading `file` column identifying the source path.
#'
#' @param dir Directory to scan for audio files.
#' @param fn Function taking a [tuneR::Wave-class] object and returning a
#'   single-row data frame/tibble. Defaults to [wa_features()].
#' @param pattern Regex for filenames to include. Defaults to the
#'   extensions [wa_read()] supports.
#' @param ... Passed on to `fn`.
#'
#' @return A tibble: one row per file, with a leading `file` column, plus
#'   whatever columns `fn` returns.
#'
#' @examples
#' # Write two short tones into a temporary folder, then featurise both.
#' d <- file.path(tempdir(), "wa_batch_example")
#' dir.create(d, showWarnings = FALSE)
#' for (f0 in c(300, 600)) {
#'   tone <- tuneR::sine(f0, duration = 8000, samp.rate = 16000,
#'                       bit = 16, pcm = TRUE)
#'   tuneR::writeWave(tone, file.path(d, paste0("tone_", f0, ".wav")))
#' }
#' features_df <- wa_batch(d, wa_features)
#' features_df[, c("file", "peak_freq_hz")]
#' unlink(d, recursive = TRUE)
#'
#' @export
wa_batch <- function(dir, fn = wa_features, pattern = "\\.(opus|ogg|wav|mp3|m4a)$", ...) {
  files <- list.files(dir, pattern = pattern, recursive = TRUE,
                       full.names = TRUE, ignore.case = TRUE)
  if (length(files) == 0) {
    warning("No matching audio files found under ", dir)
    return(tibble::tibble())
  }

  rows <- lapply(files, function(f) {
    w <- wa_read(f)
    result <- fn(w, ...)
    tibble::as_tibble(cbind(file = f, result))
  })

  do.call(rbind, rows)
}
