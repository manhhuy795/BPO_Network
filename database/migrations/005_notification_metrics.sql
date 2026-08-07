-- Ghi riêng thời điểm GLPI trả kết quả để đo Time to Ticket chính xác.
ALTER TABLE notification_events
    ADD COLUMN IF NOT EXISTS glpi_completed_at TIMESTAMPTZ;

CREATE OR REPLACE FUNCTION bpo_mark_glpi(
    p_notification_id BIGINT,
    p_incident_id BIGINT,
    p_ticket_id BIGINT,
    p_status TEXT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    integration_status TEXT;
BEGIN
    IF p_status NOT IN ('created', 'updated', 'closed', 'failed', 'skipped') THEN
        RAISE EXCEPTION 'Trạng thái GLPI không hợp lệ';
    END IF;
    integration_status := CASE
        WHEN p_status = 'closed' THEN 'closed'
        WHEN p_status = 'failed' THEN 'failed'
        ELSE 'open'
    END;

    INSERT INTO incident_integrations (incident_id, glpi_ticket_id, glpi_status)
    VALUES (p_incident_id, p_ticket_id, integration_status)
    ON CONFLICT (incident_id) DO UPDATE
    SET glpi_ticket_id = COALESCE(EXCLUDED.glpi_ticket_id, incident_integrations.glpi_ticket_id),
        glpi_status = EXCLUDED.glpi_status,
        updated_at = CURRENT_TIMESTAMP;

    UPDATE notification_events
    SET glpi_ticket_id = COALESCE(p_ticket_id, glpi_ticket_id),
        glpi_status = p_status,
        glpi_completed_at = CURRENT_TIMESTAMP,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_notification_id;
END;
$$;
