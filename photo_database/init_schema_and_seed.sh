#!/bin/bash
set -euo pipefail

# Initializes schema + seed data for the Photo Editor app.
# Conventions:
# - Uses db_connection.txt as the authoritative connection string.
# - Runs safely multiple times (idempotent DDL / seed).
#
# Usage:
#   ./startup.sh
#   ./init_schema_and_seed.sh

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONN_FILE="${ROOT_DIR}/db_connection.txt"

if [ ! -f "${CONN_FILE}" ]; then
  echo "❌ Missing ${CONN_FILE}. Run ./startup.sh first to create it."
  exit 1
fi

PSQL_CMD="$(cat "${CONN_FILE}")"

echo "ℹ Using connection: ${PSQL_CMD}"

run_sql () {
  local sql="$1"
  # Execute exactly one SQL statement per call (per container rules).
  # -v ON_ERROR_STOP=1 makes psql fail fast.
  ${PSQL_CMD} -v ON_ERROR_STOP=1 -c "${sql}"
}

echo "== Creating extensions =="
run_sql "CREATE EXTENSION IF NOT EXISTS pgcrypto;"

echo "== Creating tables =="

# Users: core identities for authentication. Email unique, password hash stored.
run_sql "CREATE TABLE IF NOT EXISTS users (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), email text NOT NULL, password_hash text NOT NULL, display_name text, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());"
run_sql "ALTER TABLE users DROP CONSTRAINT IF EXISTS users_email_unique;"
run_sql "ALTER TABLE users ADD CONSTRAINT users_email_unique UNIQUE (email);"

# Images: metadata for uploaded images and the latest edited result.
# Storage fields are strings that can point to local paths, S3 keys, Supabase storage paths, etc.
run_sql "CREATE TABLE IF NOT EXISTS images (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE, title text, original_storage_key text NOT NULL, original_mime_type text, original_width integer, original_height integer, original_size_bytes bigint, current_storage_key text, current_mime_type text, current_width integer, current_height integer, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());"

# Edit history: append-only log of edits applied to an image.
# operation: a short identifier like 'crop', 'filter', 'brightness', 'contrast'
# params: JSON payload with operation parameters (e.g., crop rect, filter name, adjustment amounts)
run_sql "CREATE TABLE IF NOT EXISTS edit_history (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), image_id uuid NOT NULL REFERENCES images(id) ON DELETE CASCADE, user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE, operation text NOT NULL, params jsonb NOT NULL DEFAULT '{}'::jsonb, created_at timestamptz NOT NULL DEFAULT now());"

echo "== Creating indexes =="

# users
run_sql "CREATE INDEX IF NOT EXISTS idx_users_created_at ON users(created_at);"

# images
run_sql "CREATE INDEX IF NOT EXISTS idx_images_user_created_at ON images(user_id, created_at DESC);"
run_sql "CREATE INDEX IF NOT EXISTS idx_images_created_at ON images(created_at DESC);"

# edit_history
run_sql "CREATE INDEX IF NOT EXISTS idx_edit_history_image_created_at ON edit_history(image_id, created_at DESC);"
run_sql "CREATE INDEX IF NOT EXISTS idx_edit_history_user_created_at ON edit_history(user_id, created_at DESC);"
run_sql "CREATE INDEX IF NOT EXISTS idx_edit_history_params_gin ON edit_history USING GIN (params);"

echo "== Adding lightweight triggers for updated_at =="

# Keep users.updated_at current on UPDATE
run_sql "CREATE OR REPLACE FUNCTION set_updated_at() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN NEW.updated_at = now(); RETURN NEW; END; $$;"
run_sql "DROP TRIGGER IF EXISTS trg_users_set_updated_at ON users;"
run_sql "CREATE TRIGGER trg_users_set_updated_at BEFORE UPDATE ON users FOR EACH ROW EXECUTE FUNCTION set_updated_at();"

# Keep images.updated_at current on UPDATE
run_sql "DROP TRIGGER IF EXISTS trg_images_set_updated_at ON images;"
run_sql "CREATE TRIGGER trg_images_set_updated_at BEFORE UPDATE ON images FOR EACH ROW EXECUTE FUNCTION set_updated_at();"

echo "== Seeding (idempotent) =="

# Seed strategy:
# - Insert a demo user if it doesn't exist.
# - Insert a demo image row linked to that user if it doesn't exist.
# - Insert one demo edit history row if it doesn't exist.
#
# NOTE: password_hash is a placeholder hash string (backend should manage real hashing).
run_sql "INSERT INTO users (email, password_hash, display_name) VALUES ('demo@photo.app', 'demo_password_hash_replace_in_backend', 'Demo User') ON CONFLICT (email) DO NOTHING;"

run_sql "INSERT INTO images (user_id, title, original_storage_key, original_mime_type, original_width, original_height, original_size_bytes) SELECT u.id, 'Demo Image', 'seed/demo.jpg', 'image/jpeg', 1200, 800, 123456 FROM users u WHERE u.email = 'demo@photo.app' AND NOT EXISTS (SELECT 1 FROM images i WHERE i.original_storage_key = 'seed/demo.jpg');"

run_sql "INSERT INTO edit_history (image_id, user_id, operation, params) SELECT i.id, i.user_id, 'seed', '{\"note\":\"Initial seed edit\"}'::jsonb FROM images i WHERE i.original_storage_key = 'seed/demo.jpg' AND NOT EXISTS (SELECT 1 FROM edit_history eh WHERE eh.operation='seed' AND eh.image_id=i.id);"

echo "✅ Schema + seed complete."
