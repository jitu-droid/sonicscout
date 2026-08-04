# Real WhatsApp Round-Trip Validation

No `received_NN_*` files are present under either `received/attachment/` or 
`received/voicenote/` yet. This document will be generated for real once they are -- see 
`docs/roundtrip_procedure.md` for the manual steps covering both experiments.

## Tolerance, stated before any real data was collected

- PASS: real-vs-simulated spectral correlation >= 0.90 AND mean per-band retention divergence <= 0.10
- CAUTION: correlation >= 0.75 AND divergence <= 0.20 (and not PASS)
- FAIL: anything worse than CAUTION

Applied identically to both the attachment and voice-note arms. See 
`R/10_roundtrip_validation.R`'s header for the full reasoning behind these numbers and why 
there are two arms.
