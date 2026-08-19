$ErrorActionPreference = "Stop"

$ThuMucGoc = Split-Path -Parent $PSScriptRoot
$FileCompose = Join-Path $ThuMucGoc "docker/docker-compose.yml"
$FileMoiTruong = Join-Path $ThuMucGoc ".env"
$ThamSoCompose = @("compose", "--env-file", $FileMoiTruong, "-f", $FileCompose)
$SoLoi = 0

function Lay-Bien([string]$Ten) {
    $Dong = Get-Content $FileMoiTruong | Where-Object { $_ -match "^$Ten=" } | Select-Object -First 1
    if (-not $Dong) { throw "Thieu bien $Ten trong .env." }
    return ($Dong -split '=', 2)[1].Trim()
}

function Psql([string]$Sql) {
    $KetQua = & docker exec -e "PGPASSWORD=$MatKhau" bpo-postgres `
        psql -v ON_ERROR_STOP=1 -U $NguoiDung -d $TenDatabase -Atc $Sql 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Truy van PostgreSQL that bai." }
    return (@($KetQua) -join "`n").Trim()
}

function Psql-MaThoat([string]$Sql) {
    $ErrorActionPreferenceCu = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & docker exec -e "PGPASSWORD=$MatKhau" bpo-postgres `
            psql -v ON_ERROR_STOP=1 -U $NguoiDung -d $TenDatabase -Atc $Sql *> $null
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $ErrorActionPreferenceCu
    }
}

function Chay-Docker([string[]]$ThamSo) {
    $ErrorActionPreferenceCu = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & docker @ThamSo *> $null
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $ErrorActionPreferenceCu
    }
}

function Kiem-Tra([string]$MoTa, [scriptblock]$NoiDung) {
    try {
        if (-not (& $NoiDung)) { throw "Dieu kien kiem tra khong dat." }
        Write-Host "[DAT] $MoTa"
    } catch {
        $script:SoLoi++
        Write-Host "[KHONG DAT] $MoTa - $($_.Exception.Message)"
    }
}

if (-not (Test-Path $FileMoiTruong)) {
    Write-Host "[KHONG DAT] Chua co file .env, ma thoat 2."
    exit 2
}

$TenDatabase = Lay-Bien "POSTGRES_DB"
$NguoiDung = Lay-Bien "POSTGRES_USER"
$MatKhau = Lay-Bien "POSTGRES_PASSWORD"

if ((Chay-Docker ($ThamSoCompose + @("up", "-d", "postgres"))) -ne 0) {
    Write-Host "[KHONG DAT] Khong the khoi dong PostgreSQL."
    exit 2
}

$DuLieuCu = Psql "SELECT (SELECT count(*) FROM raw_alerts) || '|' || (SELECT count(*) FROM incidents);"
if ((Chay-Docker ($ThamSoCompose + @("run", "--rm", "database-init"))) -ne 0) {
    Write-Host "[KHONG DAT] Khong the ap dung migration."
    exit 2
}

Kiem-Tra "Migration giu nguyen du lieu canh bao va su co cu" {
    (Psql "SELECT (SELECT count(*) FROM raw_alerts) || '|' || (SELECT count(*) FROM incidents);") -eq $DuLieuCu
}

Kiem-Tra "Co du ba bang topology" {
    (Psql "SELECT count(*) FROM pg_tables WHERE schemaname='public' AND tablename IN ('topology_nodes','topology_edges','alert_entity_mapping');") -eq "3"
}

Kiem-Tra "Topology phan anh dung 20 node va 20 link Mininet" {
    (Psql "SELECT count(*) || '|' || (SELECT count(*) FROM topology_edges) FROM topology_nodes;") -eq "20|20"
}

Kiem-Tra "Thong tin host, IP va VLAN khop topology hien tai" {
    (Psql "SELECT node_key || '|' || host(ip_address) || '|' || vlan FROM topology_nodes WHERE node_key='pc_it';") -eq "pc_it|10.10.60.10|60"
}

Kiem-Tra "Anh xa alert nhan dung node theo provider va service" {
    $Fpt = Psql "SELECT node_key FROM bpo_map_alert_entity('HighLatency','fpt',NULL);"
    $Crm = Psql "SELECT node_key FROM bpo_map_alert_entity('CRMDown',NULL,'crm');"
    $Fpt -eq "isp_fpt" -and $Crm -eq "srv_crm"
}

Kiem-Tra "Ham parent tra dung parent truc tiep" {
    (Psql "SELECT string_agg(node_key, ',' ORDER BY node_key) FROM bpo_topology_parents('srv_crm');") -eq "s_outside"
}

Kiem-Tra "Ham ancestor tra du chuoi dependency va khong lap" {
    $Ancestor = Psql "SELECT string_agg(node_key, ',' ORDER BY node_key) FROM bpo_topology_ancestors('srv_crm');"
    $Ancestor -eq "isp_fpt,isp_viettel,r1,r_internet,s_outside"
}

Kiem-Tra "Rang buoc chan node, edge va mapping trung" {
    $Node = Psql-MaThoat "INSERT INTO topology_nodes(node_key,display_name,node_type) VALUES ('r1','trung','router');"
    $Edge = Psql-MaThoat "INSERT INTO topology_edges(parent_node_id,child_node_id) SELECT p.id,c.id FROM topology_nodes p,topology_nodes c WHERE p.node_key='r1' AND c.node_key='s_core';"
    $Map = Psql-MaThoat "INSERT INTO alert_entity_mapping(alert_name,provider,service,node_id) SELECT 'BothWANDown',NULL,NULL,id FROM topology_nodes WHERE node_key='r1';"
    $Node -ne 0 -and $Edge -ne 0 -and $Map -ne 0
}

Kiem-Tra "Migration chay lai idempotent va khong sinh du lieu trung" {
    (Chay-Docker ($ThamSoCompose + @("run", "--rm", "database-init"))) -eq 0 -and
        (Psql "SELECT count(*) || '|' || (SELECT count(*) FROM topology_edges) || '|' || (SELECT count(*) FROM alert_entity_mapping) FROM topology_nodes;") -eq "20|20|14" -and
        (Psql "SELECT (SELECT count(*) FROM raw_alerts) || '|' || (SELECT count(*) FROM incidents);") -eq $DuLieuCu
}

if ($SoLoi -gt 0) {
    Write-Host "[KHONG DAT] Phase 7 con $SoLoi loi, ma thoat 1."
    exit 1
}

Write-Host "[DAT] Toan bo 9/9 kiem thu Phase 7 dat, ma thoat 0."
exit 0
