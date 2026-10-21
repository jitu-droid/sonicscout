#' Read a compressed voice-note audio file into a Wave object
#'
#' Handles the container/codec mess of mobile voice notes: `.opus` and
#' `.ogg` files are decoded via a system `ffmpeg` binary into a temporary
#' WAV before being read with [tuneR::readWave()]. `.wav` files are read
#' directly, and `.mp3`/`.m4a` are routed through the same decode step as
#' opus/ogg.
#'
#' @details
#' # WORKAROUND: decoding via system ffmpeg instead of `av`
#' The obvious implementation would use [av::av_audio_convert()] (`av` binds
#' FFmpeg's libav* libraries directly, no subprocess needed). That was tried
#' first, but on the machine this package was built and tested on,
#' `av::av_audio_convert()` and even `av::av_media_info()` segfault the R
#' process outright -- confirmed even against `av`'s own bundled sample
#' file, so it isn't an input-file issue. A segfault can't be caught with
#' `tryCatch()`, which makes `av` unsafe to call from a long-running
#' process (a webhook server, a Shiny session) on that machine. See
#' `BLOCKERS.md` in the parent repo for the full diagnosis. This function
#' shells out to a system `ffmpeg` binary instead, which is confirmed
#' working. If a future `av` version/rebuild is confirmed not to segfault
#' on your machine, switching back to `av::av_audio_convert()` would avoid
#' the subprocess-spawn overhead.
#'
#' # Sample rate
#' By default the audio comes back at whatever rate the file decodes to --
#' 48 kHz for Opus, usually 44.1 or 48 kHz for MP3/WAV. A model trained at
#' one sample rate must be fed that same rate: spectral features computed
#' over a different bandwidth are not comparable. Pass `sample_rate` (and
#' `mono = TRUE`) to have ffmpeg resample on decode, using its filtered
#' resampler (with anti-aliasing), not naive decimation.
#'
#' @param path Path to an audio file (`.opus`, `.ogg`, `.wav`, `.mp3`, `.m4a`).
#' @param sample_rate Optional target sample rate in Hz. `NULL` (default)
#'   keeps the file's own rate.
#' @param mono If `TRUE`, downmix to one channel (averaging channels).
#'   Default `FALSE` keeps the file's channels.
#'
#' @return A [tuneR::Wave-class] object.
#'
#' @examples
#' \dontrun{
#' w <- wa_read("voice_note.opus")
#' w16 <- wa_read("voice_note.opus", sample_rate = 16000, mono = TRUE)
#' }
#'
#' @export
wa_read <- function(path, sample_rate = NULL, mono = FALSE) {
  if (!file.exists(path)) {
    stop("File not found: ", path)
  }
  if (!is.null(sample_rate) &&
      (!is.numeric(sample_rate) || length(sample_rate) != 1 || is.na(sample_rate) || sample_rate <= 0)) {
    stop("sample_rate must be a single positive number (Hz), or NULL")
  }

  ext <- tolower(tools::file_ext(path))

  if (!ext %in% c("wav", "opus", "ogg", "mp3", "m4a")) {
    stop("Unsupported audio format '.", ext, "' -- expected one of: ",
         "opus, ogg, wav, mp3, m4a")
  }

  if (ext == "wav") {
    # Already in the requested shape? Read it untouched rather than
    # round-tripping it through ffmpeg.
    hdr <- tuneR::readWave(path, header = TRUE)
    rate_ok <- is.null(sample_rate) || hdr$sample.rate == sample_rate
    channels_ok <- !mono || hdr$channels == 1
    if (rate_ok && channels_ok) return(tuneR::readWave(path))
  }

  ffmpeg_bin <- Sys.which("ffmpeg")
  if (ffmpeg_bin == "") {
    stop("ffmpeg not found on PATH -- wa_read() needs a system ffmpeg build ",
         "to decode or resample '.", ext, "' files (see BLOCKERS.md: av::av_audio_convert() ",
         "segfaults on the reference machine, so this function doesn't use it).")
  }

  tmp_wav <- tempfile(fileext = ".wav")
  on.exit(unlink(tmp_wav), add = TRUE)
  args <- c("-y", "-loglevel", "error", "-i", shQuote(path))
  if (!is.null(sample_rate)) args <- c(args, "-ar", as.character(as.integer(sample_rate)))
  if (mono) args <- c(args, "-ac", "1")
  # shQuote: system2() passes arguments unquoted, so a path with spaces breaks.
  status <- system2(ffmpeg_bin, args = c(args, shQuote(tmp_wav)))
  if (status != 0) stop("ffmpeg failed to decode ", path)

  tuneR::readWave(tmp_wav)
}
