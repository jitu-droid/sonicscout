# Prompt 4, Step 4 -- resolves the chewing-sound scope question.
#
# InsectSet459 contains only Orthoptera and Cicadidae -- it cannot answer
# whether lepidopteran larval chewing survives WhatsApp compression, because
# it has no lepidopteran larvae at all. Time-boxed search found the USDA-ARS
# "Reference Library of Digitized Insect Sounds"
# (ars.usda.gov/ARSUserFiles/3559/soundlibrary.html), which hosts real
# larval feeding/chewing recordings as plain .wav files, including
# Plodia interpunctella (Indian meal moth) -- a Lepidoptera larva, the same
# order as Fall Armyworm (Spodoptera frugiperda), making it a far closer
# taxonomic/behavioural proxy than any Coleoptera larva would be.
#
# LICENSING NOTE: this page has no explicit Creative Commons / licence
# statement. It is hosted by USDA-ARS, a US federal agency; works produced
# by the US federal government are presumed public domain under
# 17 U.S.C. section 105, but that is a presumption based on the hosting
# agency, not an explicit licence grant on the page itself -- record this
# caveat verbatim in the manifest and don't present it as equivalent to an
# explicit CC0/CC-BY dataset.
#
# Usage:
#   Rscript R/fetch_chewing_sounds.R

library(httr2)

source(file.path("R", "utils.R"))

RAW_DIR       <- file.path("data", "raw")
MANIFEST_PATH <- file.path(RAW_DIR, "manifest.csv")
BASE_URL      <- "https://www.ars.usda.gov/ARSUserFiles/3559/"
LICENSE_NOTE  <- "US Government work (USDA-ARS) -- presumed public domain under 17 U.S.C. sec 105; no explicit licence statement on the source page (ars.usda.gov/ARSUserFiles/3559/soundlibrary.html)"

# species -> (label used for classes/directories, file list on the page)
CHEWING_FILES <- list(
  list(species = "Plodia_interpunctella", label = "chewing_plodia_interpunctella",
       files = c("dfaccs11.wav", "piezimm1.wav")),  # Lepidoptera larva -- closest proxy to Fall Armyworm
  list(species = "Sitophilus_oryzae", label = "chewing_sitophilus_oryzae",
       files = c("pvdfrw1.wav", "accelrw.wav", "w40khzrw1.wav", "w30khzrw1.wav", "piezorw1.wav")),
  list(species = "Phyllophaga", label = "chewing_phyllophaga",
       files = c("grubsnd.wav", "unid5ed.wav", "seg20l1.wav", "seg20r1.wav")),
  list(species = "Diaprepes_abbreviatus", label = "chewing_diaprepes_abbreviatus",
       files = c("diaplab.wav", "diapfld.wav", "diaprep1.wav")),
  list(species = "Otiorhynchus_sulcatus", label = "chewing_otiorhynchus_sulcatus",
       files = c("bvws22-2.wav"))
)

read_manifest <- function() {
  if (!file.exists(MANIFEST_PATH)) {
    return(data.frame(file = character(), source = character(), source_url = character(),
                       label = character(), license = character(), md5 = character(),
                       bytes = numeric(), downloaded_at = character(), stringsAsFactors = FALSE))
  }
  utils::read.csv(MANIFEST_PATH, stringsAsFactors = FALSE)
}

append_manifest <- function(manifest, row) {
  updated <- rbind(manifest, as.data.frame(row, stringsAsFactors = FALSE))
  ensure_dir(dirname(MANIFEST_PATH))
  utils::write.csv(updated, MANIFEST_PATH, row.names = FALSE)
  updated
}

#' Download a file if needed, and (this is the important part) ALWAYS make
#' sure it has a manifest row -- not just when freshly downloaded. Caught a
#' real bug from this: files already present on disk (from an earlier,
#' possibly now-lost manifest state) were silently invisible to
#' collect_labeled_sources() forever, because the old logic returned early
#' on `file.exists(dest_path)` before ever registering/backfilling a
#' manifest entry for them.
download_one <- function(url, dest_path, label, manifest) {
  if (file.exists(dest_path)) {
    already_recorded <- dest_path %in% manifest$file
    if (already_recorded) return(manifest)
    message("  ", dest_path, " already on disk but missing from the manifest -- backfilling its entry.")
    return(append_manifest(manifest, list(
      file = dest_path, source = "USDA-ARS-soundlibrary", source_url = url,
      label = label, license = LICENSE_NOTE,
      md5 = unname(tools::md5sum(dest_path)), bytes = file.info(dest_path)$size,
      downloaded_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z")
    )))
  }

  message("  downloading ", url, " ...")
  ensure_dir(dirname(dest_path))
  ok <- tryCatch({
    resp <- httr2::request(url) |> httr2::req_timeout(60) |> httr2::req_perform(path = dest_path)
    httr2::resp_status(resp) < 400
  }, error = function(e) {
    message("  FAILED: ", conditionMessage(e))
    FALSE
  })
  if (!ok) { unlink(dest_path); return(manifest) }

  append_manifest(manifest, list(
    file = dest_path, source = "USDA-ARS-soundlibrary", source_url = url,
    label = label, license = LICENSE_NOTE,
    md5 = unname(tools::md5sum(dest_path)), bytes = file.info(dest_path)$size,
    downloaded_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z")
  ))
}

main <- function() {
  manifest <- read_manifest()
  for (entry in CHEWING_FILES) {
    dest_dir <- file.path(RAW_DIR, "chewing_sounds", entry$label)
    for (fname in entry$files) {
      url <- paste0(BASE_URL, fname)
      dest_path <- file.path(dest_dir, fname)
      manifest <- download_one(url, dest_path, entry$label, manifest)
    }
    n_have <- length(list.files(dest_dir, pattern = "\\.wav$"))
    message("Chewing sounds '", entry$species, "': ", n_have, " of ",
            length(entry$files), " files present.")
  }
  invisible(manifest)
}

if (sys.nframe() == 0) {
  main()
}
