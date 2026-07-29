#' Simulate lossy VoIP voice-note compression on a Wave object
#'
#' Round-trips a [tuneR::Wave-class] object through the same codec pipeline
#' WhatsApp (and similar apps) apply to voice notes: resample to `sr` Hz,
#' downmix to mono, encode to Opus at `bitrate` bits/sec inside an Ogg
#' container, then decode back to PCM.
#'
#' @details
#' # WORKAROUND: both encode and decode go through system ffmpeg
#' [av::av_audio_convert()] would be the obvious choice here, and its
#' installed version does have a `bit_rate` argument -- but empirically it
#' (and even `av::av_media_info()`) segfaults R outright on the machine this
#' package was built and tested on, including against `av`'s own bundled
#' sample file. A segfault can't be caught with `tryCatch()`, which makes it
#' unsafe to call from a long-running process. See `BLOCKERS.md` in the
#' parent repo. Both the encode and decode steps here shell out to a system
#' `ffmpeg` binary (with `libopus`) instead. This requires `ffmpeg` to be on
#' `PATH`; call `Sys.which("ffmpeg")` to check.
#'
#' @param wave A [tuneR::Wave-class] object.
#' @param bitrate Target bitrate in bits/sec (default `16000`, i.e. 16 kbps,
#'   matching WhatsApp's voice-note encoding).
#' @param sr Target sample rate in Hz (default `16000`, matching WhatsApp).
#'
#' @return A [tuneR::Wave-class] object: the degraded, round-tripped audio.
#'
#' @examples
#' \dontrun{
#' w <- wa_read("clean_recording.wav")
#' degraded <- wa_simulate_compression(w, bitrate = 16000, sr = 16000)
#' }
#'
#' @export
wa_simulate_compression <- function(wave, bitrate = 16000, sr = 16000) {
  ffmpeg_bin <- Sys.which("ffmpeg")
  if (ffmpeg_bin == "") {
    stop("ffmpeg not found on PATH. wa_simulate_compression() needs a system ",
         "ffmpeg build with libopus support (av::av_audio_convert() segfaults ",
         "on the reference machine -- see BLOCKERS.md -- so this function ",
         "doesn't use it).")
  }

  tmp_in  <- tempfile(fileext = ".wav")
  tmp_ogg <- tempfile(fileext = ".ogg")
  tmp_out <- tempfile(fileext = ".wav")
  on.exit(unlink(c(tmp_in, tmp_ogg, tmp_out)), add = TRUE)

  tuneR::writeWave(wave, tmp_in)

  bitrate_kbps <- round(bitrate / 1000)
  encode_args <- c(
    "-y", "-loglevel", "error",
    "-i", tmp_in,
    "-ar", as.character(sr),
    "-ac", "1",
    "-c:a", "libopus",
    "-b:a", paste0(bitrate_kbps, "k"),
    tmp_ogg
  )
  status <- system2(ffmpeg_bin, args = encode_args)
  if (status != 0) stop("ffmpeg encode step failed")

  decode_args <- c("-y", "-loglevel", "error", "-i", tmp_ogg, "-ar", as.character(sr), "-ac", "1", tmp_out)
  status <- system2(ffmpeg_bin, args = decode_args)
  if (status != 0) stop("ffmpeg decode step failed")

  tuneR::readWave(tmp_out)
}
