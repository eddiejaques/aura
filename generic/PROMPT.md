# PROMPT.md — generate a pipeline like this one

A reusable instruction for getting an LLM to produce a working n8n workflow JSON in the shape of
`feedback-pipeline-daily.json`: fetch feedback from an API, classify each item with a model, and
land it in a warehouse without duplicates.

**How to use it:** fill in the five bracketed values in Part 1, paste Parts 1–4 into a capable
model, then import the result into n8n and follow the checklist in Part 5. Expect to fix the
credential mappings by hand — that part is not worth automating.

**Why the constraints in Part 3 exist:** every one of them is something that broke, or would have.
Don't drop them to make the output shorter.

---

## Part 1 — Fill this in

```
SOURCE:          [e.g. Zendesk tickets / Trustpilot reviews / an in-app NPS survey]
SOURCE API:      [base URL + the endpoint that lists items, and whether it paginates]
AUTH:            [none | bearer token | API key header | JWT you sign (say the algorithm) |
                  service-account JWT exchanged for an OAuth token]
WAREHOUSE:       [Snowflake | BigQuery | Postgres] , table [name]
THEMES:          [8–12 category names with a one-line definition each. If you don't have a list,
                  say "derive one" and see Part 4.]
SCHEDULE:        [e.g. daily at 07:00, or manual trigger only]
```

---

## Part 2 — What to build

Produce a **single n8n workflow JSON file** that I can import directly. The pipeline is nine steps:

```
Trigger
  → Code: build config + sign/fetch auth
  → HTTP: fetch items
  → Code: flatten into one n8n item per feedback, dropping personal data
  → SplitInBatches (Loop Over Items)
      → LLM: classify this item into exactly one theme
      → Code: parse the response and validate it
  → Code: build the output row, with a stable unique id
  → SQL: select the ids already stored
  → Code: keep only ids that are new
  → If (count > 0)
  → Insert
```

Output the JSON only, with no commentary around it.

---

## Part 3 — Hard requirements

These are non-negotiable. Each one exists because of a specific failure mode.

### 3.1 File shape

Top-level keys, exactly these:

```json
{
  "name": "...", "nodes": [], "connections": {}, "pinData": {},
  "active": false, "settings": {"executionOrder": "v1"},
  "versionId": "<uuid>", "meta": {}, "id": "<16 hex chars>", "tags": []
}
```

Every node object has: `parameters`, `name`, `type`, `typeVersion`, `position` (`[x, y]`), `id`
(uuid), and `credentials` where relevant. Node **names must be unique** — they are the addressing
mechanism for both connections and `$('Node Name')` back-references.

`connections` is keyed by **source node name**, and the array index is the **output index**:

```json
"Loop Over Items": {
  "main": [
    [ { "node": "Build Row",       "type": "main", "index": 0 } ],
    [ { "node": "Classify Item",   "type": "main", "index": 0 } ]
  ]
}
```

Working node types and versions to copy:

| Purpose | `type` | `typeVersion` |
|---|---|---|
| Schedule trigger | `n8n-nodes-base.scheduleTrigger` | 1 |
| Manual trigger | `n8n-nodes-base.manualTrigger` | 1 |
| JavaScript | `n8n-nodes-base.code` | 2 |
| HTTP request | `n8n-nodes-base.httpRequest` | 4.2 |
| Sign a JWT | `n8n-nodes-base.jwt` | 1 |
| Loop | `n8n-nodes-base.splitInBatches` | 3 |
| Branch | `n8n-nodes-base.if` | 2.3 |
| LLM (Gemini) | `@n8n/n8n-nodes-langchain.googleGemini` | 1.1 |
| Snowflake | `n8n-nodes-base.snowflake` | 1 |
| Canvas note | `n8n-nodes-base.stickyNote` | 1 |

Set `credentials` to `{"<credType>": {"id": null, "name": "<human name>"}}`. Never invent a
credential id, and leave `meta` empty — a real id points at someone else's n8n instance.

### 3.2 The loop node — output 0 is *done*

`splitInBatches` has two outputs and they are the reverse of what most people assume:

- **output 0 = done** — fires once, carrying every item, after the loop finishes. The rest of the
  pipeline hangs off this.
- **output 1 = loop** — fires per batch. The classify step hangs off this and must connect **back**
  into the loop node.

Getting this backwards is the single most common way this workflow shape fails.

### 3.3 The model gets a closed menu, and code checks the answer

- The prompt must list the exact theme names with one-line definitions and say: pick exactly one,
  copy the string exactly, return only JSON, no markdown fences.
- The parse Code node must strip ``` fences defensively, `JSON.parse`, then validate:

```js
const ALLOWED = new Set([ /* the exact theme names */ ]);
const category = ALLOWED.has(parsed.category?.trim()) ? parsed.category.trim() : 'N/A';
```

- **The theme names in the prompt and in `ALLOWED` must match byte for byte** — same punctuation,
  same `&` vs `and`. A mismatch turns every row into `N/A` silently, with no error anywhere.
- Always include a theme for praise, one for uncategorisable input (gibberish, a bare email, empty
  text), and one for vague dissatisfaction with no actionable detail.
- Wrap the parse in `try/catch` and fall back to `N/A`. A model that returns prose instead of JSON
  must not end the run.

### 3.4 Stable ids, and no personal data stored

Build the row's key by hashing fields that don't change:

```js
const id = crypto.createHash('sha256')
  .update(`${item.created_at}|${item.source_id}|${item.author ?? ''}`)
  .digest('hex').substring(0, 32);
```

The author's name goes **into** the hash and is never stored as a column. Delete email addresses in
the flatten node — from the item *and* from any raw payload you retain. Dropping personal data at
the point of ingestion is much easier than removing it from a warehouse later.

### 3.5 Every run must be safe to re-run

`SELECT DISTINCT <key>` → filter in a Code node → `If count > 0` → insert. Re-running after a
failure must insert nothing new.

State plainly in a sticky note that this dedup is **application-level and not concurrency-safe**:
two overlapping runs both read "not present" before either writes. Prefer `MERGE ... WHEN NOT
MATCHED THEN INSERT` if the target supports it. Note also that `PRIMARY KEY` is **enforced on
Postgres but informational and unenforced on Snowflake and BigQuery**.

### 3.6 Configuration comes from `$env`

No app ids, package names, account emails, project ids, database or schema names as literals.

**A field only evaluates `{{ ... }}` if it is an n8n expression, meaning the string starts with
`=`.** This bites hardest on SQL, where a plain string looks fine and silently doesn't interpolate:

```jsonc
"query": "=SELECT DISTINCT id FROM {{ $env.DB }}.{{ $env.SCHEMA }}.MY_TABLE WHERE source = 'x'"
```

**Do not turn the classification prompt into an expression.** Those prompts contain literal `{` and
`}` (they specify a JSON response shape), and n8n would try to parse that as templating and break
the prompt. Leave a plain-text placeholder like `YOUR_PRODUCT` in the prompt instead.

Also emit a `.env.example` listing every variable you used.

### 3.7 Never concatenate outside values into SQL

If ids from config end up in an `IN (...)` clause, validate them first:

```js
const UUID = /^[0-9a-fA-F-]{36}$/;
if (!UUID.test(String(id))) throw new Error('refusing non-UUID id: ' + id);
```

Prefer query parameters where the node supports them.

### 3.8 Explicit pagination when the built-in kind fails

n8n's built-in HTTP pagination does not reliably advance the cursor on every endpoint — notably
`POST`-based filter endpoints, where it can refetch page one forever and report success. If the
source paginates, write the loop in a Code node:

```js
let after = null, hasMore = true, guard = 0;
while (hasMore && guard++ < 500) {              // guard: bounded, not infinite
  const res = await this.helpers.httpRequest({ method: 'POST', url: `${base}?limit=100${after ? `&after=${encodeURIComponent(after)}` : ''}`, headers, body, json: true });
  const data = Array.isArray(res) ? res[0]?.data : res?.data;
  for (const it of data?.items ?? []) out.push({ json: it });
  after = data?.next?.after ?? null;
  hasMore = !!data?.has_more && !!after;
}
```

### 3.9 Layout and documentation

Lay nodes out left to right, ~224px apart on x, with separate branches on different y bands. Add a
`stickyNote` describing what the workflow does, which env vars it needs, which credentials to
re-link, and any known weakness. The canvas is the documentation — someone who doesn't read code
should be able to follow it.

---

## Part 4 — If I asked you to derive the themes

Before writing the workflow, ask me for a sample of real feedback. Then:

1. Cluster it into 8–12 themes that a team could actually act on differently. "Slow" and
   "crashes" belong in one bucket if the same team fixes both.
2. Give each a name and a one-line definition with concrete examples from the sample.
3. Add the three structural buckets from §3.3 (praise, uncategorisable, vague).
4. Show me the list and **wait for me to edit it** before generating the workflow. Which themes are
   worth separating is a product judgement, not a clustering result.

---

## Part 5 — Check before trusting the output

Run these against the generated file. They catch the failures that produce no error message:

1. It parses as JSON, and every name in `connections` exists in `nodes`.
2. Every theme name in the prompt appears verbatim in the `ALLOWED` set, and vice versa.
3. Every field containing `{{` starts with `=`.
4. No credential `id` values, and `meta` is empty.
5. No real app ids, project ids, emails, database names or table paths as literals.
6. Every Code node is valid JavaScript (`node --check` on the body wrapped in an async function).
7. The classify node hangs off loop output **1**; the rest of the pipeline off output **0**.

Then, in n8n: re-link credentials, run one branch manually, confirm rows land — and **run it a
second time**. Zero new rows on the second run is the signal that dedup works.
