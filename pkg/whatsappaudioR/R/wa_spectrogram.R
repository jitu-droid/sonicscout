#' Compute a tidy spectrogram data frame from a Wave object
#'
#' Wraps [seewave::spectro()] and reshapes its matrix output into a long
#' tibble of `time` / `freq` / `amplitude`, which composes far more easily
#' with `dplyr`/`ggplot2` than the raw list-of-matrices `seewave` returns.
#'
#' @param wave A [tuneR::Wave-class] object, e.g. from [wa_read()].
#' @param wl Window length (samples) for the STFT. Longer windows give
#'   better frequency resolution at the cost of time resolution -- for
#'   low-frequency signals (like insect wingbeats) prefer a longer window
#'   (e.g. 1024-2048) over the seewave default.
#' @param ovlp Percent overlap between successive analysis windows.
#'
#' @return A tibble with columns `time` (seconds), `freq` (kHz, matching
#'   `seewave`'s convention), and `amplitude`.
#'
#' @examples
#' # Half a second of a 440 Hz tone.
#' w <- tuneR::sine(440, duration = 8000, samp.rate = 16000)
#' spec_df <- wa_spectrogram(w, wl = 512)
#' head(spec_df)
#'
#' @export
wa_spectrogram <- function(wave, wl = 1024, ovlp = 50) {
  spec <- seewave::spectro(wave, wl = wl, ovlp = ovlp, plot = FALSE)

  tibble::tibble(
    time = rep(spec$time, each = length(spec$freq)),
    freq = rep(spec$freq, times = length(spec$time)),
    amplitude = as.vector(spec$amp)
  )
}
