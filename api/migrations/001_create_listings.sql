CREATE TABLE IF NOT EXISTS listings (
  id           SERIAL PRIMARY KEY,
  title        TEXT        NOT NULL,
  city         TEXT        NOT NULL,
  listing_type TEXT        NOT NULL,
  price_ngn    BIGINT      NOT NULL,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
