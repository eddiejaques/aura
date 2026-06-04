# Aura — App Reviews Fetch & Analyze (n8n Workflow)

This is an [n8n](https://n8n.io) workflow exported as JSON. It automatically fetches app store reviews from both **Apple App Store** and **Google Play Store**, runs AI-powered sentiment analysis, and generates draft customer responses — every 6 hours.

## What It Does

Three parallel pipelines run on the same schedule:

| Pipeline | Platform | AI Model |
|---|---|---|
| Apple App Store | App Store Connect API | GPT-4o-mini (OpenAI) |
| Google Play (OpenAI) | Google Play Developer API | GPT-4o-mini (OpenAI) |
| Google Play (Gemini) | Google Play Developer API | Gemini 3.1 Flash Lite + Gemini 2.5 Flash |

Each pipeline follows the same steps:

```
Schedule (every 6h)
  → Authenticate (JWT)
  → Fetch Reviews (HTTP)
  → Parse & Split reviews into individual items
  → Loop over each review:
      → Analyze Sentiment (AI)
      → Parse Sentiment JSON
      → Generate Response Draft (AI)
      → Parse & compile final output
```

## Node Breakdown

### Trigger
- **Schedule - Every 6 Hours** — fires all three pipelines every 6 hours.

### Apple App Store Pipeline
1. **Code in JavaScript1** — generates a JWT token using ES256 (Apple's required algorithm) with `APPLE_ISSUER_ID` and `APPLE_KEY_ID` env vars.
2. **Fetch Apple Reviews1** — calls `GET /v1/apps/{appId}/customerReviews` (App Store Connect API), fetches the 5 most recent reviews sorted by date.
3. **Parse Sentiment3** — unpacks the API response array into individual review items with normalized fields (`reviewId`, `rating`, `title`, `body`, `territory`, etc.).
4. **Loop Over Items** — processes one review at a time.
5. **Analyze Sentiment - OpenAI1** — sends the review to GPT-4o-mini with a structured system prompt. Returns a JSON object with `sentiment`, `category`, `key_issues`, `urgency`, `summary`, `response_tone`, `action_required`, `customer_emotion`.
6. **Parse Sentiment1** — strips markdown wrappers from the AI response and merges analysis with review metadata.
7. **Generate Response - OpenAI1** — sends the full review + analysis back to GPT-4o-mini to generate a personalized, plain-text customer reply draft (under 200 words).
8. **Parse Response1** — assembles the final output object combining review info, sentiment analysis, and the generated response.

### Google Play Pipeline (OpenAI)
1. **JWT** — mints a service-account JWT using Google's OAuth2 scope for `androidpublisher`.
2. **HTTP Request** — exchanges the JWT for a Google OAuth2 `access_token`.
3. **HTTP Request1** — calls `GET /androidpublisher/v3/applications/{packageName}/reviews?maxResults=10`.
4. **Code in JavaScript** — normalizes Play Store review structure (nested `comments[0].userComment`) into flat fields including `device`, `androidOsVersion`, `appVersionCode`.
5. **Loop Over Items1** — processes one review at a time.
6. **Analyze Sentiment - OpenAI** — same structured analysis as the Apple pipeline, but adds a `device_context` field relevant to Android device/OS issues.
7. **Parse Sentiment** — parses and merges AI response with review data.
8. **Generate Response - OpenAI** — generates a device-aware customer reply draft.
9. **Parse Response** — compiles the final output with `platform: 'google_play'`.

### Google Play Pipeline (Gemini) — experimental
Identical structure to the OpenAI Play pipeline, but uses:
- **Message a model** (Gemini 3.1 Flash Lite) for sentiment analysis
- **Message a model1** (Gemini 2.5 Flash) for response generation
- Gemini returns content in `content.parts[0].text` format, handled in **Parse Sentiment2** and **Parse Response2**.

## AI Output Schema

### Sentiment Analysis
```json
{
  "sentiment": "positive | negative | neutral",
  "category": "bug | feature_request | complaint | praise | general_feedback | performance | ui_ux | pricing | compatibility",
  "key_issues": ["issue 1", "issue 2"],
  "urgency": "low | medium | high | critical",
  "summary": "one-sentence summary",
  "response_tone": "apologetic | grateful | helpful | empathetic | professional",
  "action_required": true,
  "customer_emotion": "frustrated | angry | satisfied | disappointed | happy | neutral",
  "device_context": "Play Store only — notes on device/OS relevance"
}
```

### Final Output per Review
```json
{
  "review_id": "...",
  "rating": 3,
  "review_text": "...",
  "sentiment": "negative",
  "urgency": "high",
  "suggested_response": "Plain text draft response...",
  "response_generated_at": "2026-06-05T10:00:00.000Z",
  "platform": "apple_app_store | google_play"
}
```

## Setup

### Required Credentials (configure in n8n)

| Credential | Used By |
|---|---|
| `OpenAi account` | All OpenAI sentiment + response nodes |
| `JWT Auth account` | Google Play JWT nodes |
| `Google Gemini(PaLM) Api account` | Gemini pipeline nodes |

### Required Environment Variables

| Variable | Description |
|---|---|
| `APPLE_ISSUER_ID` | App Store Connect API issuer ID |
| `APPLE_KEY_ID` | App Store Connect API key ID |
| `APPLE_PRIVATE_KEY` | Apple ES256 private key (PEM format, full `-----BEGIN PRIVATE KEY-----` block) |
| `APPLE_APP_ID` | Numeric App Store app ID (e.g. `826510222`) |
| `GOOGLE_SERVICE_ACCOUNT_EMAIL` | Google service account email for Android Publisher API |
| `GOOGLE_PLAY_PACKAGE_NAME` | Android app package name (e.g. `com.example.app`) |

Create a `.env` file locally (it is gitignored) and load it into your n8n instance's environment before running the workflow.

### App IDs and Service Account
These are all driven by environment variables — no hardcoded values remain in the JSON:
- `APPLE_APP_ID` — your numeric App Store app ID
- `GOOGLE_PLAY_PACKAGE_NAME` — your Android package name
- `GOOGLE_SERVICE_ACCOUNT_EMAIL` — your Google service account email

## How to Import

1. Open your n8n instance.
2. Go to **Workflows** → **Import from file**.
3. Upload `aura.json`.
4. Configure all credentials listed above.
5. Set the required environment variables.
6. Update the App IDs and service account email for your apps.
7. Activate the workflow.

## Security Notice — Instance-Specific IDs in the JSON

The `aura.json` has been scrubbed before publishing. Here's what was removed and what remains:

| Field | Status | What it is |
|---|---|---|
| `credentials.id` inside each node | **Nulled out** | Was the source instance's internal credential reference — n8n will prompt you to re-link on import |
| `meta.instanceId` | Remains | Hash identifying the source n8n instance — harmless, no functional effect |
| `versionId` / `id` | Remains | Workflow version and ID from the source instance — harmless, overwritten on import |

**When you import this workflow:**
- n8n will detect the null credential IDs and prompt you to select or create credentials for each node. This is expected — just link them to your own OpenAI, JWT Auth, and Gemini credentials.
- After re-linking, if you re-export and commit, the JSON will contain **your** instance's credential IDs. Null them out again before committing (search for any `"id":` values inside `"credentials"` blocks that are not `null`).

## Notes

- All generated responses are **drafts** — intended for human review before posting publicly.
- The Gemini pipeline (`Schedule - Every 6 Hours4`) appears to be experimental, as noted by the sticky note "Build a gemini based pipeline."
- The workflow is currently set to `"active": false` in the JSON — you must activate it after importing.
- Response temperature is `0.3` for analysis (deterministic) and `0.7` for response generation (creative).
