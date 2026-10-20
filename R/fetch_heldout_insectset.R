# Download a small set of HELD-OUT InsectSet459 recordings per target
# species -- audio the classifier has never seen, for honest demo seeding
# and for playing aloud in a live demo.
#
# Why this exists: every InsectSet459 recording fetched by
# R/01_download_data.R (45 per species) was used in training, and the
# codec-reference clips under data/codec_experiment/reference/real_* are
# WAV conversions of those same training recordings. So there was no
# held-out insect audio at all.
#
# "Held out" is enforced by SOURCE RECORDING, not by file: InsectSet459 file
# names carry the iNaturalist observation ID ("..._IN129404391_514240.mp3"),
# and a candidate is only eligible if its observation ID matches no
# training file's. Files are kept small (HEAD-probed before download).
#
# These files are recorded in data/raw/manifest.csv with source
# "InsectSet459-heldout" and stored under data/raw/insectset459_heldout/,
# and R/03_preprocess.R explicitly excludes that source -- so re-running the
# pipeline can never quietly fold them into the training set. This script
# does not retrain anything.
#
# Usage:
#   Rscript R/fetch_heldout_insectset.R

source(file.path("R", "utils.R"))
source(file.path("R", "01_download_data.R"))  # read_manifest(), download_tracked(), head_content_length(), targets

HELDOUT_SOURCE    <- "InsectSet459-heldout"
HELDOUT_DIR       <- file.path(RAW_DIR, "insectset459_heldout")
FEATURES_PATH     <- file.path("data", "processed", "features.csv")
N_HELDOUT_PER_SPECIES <- 5
HELDOUT_MAX_FILE_BYTES <- 3 * 1024^2  # "small files only": ~3MB

#' iNaturalist observation ID ("IN129404391") from an InsectSet459 file name.
observation_id <- function(file_name) {
  id <- sub("^.*_(IN[0-9]+)_.*$", "\\1", basename(file_name))
  ifelse(id == basename(file_name), NA_character_, id)
}

main <- function(n_per_species = N_HELDOUT_PER_SPECIES) {
  if (!file.exists(FEATURES_PATH)) {
    stop(FEATURES_PATH, " not found -- can't tell which recordings were used in training.")
  }
  train_files <- unique(utils::read.csv(FEATURES_PATH, stringsAsFactors = FALSE)$source_file)
  train_ids <- stats::na.omit(observation_id(train_files))

  annotation <- utils::read.csv(file.path(RAW_DIR, "insectset459", "annotation.csv"), stringsAsFactors = FALSE)

  manifest_env <- new.env()
  manifest_env$manifest <- read_manifest()

  summary <- list()
  for (target in INSECTSET459_TARGET_SPECIES) {
    sub_df <- annotation[annotation$species_name == target$species, ]
    sub_df$obs_id <- observation_id(sub_df$file_name)
    # iNaturalist only: it always reports Content-Length on HEAD, so "small
    # files only" can be enforced before downloading (see R/01_download_data.R).
    eligible <- sub_df[!is.na(sub_df$obs_id) &
                       !(sub_df$obs_id %in% train_ids) &
                       grepl("^https://static\\.inaturalist\\.org/", sub_df$file), ]
    # One recording per observation, so five clips really are five sources.
    eligible <- eligible[!duplicated(eligible$obs_id), ]

    set.seed(20260729)
    eligible <- eligible[sample(nrow(eligible)), ]

    dest_dir <- file.path(HELDOUT_DIR, target$label)
    n_ok <- sum(file.exists(file.path(dest_dir, eligible$file_name)))
    n_skipped_large <- 0
    for (i in seq_len(nrow(eligible))) {
      if (n_ok >= n_per_species) break
      row <- eligible[i, ]
      dest_path <- file.path(dest_dir, row$file_name)
      if (file.exists(dest_path)) next
      size_bytes <- head_content_length(row$file)
      if (is.na(size_bytes) || size_bytes > HELDOUT_MAX_FILE_BYTES) {
        n_skipped_large <- n_skipped_large + 1
        next
      }
      if (download_tracked(row$file, dest_path, HELDOUT_SOURCE, target$label, row$license,
                            manifest_env, timeout_s = INSECTSET459_TIMEOUT_S)) {
        n_ok <- n_ok + 1
      }
    }
    message(sprintf("%s: %d held-out recordings on disk (%d eligible observations not used in training; %d skipped as >%.0fMB or unknown size).",
                    target$label, n_ok, nrow(eligible), n_skipped_large, HELDOUT_MAX_FILE_BYTES / 1024^2))
    summary[[target$label]] <- n_ok
  }
  make_demo_clips(annotation)
  invisible(summary)
}

# ---- demo_clips/: one held-out clip per species, to play aloud -------------

DEMO_CLIPS_DIR <- "demo_clips"
DEMO_TARGET_SECONDS <- 20

#' Write one held-out clip per species to demo_clips/ as a WAV for playing
#' out loud during a live demo (the phone then records + compresses it like
#' any real voice note). Picks the held-out recording closest to
#' DEMO_TARGET_SECONDS long (at least 10s, so a voice note of it clears the
#' webhook's 3s minimum comfortably), loudness-normalized the same way as the
#' round-trip "sent" files so playback levels are consistent. Writes a
#' README with source and licence for each (most are CC BY-NC: attribution
#' required, non-commercial use only).
make_demo_clips <- function(annotation) {
  ensure_dir(DEMO_CLIPS_DIR)
  rows <- list()
  for (target in INSECTSET459_TARGET_SPECIES) {
    files <- list.files(file.path(HELDOUT_DIR, target$label), full.names = TRUE)
    if (length(files) == 0) next
    durations <- vapply(files, function(f) {
      w <- whatsappaudioR::wa_read(f)
      length(w@left) / w@samp.rate
    }, numeric(1))
    ok <- durations >= 10
    if (!any(ok)) {
      message("No held-out ", target$label, " clip is 10s or longer -- no demo clip written for it.")
      next
    }
    pick <- files[ok][which.min(abs(durations[ok] - DEMO_TARGET_SECONDS))]
    dest <- file.path(DEMO_CLIPS_DIR, paste0(target$label, ".wav"))
    status <- system2(Sys.which("ffmpeg"), args = c(
      "-y", "-loglevel", "error", "-i", pick,
      "-af", "loudnorm=I=-16:TP=-1.5:LRA=11", "-ar", "44100", "-ac", "1", dest
    ))
    if (status != 0) stop("ffmpeg failed writing ", dest)
    meta <- annotation[annotation$file_name == basename(pick), ][1, ]
    rows[[length(rows) + 1]] <- sprintf("| `%s` | *%s* | %.0fs | %s | [observation](%s) | %s |",
      basename(dest), gsub("_", " ", target$species), durations[pick], meta$contributor,
      meta$observation, meta$license)
  }
  writeLines(c(
    "# Demo clips",
    "",
    "One **held-out** recording per target species -- never used to train the classifier",
    "(different iNaturalist observations from every training recording; see",
    "`R/fetch_heldout_insectset.R`). Play one out loud near a phone and record it as a",
    "WhatsApp voice note during a live demo.",
    "",
    "Loudness-normalized to -16 LUFS, 44.1kHz mono. Regenerate with",
    "`Rscript R/fetch_heldout_insectset.R`.",
    "",
    "| File | Species | Length | Recorded by | Source | Licence |",
    "|---|---|---|---|---|---|",
    unlist(rows),
    "",
    "Source: InsectSet459 (Zenodo 10.5281/zenodo.18554693), original recordings from",
    "iNaturalist. Licences as listed per recording -- CC BY-NC requires attribution and",
    "non-commercial use only."
  ), file.path(DEMO_CLIPS_DIR, "README.md"))
  message("Wrote ", length(rows), " demo clips to ", DEMO_CLIPS_DIR, "/")
}

if (sys.nframe() == 0) {
  main()
}
