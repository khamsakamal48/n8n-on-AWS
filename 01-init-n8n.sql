-- =============================================================================
-- PostgreSQL Init Script — Runs only on first database initialization
-- Ensures n8n database has proper schema, extensions, and permissions
-- =============================================================================

-- Enable useful extensions
CREATE EXTENSION IF NOT EXISTS pg_trgm;       -- Trigram index for text search (workflow names, tags)
CREATE EXTENSION IF NOT EXISTS btree_gin;     -- GIN index support for faster lookups

-- Ensure public schema exists with correct ownership
ALTER SCHEMA public OWNER TO n8n;

-- Grant full privileges on the n8n database
GRANT ALL PRIVILEGES ON DATABASE n8n TO n8n;
GRANT ALL PRIVILEGES ON SCHEMA public TO n8n;

-- Default privileges for future tables/sequences created by n8n
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO n8n;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO n8n;
