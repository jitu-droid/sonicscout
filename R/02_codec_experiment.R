# Deliverable A -- Codec characterisation experiment
#
# Measures what WhatsApp's Opus/Ogg voice-note compression actually does to
# insect bioacoustic signatures, band by band. This is the scientific backbone
# of SonicScout: our claim is that pest signatures survive lossy VoIP
# compression, and that claim has to be measured, not assumed. This script
# does not tune anything to produce a flattering result -- whatever the
# numbers say is what goes in docs/codec_findings.md.
#
# Usage:
#   Rscript R/02_codec_experiment.R
#
# Inputs:
#   data/codec_experiment/reference/<species>/<file>.wav
#     A handful of clean reference clips per target species (see
#     docs/methodology.md for how these were sourced from InsectSet459).
#
# Outputs:
#   data/codec_experiment/degraded/<species>/<file>.wav  -- WhatsApp-simulated
#   docs/figures/codec_before_after.png                  -- before/after panel
#   docs/codec_findings.md                               -- results + narrative

library(tuneR)
library(seewave)
library(dplyr)
library(tidyr)
library(purrr)
library(tibble)
library(knitr)

source(file.path("R", "utils.R"))

REFERENCE_DIR <- file.path("data", "codec_experiment", "reference")
DEGRADED_DIR  <- file.path("data", "codec_experiment", "degraded")
REAL_DIR      <- file.path("data", "codec_experiment", "real")
FIGURES_DIR   <- file.path("docs", "figures")
FINDINGS_PATH <- file.path("docs", "codec_findings.md")

# ---- Step 1: simulate the WhatsApp pipeline --------------------------------

#' Simulate WhatsApp's Opus/Ogg voice-note compression on a WAV file.
#'
#' # WORKAROUND: both encode and decode go through system ffmpeg, not `av`
#' The installed `av` version (0.9.6) does have a `bit_rate` argument on
#' `av_audio_convert()`, contradicting this function's original note that
#' bitrate wasn't controllable via `av`. But empirically, `av::av_audio_convert()`
#' -- and even `av::av_media_info()` -- segfault R outright on this machine,
#' confirmed even against `av`'s own bundled sample file (not an input-file
#' issue). A segfault can't be caught with `tryCatch()`. See `BLOCKERS.md`
#' for the full diagnosis. Both the encode and decode steps here use a
#' system `ffmpeg` binary instead (confirmed working, with `libopus`).
simulate_whatsapp_compression <- function(input_wav,
                                           output_wav,
                                           sample_rate = WHATSAPP_SAMPLE_RATE,
                                           bitrate_kbps = WHATSAPP_BITRATE_KBPS) {
  stopifnot(file.exists(input_wav))
  ensure_dir(dirname(output_wav))

  ffmpeg_bin <- Sys.which("ffmpeg")
  if (ffmpeg_bin == "") {
    stop("ffmpeg not found on PATH. Install FFmpeg and ensure `ffmpeg` is ",
         "callable from R (Sys.which('ffmpeg')), or update ",
         "simulate_whatsapp_compression() if a newer `av` package version ",
         "exposes bitrate control directly.")
  }

  ogg_tmp <- tempfile(fileext = ".ogg")
  on.exit(unlink(ogg_tmp), add = TRUE)

  encode_args <- c(
    "-y", "-loglevel", "error",
    "-i", input_wav,
    "-ar", as.character(sample_rate),
    "-ac", "1",
    "-c:a", "libopus",
    "-b:a", paste0(bitrate_kbps, "k"),
    ogg_tmp
  )
  status <- system2(ffmpeg_bin, args = encode_args)
  if (status != 0) stop("ffmpeg encode step failed for ", input_wav)

  decode_args <- c("-y", "-loglevel", "error", "-i", ogg_tmp,
                    "-ar", as.character(sample_rate), "-ac", "1", output_wav)
  status <- system2(ffmpeg_bin, args = decode_args)
  if (status != 0) stop("ffmpeg decode step failed for ", input_wav)

  invisible(output_wav)
}

# ---- Step 2: spectral analysis ---------------------------------------------

#' Mean power spectrum (frequency in Hz vs amplitude) for a wave file.
#' NOTE: seewave::meanspec() returns frequency in kHz by convention; converted
#' to Hz here so it composes with FREQ_BANDS (defined in Hz in utils.R).
compute_mean_spectrum <- function(wave_path, fft_window = FFT_WINDOW) {
  w <- tuneR::readWave(wave_path)
  spec <- seewave::meanspec(w, wl = fft_window, plot = FALSE)
  tibble::tibble(freq_hz = spec[, 1] * 1000, amplitude = spec[, 2])
}

#' Sum spectral energy within [lo, hi) Hz.
band_energy <- function(spectrum_df, lo, hi) {
  in_band <- spectrum_df$freq_hz >= lo & spectrum_df$freq_hz < hi
  sum(spectrum_df$amplitude[in_band])
}

#' Per-band energy retention ratio (degraded / original) for one file pair.
#'
#' A band is only given a ratio if the original signal actually had
#' non-trivial energy there (>= `min_energy_fraction` of the original's total
#' spectral energy). Without this guard, a band where the original was
#' essentially silent (e.g. the 0-500Hz band for a pure 10kHz tone) produces
#' a "retention ratio" of tiny-leakage / near-zero, which can blow up to an
#' arbitrarily large, meaningless number -- not a real finding, just a
#' division artifact. Those bands get `NA` instead.
band_retention_ratios <- function(original_spectrum, degraded_spectrum, min_energy_fraction = 0.005) {
  total_original_energy <- sum(original_spectrum$amplitude)

  purrr::map_dfr(seq_along(FREQ_BANDS), function(i) {
    band <- FREQ_BANDS[[i]]
    orig_e <- band_energy(original_spectrum, band[1], band[2])
    deg_e  <- band_energy(degraded_spectrum,  band[1], band[2])
    has_meaningful_energy <- total_original_energy > 0 &&
      (orig_e / total_original_energy) >= min_energy_fraction
    tibble::tibble(
      band = FREQ_BAND_LABELS[i],
      original_energy = orig_e,
      degraded_energy = deg_e,
      retention_ratio = if (has_meaningful_energy) deg_e / orig_e else NA_real_
    )
  })
}

#' Align two spectra onto a common frequency grid up to `max_freq` and compute
#' Pearson correlation + cosine similarity. Defaults to the degraded signal's
#' own Nyquist limit, since nothing above it can possibly match anyway.
spectral_similarity <- function(original_spectrum, degraded_spectrum,
                                 max_freq = WHATSAPP_SAMPLE_RATE / 2) {
  common_freq <- seq(0, max_freq, length.out = 512)
  orig_interp <- approx(original_spectrum$freq_hz, original_spectrum$amplitude,
                         xout = common_freq, rule = 2)$y
  deg_interp  <- approx(degraded_spectrum$freq_hz, degraded_spectrum$amplitude,
                         xout = common_freq, rule = 2)$y

  pearson <- suppressWarnings(stats::cor(orig_interp, deg_interp))
  cosine  <- sum(orig_interp * deg_interp) /
    (sqrt(sum(orig_interp^2)) * sqrt(sum(deg_interp^2)))

  list(pearson_correlation = pearson, cosine_similarity = cosine)
}

#' Single scalar survivability score: mean of below-Nyquist spectral
#' correlation and cosine similarity. 1.0 = perfect survival, 0 = no
#' relationship. This is a transparent composite, not a validated perceptual
#' metric -- always report it alongside its two components, never alone.
survivability_score <- function(similarity) {
  mean(c(similarity$pearson_correlation, similarity$cosine_similarity), na.rm = TRUE)
}

# ---- Step 3: run the experiment --------------------------------------------

#' Run the full codec experiment over every reference clip.
#' Expects reference_dir/<species>/<file>.wav layout.
run_codec_experiment <- function(reference_dir = REFERENCE_DIR,
                                  degraded_dir = DEGRADED_DIR,
                                  sample_rate = WHATSAPP_SAMPLE_RATE,
                                  bitrate_kbps = WHATSAPP_BITRATE_KBPS) {
  ref_files <- list.files(reference_dir, pattern = "\\.wav$",
                           recursive = TRUE, full.names = TRUE)
  if (length(ref_files) == 0) {
    stop("No .wav reference files found under ", reference_dir,
         ". Populate data/codec_experiment/reference/<species>/*.wav with a ",
         "handful of clean Orthoptera/chewing-sound clips (see ",
         "docs/methodology.md) before running this experiment.")
  }

  results <- purrr::map(ref_files, function(ref_path) {
    tryCatch({
      species <- basename(dirname(ref_path))
      degraded_path <- file.path(degraded_dir, species, basename(ref_path))

      simulate_whatsapp_compression(ref_path, degraded_path, sample_rate, bitrate_kbps)

      orig_spec <- compute_mean_spectrum(ref_path)
      deg_spec  <- compute_mean_spectrum(degraded_path)

      retention  <- band_retention_ratios(orig_spec, deg_spec)
      similarity <- spectral_similarity(orig_spec, deg_spec)
      score      <- survivability_score(similarity)

      dplyr::mutate(
        retention,
        species = species,
        file = basename(ref_path),
        pearson_correlation = similarity$pearson_correlation,
        cosine_similarity = similarity$cosine_similarity,
        survivability_score = score,
        .before = 1
      )
    }, error = function(e) {
      # One malformed source file (seen once already: a 2005-era WAV with a
      # corrupt header that ffmpeg silently mis-parses) must not take down
      # the whole experiment -- skip it, but say so out loud rather than
      # silently dropping it from the results.
      message("Skipping ", ref_path, " (codec experiment): ", conditionMessage(e))
      NULL
    })
  })

  n_failed <- sum(vapply(results, is.null, logical(1)))
  if (n_failed > 0) {
    message(n_failed, " of ", length(ref_files), " reference files failed and were skipped -- see messages above.")
  }

  dplyr::bind_rows(results)
}

# ---- Step 4: figures --------------------------------------------------------

#' Render a before/after spectrogram panel (one row per species, using its
#' first reference file) to docs/figures/codec_before_after.png.
#'
#' @param species_filter Optional character vector of species directory
#'   names to include (exact match). Defaults to all species found -- but
#'   once real recordings are added alongside the synthetic ones, the panel
#'   can get long enough to stop being slide-legible, so callers should pass
#'   a curated subset (e.g. the synthetic 10kHz ground-truth control plus a
#'   couple of real species) rather than relying on the default.
render_before_after_panel <- function(reference_dir = REFERENCE_DIR,
                                       degraded_dir = DEGRADED_DIR,
                                       output_path = file.path(FIGURES_DIR, "codec_before_after.png"),
                                       fft_window = FFT_WINDOW,
                                       species_filter = NULL) {
  ensure_dir(dirname(output_path))
  ref_files <- list.files(reference_dir, pattern = "\\.wav$",
                          recursive = TRUE, full.names = TRUE)
  if (length(ref_files) == 0) {
    stop("No .wav reference files found under ", reference_dir, "; nothing to plot.")
  }
  species_first_file <- purrr::map_chr(split(ref_files, basename(dirname(ref_files))), 1)
  if (!is.null(species_filter)) {
    species_first_file <- species_first_file[names(species_first_file) %in% species_filter]
    if (length(species_first_file) == 0) {
      stop("species_filter matched none of the available species: ",
           paste(names(species_first_file), collapse = ", "))
    }
  }

  n <- length(species_first_file)
  grDevices::png(output_path, width = 1600, height = 550 * n, res = 150)
  on.exit(grDevices::dev.off(), add = TRUE)
  graphics::par(mfrow = c(n, 2), mar = c(4.5, 4.5, 3.5, 1.5),
                cex.main = 1.1, cex.lab = 1.05, cex.axis = 0.95)

  first_row <- TRUE
  for (species in names(species_first_file)) {
    ref_path <- species_first_file[[species]]
    deg_path <- file.path(degraded_dir, species, basename(ref_path))

    w_orig <- tuneR::readWave(ref_path)
    w_deg  <- tuneR::readWave(deg_path)

    nyquist_label <- if (first_row) "8kHz ceiling" else NULL

    seewave::spectro(w_orig, wl = fft_window, scale = FALSE,
                      main = paste(species, "- original"))
    graphics::abline(h = 8, col = "red", lty = 2, lwd = 1.5)
    if (!is.null(nyquist_label)) {
      graphics::text(x = 0.05, y = 8, labels = nyquist_label, col = "red",
                      pos = 4, offset = 0.3, cex = 0.85)
    }

    seewave::spectro(w_deg, wl = fft_window, scale = FALSE,
                      main = paste(species, "- WhatsApp-simulated"))
    graphics::abline(h = 8, col = "red", lty = 2, lwd = 1.5)

    first_row <- FALSE
  }

  invisible(output_path)
}

# ---- Step 5: findings report -------------------------------------------------

#' Write docs/codec_findings.md from the results tibble. Reports whatever the
#' numbers say; the "Interpretation" section is left as TBD for a human to
#' fill in after reading the tables, not auto-generated prose.
write_codec_findings <- function(results, output_path = FINDINGS_PATH) {
  ensure_dir(dirname(output_path))

  species_summary <- results |>
    dplyr::group_by(species) |>
    dplyr::summarise(
      mean_survivability = mean(survivability_score, na.rm = TRUE),
      mean_pearson = mean(pearson_correlation, na.rm = TRUE),
      mean_cosine = mean(cosine_similarity, na.rm = TRUE),
      n_files = dplyr::n_distinct(file),
      .groups = "drop"
    ) |>
    dplyr::arrange(dplyr::desc(mean_survivability))

  band_summary <- results |>
    dplyr::group_by(species, band) |>
    # na.rm = TRUE means "mean of all-NA" (a band with no meaningful energy
    # in any file for this species) comes back as NaN, not NA -- replace
    # with NA below so it renders as a clean "n/a" rather than "NaN".
    dplyr::summarise(mean_retention = mean(retention_ratio, na.rm = TRUE), .groups = "drop") |>
    dplyr::mutate(mean_retention = ifelse(is.nan(mean_retention), NA_real_, mean_retention)) |>
    tidyr::pivot_wider(names_from = band, values_from = mean_retention)

  species_table_md <- knitr::kable(species_summary, format = "markdown", digits = 3)
  band_table_md <- knitr::kable(band_summary, format = "markdown", digits = 3)

  lines <- c(
    "# Codec Findings: What Survives WhatsApp Compression",
    "",
    "Generated by `R/02_codec_experiment.R`. These are measured numbers from an",
    "actual Opus/Ogg round-trip simulation at WhatsApp's parameters",
    paste0("(", WHATSAPP_SAMPLE_RATE, " Hz, ", WHATSAPP_BITRATE_KBPS, " kbps, mono),"),
    "not estimates. Re-run the script to regenerate this file from scratch.",
    "",
    "## Signature survivability by species",
    "",
    species_table_md,
    "",
    "## Per-frequency-band energy retention (degraded / original)",
    "",
    band_table_md,
    "",
    "## Reading the >8kHz column",
    "",
    "A retention value at or near 0 in the >8kHz band confirms the hard",
    "Nyquist ceiling: content above 8 kHz cannot survive a 16 kHz-sample-rate",
    "resample. It is not attenuated -- it is physically absent from the",
    "degraded signal. This is expected and is not a pipeline bug.",
    "",
    "## Reading NA retention cells",
    "",
    "NA means the original signal had negligible energy in that band to",
    "begin with (below 0.5% of its total spectral energy) -- e.g. the",
    "0-500Hz column for a pure 10kHz tone. Computing a ratio there would",
    "divide tiny leakage by near-zero, producing an arbitrarily large number",
    "that isn't a real finding. Only cells with a value reflect a band the",
    "source signal actually had meaningful energy in.",
    "",
    "## Before/after spectrogram panel",
    "",
    "![Before/after compression spectrograms](figures/codec_before_after.png)",
    "",
    "## Real WhatsApp round-trip check",
    "",
    "See `data/codec_experiment/real_vs_simulated.csv` (generated only if real",
    "WhatsApp-exported .opus files were provided under",
    "`data/codec_experiment/real/`; see the manual procedure documented above",
    "`compare_real_vs_simulated()` in `R/02_codec_experiment.R`).",
    "",
    "## Interpretation",
    "",
    "TBD -- fill in after reading the tables above. Describe what they",
    "actually show, including any species/band where survival was poor. If a",
    "target pest's signature does not survive, say so plainly here and scope",
    "the MVP accordingly (see docs/methodology.md limitations section)."
  )

  writeLines(lines, output_path)
  invisible(output_path)
}

# ---- Step 6: round-trip sanity check against a REAL WhatsApp file ----------
#
# Manual procedure (documented here so it's reproducible by teammates):
#   1. On a phone, play a reference clip out loud near a WhatsApp microphone
#      (or route audio directly into the mic input via cable/emulator).
#   2. Record and send it as a genuine WhatsApp voice note to a test contact
#      or to yourself.
#   3. On the receiving device: open the chat -> Export Chat -> "Include Media".
#   4. Extract the .opus file from the exported archive and place it at
#      data/codec_experiment/real/<species>/<original_filename>.opus
#      (same basename as the corresponding file in reference/<species>/).
#   5. Re-run compare_real_vs_simulated() below.
#
# This exists because our local FFmpeg-based simulation is a best-effort
# approximation of WhatsApp's actual client-side encoding (codec version, VBR
# vs CBR behaviour, and any client-side preprocessing such as noise
# suppression or AGC could all differ from a raw `ffmpeg -c:a libopus` call).
# A large divergence here is a critical finding, not a bug in this script --
# report it in docs/codec_findings.md rather than silently trusting the
# simulation.

#' Compare a real WhatsApp-recorded .opus file against our local simulation
#' of the same source clip. Returns NULL (with a message) if no real files
#' have been provided yet.
compare_real_vs_simulated <- function(reference_dir = REFERENCE_DIR,
                                       real_dir = REAL_DIR,
                                       degraded_dir = DEGRADED_DIR) {
  real_files <- list.files(real_dir, pattern = "\\.opus$",
                            recursive = TRUE, full.names = TRUE)
  if (length(real_files) == 0) {
    message("No real WhatsApp .opus files found under ", real_dir,
            " -- skipping round-trip sanity check. See the manual procedure ",
            "documented above compare_real_vs_simulated() in this file.")
    return(invisible(NULL))
  }

  purrr::map_dfr(real_files, function(real_path) {
    species <- basename(dirname(real_path))
    stem <- tools::file_path_sans_ext(basename(real_path))
    simulated_path <- file.path(degraded_dir, species, paste0(stem, ".wav"))

    if (!file.exists(simulated_path)) {
      message("No matching simulated file for ", real_path,
              " (expected ", simulated_path, "); skipping.")
      return(NULL)
    }

    real_wav <- tempfile(fileext = ".wav")
    on.exit(unlink(real_wav), add = TRUE)
    ffmpeg_bin <- Sys.which("ffmpeg")
    if (ffmpeg_bin == "") stop("ffmpeg not found on PATH")
    status <- system2(ffmpeg_bin, args = c("-y", "-loglevel", "error", "-i", real_path, real_wav))
    if (status != 0) stop("ffmpeg failed to decode ", real_path)

    real_spec <- compute_mean_spectrum(real_wav)
    sim_spec  <- compute_mean_spectrum(simulated_path)
    similarity <- spectral_similarity(real_spec, sim_spec)

    tibble::tibble(
      species = species,
      file = stem,
      real_vs_simulated_pearson = similarity$pearson_correlation,
      real_vs_simulated_cosine = similarity$cosine_similarity
    )
  })
}

# ---- Entry point -------------------------------------------------------------

main <- function() {
  results <- run_codec_experiment()

  # Figure legibility: always include the synthetic 10kHz ground-truth
  # control (the "does the simulation actually destroy content above
  # Nyquist" check), plus real recordings if R/prepare_real_reference.R has
  # populated any `real_*` species -- that's the slide that matters most
  # once real audio is available. Falls back to a couple of synthetic pest
  # analogues if no real species exist yet, so the figure is never empty.
  available_species <- basename(list.dirs(REFERENCE_DIR, recursive = FALSE))
  real_species <- available_species[startsWith(available_species, "real_")]
  figure_species <- if (length(real_species) > 0) {
    c("synthetic_above_nyquist_control", real_species)
  } else {
    c("synthetic_above_nyquist_control", "synthetic_stridulation", "synthetic_mosquito_wingbeat")
  }
  figure_species <- intersect(figure_species, available_species)

  render_before_after_panel(species_filter = figure_species)
  write_codec_findings(results)

  realcheck <- compare_real_vs_simulated()
  if (!is.null(realcheck)) {
    utils::write.csv(realcheck,
                      file.path("data", "codec_experiment", "real_vs_simulated.csv"),
                      row.names = FALSE)
  }

  message("Codec experiment complete. See docs/codec_findings.md and ",
          "docs/figures/codec_before_after.png")
  invisible(results)
}

# Runs only when executed directly (Rscript / top-level source()), not when
# sourced from inside a test helper function.
if (sys.nframe() == 0) {
  main()
}
