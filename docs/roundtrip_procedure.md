# Real WhatsApp Round-Trip Validation: Manual Procedure

Why this exists: every codec/compression-delta/classifier number in this
project comes from a LOCAL FFmpeg simulation of what WhatsApp's Opus/Ogg
voice-note encoder does to audio (`simulate_whatsapp_compression()`,
`R/02_codec_experiment.R`). That simulation has never been checked against
a genuine WhatsApp-compressed file. This procedure produces the one thing
that check needs: matched (sent, received) audio pairs where "sent" is a
known reference clip and "received" is what a real WhatsApp voice note of
that clip actually looks like after transiting WhatsApp's real servers and
client.

## What you need

- A phone with WhatsApp installed, able to send a voice note to yourself
  or a second contact/device you also control (sending to yourself in
  WhatsApp -- message yourself, or use WhatsApp Web/Desktop as the
  "receiving" side of a chat with a friend -- both work; the point is you
  need to be able to EXPORT the chat afterward from the RECEIVING side).
- A way to play the four prepared audio files out loud near the phone's
  microphone, OR to route them directly into the phone's mic input (a
  cable/adapter, or an app that lets WhatsApp record from a file instead
  of the live mic, if you have one -- direct routing avoids any acoustic
  environment/speaker-quality variables and is preferred if available,
  but playing near the mic is a perfectly valid fallback).
- A computer to receive the exported chat archive and extract the audio.

## The four files

Already prepared in `data/codec_experiment/real_roundtrip/sent/`,
loudness-normalized to a consistent level so none of them are painfully
quiet or clip on playback:

| File | Content | Duration |
|---|---|---|
| `sent_01_chorthippus_biguttulus.wav` | Real grasshopper stridulation | 12s |
| `sent_02_cicada_orni.wav` | Real cicada song | ~12s |
| `sent_03_synthetic_above_nyquist_control.wav` | Pure 10kHz tone (ground-truth Nyquist-cut check) | 3s |
| `sent_04_synthetic_broadband_noise.wav` | Broadband noise | 3s |

These four were chosen to span the range this project's claims rest on: a
real target species with a documented pulsed call structure, a real
target species with a continuous drone, a synthetic tone specifically
designed to prove content above 8kHz is destroyed (not just attenuated),
and unstructured noise as a spectral-shape control.

## Steps

1. **Send each file as its own separate WhatsApp voice note**, in order,
   to the same chat (yourself, or a contact/device you'll export from).
   Do not concatenate them into one message -- four separate voice notes,
   so each becomes its own exported audio file. If routing directly
   (recommended when available): play/route `sent_01_*.wav` through the
   mic input while recording a WhatsApp voice note, send it, then repeat
   for `sent_02`, `sent_03`, `sent_04`. If playing acoustically: use a
   quiet room, hold the phone's mic a consistent, close distance from the
   speaker for all four, and try not to let the speaker clip (turn it down
   if the source sounds distorted).
2. **Wait for delivery** (a few seconds) before exporting, so WhatsApp has
   finished uploading/processing each voice note.
3. **On the RECEIVING device/side of the chat**, open the conversation
   containing the four voice notes.
4. **Export the chat with media**:
   - WhatsApp mobile: open the chat -> tap the contact/chat name at the
     top -> scroll down -> **Export Chat** -> choose **"Include Media"**
     (NOT "Without Media"). This produces a `.zip` (iOS) or a share sheet
     you can save as a `.zip` (Android) containing a text transcript plus
     every media file, including the four voice notes as `.opus` files
     (WhatsApp's actual voice-note container/codec).
   - WhatsApp Desktop/Web: media can be downloaded per-message (click the
     download icon on each voice note) if a full chat export isn't
     available in your version -- four individual downloads is fine, same
     end result.
5. **Get the exported archive onto the computer** running this project
   (AirDrop, email it to yourself, USB, cloud sync -- whatever's
   convenient) and unzip it if it's a `.zip`.
6. **Find the four voice-note audio files** in the extracted contents
   (typically named something like `WhatsApp Audio 2026-08-04 at
   12.34.56.opus` or similar -- match them to the four you sent by
   listening or by send order/timestamp in the exported chat transcript,
   which lists messages in order).
7. **Place them in `data/codec_experiment/real_roundtrip/received/`**,
   renamed to match their `sent_NN_*` counterpart's numeric prefix, e.g.:

   ```
   data/codec_experiment/real_roundtrip/received/received_01_chorthippus_biguttulus.opus
   data/codec_experiment/real_roundtrip/received/received_02_cicada_orni.opus
   data/codec_experiment/real_roundtrip/received/received_03_synthetic_above_nyquist_control.opus
   data/codec_experiment/real_roundtrip/received/received_04_synthetic_broadband_noise.opus
   ```

   The file extension doesn't need to be `.opus` specifically -- whatever
   container WhatsApp's export produced is fine; `R/10_roundtrip_validation.R`
   decodes it with `ffmpeg`, which reads essentially anything. Only the
   `received_NN_` numeric prefix matters for matching against `sent_NN_`.

8. **Re-run the analysis**: `Rscript R/10_roundtrip_validation.R`. This
   regenerates `docs/roundtrip_validation.md` and one 3-panel spectrogram
   figure per file under `docs/figures/`.

## What happens if only some files are received

The script reports per-file results for whatever pairs it can match, and
explicitly lists which sent files had no matching received file -- partial
data still produces a partial, honestly-labelled result, not a silent gap
or an error. Four files were chosen to span the range that matters most
(a pulsed real call, a continuous real call, the Nyquist ground-truth, a
noise control), but even one or two matched pairs would be a real,
reportable data point where zero currently exist.

## After the results land

See `docs/roundtrip_validation.md`'s "Tolerance, stated before any real
data was collected" section for the PASS/CAUTION/FAIL criteria (decided
and written into `R/10_roundtrip_validation.R` before this procedure was
ever run against real data). If the simulation validates within
tolerance, that finding gets written into `docs/codec_findings.md` and
`README.md` as a real, checked claim -- currently the single biggest
"trust us" gap in this project's methodology. If it diverges, the
divergence gets quantified and named, and the compression-delta and
classifier evaluations get re-run using real-round-trip parameters if the
real round-trip turns out more destructive than simulated -- that result
would supersede every simulated one.
