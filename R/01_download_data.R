# Deliverable C -- Data pipeline, step 1: fetch a scoped real-data corpus.
#
# InsectSet459 itself (Zenodo record 10.5281/zenodo.18554693, concept DOI
# 10.5281/zenodo.14056457) only distributes as three monolithic zips
# (Train.zip 51.2GB, Validation.zip 16.4GB, Test.zip 16.0GB -- 83.7GB total,
# and note even the *smallest* split alone is 16.4GB, nowhere near our 2GB
# cap despite that being the plan). Confirmed via a HEAD/Range request that
# Zenodo's storage does support byte-range requests (206 Partial Content),
# so partial in-zip extraction was technically possible -- but turned out
# to be unnecessary: the annotation CSV's `file` column links directly to
# each recording's original source file on iNaturalist (all 12,915 rows in
# the CSV resolve to static.inaturalist.org), so we can fetch exactly the
# files we want directly from their original public URLs without touching
# the zips at all. xeno-canto is NOT used here (abandoned per instruction --
# its public API v2 returns HTTP 404 on every query, most likely because
# it's deprecated in favour of v3, which needs a registered key; not worth
# the time for what direct-URL access via InsectSet459's own CSV already
# solves better).
#
# Ambient/negative class: ESC-50 (github.com/karolpiczak/ESC-50), a single
# ~600MB zip, CC BY-NC 3.0.
#
# Idempotent: re-running skips files already recorded in the manifest with
# their bytes intact. Respects a 2GB total download cap across everything
# this script downloads (tracked via the manifest, not just this run) --
# though in practice this real-audio approach uses well under 100MB.
#
# Usage:
#   Rscript R/01_download_data.R

library(httr2)
library(jsonlite)

source(file.path("R", "utils.R"))

RAW_DIR       <- file.path("data", "raw")
MANIFEST_PATH <- file.path(RAW_DIR, "manifest.csv")
BLOCKERS_PATH <- "BLOCKERS.md"
DOWNLOAD_CAP_BYTES <- 2 * 1024^3  # 2 GB, per the brief's guardrail

ESC50_ZIP_URL <- "https://codeload.github.com/karolpiczak/ESC-50/zip/refs/heads/master"
ESC50_LICENSE <- "CC BY-NC 3.0 (https://github.com/karolpiczak/ESC-50)"

# Ambient/negative categories relevant to a farm-at-night setting, selected
# from ESC-50's 50 classes. Includes "crickets" deliberately as a hard
# negative: a real Orthoptera sound that is NOT one of our target pests, to
# stress-test whether the classifier is actually discriminating species
# rather than just "insect vs not".
AMBIENT_CATEGORIES <- c(
  "wind", "rain", "crickets", "frog", "dog", "cow", "engine",
  "footsteps", "door_wood_knock", "clock_tick", "crackling_fire",
  "chirping_birds", "car_horn", "airplane"
)

# InsectSet459 metadata (small CSV, not the multi-GB zips -- see header note).
INSECTSET459_CSV_URL <- "https://zenodo.org/records/18554693/files/InsectSet459_Train_Val_Test_Annotation.csv?download=1"
INSECTSET459_ZENODO_RECORD_URL <- "https://zenodo.org/records/18554693"

# Target species: Orthoptera grasshoppers (Acrididae -- the closest real
# taxonomic proxy to locust/grasshopper pest relevance in this dataset;
# InsectSet459 doesn't include Schistocerca/Locusta specifically) first,
# Cicadidae as a secondary real acoustic category to discriminate against
# (loud, distinctive, per the run instructions). Species chosen for having
# reasonable representation in the annotation CSV (checked empirically --
# see PROGRESS.md).
INSECTSET459_TARGET_SPECIES <- list(
  list(species = "Chorthippus_biguttulus", label = "chorthippus_biguttulus", group = "Orthoptera"),
  list(species = "Chorthippus_brunneus",   label = "chorthippus_brunneus",   group = "Orthoptera"),
  list(species = "Cicada_orni",            label = "cicada_orni",           group = "Cicadidae")
)
# Raised from 20 -> 30 (Prompt 5, Step 2c): 40 source files across 3 species
# was thin for a grouped split. Individual downloads also get a longer
# per-file timeout than the 60s default here (see fetch_insectset459) --
# the first pass's 60s timeout left some attempts short on a slow
# connection (~0.5MB/s observed); idempotency means re-running only
# retries what's still missing, it doesn't re-fetch what already succeeded.
INSECTSET459_MAX_FILES_PER_SPECIES <- 30
INSECTSET459_TIMEOUT_S <- 120

# ---- Manifest -----------------------------------------------------------

read_manifest <- function() {
  if (!file.exists(MANIFEST_PATH)) {
    return(data.frame(
      file = character(), source = character(), source_url = character(),
      label = character(), license = character(), md5 = character(),
      bytes = numeric(), downloaded_at = character(),
      stringsAsFactors = FALSE
    ))
  }
  utils::read.csv(MANIFEST_PATH, stringsAsFactors = FALSE)
}

append_manifest <- function(manifest, row) {
  updated <- rbind(manifest, as.data.frame(row, stringsAsFactors = FALSE))
  ensure_dir(dirname(MANIFEST_PATH))
  utils::write.csv(updated, MANIFEST_PATH, row.names = FALSE)
  updated
}

#' Append a blocker entry, unless an entry with the same "what_tried" title
#' already exists -- avoids spamming BLOCKERS.md with duplicate entries every
#' time this idempotent script is re-run and hits the same known issue.
log_blocker <- function(what_tried, error_msg, believed_fix, what_jitu_needs) {
  ensure_dir(dirname(BLOCKERS_PATH))
  if (file.exists(BLOCKERS_PATH)) {
    existing <- paste(readLines(BLOCKERS_PATH, warn = FALSE), collapse = "\n")
    if (grepl(paste0("-- ", what_tried, "\n"), existing, fixed = TRUE)) {
      return(invisible(NULL))
    }
  }
  entry <- paste0(
    "\n## ", format(Sys.time(), "%Y-%m-%d %H:%M"), " -- ", what_tried, "\n\n",
    "**Error:** ", error_msg, "\n\n",
    "**Believed fix:** ", believed_fix, "\n\n",
    "**What Jitu needs to do:** ", what_jitu_needs, "\n"
  )
  cat(entry, file = BLOCKERS_PATH, append = TRUE)
  invisible(entry)
}

# ---- Download helper with cap + idempotency ------------------------------

#' Download a file if not already present in the manifest, respecting the
#' global byte cap. Returns TRUE if the file exists on disk afterwards
#' (whether freshly downloaded or already cached), FALSE if skipped/failed.
#'
#' @param timeout_s Per-request timeout. Defaults short (60s) since most
#'   calls here are small individual audio files; a hung connection to one
#'   file should fail fast, not block the whole run for up to 30 minutes.
#'   Pass a larger value explicitly for genuinely large archives (e.g. the
#'   ESC-50 zip, which needs ~30 min on this connection's ~0.5MB/s).
download_tracked <- function(url, dest_path, source, label, license, manifest_env, timeout_s = 60) {
  if (file.exists(dest_path)) {
    return(TRUE)  # idempotent: trust an already-downloaded file
  }

  current_total <- sum(manifest_env$manifest$bytes, na.rm = TRUE)
  if (current_total >= DOWNLOAD_CAP_BYTES) {
    message("Download cap (2GB) reached -- skipping ", url)
    return(FALSE)
  }

  message("  downloading ", url, " -> ", dest_path, " ...")
  ensure_dir(dirname(dest_path))
  ok <- tryCatch({
    req <- httr2::request(url) |> httr2::req_timeout(timeout_s)
    resp <- httr2::req_perform(req, path = dest_path)
    httr2::resp_status(resp) < 400
  }, error = function(e) {
    message("  FAILED: ", url, ": ", conditionMessage(e))
    FALSE
  })

  if (!ok) {
    unlink(dest_path)
    return(FALSE)
  }

  bytes <- file.info(dest_path)$size
  md5 <- unname(tools::md5sum(dest_path))
  manifest_env$manifest <- append_manifest(manifest_env$manifest, list(
    file = dest_path, source = source, source_url = url, label = label,
    license = license, md5 = md5, bytes = bytes,
    downloaded_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z")
  ))
  TRUE
}

# ---- ESC-50 (ambient / negative class) -----------------------------------

fetch_esc50 <- function(manifest_env) {
  zip_path <- file.path(RAW_DIR, "esc50", "ESC-50-master.zip")
  extract_dir <- file.path(RAW_DIR, "esc50", "ESC-50-master")

  ok <- download_tracked(ESC50_ZIP_URL, zip_path, "ESC-50", "ambient_corpus",
                          ESC50_LICENSE, manifest_env, timeout_s = 1800)
  if (!ok && !file.exists(zip_path)) {
    log_blocker(
      "Download ESC-50 ambient corpus",
      "download_tracked() returned FALSE for the ESC-50 zip (see console output above for the underlying error)",
      "Check network access to codeload.github.com, or manually download https://github.com/karolpiczak/ESC-50 and place ESC-50-master.zip at data/raw/esc50/",
      "Nothing required unless the automated download keeps failing -- check BLOCKERS.md history for repeat failures"
    )
    return(invisible(NULL))
  }

  if (!dir.exists(extract_dir)) {
    utils::unzip(zip_path, exdir = file.path(RAW_DIR, "esc50"))
  }

  meta_path <- file.path(extract_dir, "meta", "esc50.csv")
  if (!file.exists(meta_path)) {
    log_blocker(
      "Locate ESC-50 metadata CSV after extraction",
      paste0("Expected ", meta_path, " but it does not exist"),
      "ESC-50's internal zip structure may have changed since this script was written",
      "Manually inspect data/raw/esc50/ESC-50-master/ and update fetch_esc50()'s expected paths in R/01_download_data.R"
    )
    return(invisible(NULL))
  }

  esc_meta <- utils::read.csv(meta_path, stringsAsFactors = FALSE)
  kept <- esc_meta[esc_meta$category %in% AMBIENT_CATEGORIES, ]

  for (i in seq_len(nrow(kept))) {
    src_wav <- file.path(extract_dir, "audio", kept$filename[i])
    if (!file.exists(src_wav)) next
    manifest_env$manifest <- append_manifest(manifest_env$manifest, list(
      file = src_wav, source = "ESC-50", source_url = ESC50_ZIP_URL,
      label = paste0("ambient_", kept$category[i]), license = ESC50_LICENSE,
      md5 = unname(tools::md5sum(src_wav)), bytes = file.info(src_wav)$size,
      downloaded_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z")
    ))
  }

  message("ESC-50: registered ", nrow(kept), " ambient clips across ",
          length(AMBIENT_CATEGORIES), " categories in the manifest.")
  invisible(kept)
}

# ---- InsectSet459 (real target-species audio, direct source URLs) --------

#' Fetch the InsectSet459 annotation CSV (small, ~6.9MB metadata file --
#' NOT one of the multi-GB audio zips) and, for each target species, sample
#' up to INSECTSET459_MAX_FILES_PER_SPECIES recordings and download them
#' directly from their original iNaturalist source URL (the CSV's `file`
#' column), bypassing the zips entirely.
fetch_insectset459 <- function(manifest_env) {
  csv_path <- file.path(RAW_DIR, "insectset459", "annotation.csv")
  ok <- download_tracked(INSECTSET459_CSV_URL, csv_path, "InsectSet459-meta",
                          "annotation_csv", "CC-BY-4.0", manifest_env)
  if (!ok && !file.exists(csv_path)) {
    log_blocker(
      "Download InsectSet459 annotation CSV",
      "download_tracked() returned FALSE for the annotation CSV (see console output above)",
      paste0("Check network access to zenodo.org, or manually download ", INSECTSET459_CSV_URL,
             " and place it at ", csv_path),
      "Nothing required unless the automated download keeps failing"
    )
    return(invisible(NULL))
  }

  annotation <- utils::read.csv(csv_path, stringsAsFactors = FALSE)

  for (target in INSECTSET459_TARGET_SPECIES) {
    sub_df <- annotation[annotation$species_name == target$species, ]
    if (nrow(sub_df) == 0) {
      log_blocker(
        paste0("InsectSet459 species coverage for '", target$species, "'"),
        "Annotation CSV has zero rows for this species_name",
        "Species name may not match the CSV's naming convention (underscored binomial) -- check InsectSet459_Train_Val_Test_Annotation.csv directly",
        paste0("Pick a different target species from the CSV's species_name column, or accept synthetic-only coverage for this class")
      )
      next
    }

    set.seed(20260729)
    take_idx <- if (nrow(sub_df) > INSECTSET459_MAX_FILES_PER_SPECIES) {
      sample(seq_len(nrow(sub_df)), INSECTSET459_MAX_FILES_PER_SPECIES)
    } else {
      seq_len(nrow(sub_df))
    }

    dest_dir <- file.path(RAW_DIR, "insectset459", target$label)
    n_ok <- 0
    for (i in take_idx) {
      row <- sub_df[i, ]
      file_url <- row$file
      if (is.na(file_url) || file_url == "") next
      dest_path <- file.path(dest_dir, row$file_name)
      if (download_tracked(file_url, dest_path, "InsectSet459", target$label, row$license, manifest_env,
                            timeout_s = INSECTSET459_TIMEOUT_S)) {
        n_ok <- n_ok + 1
      }
    }

    message("InsectSet459 '", target$species, "': downloaded ", n_ok, " of ",
            length(take_idx), " attempted (", nrow(sub_df), " available in the CSV).")
  }

  invisible(annotation)
}

# ---- Entry point ----------------------------------------------------------

main <- function() {
  manifest_env <- new.env()
  manifest_env$manifest <- read_manifest()

  fetch_esc50(manifest_env)
  fetch_insectset459(manifest_env)

  total_bytes <- sum(manifest_env$manifest$bytes, na.rm = TRUE)
  message(sprintf("Done. Manifest has %d entries, %.1f MB total (cap: %.0f MB).",
                   nrow(manifest_env$manifest), total_bytes / 1e6,
                   DOWNLOAD_CAP_BYTES / 1e6))
  invisible(manifest_env$manifest)
}

if (sys.nframe() == 0) {
  main()
}
