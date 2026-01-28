# Photo Editor DB Schema (PostgreSQL)

This container uses `startup.sh` to start PostgreSQL and writes the canonical connection command into `db_connection.txt`:

- `db_connection.txt` example:
  - `psql postgresql://appuser:dbuser123@localhost:5000/myapp`

## Initialization

After DB startup, `startup.sh` will run:

- `init_schema_and_seed.sh` (unless `SKIP_APP_INIT=1`)

This script is **idempotent** and can be run multiple times.

## Tables

### `users`
Stores application users (authentication identity).

Columns:
- `id` (uuid, PK)
- `email` (text, unique, required)
- `password_hash` (text, required)
- `display_name` (text, optional)
- `created_at`, `updated_at` (timestamptz)

Indexes / constraints:
- `UNIQUE(email)`
- `idx_users_created_at`

### `images`
Stores image metadata and storage references.

Columns:
- `id` (uuid, PK)
- `user_id` (uuid, FK -> users.id, cascade delete)
- `title` (text)
- `original_storage_key` (text, required)
- `original_mime_type` (text)
- `original_width`, `original_height` (int)
- `original_size_bytes` (bigint)
- `current_storage_key` (text) and derived current_* metadata (optional)
- `created_at`, `updated_at` (timestamptz)

Indexes:
- `idx_images_user_created_at (user_id, created_at desc)`
- `idx_images_created_at (created_at desc)`

### `edit_history`
Append-only log of edits performed on an image.

Columns:
- `id` (uuid, PK)
- `image_id` (uuid, FK -> images.id, cascade delete)
- `user_id` (uuid, FK -> users.id, cascade delete)
- `operation` (text, required) e.g. `crop`, `filter`, `brightness`
- `params` (jsonb, required; default `{}`)
- `created_at` (timestamptz)

Indexes:
- `idx_edit_history_image_created_at (image_id, created_at desc)`
- `idx_edit_history_user_created_at (user_id, created_at desc)`
- `idx_edit_history_params_gin` (GIN on `params` for querying JSON)

## Seed strategy

`init_schema_and_seed.sh` inserts:
- a demo user: `demo@photo.app`
- a demo image row with `original_storage_key='seed/demo.jpg'`
- a demo edit_history entry (`operation='seed'`)

All seed inserts are guarded by `ON CONFLICT DO NOTHING` or `NOT EXISTS` checks.
