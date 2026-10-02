#!/bin/sh
# Tạo role runtime `learning_engine_app` (quyền tối thiểu) khi khởi tạo volume Postgres lần đầu.
# Role owner `learning_engine_owner` là POSTGRES_USER, sở hữu schema và chạy migration.
# GRANT trên bảng do migration của MAIN-FND-02 trở đi cấp (ALTER DEFAULT PRIVILEGES).
set -eu
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<SQL
CREATE ROLE learning_engine_app LOGIN PASSWORD '${LEARNING_ENGINE_POSTGRES_APP_PASSWORD}';
GRANT CONNECT ON DATABASE ${POSTGRES_DB} TO learning_engine_app;
GRANT USAGE ON SCHEMA public TO learning_engine_app;
ALTER DEFAULT PRIVILEGES FOR ROLE ${POSTGRES_USER} IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO learning_engine_app;
ALTER DEFAULT PRIVILEGES FOR ROLE ${POSTGRES_USER} IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO learning_engine_app;
SQL
