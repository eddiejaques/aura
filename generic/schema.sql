-- Tables the two generic workflows write into.
-- Written for Snowflake. See ADAPT.md for the BigQuery / Postgres equivalents.
--
-- Column order matters: the "columns" field on each Snowflake insert node in the
-- workflow lists these names in exactly this order. If you add or reorder a column
-- here, update the matching insert node too.

CREATE DATABASE IF NOT EXISTS ANALYTICS;
CREATE SCHEMA   IF NOT EXISTS ANALYTICS.FEEDBACK;

-- ---------------------------------------------------------------------------
-- App store reviews (Apple App Store + Google Play, one table, one platform column)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ANALYTICS.FEEDBACK.APP_STORE_REVIEWS (
    id                VARCHAR(32)   NOT NULL,  -- sha256(review_date|review_id|author)[:32]
    platform          VARCHAR(32)   NOT NULL,  -- 'apple_app_store' | 'google_play'
    review_id         VARCHAR,                 -- the store's own id
    review_title      VARCHAR,                 -- Apple only; NULL for Play
    review_body       VARCHAR,
    original_text     VARCHAR,                 -- Play only: pre-translation text
    rating            NUMBER(2,0),
    review_date       TIMESTAMP_NTZ,
    territory         VARCHAR(8),              -- Apple only
    device            VARCHAR,                 -- Play only
    os_version        VARCHAR,                 -- Play only
    app_version       VARCHAR,                 -- Play only

    -- LLM output, validated in a Code node before it gets here
    sentiment         VARCHAR(16),             -- positive | negative | neutral
    category          VARCHAR(64),             -- one of the 11 clusters, or 'N/A'
    key_issues        VARCHAR,                 -- JSON array, stringified
    urgency           VARCHAR(16),             -- low | medium | high | critical
    summary           VARCHAR,
    response_tone     VARCHAR(32),
    action_required   BOOLEAN,
    customer_emotion  VARCHAR(32),
    device_context    VARCHAR,                 -- Play only

    analyzed_at       TIMESTAMP_NTZ
);

-- The dedup step reads this column on every run, so it is worth an index/clustering key
-- once the table is large.
-- ALTER TABLE ANALYTICS.FEEDBACK.APP_STORE_REVIEWS CLUSTER BY (platform, id);

-- ---------------------------------------------------------------------------
-- Survey / in-app feedback (Usersnap)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ANALYTICS.FEEDBACK.USERSNAP_FEEDBACK (
    project_id        VARCHAR   NOT NULL,      -- survey/project the item came from
    survey_name       VARCHAR,                 -- human label, set in the config Code node
    feedback_id       VARCHAR   NOT NULL,      -- dedup key
    feedback_number   NUMBER,
    public_link       VARCHAR,
    created_at        TIMESTAMP_NTZ,
    updated_at        TIMESTAMP_NTZ,
    status            VARCHAR,
    country           VARCHAR,
    city              VARCHAR,
    browser           VARCHAR,
    os                VARCHAR,
    page_url          VARCHAR,
    app_version       VARCHAR,
    rating            NUMBER,
    feedback_text     VARCHAR,                 -- all free-text answers, newline-joined
    questions         VARCHAR,                 -- JSON: per-question id/label/type/value
    category          VARCHAR(64),             -- one of the 11 clusters, or 'N/A'
    labels            VARCHAR,
    raw_payload       VARCHAR,                 -- original item, email scrubbed
    categorized_at    TIMESTAMP_NTZ
);

-- ALTER TABLE ANALYTICS.FEEDBACK.USERSNAP_FEEDBACK CLUSTER BY (project_id, feedback_id);

-- ---------------------------------------------------------------------------
-- Constraints: read this before you trust the dedup
-- ---------------------------------------------------------------------------
-- The workflows dedup in application code: SELECT the existing keys, filter in a
-- Code node, insert the rest. There is NOTHING in the database stopping a duplicate.
--
-- That is a real race, not a theoretical one. Run the daily job while the backfill is
-- running over the same survey and both will read "this key does not exist yet", both
-- will pass the If node, and both will insert. You get two rows and no error.
--
-- Adding a key helps only on some engines. Be precise about which one you are on:
--
--   Postgres    PRIMARY KEY / UNIQUE are ENFORCED. Add them. The duplicate insert
--               fails loudly instead of succeeding quietly.
--   Snowflake   PRIMARY KEY / UNIQUE are METADATA ONLY and are NOT enforced. Declaring
--               them documents intent and helps the optimiser, but will not stop a
--               single duplicate row. Only NOT NULL is enforced.
--   BigQuery    Same story: PRIMARY KEY is informational and unenforced.
--
-- So on Snowflake and BigQuery the constraint below is documentation, and the actual
-- fix is to stop inserting blindly and use MERGE instead (see ADAPT.md §10).

ALTER TABLE ANALYTICS.FEEDBACK.APP_STORE_REVIEWS
    ADD PRIMARY KEY (id);                    -- enforced on Postgres; advisory on Snowflake/BigQuery

ALTER TABLE ANALYTICS.FEEDBACK.USERSNAP_FEEDBACK
    ADD PRIMARY KEY (feedback_id);           -- ditto

-- The enforced version, for any engine, replacing the SELECT/filter/If/Insert chain:
--
--   MERGE INTO ANALYTICS.FEEDBACK.APP_STORE_REVIEWS t
--   USING (SELECT ? AS id, ? AS platform, ...) s
--      ON t.id = s.id
--   WHEN NOT MATCHED THEN INSERT (...) VALUES (...);
--
-- One statement, atomic, safe under concurrency, and it does not pull every existing
-- key across the wire on every run.

-- ---------------------------------------------------------------------------
-- Note on PII
-- ---------------------------------------------------------------------------
-- Neither table stores an email address or a reviewer name.
--   * The reviewer's nickname is used to build the hash in `id`, then discarded.
--   * `email` is deleted from the Usersnap item AND from the copy kept in
--     `raw_payload` before the row is ever built.
-- If you add columns, keep that property deliberate rather than accidental.
