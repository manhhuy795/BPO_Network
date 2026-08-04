-- Chỉ mục phục vụ tra cứu, gom nhóm và lịch sử sự cố.

CREATE INDEX IF NOT EXISTS idx_raw_alerts_fingerprint
    ON raw_alerts (fingerprint);
CREATE INDEX IF NOT EXISTS idx_raw_alerts_status_received
    ON raw_alerts (status, received_at DESC);
CREATE INDEX IF NOT EXISTS idx_raw_alerts_alert_name
    ON raw_alerts (alert_name);

CREATE INDEX IF NOT EXISTS idx_incidents_status_last_seen
    ON incidents (status, last_seen DESC);
CREATE INDEX IF NOT EXISTS idx_incidents_severity
    ON incidents (severity);

CREATE INDEX IF NOT EXISTS idx_incident_alerts_alert_id
    ON incident_alerts (alert_id);
CREATE INDEX IF NOT EXISTS idx_incident_events_incident_created
    ON incident_events (incident_id, created_at DESC);
