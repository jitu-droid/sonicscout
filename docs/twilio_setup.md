# Twilio WhatsApp Sandbox Setup

Manual steps needed from Jitu before the webhook (`api/plumber.R`) can be
tested against a real WhatsApp message. This cannot be automated end-to-end
because it needs your own Twilio account and phone.

## 1. Create a Twilio account and open the WhatsApp Sandbox

1. Sign up at https://www.twilio.com/try-twilio (free trial is enough).
2. In the Twilio Console, go to **Messaging -> Try it out -> Send a WhatsApp message**.
3. You'll see a sandbox number (e.g. `+1 415 523 8886`) and a join code like
   `join <two-words>`.
4. From your own WhatsApp, send that join code as a message to the sandbox
   number. Your number is now bound to the sandbox for testing.

## 2. Get your credentials

From the Twilio Console dashboard, copy:

- **Account SID** (`ACxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx`)
- **Auth Token**

## 3. Set environment variables

Copy `.env.example` to `.env` (never commit `.env` -- it's already in
`.gitignore`) and fill in:

```
TWILIO_ACCOUNT_SID=ACxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
TWILIO_AUTH_TOKEN=your_auth_token_here
TWILIO_WHATSAPP_FROM=whatsapp:+14155238886
```

## 4. Smoke-test before going live

Before standing up a tunnel and touching the real sandbox, run:

```bash
Rscript R/11_twilio_smoke_test.R
```

This checks, without needing an inbound message at all: that
`TWILIO_ACCOUNT_SID`/`TWILIO_AUTH_TOKEN` load (from an already-exported
environment or directly from `.env` in the repo root -- it loads `.env`
itself, no extra step needed), that Twilio's API is reachable and these
specific credentials are accepted (a real authenticated round trip to
Twilio, not just "the variable is non-empty"), and whether the local
webhook is already responding on `/health` (fine if it isn't yet -- you
haven't started it). Fix anything it flags before continuing; a live
phone test is a much slower way to discover a typo in an auth token.

Separately, `api/plumber.R` itself now validates its own startup
conditions (Prompt 11): it refuses to start at all -- fails immediately,
not on the first real request -- if credentials are missing or
`models/classifier.rds` doesn't exist. If `Rscript -e
"plumber::pr_run(plumber::pr('api/plumber.R'), ...)"` errors out
immediately with a "Startup validation failed" message, that error message
itself says exactly what's missing.

## 5. Expose the plumber API and point Twilio at it

Twilio needs a public HTTPS URL to send webhooks to. For local development,
use a tunnel (e.g. `ngrok http 8000` if running plumber on port 8000), then:

1. In the Twilio Console, go to the WhatsApp Sandbox settings.
2. Set **"When a message comes in"** to
   `https://<your-ngrok-subdomain>.ngrok.io/webhook` (or wherever
   `api/plumber.R`'s endpoint is mounted), method `POST`.

## 6. Run the live test

1. Start the API: `Rscript -e "plumber::pr_run(plumber::pr('api/plumber.R'), port = 8000)"`.
   If this errors immediately with "Startup validation failed", fix what
   it names (see step 4) before continuing.
2. Start the tunnel.
3. Set the sandbox webhook URL as above.
4. Send a real WhatsApp voice note (10-30s, recorded at night near a target
   sound if possible) to the sandbox number from your joined phone. Note
   the send time so wall-clock latency (send -> reply received) can be
   measured from the chat timestamps or `logs/requests.jsonl`'s own
   timestamp against when the reply visibly arrives.
5. Confirm: the reply arrives on WhatsApp with a pest ID + confidence, and a
   new entry appears in `logs/requests.jsonl` with the full path (media
   retrieval, decode, prediction) reflected in its fields.

## 7. Test the failure paths too, for real

Send each of these to the sandbox number and confirm the reply matches
what's expected -- these are all handled explicitly in `api/plumber.R`
but have only ever been exercised by the mock test suite, not real Twilio
payloads:

1. **A text-only message** (no attachment) -- expect: "Please send a voice
   note recording of the field (10-30 seconds)."
2. **A very short voice note** (under 3 seconds) -- expect: a message
   naming the actual duration and asking for at least 3 seconds.
3. **A silent voice note** (record with the mic covered, or in total
   silence) -- expect: either the low-confidence path, or (if every window
   gets energy-gated) the "too quiet to find any signal" message -- not an
   error and not a spurious species guess.
4. **A non-audio attachment** (a photo, for instance) -- expect: "That
   doesn't look like an audio file..."

If any of these instead returns "Sorry, something went wrong..." or times
out, that's a real bug the mock test suite didn't catch (mocked media
downloads and synthetic test audio don't necessarily exercise every real
WhatsApp encoding quirk) -- log it and fix it before treating the webhook
as demo-ready.

## Known limitation

The Twilio **Sandbox** (not the full WhatsApp Business API) is what this
project uses, per the original brief -- it's free and instant but only
works for phone numbers that have sent the join code, and sandbox sessions
expire periodically (you may need to re-send the join code). This is fine
for a hackathon demo; it is not a production WhatsApp Business setup.

See `BLOCKERS.md` for "set up Twilio sandbox and run live test" as an
outstanding action item -- the autonomous build run cannot do this part
without your Twilio account.
