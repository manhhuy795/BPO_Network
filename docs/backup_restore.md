# Backup và restore thực tế

## Phạm vi và nguồn khôi phục

| Thành phần | Nội dung backup | Nguồn khôi phục |
|---|---|---|
| PostgreSQL | Toàn bộ database `POSTGRES_DB`, gồm dữ liệu nghiệp vụ và schema n8n | `postgres.dump` bằng `pg_dump` custom format |
| GLPI | Toàn bộ MySQL database `MYSQL_DATABASE` | `glpi.sql` bằng `mysqldump` |
| n8n | Tất cả workflow export và trạng thái n8n trong PostgreSQL | `n8n_workflows.json` và `postgres.dump` |
| `N8N_ENCRYPTION_KEY` | Không ghi vào backup hoặc manifest | Kho secret an toàn nằm ngoài repository |
| Prometheus/Alertmanager | Cấu hình và luật | Git: `docker/prometheus`, `docker/alertmanager` |
| Grafana | Dashboard và provisioning | Git: `docker/grafana/dashboards`, `docker/grafana/provisioning` |

Manifest lưu thời điểm tạo, tên ba artifact, Git commit, database, danh sách bảng bắt buộc và SHA-256. Manifest không chứa password hoặc giá trị `N8N_ENCRYPTION_KEY`.

## Tạo backup

Docker Desktop và ba container `bpo-postgres`, `bpo-glpi-db`, `bpo-n8n` phải đang chạy. Từ thư mục gốc repository:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/backup/backup.ps1
```

Mặc định backup nằm ngoài repository tại `%TEMP%\BPO_Network_backups`. Nên chỉ định ổ đĩa mã hóa có quyền truy cập hạn chế:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/backup/backup.ps1 `
  -OutputRoot D:\BPO_Backups
```

Một lần backup tạo:

```text
bpo-backup-<timestamp>-<id>/
├── postgres.dump
├── glpi.sql
├── n8n_workflows.json
└── manifest.json
```

## Test restore an toàn

Lệnh dưới đây tạo một incident nhận diện riêng, backup, restore PostgreSQL và MySQL vào hai database test, kiểm tra schema/record/workflow/ticket rồi luôn cleanup bằng `finally`:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/restore/test_restore.ps1
```

Test không restore đè database chính, không xóa volume và không restart container.

## Khôi phục có kiểm soát

Luôn thử restore vào database mới trước. Ví dụ PostgreSQL:

```powershell
docker cp D:\BPO_Backups\<backup>\postgres.dump bpo-postgres:/tmp/postgres.dump
docker exec bpo-postgres sh -c 'createdb --username="$POSTGRES_USER" bpo_restore_check'
docker exec bpo-postgres sh -c 'pg_restore --username="$POSTGRES_USER" --dbname=bpo_restore_check --exit-on-error --no-owner --no-acl /tmp/postgres.dump'
```

Ví dụ MySQL GLPI:

```powershell
docker cp D:\BPO_Backups\<backup>\glpi.sql bpo-glpi-db:/tmp/glpi.sql
docker exec bpo-glpi-db sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql --user=root --execute="CREATE DATABASE glpi_restore_check CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"'
docker exec bpo-glpi-db sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql --user=root glpi_restore_check < /tmp/glpi.sql'
```

Khôi phục toàn bộ `postgres.dump` cũng khôi phục schema n8n. Trước khi chạy n8n với database đã restore, phải cung cấp đúng `N8N_ENCRYPTION_KEY` cũ. Nếu chỉ cần import workflow JSON trong cửa sổ bảo trì:

```powershell
docker cp D:\BPO_Backups\<backup>\n8n_workflows.json bpo-n8n:/tmp/n8n_workflows.json
docker exec bpo-n8n n8n import:workflow --input=/tmp/n8n_workflows.json
```

Không import đè workflow đang active khi n8n đang phục vụ webhook. Với sự cố thật, dừng nhận webhook, xác minh backup, restore vào database trống, cấu hình lại secret rồi mới khởi động n8n.

## Bảo quản `N8N_ENCRYPTION_KEY`

Lưu giá trị thật trong password manager, secret vault hoặc tệp mã hóa ngoại tuyến và sao lưu ở vị trí khác máy Docker. Không đưa giá trị vào Git, manifest, log, ảnh chụp màn hình hoặc chung thư mục dump. Mất khóa này có thể làm credential n8n trong PostgreSQL không giải mã được sau restore.

## Giới hạn

- Các dump được tạo tuần tự nên không phải snapshot giao dịch đồng thời giữa PostgreSQL và MySQL.
- Backup chứa dữ liệu nhạy cảm nhưng script không tự mã hóa artifact; nơi lưu phải được mã hóa và giới hạn quyền.
- `glpi_data` chứa file/attachment của GLPI không nằm trong phạm vi database của Phase 6.
- Volume `n8n_data` không được copy; cấu hình/workflow quan trọng hiện nằm trong PostgreSQL và Git. Nếu sau này workflow lưu binary/file cục bộ, phải backup volume này riêng.
- Prometheus TSDB, Alertmanager runtime state, Grafana runtime user và dashboard tạo tay trong volume không được backup; cấu hình/dashboard do Git quản lý được khôi phục theo commit trong manifest.
- Workflow export không thay thế `N8N_ENCRYPTION_KEY`; credential mã hóa và trạng thái n8n đầy đủ được khôi phục qua PostgreSQL.
