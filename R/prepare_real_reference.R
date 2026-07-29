# Prompt 4, Step 2 (and Step 4) support -- converts a sample of real
# recordings, already downloaded to data/raw/<source>/<label>/*, into WAV
# files under data/codec_experiment/reference/real_<label>/, so
# R/02_codec_experiment.R can measure compression survivability on real
# audio, not just synthetic ground-truth tones. Covers both:
#   - data/raw/insectset459/     (R/01_download_data.R -- Orthoptera/Cicadidae)
#   - data/raw/chewing_sounds/   (R/fetch_chewing_sounds.R -- larval chewing)
#
# IMPORTANT: these `real_*` directories live alongside the existing
# `synthetic_*` ones under data/codec_experiment/reference/ so the SAME
# codec-experiment code processes both uniformly (one findings table, one
# before/after figure) -- but R/03_preprocess.R (which feeds the
# classifier, Deliverable D) deliberately only scans `synthetic_*`
# directories there, specifically to avoid double-counting: real audio for
# the classifier is sourced from data/raw/manifest.csv instead (which has
# its own, larger, independently-sampled set of files per species).
#
# Usage:
#   Rscript R/prepare_real_reference.R

library(jsonlite)

source(file.path("R", "utils.R"))

RAW_SOURCE_DIRS <- c(
  file.path("data", "raw", "insectset459"),
  file.path("data", "raw", "chewing_sounds")
)
REFERENCE_DIR <- file.path("data", "codec_experiment", "reference")

# Kept small and separate from the classifier's own (larger) per-species
# sample -- this is just enough for the codec survivability measurement,
# which only needs a handful of real examples per species to be meaningful.
MAX_FILES_PER_SPECIES <- 5

#' Fallback for WAV files whose header ffmpeg mis-parses as zero-duration
#' (seen throughout the USDA-ARS chewing-sound library, which dates to
#' 2005 -- inspected one file's header by hand: RIFF/fmt/data chunk sizes
#' all decode as perfectly standard 16-bit PCM, so this looks like an
#' ffmpeg 8.1.2 WAV-demuxer quirk on these files specifically, not
#' genuinely corrupt data). Locates the `data` sub-chunk directly and
#' re-encodes the raw PCM bytes, using stream format parameters read via
#' `ffprobe` -- which reports sample_rate/channels/sample_fmt correctly
#' even on files where it gets duration wrong.
convert_raw_pcm_fallback <- function(src_path, wav_path) {
  ffmpeg_bin  <- Sys.which("ffmpeg")
  ffprobe_bin <- Sys.which("ffprobe")
  if (ffmpeg_bin == "" || ffprobe_bin == "") stop("ffmpeg/ffprobe not found on PATH")

  probe_json <- system2(ffprobe_bin,
                         args = c("-v", "quiet", "-print_format", "json", "-show_streams", src_path),
                         stdout = TRUE)
  probe <- jsonlite::fromJSON(paste(probe_json, collapse = "\n"))
  stream <- probe$streams[1, ]
  sample_rate <- as.integer(stream$sample_rate)
  channels <- as.integer(stream$channels)
  ffmpeg_fmt <- switch(as.character(stream$sample_fmt),
                        "s16" = "s16le", "u8" = "u8", "s32" = "s32le",
                        stop("Unsupported sample_fmt for raw-PCM fallback: ", stream$sample_fmt))

  raw_bytes <- readBin(src_path, "raw", n = file.info(src_path)$size)
  data_offset <- grepRaw("data", raw_bytes, fixed = TRUE)[1]
  if (is.na(data_offset)) stop("Could not locate a 'data' chunk in ", src_path)
  pcm_start <- data_offset + 8L  # skip the "data" marker (4 bytes) + chunk size field (4 bytes)
  if (pcm_start > length(raw_bytes)) stop("'data' chunk in ", src_path, " has no audio bytes after it")
  pcm_bytes <- raw_bytes[pcm_start:length(raw_bytes)]

  tmp_pcm <- tempfile(fileext = ".pcm")
  on.exit(unlink(tmp_pcm), add = TRUE)
  writeBin(pcm_bytes, tmp_pcm)

  ensure_dir(dirname(wav_path))
  status <- system2(ffmpeg_bin, args = c(
    "-y", "-loglevel", "error",
    "-f", ffmpeg_fmt, "-ar", as.character(sample_rate), "-ac", as.character(channels),
    "-i", tmp_pcm, wav_path
  ))
  if (status != 0) stop("ffmpeg raw-PCM fallback encode failed for ", src_path)
  wav_path
}

#' Convert to WAV via ffmpeg, and VERIFY the output actually has audio in
#' it -- not just that ffmpeg exited 0. If the normal conversion produces a
#' near-empty output (this ffmpeg version mis-parses several of the older
#' source files' WAV headers as zero-duration, despite the headers decoding
#' as valid on manual inspection), falls back to
#' `convert_raw_pcm_fallback()` before giving up.
convert_to_wav <- function(src_path, wav_path, min_bytes = 1000) {
  ffmpeg_bin <- Sys.which("ffmpeg")
  if (ffmpeg_bin == "") stop("ffmpeg not found on PATH")
  ensure_dir(dirname(wav_path))
  status <- system2(ffmpeg_bin, args = c("-y", "-loglevel", "error", "-i", src_path, wav_path))

  out_size <- if (status == 0) file.info(wav_path)$size else NA_real_
  if (is.na(out_size) || out_size < min_bytes) {
    result <- tryCatch({
      convert_raw_pcm_fallback(src_path, wav_path)
      TRUE
    }, error = function(e) {
      message("  raw-PCM fallback also failed for ", src_path, ": ", conditionMessage(e))
      FALSE
    })
    if (!result) {
      unlink(wav_path)
      stop("ffmpeg produced a near-empty output for ", src_path,
           ", and the raw-PCM fallback also failed -- see message above.")
    }
  }
  wav_path
}

main <- function() {
  raw_dirs_present <- RAW_SOURCE_DIRS[dir.exists(RAW_SOURCE_DIRS)]
  if (length(raw_dirs_present) == 0) {
    stop("None of the expected raw source directories exist (",
         paste(RAW_SOURCE_DIRS, collapse = ", "),
         ") -- run R/01_download_data.R and/or R/fetch_chewing_sounds.R first.")
  }

  species_dirs <- unlist(lapply(raw_dirs_present, list.dirs, recursive = FALSE))
  if (length(species_dirs) == 0) {
    stop("No species subdirectories found under ", paste(raw_dirs_present, collapse = ", "))
  }

  for (d in species_dirs) {
    label <- basename(d)
    files <- list.files(d, pattern = "\\.(mp3|m4a|wav|ogg)$", full.names = TRUE, ignore.case = TRUE)
    if (length(files) == 0) next

    take <- utils::head(sort(files), MAX_FILES_PER_SPECIES)
    out_dir <- file.path(REFERENCE_DIR, paste0("real_", label))
    ensure_dir(out_dir)

    n_ok <- 0
    for (f in take) {
      wav_name <- paste0(tools::file_path_sans_ext(basename(f)), ".wav")
      out_path <- file.path(out_dir, wav_name)
      if (file.exists(out_path)) { n_ok <- n_ok + 1; next }
      ok <- tryCatch({ convert_to_wav(f, out_path); TRUE },
                      error = function(e) { message("Failed to convert ", f, ": ", conditionMessage(e)); FALSE })
      if (ok) n_ok <- n_ok + 1
    }
    message("Prepared ", n_ok, " of ", length(take), " real reference files for '", label, "'")
  }
}

if (sys.nframe() == 0) {
  main()
}
