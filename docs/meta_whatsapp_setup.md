# Meta WhatsApp Cloud API Setup

The live WhatsApp path now runs through Meta's WhatsApp Cloud API, alongside
the Twilio sandbox (which stays in place). Why: the Twilio trial accepted
incoming messages, but downloading their media returned HTTP 401 and custom
replies were never delivered (see the 2026-10-21 13:45 entry in
`logs/requests.jsonl`).

These are the steps only you can do, because they need your Meta account and
phone. Meta's dashboard labels change from time to time; if one below doesn't
match exactly, look for the nearest equivalent.

## 1. Create the app and get a test number

1. Sign in at https://developers.facebook.com and create an app. Choose the
   WhatsApp use case ("Connect with customers through WhatsApp" or similar),
   and connect or create a Business portfolio when asked.
2. Open **WhatsApp > API Setup**. Meta gives you a free **test phone number**.
3. Under the "To" field, **add your own WhatsApp number** as a recipient and
   confirm it with the code Meta sends. A test number can only exchange
   messages with numbers added here (up to 5).

## 2. Fill in `.env`

Copy `.env.example` to `.env` if you haven't already, then fill in:

| Variable | Where to find it |
|---|---|
| `META_ACCESS_TOKEN` | WhatsApp > API Setup > **Temporary access token** (click to copy). |
| `META_PHONE_NUMBER_ID` | WhatsApp > API Setup > **Phone number ID** -- the long ID under the test number, not the phone number itself. |
| `META_VERIFY_TOKEN` | **You make this up** -- any long random string. You'll paste the same value into Meta in step 4. |
| `META_APP_SECRET` | Optional but recommended: **App settings > Basic > App secret** ("Show"). With it set, the webhook refuses any delivery whose signature doesn't match. |
| `META_GRAPH_VERSION` | Optional. Defaults to `v26.0`. |

Never commit `.env` (it is gitignored).

**The temporary access token expires after about 24 hours.** When it does,
voice notes stop being downloaded and replies stop arriving, and the log
shows `download_failed` / `reply_failed` entries mentioning "Graph API HTTP
401" or code 190. Copy a fresh token from API Setup into `.env` and restart
the server. For anything longer than a demo day, create a **System User**
(Business settings > Users > System users), give it the WhatsApp app with
`whatsapp_business_messaging` and `whatsapp_business_management`
permissions, and generate a token that doesn't expire.

The Twilio variables can stay in `.env` or be removed: the server starts
with either provider fully configured. It refuses to start if a provider is
only half filled in, and the error says which variable is missing.

## 3. Start the server, the smoke test, and a tunnel

From the repo root, in three terminals:

```bash
Rscript R/start_webhook.R
```

```bash
Rscript R/12_meta_smoke_test.R
```

```bash
tools/cloudflared.exe tunnel --url http://localhost:8000
```

The smoke test checks that the token is accepted (by looking up your phone
number ID) and that `/meta-webhook` answers a verification request; fix
anything it flags first. cloudflared prints a public address like
`https://<random-words>.trycloudflare.com`. **That address changes every
time cloudflared restarts**, and Meta then needs the new one (step 4).

## 4. Point Meta at the webhook

1. Open **WhatsApp > Configuration** (or **Webhooks**).
2. **Callback URL:** `https://<tunnel>/meta-webhook`, e.g.
   `https://<random-words>.trycloudflare.com/meta-webhook`.
3. **Verify token:** exactly your `META_VERIFY_TOKEN`.
4. Click **Verify and save**. Meta calls `GET /meta-webhook`; the server
   answers only if the verify token matches.
5. Under **Webhook fields**, **subscribe to `messages`**. Without this, no
   messages are delivered.

## 5. Live test

1. From your phone (the number added in step 1), send a WhatsApp **voice
   note** of 10-30 seconds to the test number -- for example,
   `demo_clips/cicada_orni.wav` played out loud.
2. Within a few seconds you should get a reply such as
   "90% match -- cicada_orni", or the low-confidence / too-short message.
3. `logs/requests.jsonl` gains an entry with `"source":"meta"`, your number
   as `"from":"whatsapp:+<number>"`, and the outcome. The dashboard shows it.
4. Also try a text message and a photo: each gets the same reply the Twilio
   path gives.

## How the webhook behaves

- Each delivery is acknowledged with HTTP 200 at once; the download,
  prediction and reply happen just after. (Meta re-sends deliveries it
  doesn't see acknowledged quickly.)
- A message re-delivered with the same message ID is answered only once.
  The record of seen IDs is kept in memory, so a re-delivery that arrives
  after a server restart would be answered again.
- Delivery-status events (sent / delivered / read) are ignored.
- Graph API errors are written to the log; the access token never is.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| "Verify and save" fails | Server or tunnel not running, wrong callback URL (must end in `/meta-webhook`), or verify token mismatch. |
| Nothing arrives at all | `messages` webhook field not subscribed, or your number isn't in the "To" list. |
| `download_failed` / `reply_failed` with HTTP 401 or code 190 | Access token expired -- see step 2. |
| Everything is refused with 403 | `META_APP_SECRET` doesn't match the app's secret. |
| Worked yesterday, not today | Temporary token expired, or the cloudflared address changed. |
