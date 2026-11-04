# whatsappaudioR 0.2.0

* First CRAN submission.
* `wa_read()` and `wa_simulate_compression()` now call 'FFmpeg' with
  `-nostdin`. Without it, 'FFmpeg' read keystrokes from R's standard input
  and silently consumed bytes of any script piped into R.
* `wa_read()` gains `sample_rate` and `mono` arguments, so audio can be
  resampled on decode to the rate a model was trained at.
* `wa_features()` adds temporal features (pulse rate, inter-pulse intervals,
  envelope modulation, duty cycle and phrase structure) alongside the
  spectral features and MFCCs.
* A short example voice note now ships in `inst/extdata/sample.opus`, and all
  examples run without network access. Examples that need 'FFmpeg' skip
  themselves when it is not installed.
