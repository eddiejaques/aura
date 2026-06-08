# Aura — App Reviews Fetch & Analyze (n8n Workflow)

This is an [n8n](https://n8n.io) workflow exported as JSON. It automatically fetches app store reviews from both **Apple App Store** and **Google Play Store**, runs AI-powered sentiment analysis, generates draft customer responses, deduplicates against BigQuery, and inserts new rows into BigQuery analysis tables — every 24 hours.

## What It Does

Two pipelines run on the same 24-hour schedule:

| Pipeline | Platform | AI Model |
|---|---|---|
| Apple App Store | App Store Connect API | GPT-4o-mini (OpenAI) |
| Google Play | Google Play Developer API | Gemini 3.1 Flash Lite + Gemini 2.5 Flash |

Each pipeline follows the same steps:

```
Schedule (every 24h)
  → Authenticate (JWT)
  → Fetch Reviews (HTTP)
  → Parse & Split reviews into individual items
  → Loop over each review:
      → Analyze Sentiment (AI)
      → Parse Sentiment JSON
      → Generate Response Draft (AI)
      → Parse & compile final output
  → Add Unique ID (hash of timestamp + reviewer)
  → Query BigQuery for review_ids inserted in the last 2 days
  → Check Duplicates (filter out review_ids already present)
  → If new rows exist → Insert into BigQuery analysis table
```

## Node Breakdown

### Trigger
- **Schedule - Every 24 hours** — fires both pipelines once a day (at minute 24).

### Apple App Store Pipeline
1. **Create JWT** — generates a JWT token using ES256 (Apple's required algorithm) with `APPLE_ISSUER_ID`, `APPLE_KEY_ID`, and `APPLE_PRIVATE_KEY` env vars.
2. **Fetch IOS Reviews VIA API** — calls `GET /v1/apps/{APPLE_APP_ID}/customerReviews` (App Store Connect API), fetches the 10 most recent reviews sorted by date.
3. **Parse Sentiment3** — unpacks the API response array into individual review items with normalized fields (`reviewId`, `rating`, `title`, `body`, `territory`, etc.).
4. **Loop Over Items** — processes one review at a time.
5. **Analyze Sentiment - OpenAI1** — sends the review to GPT-4o-mini with a structured system prompt. Returns a JSON object with `sentiment`, `category`, `key_issues`, `urgency`, `summary`, `response_tone`, `action_required`, `customer_emotion`.
6. **Parse Sentiment1** — strips markdown wrappers from the AI response and merges analysis with review metadata.
7. **Generate Response - OpenAI1** — sends the full review + analysis back to GPT-4o-mini to generate a personalized, plain-text customer reply draft (under 200 words).
8. **Parse Response1** — assembles the final output object combining review info, sentiment analysis, and the generated response.
9. **Add Unique ID** — hashes `response_generated_at` + `reviewer_nickname` (SHA-256, first 32 chars) into a stable `id`.
10. **Execute a SQL query - iOS** — pulls `review_id`s already inserted into BigQuery in the last 2 days.
11. **Check Duplicates** — filters out reviews whose `review_id` is already present in BigQuery.
12. **If** — branches: rows to insert → **Insert rows in iOS Table**; otherwise continues to the Android JWT step (so both pipelines always run on the same trigger).
13. **Insert rows in iOS Table** — inserts new analyzed reviews into the `ios_app_store_analysis` BigQuery table.

### Google Play Pipeline (Gemini)
1. **Android - JWT - Begins** — mints a service-account JWT using Google's OAuth2 scope for `androidpublisher`, with `iss` from `GOOGLE_SERVICE_ACCOUNT_EMAIL`.
2. **HTTP Request2** — exchanges the JWT for a Google OAuth2 `access_token`.
3. **HTTP Request3** — calls `GET /androidpublisher/v3/applications/{GOOGLE_PLAY_PACKAGE_NAME}/reviews?maxResults=10`.
4. **Code in JavaScript2** — normalizes Play Store review structure (nested `comments[0].userComment`) into flat fields including `device`, `androidOsVersion`, `appVersionCode`.
5. **Loop Over Items2** — processes one review at a time.
6. **Message a model** (Gemini 3.1 Flash Lite) — structured sentiment analysis, adds a `device_context` field relevant to Android device/OS issues.
7. **Parse Sentiment2** — parses Gemini's `content.parts[0].text` response and merges with review data.
8. **Message a model1** (Gemini 2.5 Flash) — generates a device-aware customer reply draft.
9. **Parse Response2** — compiles the final output with `platform: 'google_play'`.
10. **Add Unique ID - Android** — converts the `last_modified` `{seconds, nanos}` object into an ISO timestamp and hashes `response_generated_at` + `author_name` into a stable `id`.
11. **Execute a SQL query - Android** — pulls `review_id`s already inserted into BigQuery in the last 2 days.
12. **Check Duplicates-Android** — filters out reviews whose `review_id` is already present in BigQuery.
13. **If1** — branches: rows to insert → **Insert rows in a table - Android**.
14. **Insert rows in a table - Android** — inserts new analyzed reviews into the `android_app_store_analysis` BigQuery table.

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

### Final Output per Review (pre-BigQuery insert)
```json
{
  "review_id": "...",
  "rating": 3,
  "review_text": "...",
  "sentiment": "negative",
  "urgency": "high",
  "suggested_response": "Plain text draft response...",
  "response_generated_at": "2026-06-05T10:00:00.000Z",
  "platform": "apple_app_store | google_play",
  "id": "sha256-derived-32-char-hash"
}
```

## Setup

### Required Credentials (configure in n8n)

| Credential | Used By |
|---|---|
| `OpenAi account` | OpenAI sentiment + response nodes (Apple pipeline) |
| `JWT Auth account` | Apple & Google Play JWT nodes |
| `Google Gemini(PaLM) Api account` | Gemini pipeline nodes (Google Play) |
| `Google BigQuery Account V2` | Dedup queries + table inserts (both pipelines) |

> **Note:** the `aura.json` checked into this repo currently contains the *source instance's* credential reference IDs (the values inside each node's `"credentials": { ... "id": ... }` block) and BigQuery `projectId`/`datasetId` resource locators. On import, n8n will likely resolve these to the wrong (or missing) credentials/resources for your instance — re-link every credential and re-pick the BigQuery project/dataset before activating.

### Required Environment Variables

| Variable | Description |
|---|---|
| `APPLE_ISSUER_ID` | App Store Connect API issuer ID |
| `APPLE_KEY_ID` | App Store Connect API key ID |
| `APPLE_PRIVATE_KEY` | Apple ES256 private key (PEM format, full `-----BEGIN PRIVATE KEY-----` block) |
| `APPLE_APP_ID` | Numeric App Store app ID |
| `GOOGLE_SERVICE_ACCOUNT_EMAIL` | Google service account email for Android Publisher API |
| `GOOGLE_PLAY_PACKAGE_NAME` | Android app package name (e.g. `com.example.app`) |
| `BIGQUERY_PROJECT_ID` | GCP project ID hosting the BigQuery dataset |
| `BIGQUERY_DATASET` | BigQuery dataset name containing the `ios_app_store_analysis` / `android_app_store_analysis` tables |

Create a `.env` file locally (it is gitignored, see `.env.example`) and load it into your n8n instance's environment before running the workflow.

### App IDs, Service Account, and BigQuery
The fetch URLs, JWT claims, and the deduplication SQL queries are all driven by environment variables — no app/package/service-account/dataset values are hardcoded in the JSON's expressions:
- `APPLE_APP_ID` — your numeric App Store app ID
- `GOOGLE_PLAY_PACKAGE_NAME` — your Android package name
- `GOOGLE_SERVICE_ACCOUNT_EMAIL` — your Google service account email
- `BIGQUERY_PROJECT_ID` / `BIGQUERY_DATASET` — your BigQuery project and dataset

The BigQuery node *resource locators* (`projectId`/`datasetId`/`tableId` pickers and their `cachedResultUrl`/`cachedResultName`) still reference the source instance's project/dataset — re-pick these in the n8n UI after import (see Security Notice below).

## How to Import

1. Open your n8n instance.
2. Go to **Workflows** → **Import from file**.
3. Upload `aura.json`.
4. Re-link all credentials listed above (OpenAI, JWT Auth, Gemini, BigQuery).
5. Re-pick the BigQuery project, dataset, and tables in each BigQuery node (the imported resource locators point at the source instance's project/dataset).
6. Set the required environment variables.
7. Verify the App ID, package name, service account email, and BigQuery project/dataset resolve correctly via the env vars.
8. Activate the workflow (it imports as `"active": true`).

## Security Notice — Instance-Specific Data in the JSON

| Field | Status | What it is |
|---|---|---|
| Fetch URLs / JWT `iss` claims / dedup SQL | **Parameterized** | Now use `$env.APPLE_APP_ID`, `$env.GOOGLE_PLAY_PACKAGE_NAME`, `$env.GOOGLE_SERVICE_ACCOUNT_EMAIL`, `$env.BIGQUERY_PROJECT_ID`, `$env.BIGQUERY_DATASET` |
| `credentials.id` inside each node | **Not nulled** | Currently contains the source instance's live credential vault references — re-link on import, then null these out (or re-export from your own instance) before committing further changes |
| BigQuery `projectId`/`datasetId` `__rl` objects (`cachedResultName`/`cachedResultUrl`) | **Not parameterized** | Still point at the source instance's GCP project/dataset — re-pick in the n8n UI after import |
| `meta.instanceId` | Remains | Hash identifying the source n8n instance — harmless, no functional effect |
| `versionId` / workflow `id` | Remains | Workflow version and ID from the source instance — harmless, overwritten on import |

**Before committing any future re-export of this workflow:**
- Search for `"id":` values inside `"credentials"` blocks and null them out (or confirm they belong to your own instance).
- Search for your BigQuery project/dataset names in `projectId`/`datasetId`/`cachedResultUrl` fields and replace with placeholders if sharing publicly.

## Notes

- All generated responses are **drafts** — intended for human review before posting publicly.
- The workflow imports as `"active": true` — review the schedule and credentials before letting it run live.
- Response temperature is `0.3` for analysis (deterministic) and `0.7` for response generation (creative).
- Deduplication looks back 2 days in BigQuery (`TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 2 DAY)`) before inserting — adjust the interval in the SQL query nodes if your run cadence changes.
