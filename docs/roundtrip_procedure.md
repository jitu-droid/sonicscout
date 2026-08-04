# Real WhatsApp Round-Trip Validation: Manual Procedure

Why this exists: every codec/compression-delta/classifier number in this
project comes from a LOCAL FFmpeg simulation of what WhatsApp's Opus/Ogg
voice-note encoder does to audio (`simulate_whatsapp_compression()`,
`R/02_codec_experiment.R`). That simulation has never been checked against
a genuine WhatsApp-compressed file.

**This is two separate experiments, not one**, because WhatsApp voice
notes can only be recorded in-app via the mic button -- there's no way to
hand WhatsApp a WAV file and have it become a voice note directly. Sending
a WAV as a file/audio attachment is a different send path that may not go
through the same encoder a recorded voice note does. Conflating the two
would risk validating the wrong thing:

- **Experiment 1 (attachment)**: send each file as a file/audio
  ATTACHMENT. No speaker, no microphone, no room -- isolates whatever
  WhatsApp's attachment transport does to the file on its own.
- **Experiment 2 (voicenote)**: play each file out loud and re-record it
  as a real WhatsApp voice note (mic button, in-app). This is the actual
  deployment path a farmer's phone would produce -- it bundles acoustic
  capture loss (speaker, room, phone mic) together with whatever codec
  compression WhatsApp applies to voice notes.

Comparing the two is what actually separates codec loss from
acoustic-path loss (see `R/10_roundtrip_validation.R`'s header for the
full reasoning, including how the script auto-detects whether the
attachment arm turned out to be a real codec isolation or a
near-lossless passthrough).

## What you need

- A phone with WhatsApp installed, able to send to yourself or a second
  contact/device you also control (message yourself, or use WhatsApp
  Web/Desktop as the "receiving" side of a chat with a friend -- both
  work; the point is you need to be able to EXPORT the chat afterward
  from the RECEIVING side).
- A way to play the four prepared audio files out loud (a speaker, or the
  phone itself) for Experiment 2's recording step.
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

You will send this same set of four files TWICE -- once for each
experiment -- so 8 total sends.

## Experiment 1: File-attachment round trip

1. In WhatsApp, use the attach/paperclip icon and choose **Document** (or
   **Audio**, if your WhatsApp version offers a distinct audio-file
   picker) -- NOT the microphone/voice-note button. Attach and send
   `sent_01_chorthippus_biguttulus.wav` as its own message. Repeat for
   `sent_02`, `sent_03`, `sent_04` -- four separate attachment messages,
   not one combined message.
2. Wait a few seconds after each send for it to finish uploading before
   sending the next.
3. On the RECEIVING device/side of the chat, export the chat with media
   (see "Exporting and placing files" below) and place the four resulting
   audio files under
   `data/codec_experiment/real_roundtrip/received/attachment/`, renamed
   `received_01_*` through `received_04_*` matching the `sent_NN` prefix.

## Experiment 2: Voice-note record round trip

1. Play `sent_01_chorthippus_biguttulus.wav` out loud (phone speaker,
   laptop speaker, whatever you have) in a reasonably quiet room.
2. At the same time, on the SENDING phone, press and hold WhatsApp's
   microphone/voice-note button and record the played audio, holding the
   phone's mic a consistent, close distance from the speaker. Release to
   send once the clip finishes playing. This produces a genuine recorded
   WhatsApp voice note (the actual deployment path), not an attachment.
3. Repeat for `sent_02`, `sent_03`, `sent_04`, keeping the same
   phone-to-speaker distance and volume level each time so the four
   recordings are comparable.
4. On the RECEIVING device/side of the chat, export the chat with media
   and place the four resulting audio files under
   `data/codec_experiment/real_roundtrip/received/voicenote/`, renamed
   `received_01_*` through `received_04_*` matching the `sent_NN` prefix.

## Exporting and placing files (both experiments)

1. **On the RECEIVING device**, open the conversation containing the
   voice notes or attachments.
2. **Export the chat with media**:
   - WhatsApp mobile: open the chat -> tap the contact/chat name at the
     top -> scroll down -> **Export Chat** -> choose **"Include Media"**
     (NOT "Without Media"). This produces a `.zip` (iOS) or a share sheet
     you can save as a `.zip` (Android) containing a text transcript plus
     every media file.
   - WhatsApp Desktop/Web: media can be downloaded per-message (click the
     download icon on each message) if a full chat export isn't
     available in your version -- four individual downloads is fine, same
     end result.
3. **Get the exported archive onto the computer** running this project
   (AirDrop, email it to yourself, USB, cloud sync) and unzip it if it's
   a `.zip`.
4. **Find the four audio files** in the extracted contents (typically
   named something like `WhatsApp Audio 2026-08-04 at 12.34.56.opus` --
   match them to the four you sent by listening or by send order/
   timestamp in the exported chat transcript, which lists messages in
   order).
5. **Place them in the correct experiment's directory**, renamed to match
   their `sent_NN_*` counterpart's numeric prefix, e.g. for Experiment 1:

   ```
   data/codec_experiment/real_roundtrip/received/attachment/received_01_chorthippus_biguttulus.opus
   data/codec_experiment/real_roundtrip/received/attachment/received_02_cicada_orni.opus
   data/codec_experiment/real_roundtrip/received/attachment/received_03_synthetic_above_nyquist_control.opus
   data/codec_experiment/real_roundtrip/received/attachment/received_04_synthetic_broadband_noise.opus
   ```

   ...and correspondingly under `received/voicenote/` for Experiment 2's
   files. The file extension doesn't need to be `.opus` specifically --
   whatever container WhatsApp's export produced is fine (`.m4a`, `.aac`,
   `.wav`, whatever); `R/10_roundtrip_validation.R` decodes it with
   `ffmpeg`, which reads essentially anything. Only the `received_NN_`
   numeric prefix and which directory it's placed in matter.

6. **Re-run the analysis**: `Rscript R/10_roundtrip_validation.R`. This
   regenerates `docs/roundtrip_validation.md` (both experiments plus a
   codec-vs-acoustic comparison section) and one 3-panel spectrogram
   figure per file per experiment under `docs/figures/`.

## What happens if only some files are received, or only one experiment

The script reports per-file results for whatever pairs it can match in
each arm independently, and explicitly lists which sent files had no
matching received file -- partial data still produces a partial,
honestly-labelled result, not a silent gap or an error. The same is true
if you only complete one of the two experiments: that arm's section is
generated normally and the other is reported as "not run yet." The
codec-vs-acoustic comparison section only runs once at least one file id
has a result in both arms.

## After the results land

See `docs/roundtrip_validation.md`'s "Tolerance, stated before any real
data was collected" section for the PASS/CAUTION/FAIL criteria (decided
and written into `R/10_roundtrip_validation.R` before this procedure was
ever run against real data, applied identically to both arms). The
**voice-note arm is the headline claim** (it's the actual deployment
path); the attachment arm's verdict is diagnostic, and the comparison
section states -- from the numbers, not assumed -- whether the attachment
arm turned out to be a genuine codec isolation or a near-lossless
passthrough.

If the voice-note simulation validates within tolerance, that finding
gets written into `docs/codec_findings.md` and `README.md` as a real,
checked claim -- currently the single biggest "trust us" gap in this
project's methodology. If it diverges, the divergence gets quantified and
named, and the compression-delta and classifier evaluations get re-run
using real-round-trip parameters if the real round trip turns out more
destructive than simulated -- that result would supersede every
simulated one.
