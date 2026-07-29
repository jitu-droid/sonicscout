# Environment

Documented as discovered during the autonomous build run. This machine is
Windows 11.

## R

- Installed at `C:\Program Files\R\R-4.6.1`, **not on PATH** in the shells
  this session has access to. Invoke via the full path:
  `"C:\Program Files\R\R-4.6.1\bin\Rscript.exe"`.
- User package library: `C:\Users\Anirjit\AppData\Local\R\win-library\4.6`.

If you want `Rscript`/`R` callable by name in a fresh terminal, add
`C:\Program Files\R\R-4.6.1\bin` to your user PATH (Windows Settings ->
Environment Variables, or `setx PATH "%PATH%;C:\Program Files\R\R-4.6.1\bin"`
from a terminal, then open a new terminal).

## FFmpeg

Installed via:

```powershell
winget install --id Gyan.FFmpeg -e
```

This is the `full_build` from gyan.dev, confirmed to include `libopus`
(checked with `ffmpeg -hide_banner -encoders | grep -i opus`). winget
creates a symlink at
`%LOCALAPPDATA%\Microsoft\WinGet\Links\ffmpeg.exe`, and that `Links`
directory is on the user PATH -- but only in shells started *after* the
install. Open a fresh terminal (or `refreshenv`-equivalent) to pick it up;
mid-session shells need `ffmpeg.exe`'s full path or a manual `PATH` append.

**Why a system FFmpeg at all**, when the brief expected `av` to handle
everything: `av::av_audio_convert()` (the package's high-level convert
function) does not expose a bitrate argument, only
format/channels/sample_rate. Since WhatsApp's ~16kbps target bitrate is the
single most important parameter in the codec experiment, encoding shells out
to a system `ffmpeg -c:a libopus -b:a <rate>k` call; `av` is used only for
the decode-back-to-WAV step, which doesn't need bitrate control. See
`PROGRESS.md` for whether this was re-verified against the installed `av`
version's actual API.

## R packages

Installed with `install.packages(p, dependencies = c("Depends", "Imports",
"LinkingTo"))` -- deliberately **excluding** `Suggests`, since
`dependencies = TRUE` recursively pulls every suggested package too (e.g.
`caret` and `seewave` between them suggest on the order of 100+ unrelated
packages for optional plotting backends, alternate model engines, etc. that
this project never calls). See `PROGRESS.md` for the exact package list and
what happened when the first attempt used `dependencies = TRUE`.

## renv

Status: TBD -- see `PROGRESS.md` / `BLOCKERS.md` for whether `renv::init()` +
`renv::snapshot()` completed for this session.
