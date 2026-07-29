# Methodology

This file is being built out deliverable by deliverable (see the repo root
brief). It will eventually cover the full pipeline, the codec finding with
real measured numbers, and a candid limitations section. Right now it only
documents what's needed to run Deliverable A.

## Sourcing reference clips for the codec experiment (Deliverable A)

`R/02_codec_experiment.R` expects clean reference recordings at:

```
data/codec_experiment/reference/<species>/<file>.wav
```

one subdirectory per species (the directory name is used as the species
label). These have not been downloaded yet -- downloading files requires an
explicit go-ahead, and the actual selection should be driven by
`R/01_download_data.R` (Deliverable C) pulling a small, deliberately chosen
subset of InsectSet459 (Orthoptera stridulation/wingbeat clips, plus any
lepidopteran larval chewing clips available, since that one is uncertain and
must be measured, not assumed -- see the brief's risk section).

Until that subset is chosen and fetched, this directory stays empty and
`run_codec_experiment()` will fail loudly with a clear message rather than
silently produce no results.

## InsectSet459 citation

Reference corpus: InsectSet459 -- 26,399 audio files across 459 species of
Orthoptera and Cicadidae, curated from xeno-canto, iNaturalist and
BioAcoustica. CC-BY-4.0 / CC0. arXiv:2503.15074; also published in
*Scientific Data*. Full citation to be finalized in the README (Deliverable G).

## TODO (filled in by later deliverables)

- End-to-end pipeline description (Deliverable C/D)
- Codec finding narrative with real numbers (after Deliverable A actually runs)
- Measured classifier performance (Deliverable D)
- Limitations: 8kHz ceiling, species coverage, untested field noise, single-mic
  localisation (Deliverable G)
