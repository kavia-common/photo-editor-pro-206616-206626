#!/bin/bash

# Minimal PostgreSQL startup script with full paths
#
# NOTE:
# This container is expected to expose PostgreSQL on the container's `PORT`
# (see .env). Historically this script hard-coded 5000, which caused readiness
# checks to fail when the platform expects port 5001.
DB_NAME="myapp"
DB_USER="appuser"
DB_PASSWORD="dbuser123"

# Prefer platform-provided PORT (readiness checks use this). Allow DB_PORT override.
DB_PORT="${DB_PORT:-${PORT:-5001}}"

DATA_DIR="/var/lib/postgresql/data"
PID_FILE="${DATA_DIR}/postmaster.pid"

echo "Starting PostgreSQL setup on port ${DB_PORT}..."

# Find PostgreSQL version and set paths
PG_VERSION=$(ls /usr/lib/postgresql/ | head -1)
PG_BIN="/usr/lib/postgresql/${PG_VERSION}/bin"

echo "Found PostgreSQL version: ${PG_VERSION}"

stop_existing_postgres_if_any () {
    # If postgres is already running using this data dir, it will have a PID file.
    # We must avoid starting a second postmaster on the same data directory.
    if [ ! -f "${PID_FILE}" ]; then
        return 0
    fi

    local existing_pid
    existing_pid="$(head -n 1 "${PID_FILE}" 2>/dev/null || true)"

    if [ -z "${existing_pid}" ]; then
        echo "⚠ Found ${PID_FILE} but could not read PID. Removing stale PID file."
        sudo rm -f "${PID_FILE}" || true
        return 0
    fi

    if ! ps -p "${existing_pid}" >/dev/null 2>&1; then
        echo "⚠ Found stale PID file for PID ${existing_pid}. Removing ${PID_FILE}."
        sudo rm -f "${PID_FILE}" || true
        return 0
    fi

    # Postgres is running. If it's not already serving on the desired port, restart it.
    if sudo -u postgres "${PG_BIN}/pg_isready" -p "${DB_PORT}" >/dev/null 2>&1; then
        echo "PostgreSQL is already running and accepting connections on port ${DB_PORT}."
        return 0
    fi

    echo "⚠ PostgreSQL is running (PID ${existing_pid}) but not accepting on port ${DB_PORT}."
    echo "   Stopping it so we can restart on port ${DB_PORT}..."

    # Try fast/clean shutdown first.
    if sudo -u postgres "${PG_BIN}/pg_ctl" -D "${DATA_DIR}" -m fast stop >/dev/null 2>&1; then
        echo "✓ Existing PostgreSQL stopped."
    else
        echo "⚠ pg_ctl stop failed; sending SIGTERM to PID ${existing_pid}..."
        sudo kill -TERM "${existing_pid}" >/dev/null 2>&1 || true
        sleep 2
    fi

    # Ensure stale lock removed so new postmaster can start.
    sudo rm -f "${PID_FILE}" >/dev/null 2>&1 || true
}

# If PostgreSQL is already running on the specified port, exit early.
if sudo -u postgres "${PG_BIN}/pg_isready" -p "${DB_PORT}" >/dev/null 2>&1; then
    echo "PostgreSQL is already running on port ${DB_PORT}!"
    echo "Database: ${DB_NAME}"
    echo "User: ${DB_USER}"
    echo "Port: ${DB_PORT}"
    echo ""
    echo "To connect to the database, use:"
    echo "psql -h localhost -U ${DB_USER} -d ${DB_NAME} -p ${DB_PORT}"

    if [ -f "db_connection.txt" ]; then
        echo "Or use: $(cat db_connection.txt)"
    fi

    echo ""
    echo "Script stopped - server already running."
    exit 0
fi

# If another postmaster is running on the same data dir but a different port,
# stop it so we can reliably bind to the platform readiness port.
stop_existing_postgres_if_any

# Initialize PostgreSQL data directory if it doesn't exist
if [ ! -f "${DATA_DIR}/PG_VERSION" ]; then
    echo "Initializing PostgreSQL..."
    sudo -u postgres "${PG_BIN}/initdb" -D "${DATA_DIR}"
fi

# Start PostgreSQL server in background
echo "Starting PostgreSQL server..."
sudo -u postgres "${PG_BIN}/postgres" -D "${DATA_DIR}" -p "${DB_PORT}" &

# Wait for PostgreSQL to start
echo "Waiting for PostgreSQL to start..."
for i in {1..30}; do
    if sudo -u postgres "${PG_BIN}/pg_isready" -p "${DB_PORT}" >/dev/null 2>&1; then
        echo "PostgreSQL is ready!"
        break
    fi
    echo "Waiting... ($i/30)"
    sleep 1
done

# Hard fail if DB never became ready. This prevents writing misleading connection info.
if ! sudo -u postgres "${PG_BIN}/pg_isready" -p "${DB_PORT}" >/dev/null 2>&1; then
    echo "❌ PostgreSQL did not become ready on port ${DB_PORT}."
    echo "   Check for port conflicts or startup errors."
    exit 1
fi

# Create database and user
echo "Setting up database and user..."
sudo -u postgres "${PG_BIN}/createdb" -h localhost -p "${DB_PORT}" "${DB_NAME}" 2>/dev/null || echo "Database might already exist"

# Set up user and permissions with proper schema ownership
sudo -u postgres "${PG_BIN}/psql" -h localhost -p "${DB_PORT}" -d postgres << EOF
-- Create user if doesn't exist
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${DB_USER}') THEN
        CREATE ROLE ${DB_USER} WITH LOGIN PASSWORD '${DB_PASSWORD}';
    END IF;
    ALTER ROLE ${DB_USER} WITH PASSWORD '${DB_PASSWORD}';
END
\$\$;

-- Grant database-level permissions
GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};

-- Connect to the specific database for schema-level permissions
\c ${DB_NAME}

-- For PostgreSQL 15+, we need to handle public schema permissions differently
-- First, grant usage on public schema
GRANT USAGE ON SCHEMA public TO ${DB_USER};

-- Grant CREATE permission on public schema
GRANT CREATE ON SCHEMA public TO ${DB_USER};

-- Make the user owner of all future objects they create in public schema
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TYPES TO ${DB_USER};

-- Alternative: Grant all privileges on schema public to the user
GRANT ALL ON SCHEMA public TO ${DB_USER};

-- Ensure the user can work with any existing objects
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO ${DB_USER};
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO ${DB_USER};
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO ${DB_USER};
EOF

# Additionally, connect to the specific database to ensure permissions
sudo -u postgres ${PG_BIN}/psql -p ${DB_PORT} -d ${DB_NAME} << EOF
-- Double-check permissions are set correctly in the target database
GRANT ALL ON SCHEMA public TO ${DB_USER};
GRANT CREATE ON SCHEMA public TO ${DB_USER};

-- Show current permissions for debugging
\dn+ public
EOF

# Save connection command to a file
echo "psql postgresql://${DB_USER}:${DB_PASSWORD}@localhost:${DB_PORT}/${DB_NAME}" > db_connection.txt
echo "Connection string saved to db_connection.txt"

# Save environment variables to a file
cat > db_visualizer/postgres.env << EOF
export POSTGRES_URL="postgresql://localhost:${DB_PORT}/${DB_NAME}"
export POSTGRES_USER="${DB_USER}"
export POSTGRES_PASSWORD="${DB_PASSWORD}"
export POSTGRES_DB="${DB_NAME}"
export POSTGRES_PORT="${DB_PORT}"
EOF

echo "PostgreSQL setup complete!"
echo "Database: ${DB_NAME}"
echo "User: ${DB_USER}"
echo "Port: ${DB_PORT}"
echo ""

# Optional: initialize application schema + seed data
# (kept separate so startup remains minimal; can be skipped by setting SKIP_APP_INIT=1)
if [ "${SKIP_APP_INIT:-0}" != "1" ] && [ -f "./init_schema_and_seed.sh" ]; then
    echo ""
    echo "Initializing app schema + seed data..."
    bash ./init_schema_and_seed.sh || echo "⚠ App schema/seed init failed (see output above)"
else
    echo ""
    echo "Skipping app schema + seed init (set SKIP_APP_INIT!=1 and ensure init_schema_and_seed.sh exists)."
fi

echo "Environment variables saved to db_visualizer/postgres.env"
echo "To use with Node.js viewer, run: source db_visualizer/postgres.env"

echo "To connect to the database, use one of the following commands:"
echo "psql -h localhost -U ${DB_USER} -d ${DB_NAME} -p ${DB_PORT}"
echo "$(cat db_connection.txt)"
