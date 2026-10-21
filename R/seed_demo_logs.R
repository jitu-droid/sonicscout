# Deliverable F support -- seed logs/requests.jsonl + logs/audio/ with demo
# entries so the Shiny dashboard's replay mode has something to show without
# a live Twilio connection. Every entry is a REAL predict_pest() output on
# real audio -- not fabricated numbers.
#
# Three rules, each fixing a real problem found by audit:
#
#   1. HELD-OUT AUDIO ONLY. A clip the model was trained on says nothing
#      about how it performs, so only clips that were NOT used in training
#      are seeded. "Not used" is checked by recording, not just by file:
#      the codec-reference clips under data/codec_experiment/reference/real_*
#      are WAV conversions of training recordings (same InsectSet recording
#      ID, different bytes), and ESC-50 clips that share a freesound source
#      recording with a training clip are excluded too. Held-out insect
#      audio comes from R/fetch_heldout_insectset.R (every InsectSet459
#      recording fetched for training was used in training). If a class has
#      no held-out clip, this script says so and seeds nothing for it -- it
#      never falls back to a training clip.
#   2. WHATSAPP-COMPRESSED. Real voice notes arrive compressed, so each
#      clip is compressed first and the COMPRESSED copy is what gets
#      predicted on and archived -- the demo shows what deployment sees.
#      (This script used to seed the 44.1 kHz originals, and real species
#      came out "ambient". That was first blamed on the missing compression;
#      the real cause was a sample-rate bug in predict_pest(), since fixed.)
#   3. REPLACE, DON'T APPEND -- AND NEVER TOUCH REAL ENTRIES. Re-seeding
#      removes only previous `from == "demo-seed"` entries (and their audio
#      files, if nothing else references them). Webhook entries, and any
#      line that can't be parsed, are kept verbatim.
#
# Each entry records its `true_label` so the dashboard can show it next to
# the prediction.
#
# Don't run this while the webhook is live: the log is rewritten in place,
# and the script refuses to finish if the log changes underneath it.
#
# Usage:
#   Rscript R/seed_demo_logs.R

library(whatsappaudioR)
library(jsonlite)

source(file.path("R", "utils.R"))
source(file.path("R", "02_codec_experiment.R"))  # simulate_whatsapp_compression()
source(file.path("R", "06_predict.R"))

REQUEST_LOG_PATH  <- file.path("logs", "requests.jsonl")
REQUEST_AUDIO_DIR <- file.path("logs", "audio")
FEATURES_PATH     <- file.path("data", "processed", "features.csv")
# Held-out recordings live in their own folder (R/fetch_heldout_insectset.R);
# the original folder is scanned too in case it ever holds an unused file.
INSECTSET_DIRS    <- file.path("data", "raw", c("insectset459_heldout", "insectset459"))
MIN_CLIP_SECONDS  <- 3  # same minimum the webhook enforces (api/plumber.R)
ESC50_DIR         <- file.path("data", "raw", "esc50", "ESC-50-master")
DEMO_SEED_FROM    <- "demo-seed"
SEED_CLASSES      <- c("chorthippus_biguttulus", "chorthippus_brunneus", "cicada_orni", "ambient")
SEED_RNG          <- 20260729  # same project seed as R/05_train.R
AUDIO_EXTENSIONS  <- c("wav", "mp3", "ogg", "opus", "m4a")  # same list as R/03_preprocess.R

# ---- Held-out clip discovery --------------------------------------------------

#' Every source file the shipped model was trained on (R/05_train.R's
#' final model trains on the full features.csv corpus).
training_source_files <- function(features_path = FEATURES_PATH) {
  if (!file.exists(features_path)) {
    stop(features_path, " not found -- can't tell which clips were used in training, ",
         "so refusing to seed (run R/03_preprocess.R and R/04_features.R first).")
  }
  unique(utils::read.csv(features_path, stringsAsFactors = FALSE)$source_file)
}

#' InsectSet459 recording ID ("IN129404391") from a file name, NA if none.
insectset_recording_id <- function(path) {
  id <- sub("^.*_(IN[0-9]+)_.*$", "\\1", basename(path))
  ifelse(id == basename(path), NA_character_, id)
}

#' InsectSet459 files for `species` whose RECORDING was never used in
#' training (by recording ID, path, and content hash).
held_out_insect_clips <- function(species, train_files) {
  on_disk <- list.files(file.path(INSECTSET_DIRS, species), full.names = TRUE)
  on_disk <- on_disk[tolower(tools::file_ext(on_disk)) %in% AUDIO_EXTENSIONS]
  if (length(on_disk) == 0) return(character(0))
  train_ids <- stats::na.omit(insectset_recording_id(train_files))
  train_hashes <- unname(tools::md5sum(train_files[file.exists(train_files)]))
  ids <- insectset_recording_id(on_disk)
  keep <- !(on_disk %in% train_files) &
    !(unname(tools::md5sum(on_disk)) %in% train_hashes) &
    (is.na(ids) | !(ids %in% train_ids))
  long_enough(on_disk[keep])
}

#' Drop clips shorter than MIN_CLIP_SECONDS -- the webhook would reject
#' those as a voice note, so they don't belong in a demo of it either.
long_enough <- function(paths) {
  if (length(paths) == 0) return(paths)
  secs <- vapply(paths, function(p) {
    w <- whatsappaudioR::wa_read(p)
    length(w@left) / w@samp.rate
  }, numeric(1))
  paths[secs >= MIN_CLIP_SECONDS]
}

#' ESC-50 clips from the ambient categories the model was trained on, that
#' were not themselves used in training and share no freesound source
#' recording (`src_file`) with any training clip.
held_out_ambient_clips <- function(train_files) {
  meta_path <- file.path(ESC50_DIR, "meta", "esc50.csv")
  if (!file.exists(meta_path)) return(data.frame(path = character(0), category = character(0)))
  meta <- utils::read.csv(meta_path, stringsAsFactors = FALSE)
  train_meta <- meta[meta$filename %in% basename(train_files), ]
  cand <- meta[meta$category %in% unique(train_meta$category) &
               !(meta$filename %in% train_meta$filename) &
               !(meta$src_file %in% train_meta$src_file), ]
  cand$path <- file.path(ESC50_DIR, "audio", cand$filename)
  cand[file.exists(cand$path), c("path", "category")]
}

#' Pick up to `n` held-out clips for one class, deterministically. Ambient
#' clips are spread across different ESC-50 categories.
pick_clips <- function(cls, n, train_files) {
  set.seed(SEED_RNG)
  if (cls == "ambient") {
    cand <- held_out_ambient_clips(train_files)
    if (nrow(cand) == 0) return(character(0))
    cats <- sample(unique(cand$category), min(n, length(unique(cand$category))))
    return(vapply(cats, function(cat) {
      paths <- cand$path[cand$category == cat]
      paths[sample.int(length(paths), 1)]
    }, character(1), USE.NAMES = FALSE))
  }
  cand <- held_out_insect_clips(cls, train_files)
  if (length(cand) == 0) return(character(0))
  cand[sample.int(length(cand), min(n, length(cand)))]
}

# ---- Replacing previous demo-seed entries -------------------------------------

#' Remove previous demo-seed entries from the request log, keeping every
#' other line verbatim (real webhook entries, and anything unparseable).
#' Audio files referenced only by removed demo-seed entries are deleted;
#' any file a kept line still mentions is left alone.
#'
#' Refuses to finish (log left untouched) if the log changes while this
#' runs, e.g. a live webhook request arriving mid-rewrite.
remove_demo_seed_entries <- function(log_path = REQUEST_LOG_PATH, audio_dir = REQUEST_AUDIO_DIR) {
  if (!file.exists(log_path)) return(invisible(list(removed = 0L, kept = 0L)))
  size_before <- file.size(log_path)
  lines <- readLines(log_path, warn = FALSE)

  entries <- lapply(lines, function(l) tryCatch(jsonlite::fromJSON(l), error = function(e) NULL))
  is_seed <- vapply(entries, function(e) is.list(e) && identical(e$from, DEMO_SEED_FROM), logical(1))
  kept <- lines[!is_seed]

  tmp <- paste0(log_path, ".tmp")
  writeLines(kept, tmp)
  if (!identical(file.size(log_path), size_before)) {
    unlink(tmp)
    stop(log_path, " changed while seeding (a live request was probably logged). ",
         "Nothing was removed -- re-run when the webhook is idle.")
  }
  if (!file.rename(tmp, log_path)) {
    unlink(tmp)
    stop("Could not replace ", log_path, " -- nothing was removed.")
  }

  seed_audio <- unique(as.character(unlist(lapply(entries[is_seed], function(e) e$audio_path))))
  seed_audio <- basename(seed_audio[!is.na(seed_audio)])
  still_referenced <- vapply(seed_audio, function(b) any(grepl(b, kept, fixed = TRUE)), logical(1))
  orphaned <- file.path(audio_dir, seed_audio[!still_referenced])
  unlink(orphaned[file.exists(orphaned)])

  invisible(list(removed = sum(is_seed), kept = length(kept)))
}

# ---- Entry point ----------------------------------------------------------------

main <- function(n_per_class = 3) {
  if (!file.exists(MODEL_PATH)) {
    stop("No trained model at ", MODEL_PATH, " -- run R/05_train.R first.")
  }
  train_files <- training_source_files()

  removed <- remove_demo_seed_entries()
  message("Removed ", removed$removed, " previous demo-seed entries; kept ", removed$kept,
          " other log lines untouched.")

  ensure_dir(REQUEST_AUDIO_DIR)
  seeded <- stats::setNames(integer(length(SEED_CLASSES)), SEED_CLASSES)

  for (cls in SEED_CLASSES) {
    clips <- pick_clips(cls, n_per_class, train_files)
    if (length(clips) == 0) {
      message("No held-out clip available for ", cls, " -- every recording of it on disk ",
              "was used in training. Not seeding it (a training clip would overstate accuracy).")
      next
    }
    for (src in clips) {
      compressed <- tempfile(fileext = ".wav")
      result <- tryCatch({
        simulate_whatsapp_compression(src, compressed)
        predict_pest(compressed)
      }, error = function(e) {
        message("Skipping ", src, ": ", conditionMessage(e))
        NULL
      })
      if (is.null(result)) { unlink(compressed); next }

      audio_hash <- unname(tools::md5sum(compressed))
      archived_path <- file.path(REQUEST_AUDIO_DIR, paste0(audio_hash, ".wav"))
      file.copy(compressed, archived_path, overwrite = TRUE)
      w <- tuneR::readWave(compressed)
      unlink(compressed)

      log_event(REQUEST_LOG_PATH,
                from = DEMO_SEED_FROM,
                outcome = if (isTRUE(result$low_confidence)) "low_confidence" else "predicted",
                audio_hash = audio_hash, audio_path = archived_path,
                duration_s = length(w@left) / w@samp.rate,
                top_classes = paste(result$top_classes, collapse = "|"),
                confidences = paste(round(result$confidences, 3), collapse = "|"),
                true_label = cls,
                source_file = src,
                audio_condition = sprintf("WhatsApp-simulated (%d Hz, %d kbps, mono), held out from training",
                                          WHATSAPP_SAMPLE_RATE, WHATSAPP_BITRATE_KBPS))
      seeded[[cls]] <- seeded[[cls]] + 1L
    }
  }

  message("Seeded ", sum(seeded), " demo entries into ", REQUEST_LOG_PATH, ": ",
          paste(names(seeded), seeded, sep = "=", collapse = ", "))
  invisible(seeded)
}

if (sys.nframe() == 0) {
  main()
}
