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
# Raised from 20 -> 30 (Prompt 5) -> 45 (Prompt 8, Step 2): Prompt 7's
# 50-seed analysis found this classifier's accuracy swinging ~10-92% seed
# to seed with only 22/17/20 source files per real species, because a
# grouped split's test set for a class that small is often ONE recording
# -- accuracy then tracks which recording happened to land in test, not
# anything the model is good or bad at. The annotation CSV has far more
# available (~184/102/428 rows for the 3 target species) than was ever
# fetched; targeting 40-50 per species stays well inside that and inside
# the 2GB cap. Individual downloads get a longer per-file timeout than the
# 60s default here (see fetch_insectset459); idempotency means re-running
# only retries what's still missing, it doesn't re-fetch what already
# succeeded.
INSECTSET459_MAX_FILES_PER_SPECIES <- 45
INSECTSET459_TIMEOUT_S <- 120

# The annotation CSV exposes no duration or file-size column (checked --
# see PROGRESS.md), so "prefer many short clips over few long ones" (Prompt
# 8, Step 2) is implemented via a lightweight HTTP HEAD probe per candidate
# before committing to a full download, rather than a CSV sort. Skipping
# anything the probe reports over this size avoids both the timeout risk
# large files caused in earlier sessions AND the exact problem Step 1
# fixed at the classifier end: a handful of very long recordings each
# contributing hundreds of windows and dominating whichever fold they land
# in. If the HEAD probe can't determine a size, the candidate is now SKIPPED
# (not attempted) -- see fetch_insectset459() for why: xeno-canto.org never
# sends Content-Length on HEAD, and its files run large (37MB and 71MB+
# seen directly this session), so "unknown" turned out to mean "probably
# large," not "probably fine."
INSECTSET459_MAX_FILE_BYTES <- 20 * 1024^2  # ~20MB
INSECTSET459_HEAD_TIMEOUT_S <- 15

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
#' IMPORTANT: if the file is already on disk but has no manifest row (found
#' this exact state once already -- a whole USDA-ARS chewing-sound corpus
#' had downloaded fine but was invisible to collect_labeled_sources() forever
#' because its manifest rows never got written/were lost), backfill the
#' entry rather than silently trusting the file and moving on. Otherwise a
#' lost or partially-regenerated manifest.csv permanently hides real,
#' already-downloaded data with no error or warning.
#'
#' @param timeout_s Per-request timeout. Defaults short (60s) since most
#'   calls here are small individual audio files; a hung connection to one
#'   file should fail fast, not block the whole run for up to 30 minutes.
#'   Pass a larger value explicitly for genuinely large archives (e.g. the
#'   ESC-50 zip, which needs ~30 min on this connection's ~0.5MB/s).
download_tracked <- function(url, dest_path, source, label, license, manifest_env, timeout_s = 60) {
  if (file.exists(dest_path)) {
    if (!(dest_path %in% manifest_env$manifest$file)) {
      message("  ", dest_path, " already on disk but missing from the manifest -- backfilling its entry.")
      manifest_env$manifest <- append_manifest(manifest_env$manifest, list(
        file = dest_path, source = source, source_url = url, label = label,
        license = license, md5 = unname(tools::md5sum(dest_path)),
        bytes = file.info(dest_path)$size,
        downloaded_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z")
      ))
    }
    return(TRUE)  # idempotent: trust an already-downloaded file's bytes
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

  # BUG FOUND (Prompt 8, Step 2): this loop used to unconditionally
  # append_manifest() every matching clip on EVERY run of this script,
  # unlike download_tracked() (which checks `file %in% manifest$file`
  # first). Across this project's multiple sessions, that meant the same
  # ~561 ESC-50 files got re-registered into manifest.csv on every re-run
  # -- 5 duplicate rows per file found in the manifest this session,
  # inflating the "total bytes downloaded" the 2GB cap checks against by
  # ~1.5GB of PHANTOM re-counted bytes (nothing was actually downloaded
  # again; the same on-disk file's size was just added to the running
  # total repeatedly). This silently and falsely tripped the download cap
  # for Step 2's corpus expansion, blocking every single new download
  # attempt. Fixed by checking for an existing row first, same as
  # download_tracked().
  n_registered <- 0
  for (i in seq_len(nrow(kept))) {
    src_wav <- file.path(extract_dir, "audio", kept$filename[i])
    if (!file.exists(src_wav)) next
    if (src_wav %in% manifest_env$manifest$file) next
    manifest_env$manifest <- append_manifest(manifest_env$manifest, list(
      file = src_wav, source = "ESC-50", source_url = ESC50_ZIP_URL,
      label = paste0("ambient_", kept$category[i]), license = ESC50_LICENSE,
      md5 = unname(tools::md5sum(src_wav)), bytes = file.info(src_wav)$size,
      downloaded_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z")
    ))
    n_registered <- n_registered + 1
  }

  message("ESC-50: ", n_registered, " newly registered, ", nrow(kept) - n_registered,
          " already in the manifest, of ", nrow(kept), " matching clips across ",
          length(AMBIENT_CATEGORIES), " categories.")
  invisible(kept)
}

# ---- InsectSet459 (real target-species audio, direct source URLs) --------

#' HEAD-probe a URL's Content-Length without downloading the body. Returns
#' NA_real_ if the request fails or the header is absent (some hosts don't
#' send Content-Length on HEAD) -- callers should treat NA as "unknown",
#' not "large".
head_content_length <- function(url, timeout_s = INSECTSET459_HEAD_TIMEOUT_S) {
  tryCatch({
    req <- httr2::request(url) |> httr2::req_method("HEAD") |> httr2::req_timeout(timeout_s)
    resp <- httr2::req_perform(req)
    len <- httr2::resp_header(resp, "content-length")
    if (is.null(len)) NA_real_ else as.numeric(len)
  }, error = function(e) NA_real_)
}

#' Fetch the InsectSet459 annotation CSV (small, ~6.9MB metadata file --
#' NOT one of the multi-GB audio zips) and, for each target species, download
#' recordings directly from their original iNaturalist source URL (the CSV's
#' `file` column), bypassing the zips entirely, until
#' INSECTSET459_MAX_FILES_PER_SPECIES successful downloads are reached or the
#' species' candidates are exhausted.
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
    shuffled_idx <- sample(seq_len(nrow(sub_df)))

    dest_dir <- file.path(RAW_DIR, "insectset459", target$label)
    n_ok <- 0
    n_skipped_large <- 0
    n_attempted <- 0
    for (i in shuffled_idx) {
      if (n_ok >= INSECTSET459_MAX_FILES_PER_SPECIES) break
      row <- sub_df[i, ]
      file_url <- row$file
      if (is.na(file_url) || file_url == "") next
      dest_path <- file.path(dest_dir, row$file_name)

      if (!file.exists(dest_path)) {
        size_bytes <- head_content_length(file_url)
        # Skip on an unknown size too, not just a known-large one. Verified
        # empirically this session: static.inaturalist.org always returns
        # Content-Length on HEAD, but xeno-canto.org's /download endpoint
        # NEVER does (confirmed against 3 real URLs) -- and xeno-canto files
        # in this CSV run large (one candidate turned out to be 37MB, another
        # 71MB+, discovered only because a full download was attempted and
        # had to be killed mid-transfer after burning several minutes and
        # bandwidth on ONE file). "Unknown" was originally meant to fail
        # open (attempt anyway) for hosts that just don't send the header on
        # legitimately small files; in practice here it was hiding exactly
        # the large-file risk this filter exists to catch, so it now fails
        # closed. InsectSet459 has far more candidates than needed, nearly
        # all iNaturalist (which always reports its size), so this costs
        # negligible coverage.
        if (is.na(size_bytes) || size_bytes > INSECTSET459_MAX_FILE_BYTES) {
          n_skipped_large <- n_skipped_large + 1
          next
        }
      }

      n_attempted <- n_attempted + 1
      if (download_tracked(file_url, dest_path, "InsectSet459", target$label, row$license, manifest_env,
                            timeout_s = INSECTSET459_TIMEOUT_S)) {
        n_ok <- n_ok + 1
      }
    }

    message("InsectSet459 '", target$species, "': downloaded ", n_ok, " of ",
            n_attempted, " attempted (", n_skipped_large, " skipped as >",
            INSECTSET459_MAX_FILE_BYTES / 1e6, "MB by HEAD probe; ",
            nrow(sub_df), " total available in the CSV).")
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
