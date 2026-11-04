## Submission

This is a new submission.

## R CMD check results

0 errors | 0 warnings | 0 notes (local)

The CRAN incoming checks are expected to add the standard "New submission" NOTE.

## Test environments

* Local: Ubuntu 24.04, R 4.3.3, `R CMD check --as-cran`, run twice: once with
  'FFmpeg' on the PATH (all 48 test expectations pass) and once without it
  (FFmpeg-dependent tests skip; 35 pass).
* win-builder: R-devel.

## Notes for the reviewer

* 'FFmpeg' (with 'libopus') is declared in SystemRequirements. It is needed
  only to decode compressed audio in `wa_read()` and by
  `wa_simulate_compression()`. Examples, tests and the vignette check for it
  with `Sys.which("ffmpeg")` and skip those steps when it is absent, so the
  package checks cleanly on machines without it. All 'FFmpeg' calls use
  `-nostdin` so they never read from R's standard input.
* All examples run in well under a second and write only to `tempdir()`.
* 'WhatsApp' is used only to describe the format of the voice notes the
  package reads. The package is not affiliated with or endorsed by
  WhatsApp or Meta.
