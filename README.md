# Aura — user feedback pipelines in n8n

n8n workflows that collect user feedback from app stores and survey tools, have an LLM sort each
item into a fixed set of themes, and land the result in a warehouse as queryable rows.

There are two generations here. They solve the same problem and share most of their DNA — the
second is what the first turned into after further iteration.

| | **v1 — `aura/`** | **v2 — `generic/`** |
|---|---|---|
| Workflow | `App Reviews - Fetch & Analyze - DND5` | `…- DND12` |
| Nodes | 30 | 40 + 35 (backfill) |
| Sources | App Store, Google Play | App Store, Google Play, **survey feedback** |
| Model | GPT-4o-mini + Gemini | Gemini 3.1 Flash Lite |
| Warehouse | BigQuery | Snowflake |
| LLM output | sentiment, urgency, **draft reply** | sentiment, urgency, **fixed 11-theme taxonomy** |
| Config style | `$env` throughout | `$env` throughout (same variable names) |

The node names are the giveaway: `Parse Sentiment3`, `Add Unique ID`, `Check Duplicates` and
`Android - JWT - Begins` appear in both. v2 kept the skeleton, swapped the warehouse and the model,
added a third source, and replaced free-form categories with a controlled vocabulary.

## What's here

```
.
├─ blog/
│  └─ learning-n8n-agentic-workflows.md   the story: why this exists and how it was built
├─ aura/                                  v1 — BigQuery + OpenAI, draft replies
│  ├─ aura.json
│  ├─ README.md                             node-by-node breakdown and setup
│  └─ .env.example
└─ generic/                               v2 — Snowflake + Gemini, themed classification
   ├─ feedback-pipeline-daily.json          40 nodes: iOS + Android + survey, on schedules
   ├─ feedback-pipeline-backfill.json       35 nodes: manual history load
   ├─ schema.sql                            the two warehouse tables
   ├─ .env.example                          every environment variable, aura-style
   ├─ PROMPT.md                             instructions for generating a pipeline like this
   └─ ADAPT.md                              how to point it at your own product
```

**Want to use v2?** Start with [`generic/ADAPT.md`](generic/ADAPT.md).
**Want to build your own version of it?** Use [`generic/PROMPT.md`](generic/PROMPT.md).
**Want the node-by-node detail of v1?** Read [`aura/README.md`](aura/README.md).
**Want to know why any of it looks like this?** Read [the blog post](blog/learning-n8n-agentic-workflows.md).

## The shape

```mermaid
flowchart LR
    subgraph SRC["Sources"]
        direction TB
        S1["🍎 App Store<br/>reviews"]
        S2["🤖 Google Play<br/>reviews"]
        S3["💬 Usersnap<br/>surveys"]
    end

    subgraph N8N["n8n · self-hosted on Cloud Run"]
        direction TB
        P1["fetch + flatten<br/><i>one item per feedback, PII dropped</i>"]
        P2["🤖 LLM classifies<br/><i>1 of 11 fixed themes</i>"]
        P3["validate against allow-list<br/><i>anything invented → N/A</i>"]
        P4["hash a stable id + dedup"]
        P1 --> P2 --> P3 --> P4
    end

    W[("warehouse<br/>APP_STORE_REVIEWS<br/>USERSNAP_FEEDBACK")]

    subgraph OUT["Consumers"]
        direction TB
        C1["📊 theme trends over time"]
        C2["🚀 post-release: did the mix shift?"]
        C3["📝 insight delivery <i>(planned)</i>"]
    end

    S1 --> P1
    S2 --> P1
    S3 --> P1
    P4 --> W
    W --> C1
    W --> C2
    W --> C3

    classDef ai fill:#fdf0e6,stroke:#d97a2b,color:#2e1a05
    class P2 ai
```

Every branch is the same nine steps:

```
Schedule → sign JWT → fetch → flatten to one item per feedback
  → loop → LLM classifies into one of 11 themes → parse + validate against an allow-list
  → build row with a stable hashed id
  → SELECT existing ids → keep only new → If > 0 → insert
```

Note that the v2 canvas has **two triggers, not three** — the Android branch is chained onto the end
of the iOS one. See [`generic/ADAPT.md` §2](generic/ADAPT.md) before you delete or rewire a branch.
v1 has the same quirk; it's step 12 of the Apple pipeline in `aura/README.md`.

**Before running v2 for real, read [`ADAPT.md` §10](generic/ADAPT.md).** Three things in it are the
first-draft version: one LLM call per item rather than ~50 per call, a dedup that no database
constraint enforces (and which is not concurrency-safe), and SQL built by string concatenation —
guarded by UUID validation, but query parameters would be the real fix.

## Three properties worth preserving if you change any of this

- **The LLM's answer is validated in code** against the exact list of category names. Anything it
  invents becomes `N/A` rather than silently entering the data. In v2 that list appears in both the
  prompt and a JS `Set`, and they must match byte for byte.
- **Every run is safe to re-run.** Dedup happens before insert, on a stable id.
- **No personal data is stored.** Reviewer names are hashed into the id and discarded; email
  addresses are deleted from survey items and scrubbed from the retained raw payload.

## What is and isn't in this repo

Everything published here is sanitised. Raw n8n exports are **git-ignored** — an export carries real
app ids, service-account emails, warehouse paths and survey ids. `.gitignore` excludes everything
matching `/*.json` at the repo root, so a freshly exported workflow is untracked by default and only
becomes shareable once it has been deliberately sanitised into `generic/`.

The `generic/` workflows are structural copies of the live ones: same nodes, same connections, same
logic, with app ids, package names, account emails, warehouse paths and survey ids all read from
`$env` (see `generic/.env.example`). Only the product name inside the six LLM prompts is a literal,
because those fields cannot be n8n expressions without breaking on their own JSON braces. They were
checked to contain none of the original identifiers, the 11 category names were verified
byte-identical between every prompt and every validation list, and credential vault ids and
`meta.instanceId` were nulled out.

No secrets are in any of these files. All credentials come from n8n credentials or `$env`.

> **Not verified by execution.** The `generic/` workflows were validated structurally — valid JSON,
> node and connection graphs identical to the originals — but have not been re-imported into a live
> n8n instance since sanitising. Expect to re-link credentials on import.
>
> `aura/aura.json` still carries its source instance's credential vault ids and BigQuery resource
> locators, as its own README explains. Re-link and re-pick those after importing.
