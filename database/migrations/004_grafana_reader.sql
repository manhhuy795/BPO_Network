-- Tài khoản chỉ đọc dành riêng cho datasource PostgreSQL của Grafana.

SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'grafana_user', :'grafana_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'grafana_user')
\gexec

SELECT format('ALTER ROLE %I WITH LOGIN PASSWORD %L', :'grafana_user', :'grafana_password')
\gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', current_database(), :'grafana_user')
\gexec
SELECT format('GRANT USAGE ON SCHEMA public TO %I', :'grafana_user')
\gexec
SELECT format('GRANT SELECT ON ALL TABLES IN SCHEMA public TO %I', :'grafana_user')
\gexec
SELECT format('ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO %I', :'grafana_user')
\gexec
