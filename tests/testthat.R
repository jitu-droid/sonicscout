# Run with: Rscript tests/testthat.R
# (Sources the pipeline scripts without triggering their `main()` -- see the
# `sys.nframe() == 0` guard at the bottom of each R/*.R stage script.)

library(testthat)

source(file.path("R", "utils.R"))
source(file.path("R", "02_codec_experiment.R"))

test_dir(file.path("tests", "testthat"), reporter = "summary")
