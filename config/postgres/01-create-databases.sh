#!/bin/sh
set -e

psql -v ON_ERROR_STOP=1 \
  --username "$POSTGRES_USER" \
  --dbname "$POSTGRES_DB" \
  --set contratos_password="$CONTRATOS_DB_PASSWORD" \
  --set flash_sales_password="$FLASH_SALES_DB_PASSWORD" <<'EOSQL'
CREATE ROLE contratos LOGIN PASSWORD :'contratos_password';
CREATE DATABASE contracts_db OWNER contratos;
REVOKE ALL ON DATABASE contracts_db FROM PUBLIC;

CREATE ROLE flash_sales LOGIN PASSWORD :'flash_sales_password';
CREATE DATABASE flash_sales OWNER flash_sales;
REVOKE ALL ON DATABASE flash_sales FROM PUBLIC;
EOSQL
