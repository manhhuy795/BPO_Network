#!/bin/sh
set -eu

# Chạy một n8n tạm để thiết lập chủ sở hữu; n8n chính chỉ khởi động sau khi workflow đã nạp.
n8n start >/tmp/bpo-n8n-bootstrap.log 2>&1 &
server_pid=$!
trap 'kill "$server_pid" 2>/dev/null || true; cat /tmp/bpo-n8n-bootstrap.log 2>/dev/null || true' EXIT

# Tạo tài khoản chủ sở hữu duy nhất khi n8n chưa được thiết lập.
node <<'NODE'
const base = 'http://127.0.0.1:5678';
const env = process.env;

async function main() {
  let settings;
  for (let attempt = 0; attempt < 30; attempt += 1) {
    try {
      const response = await fetch(`${base}/rest/settings`);
      const body = await response.text();
      settings = JSON.parse(body);
      if (settings.data?.userManagement) break;
    } catch {
      // healthz có thể sẵn sàng trước API trong vài giây.
    }
    await new Promise((resolve) => setTimeout(resolve, 1000));
  }
  if (!settings?.data?.userManagement) throw new Error('API thiết lập n8n chưa sẵn sàng.');
  const management = settings.data?.userManagement ?? {};
  if (management.isInstanceOwnerSetUp || management.showSetupOnFirstLoad === false) return;

  const response = await fetch(`${base}/rest/owner/setup`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      email: env.N8N_OWNER_EMAIL,
      firstName: env.N8N_OWNER_FIRST_NAME,
      lastName: env.N8N_OWNER_LAST_NAME,
      password: env.N8N_OWNER_PASSWORD,
    }),
  });
  if (!response.ok) throw new Error(`Không tạo được tài khoản chủ n8n: HTTP ${response.status}`);
}

main().catch((error) => {
  console.error(error.message);
  process.exit(1);
});
NODE

kill "$server_pid"
wait "$server_pid" 2>/dev/null || true
trap - EXIT

# Tệp tạm chứa bí mật chỉ tồn tại trong container khởi tạo.
node <<'NODE'
const fs = require('fs');
const env = process.env;
const credential = [
  {
    id: env.BPO_CREDENTIAL_ID,
    name: 'PostgreSQL nghiệp vụ BPO',
    type: 'postgres',
    data: {
      host: env.DB_POSTGRESDB_HOST,
      port: Number(env.DB_POSTGRESDB_PORT),
      database: env.DB_POSTGRESDB_DATABASE,
      user: env.DB_POSTGRESDB_USER,
      password: env.DB_POSTGRESDB_PASSWORD,
      ssl: 'disable',
      maxConnections: 10,
      allowUnauthorizedCerts: false,
    },
  },
  {
    id: env.BPO_GLPI_CREDENTIAL_ID,
    name: 'GLPI API nội bộ BPO',
    type: 'httpBasicAuth',
    data: { user: env.GLPI_API_USER, password: env.GLPI_API_PASSWORD },
  },
  {
    id: env.BPO_SMTP_CREDENTIAL_ID,
    name: 'SMTP thông báo BPO',
    type: 'smtp',
    data: {
      user: env.SMTP_USER,
      password: env.SMTP_PASSWORD,
      host: env.SMTP_HOST,
      port: Number(env.SMTP_PORT),
      secure: env.SMTP_SECURE === 'true',
      disableStartTls: false,
    },
  },
];
fs.writeFileSync('/tmp/bpo-credentials.json', JSON.stringify(credential));
NODE

n8n import:credentials --input=/tmp/bpo-credentials.json --include=id,name,type,data
active_workflows="$(n8n list:workflow --active=true --onlyId)"
if printf '%s\n' "$active_workflows" | grep -qx "$BPO_WORKFLOW_ID" \
   && printf '%s\n' "$active_workflows" | grep -qx "$BPO_NOTIFICATION_WORKFLOW_ID"; then
    # Không import lại khi n8n chính đang chạy vì registry webhook trong bộ nhớ sẽ bị cũ.
    echo "Hai workflow BPO đã active, giữ nguyên cấu hình hiện có."
else
    n8n import:workflow --input=/bootstrap/workflows/bpo_alert_correlation.json
    n8n import:workflow --input=/bootstrap/workflows/bpo_notification_ticket.json
    n8n publish:workflow --id="$BPO_WORKFLOW_ID"
    n8n publish:workflow --id="$BPO_NOTIFICATION_WORKFLOW_ID"
fi
rm -f /tmp/bpo-credentials.json
echo "Đã nạp và kích hoạt workflow BPO."
