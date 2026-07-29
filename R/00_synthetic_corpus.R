# Step 2 (autonomous run) -- Synthetic audio corpus with known ground truth.
#
# Unblocks the codec experiment (Deliverable A) and the package fixture tests
# independently of any real dataset download succeeding. The important file
# here is the above-Nyquist control tone: after the WhatsApp compression
# round trip it must be almost entirely destroyed. If it isn't, the codec
# simulation itself is wrong and nothing downstream can be trusted -- see
# docs/codec_findings.md for that check once R/02_codec_experiment.R has run.
#
# Usage:
#   Rscript R/00_synthetic_corpus.R
#
# Output layout (matches what R/02_codec_experiment.R expects):
#   data/codec_experiment/reference/<species>/<file>.wav

library(tuneR)

source(file.path("R", "utils.R"))

REFERENCE_DIR <- file.path("data", "codec_experiment", "reference")
GEN_SAMPLE_RATE <- 44100L  # a generic "clean field recorder" rate, like a real corpus would have

# ---- Signal generators ------------------------------------------------------

#' A tone with decaying harmonics, optionally pulsed (raised-cosine envelope
#' train) to approximate a stridulation-style call rather than a pure whine.
gen_harmonic_tone <- function(f0, duration = 3, sr = GEN_SAMPLE_RATE,
                               n_harmonics = 3, harmonic_decay = 0.5,
                               amp = 0.8, pulse_rate = NULL, pulse_duty = 0.35) {
  t <- seq(0, duration, by = 1 / sr)
  x <- numeric(length(t))
  for (h in seq_len(n_harmonics)) {
    x <- x + (harmonic_decay^(h - 1)) * sin(2 * pi * f0 * h * t)
  }
  x <- x / max(abs(x))

  if (!is.null(pulse_rate)) {
    phase <- (t * pulse_rate) %% 1
    envelope <- ifelse(phase < pulse_duty, 0.5 - 0.5 * cos(2 * pi * phase / pulse_duty), 0)
    x <- x * envelope
  }

  amp * x / max(abs(x), .Machine$double.eps)
}

#' Zero-mean white noise. Sample count matches gen_harmonic_tone()'s
#' `seq(0, duration, by = 1/sr)` convention (length = duration*sr + 1, not
#' round(duration*sr)) so the two can be added/multiplied elementwise
#' without recycling.
gen_white_noise <- function(duration = 3, sr = GEN_SAMPLE_RATE, amp = 0.5) {
  n_samples <- length(seq(0, duration, by = 1 / sr))
  x <- stats::rnorm(n_samples)
  amp * x / max(abs(x))
}

#' Brick-wall bandpass via FFT bin zeroing. Good enough for synthetic ground
#' truth; not intended as a general-purpose filter.
bandpass_fft <- function(x, sr, low, high) {
  n <- length(x)
  X <- stats::fft(x)
  freqs <- seq(0, sr, length.out = n + 1)[seq_len(n)]
  freqs[freqs > sr / 2] <- freqs[freqs > sr / 2] - sr
  mask <- abs(freqs) >= low & abs(freqs) <= high
  X[!mask] <- 0
  x_filt <- Re(stats::fft(X, inverse = TRUE)) / n
  x_filt / max(abs(x_filt), .Machine$double.eps)
}

#' Amplitude-modulated bursts of band-limited noise, approximating larval
#' chewing sounds. Deliberately spans across the 8kHz Nyquist wall (band
#' 2-12kHz) since real chewing-sound survivability is explicitly uncertain
#' per the project brief and must be measured, not assumed.
gen_chewing_pulses <- function(duration = 3, sr = GEN_SAMPLE_RATE,
                                pulse_rate = 8, pulse_width = 0.06,
                                band = c(2000, 12000), amp = 0.7) {
  noise <- gen_white_noise(duration, sr, amp = 1)
  filtered <- bandpass_fft(noise, sr, band[1], band[2])

  t <- seq(0, duration, by = 1 / sr)
  phase <- (t * pulse_rate) %% 1
  envelope <- ifelse(phase < pulse_width / (1 / pulse_rate),
                      0.5 - 0.5 * cos(pi * phase / (pulse_width * pulse_rate)), 0)
  envelope[envelope < 0] <- 0

  x <- filtered * envelope
  amp * x / max(abs(x), .Machine$double.eps)
}

#' Mix a tone and noise at a target SNR (dB), both already generated at the
#' same length/sample rate.
mix_at_snr <- function(tone, noise, snr_db) {
  tone_power <- mean(tone^2)
  noise_power <- mean(noise^2)
  target_noise_power <- tone_power / (10^(snr_db / 10))
  scale <- sqrt(target_noise_power / max(noise_power, .Machine$double.eps))
  mixed <- tone + noise * scale
  0.9 * mixed / max(abs(mixed))
}

# ---- Write helper ------------------------------------------------------------

write_synthetic_wav <- function(x, species, filename, sr = GEN_SAMPLE_RATE) {
  dir <- file.path(REFERENCE_DIR, species)
  ensure_dir(dir)
  path <- file.path(dir, filename)
  int_samples <- as.integer(round(x * 32767))
  int_samples <- pmin(pmax(int_samples, -32768L), 32767L)
  w <- tuneR::Wave(left = int_samples, samp.rate = sr, bit = 16)
  tuneR::writeWave(w, path)
  path
}

# ---- Build the corpus ---------------------------------------------------------

#' @param n_variants_per_class Multiple jittered instances per class, not
#'   just one. Needed so R/05_train.R's grouped train/val/test split (by
#'   source recording) has more than a single source file to work with per
#'   class -- with only one file per class, an entire class could be
#'   isolated into just one split, both starving test coverage and risking
#'   randomForest() seeing fewer than 2 classes in training. Jitter (not
#'   identical copies) stands in for call-to-call/individual variation.
build_synthetic_corpus <- function(n_variants_per_class = 5) {
  written <- character()

  # 1. Stridulation analogue: low-frequency pulsed harmonic call (Orthoptera-like).
  stridulation_variants <- vector("list", n_variants_per_class)
  for (i in seq_len(n_variants_per_class)) {
    f0 <- 250 + stats::runif(1, -30, 30)
    pulse_rate <- 20 + stats::runif(1, -3, 3)
    tone <- gen_harmonic_tone(f0 = f0, n_harmonics = 4, harmonic_decay = 0.6,
                               pulse_rate = pulse_rate, pulse_duty = 0.4)
    stridulation_variants[[i]] <- tone
    written <- c(written, write_synthetic_wav(tone, "synthetic_stridulation", sprintf("call_%03d.wav", i)))
  }

  # 2. Mosquito wingbeat analogue: steady near-pure tone with harmonics, no AM.
  for (i in seq_len(n_variants_per_class)) {
    f0 <- 450 + stats::runif(1, -40, 40)
    tone <- gen_harmonic_tone(f0 = f0, n_harmonics = 3, harmonic_decay = 0.4)
    written <- c(written, write_synthetic_wav(tone, "synthetic_mosquito_wingbeat", sprintf("wingbeat_%03d.wav", i)))
  }

  # 3. Above-Nyquist control: a pure tone that MUST be destroyed by the 16kHz
  #    resample. This is the ground-truth check that the codec simulation is
  #    behaving correctly -- see docs/codec_findings.md after Step 3. Single
  #    file: it's a codec-experiment-only control, not a classifier class
  #    (see SYNTHETIC_CODEC_ONLY_LABELS in R/03_preprocess.R).
  above_nyquist <- gen_harmonic_tone(f0 = 10000, n_harmonics = 1, harmonic_decay = 0)
  written <- c(written, write_synthetic_wav(above_nyquist, "synthetic_above_nyquist_control", "control_10khz.wav"))

  # 4. Broadband noise (ambient/negative-class analogue).
  for (i in seq_len(n_variants_per_class)) {
    noise <- gen_white_noise()
    written <- c(written, write_synthetic_wav(noise, "synthetic_broadband_noise", sprintf("noise_%03d.wav", i)))
  }

  # 5. Chewing pulse train -- deliberately straddles the 8kHz wall.
  for (i in seq_len(n_variants_per_class)) {
    pulse_rate <- 8 + stats::runif(1, -2, 2)
    chewing <- gen_chewing_pulses(pulse_rate = pulse_rate)
    written <- c(written, write_synthetic_wav(chewing, "synthetic_chewing_pulses", sprintf("chewing_%03d.wav", i)))
  }

  # 6. Tone + noise at several SNRs (robustness sweep, uses the first stridulation variant).
  for (snr_db in c(20, 10, 0, -10)) {
    mixed <- mix_at_snr(stridulation_variants[[1]], gen_white_noise(amp = 1), snr_db)
    fname <- sprintf("call_snr_%sdB.wav", ifelse(snr_db < 0, paste0("neg", abs(snr_db)), snr_db))
    written <- c(written, write_synthetic_wav(mixed, "synthetic_tone_plus_noise", fname))
  }

  written
}

#' Compress the stridulation reference clip to Opus and save it as the
#' package fixture used by whatsappaudioR's tests. Requires a system ffmpeg
#' (see R/02_codec_experiment.R's simulate_whatsapp_compression() for why).
#' Skips gracefully (with a message) if ffmpeg isn't available yet -- this is
#' not fatal to the rest of the corpus build.
write_package_fixture <- function(fixture_dir = file.path("pkg", "whatsappaudioR", "tests", "testthat", "fixtures")) {
  ffmpeg_bin <- Sys.which("ffmpeg")
  if (ffmpeg_bin == "") {
    message("ffmpeg not on PATH -- skipping package .opus fixture for now. ",
            "Re-run write_package_fixture() once ffmpeg is installed.")
    return(invisible(NULL))
  }

  ensure_dir(fixture_dir)
  src_wav <- file.path(REFERENCE_DIR, "synthetic_stridulation", "call_001.wav")
  if (!file.exists(src_wav)) {
    stop("Expected ", src_wav, " to exist; run build_synthetic_corpus() first.")
  }

  out_opus <- file.path(fixture_dir, "sample.opus")
  args <- c("-y", "-loglevel", "error", "-i", src_wav,
            "-ar", "16000", "-ac", "1", "-c:a", "libopus", "-b:a", "16k",
            out_opus)
  status <- system2(ffmpeg_bin, args = args)
  if (status != 0) stop("ffmpeg failed while creating package fixture from ", src_wav)

  out_opus
}

main <- function() {
  files <- build_synthetic_corpus()
  message("Wrote ", length(files), " synthetic reference files under ", REFERENCE_DIR)
  write_package_fixture()
  invisible(files)
}

if (sys.nframe() == 0) {
  main()
}
