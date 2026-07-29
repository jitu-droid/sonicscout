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

## 4. Expose the plumber API and point Twilio at it

Twilio needs a public HTTPS URL to send webhooks to. For local development,
use a tunnel (e.g. `ngrok http 8000` if running plumber on port 8000), then:

1. In the Twilio Console, go to the WhatsApp Sandbox settings.
2. Set **"When a message comes in"** to
   `https://<your-ngrok-subdomain>.ngrok.io/webhook` (or wherever
   `api/plumber.R`'s endpoint is mounted), method `POST`.

## 5. Run the live test

1. Start the API: `Rscript -e "plumber::pr_run(plumber::pr('api/plumber.R'), port = 8000)"`.
2. Start the tunnel.
3. Set the sandbox webhook URL as above.
4. Send a real WhatsApp voice note (10-30s, recorded at night near a target
   sound if possible) to the sandbox number from your joined phone.
5. Confirm: the reply arrives on WhatsApp with a pest ID + confidence, and a
   new entry appears in `logs/`.

## Known limitation

The Twilio **Sandbox** (not the full WhatsApp Business API) is what this
project uses, per the original brief -- it's free and instant but only
works for phone numbers that have sent the join code, and sandbox sessions
expire periodically (you may need to re-send the join code). This is fine
for a hackathon demo; it is not a production WhatsApp Business setup.

See `BLOCKERS.md` for "set up Twilio sandbox and run live test" as an
outstanding action item -- the autonomous build run cannot do this part
without your Twilio account.
