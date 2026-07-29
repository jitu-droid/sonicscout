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
#' @param path Path to an audio file (`.opus`, `.ogg`, `.wav`, `.mp3`, `.m4a`).
#'
#' @return A [tuneR::Wave-class] object.
#'
#' @examples
#' \dontrun{
#' w <- wa_read("voice_note.opus")
#' }
#'
#' @export
wa_read <- function(path) {
  if (!file.exists(path)) {
    stop("File not found: ", path)
  }

  ext <- tolower(tools::file_ext(path))

  if (ext == "wav") {
    return(tuneR::readWave(path))
  }

  if (!ext %in% c("opus", "ogg", "mp3", "m4a")) {
    stop("Unsupported audio format '.", ext, "' -- expected one of: ",
         "opus, ogg, wav, mp3, m4a")
  }

  ffmpeg_bin <- Sys.which("ffmpeg")
  if (ffmpeg_bin == "") {
    stop("ffmpeg not found on PATH -- wa_read() needs a system ffmpeg build ",
         "to decode '.", ext, "' files (see BLOCKERS.md: av::av_audio_convert() ",
         "segfaults on the reference machine, so this function doesn't use it).")
  }

  tmp_wav <- tempfile(fileext = ".wav")
  on.exit(unlink(tmp_wav), add = TRUE)
  status <- system2(ffmpeg_bin, args = c("-y", "-loglevel", "error", "-i", path, tmp_wav))
  if (status != 0) stop("ffmpeg failed to decode ", path)

  tuneR::readWave(tmp_wav)
}
