# Deliverable C -- Data pipeline, step 1: fetch a scoped real-data corpus.
#
# InsectSet459 itself (Zenodo record 10.5281/zenodo.18554693) only distributes
# as three monolithic zips (Train.zip 51.2GB, Validation.zip 16.4GB,
# Test.zip 16.0GB -- 83.7GB total). That is far over our 2GB download cap and
# there is no per-species download option on Zenodo for this record. Per the
# brief's own fallback instruction, this script pulls a small real-audio
# corpus directly from the original sources instead:
#
#   - Target-species Orthoptera recordings from xeno-canto (which added
#     grasshopper/cricket coverage alongside its original bird archive).
#   - The ambient/negative class from ESC-50 (github.com/karolpiczak/ESC-50),
#     a single ~600MB zip, CC BY-NC 3.0.
#
# Idempotent: re-running skips files already recorded in the manifest with
# their bytes intact. Respects a 2GB total download cap across everything
# this script downloads (tracked via the manifest, not just this run).
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

# Target pest species to search on xeno-canto. Each entry: scientific name
# used in the API query, and a short label for our directory/species naming.
# Mosquito (Culicidae/Diptera) is included speculatively -- xeno-canto's
# insect expansion is documented as covering Orthoptera (grasshoppers/
# crickets); whether it also carries mosquito recordings is unverified as of
# writing this script. If the query returns zero results, that is logged,
# not treated as an error.
XC_TARGET_SPECIES <- list(
  list(query = "Schistocerca gregaria", label = "desert_locust"),
  list(query = "Locusta migratoria", label = "migratory_locust"),
  list(query = "gen:Culex", label = "culex_mosquito")
)
XC_MAX_FILES_PER_SPECIES <- 8

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
download_tracked <- function(url, dest_path, source, label, license, manifest_env) {
  if (file.exists(dest_path)) {
    return(TRUE)  # idempotent: trust an already-downloaded file
  }

  current_total <- sum(manifest_env$manifest$bytes, na.rm = TRUE)
  if (current_total >= DOWNLOAD_CAP_BYTES) {
    message("Download cap (2GB) reached -- skipping ", url)
    return(FALSE)
  }

  ensure_dir(dirname(dest_path))
  ok <- tryCatch({
    req <- httr2::request(url) |> httr2::req_timeout(1800)
    resp <- httr2::req_perform(req, path = dest_path)
    httr2::resp_status(resp) < 400
  }, error = function(e) {
    message("Download failed for ", url, ": ", conditionMessage(e))
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
                          ESC50_LICENSE, manifest_env)
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

# ---- xeno-canto (target pest species) ------------------------------------

fetch_xenocanto_species <- function(target, manifest_env) {
  api_url <- paste0("https://xeno-canto.org/api/2/recordings?query=",
                     utils::URLencode(target$query, reserved = TRUE))

  parsed <- tryCatch({
    resp <- httr2::request(api_url) |> httr2::req_timeout(60) |> httr2::req_perform()
    ctype <- httr2::resp_content_type(resp)
    if (!grepl("json", ctype, ignore.case = TRUE)) {
      stop("Expected JSON, got content-type '", ctype, "' -- likely a bot-check/HTML block page, not the API")
    }
    jsonlite::fromJSON(httr2::resp_body_string(resp))
  }, error = function(e) {
    message("xeno-canto query failed for ", target$query, ": ", conditionMessage(e))
    NULL
  })

  if (is.null(parsed)) {
    log_blocker(
      paste0("xeno-canto API query for '", target$query, "'"),
      "Request failed or returned non-JSON (possibly an anti-bot block page -- xeno-canto is known to run bot protection that can reject non-browser requests)",
      "May need a registered API key (xeno-canto API v3 requires one), a different User-Agent, or manual browser-based download of a handful of clips for this species",
      paste0("If this species has zero downloaded clips in data/raw/manifest.csv, either get an xeno-canto API key and update R/01_download_data.R, or manually download ~5 recordings for '", target$query, "' from xeno-canto.org and place them under data/raw/xenocanto/", target$label, "/")
    )
    return(invisible(NULL))
  }

  n_found <- suppressWarnings(as.integer(parsed$numRecordings))
  if (is.na(n_found) || n_found == 0 || is.null(parsed$recordings) || length(parsed$recordings) == 0) {
    log_blocker(
      paste0("xeno-canto species coverage for '", target$query, "'"),
      "API responded but returned zero recordings for this query",
      "xeno-canto's Orthoptera/insect coverage may not include this species, or the query syntax needs adjusting",
      paste0("Confirm whether '", target$query, "' has any recordings on xeno-canto.org manually; if not, the synthetic corpus (R/00_synthetic_corpus.R) is this species' only reference audio for now")
    )
    return(invisible(NULL))
  }

  recs <- parsed$recordings
  n_take <- min(XC_MAX_FILES_PER_SPECIES, nrow(recs))
  taken <- recs[seq_len(n_take), ]

  dest_dir <- file.path(RAW_DIR, "xenocanto", target$label)
  for (i in seq_len(nrow(taken))) {
    rec <- taken[i, ]
    file_url <- rec$file
    if (is.null(file_url) || is.na(file_url) || file_url == "") next
    ext <- tools::file_ext(rec[["file-name"]])
    if (is.na(ext) || ext == "") ext <- "mp3"
    dest_path <- file.path(dest_dir, paste0(target$label, "_", rec$id, ".", ext))

    license_url <- if (!is.null(rec$lic)) rec$lic else "unknown -- check recording page on xeno-canto.org"
    download_tracked(file_url, dest_path, "xeno-canto", target$label, license_url, manifest_env)
  }

  message("xeno-canto '", target$query, "': attempted ", nrow(taken), " of ",
          n_found, " available recordings.")
  invisible(taken)
}

# ---- Entry point ----------------------------------------------------------

main <- function() {
  manifest_env <- new.env()
  manifest_env$manifest <- read_manifest()

  fetch_esc50(manifest_env)

  for (target in XC_TARGET_SPECIES) {
    fetch_xenocanto_species(target, manifest_env)
  }

  total_bytes <- sum(manifest_env$manifest$bytes, na.rm = TRUE)
  message(sprintf("Done. Manifest has %d entries, %.1f MB total (cap: %.0f MB).",
                   nrow(manifest_env$manifest), total_bytes / 1e6,
                   DOWNLOAD_CAP_BYTES / 1e6))
  invisible(manifest_env$manifest)
}

if (sys.nframe() == 0) {
  main()
}
