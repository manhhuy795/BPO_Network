-- Outbox thông báo và liên kết duy nhất giữa incident BPO với phiếu GLPI.

CREATE TABLE IF NOT EXISTS incident_integrations (
    incident_id BIGINT PRIMARY KEY REFERENCES incidents(id) ON DELETE CASCADE,
    glpi_ticket_id BIGINT UNIQUE,
    glpi_status TEXT NOT NULL DEFAULT 'pending'
        CHECK (glpi_status IN ('pending', 'open', 'closed', 'failed')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS notification_events (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    notification_key TEXT NOT NULL UNIQUE,
    incident_id BIGINT NOT NULL REFERENCES incidents(id) ON DELETE CASCADE,
    raw_alert_id BIGINT NOT NULL REFERENCES raw_alerts(id) ON DELETE CASCADE,
    event_type TEXT NOT NULL
        CHECK (event_type IN ('created', 'severity_increased', 'important_update', 'resolved')),
    email_status TEXT NOT NULL DEFAULT 'pending'
        CHECK (email_status IN ('pending', 'logged', 'sent', 'failed', 'skipped')),
    email_subject TEXT NOT NULL,
    email_body TEXT NOT NULL,
    glpi_status TEXT NOT NULL DEFAULT 'pending'
        CHECK (glpi_status IN ('pending', 'created', 'updated', 'closed', 'failed', 'skipped')),
    glpi_ticket_id BIGINT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_notification_events_incident_created
    ON notification_events (incident_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_notification_events_delivery_status
    ON notification_events (email_status, glpi_status, created_at DESC);

CREATE OR REPLACE FUNCTION bpo_prepare_notification(
    p_raw_alert_id BIGINT,
    p_result_status TEXT,
    p_incident_id BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    alert_row raw_alerts%ROWTYPE;
    incident_row incidents%ROWTYPE;
    integration_row incident_integrations%ROWTYPE;
    notification_row notification_events%ROWTYPE;
    event_type_value TEXT;
    related_alerts_value TEXT;
    severity_text TEXT;
    status_text TEXT;
    suggested_action TEXT;
    subject_value TEXT;
    body_value TEXT;
    prior_severity_rank INTEGER := 0;
    glpi_action_value TEXT := 'skip';
    should_notify BOOLEAN := FALSE;
BEGIN
    IF p_result_status = 'duplicate' OR p_raw_alert_id IS NULL OR p_incident_id IS NULL THEN
        RETURN jsonb_build_object(
            'should_notify', FALSE,
            'send_email', FALSE,
            'sync_glpi', FALSE,
            'result_status', p_result_status
        );
    END IF;

    SELECT * INTO alert_row FROM raw_alerts WHERE id = p_raw_alert_id;
    SELECT * INTO incident_row FROM incidents WHERE id = p_incident_id;
    IF alert_row.id IS NULL OR incident_row.id IS NULL THEN
        RAISE EXCEPTION 'Không tìm thấy raw alert hoặc incident để chuẩn bị thông báo';
    END IF;

    SELECT * INTO integration_row
    FROM incident_integrations WHERE incident_id = incident_row.id;

    SELECT COALESCE(max(bpo_severity_rank(other_alert.severity)), 0)
    INTO prior_severity_rank
    FROM incident_alerts link
    JOIN raw_alerts other_alert ON other_alert.id = link.alert_id
    WHERE link.incident_id = incident_row.id
      AND other_alert.id <> alert_row.id;

    IF p_result_status = 'created'
       OR (integration_row.incident_id IS NULL AND incident_row.status = 'open') THEN
        event_type_value := 'created';
    ELSIF p_result_status = 'resolved' AND incident_row.status = 'resolved' THEN
        event_type_value := 'resolved';
    ELSIF p_result_status = 'updated'
          AND bpo_severity_rank(incident_row.severity) > prior_severity_rank THEN
        event_type_value := 'severity_increased';
    ELSIF p_result_status = 'updated'
          AND (
              alert_row.alert_name = 'BothWANDown'
              OR EXISTS (
                  SELECT 1 FROM incident_events event
                  WHERE event.incident_id = incident_row.id
                    AND event.event_type = 'reopened'
                    AND event.event_data->>'raw_alert_id' = alert_row.id::TEXT
              )
          ) THEN
        event_type_value := 'important_update';
    END IF;

    IF event_type_value IS NULL THEN
        RETURN jsonb_build_object(
            'should_notify', FALSE,
            'send_email', FALSE,
            'sync_glpi', FALSE,
            'result_status', p_result_status,
            'incident_id', incident_row.id,
            'incident_key', incident_row.incident_key
        );
    END IF;

    SELECT string_agg(DISTINCT linked_alert.alert_name, ', ' ORDER BY linked_alert.alert_name)
    INTO related_alerts_value
    FROM incident_alerts link
    JOIN raw_alerts linked_alert ON linked_alert.id = link.alert_id
    WHERE link.incident_id = incident_row.id;

    severity_text := CASE incident_row.severity
        WHEN 'cao' THEN 'CAO'
        WHEN 'trung_binh' THEN 'TRUNG BÌNH'
        ELSE 'THẤP'
    END;
    status_text := CASE incident_row.status
        WHEN 'resolved' THEN 'PHỤC HỒI'
        ELSE 'MỞ'
    END;
    suggested_action := CASE
        WHEN incident_row.incident_key = 'wan-total'
            THEN 'Kiểm tra router, firewall, thiết bị biên và liên hệ cả hai nhà mạng.'
        WHEN incident_row.incident_key = 'wan-fpt'
            THEN 'Kiểm tra gateway FPT, xác nhận lưu lượng đã chuyển sang Viettel và liên hệ FPT.'
        WHEN incident_row.incident_key LIKE 'service-%'
            THEN 'Kiểm tra truy cập từ nhiều máy, sau đó liên hệ đối tác dịch vụ nếu lỗi còn tồn tại.'
        WHEN incident_row.incident_key = 'monitoring-exporter'
            THEN 'Kiểm tra Ubuntu VM, tiến trình exporter, cổng 9105 và kết nối VMware NAT.'
        WHEN incident_row.incident_key LIKE 'wan-quality:%'
            THEN 'Theo dõi độ trễ, mất gói và thực hiện kiểm tra chất lượng với nhà mạng liên quan.'
        ELSE 'Kiểm tra các cảnh báo liên quan và xác minh phạm vi ảnh hưởng trước khi xử lý.'
    END;

    subject_value := format('[BPO][%s][%s] %s', severity_text, status_text, incident_row.title);
    body_value := format(
        E'Mã sự cố: BPO-%s\nTiêu đề: %s\nMức độ: %s\nTrạng thái: %s\nThời gian bắt đầu: %s\nCảnh báo liên quan: %s\nNguyên nhân nghi ngờ: %s\nĐường WAN đang sử dụng: {{WAN_ACTIVE}}\nHướng xử lý đề xuất: %s',
        incident_row.id,
        incident_row.title,
        severity_text,
        status_text,
        to_char(incident_row.first_seen AT TIME ZONE 'Asia/Ho_Chi_Minh', 'YYYY-MM-DD HH24:MI:SS'),
        COALESCE(related_alerts_value, alert_row.alert_name),
        COALESCE(incident_row.suspected_cause, 'Chưa có đủ dữ liệu để xác định.'),
        suggested_action
    );

    INSERT INTO notification_events (
        notification_key, incident_id, raw_alert_id, event_type,
        email_subject, email_body
    ) VALUES (
        alert_row.event_key || '|notification|' || event_type_value,
        incident_row.id, alert_row.id, event_type_value,
        subject_value, body_value
    )
    ON CONFLICT (notification_key) DO UPDATE
        SET updated_at = notification_events.updated_at
    RETURNING * INTO notification_row;

    IF integration_row.incident_id IS NULL AND event_type_value <> 'resolved' THEN
        INSERT INTO incident_integrations (incident_id)
        VALUES (incident_row.id)
        ON CONFLICT (incident_id) DO NOTHING;
        SELECT * INTO integration_row
        FROM incident_integrations WHERE incident_id = incident_row.id;
    END IF;

    glpi_action_value := CASE
        WHEN event_type_value = 'resolved' AND integration_row.glpi_ticket_id IS NULL THEN 'skip'
        WHEN event_type_value = 'resolved' AND integration_row.glpi_ticket_id IS NOT NULL THEN 'close'
        WHEN integration_row.glpi_ticket_id IS NULL
             AND (event_type_value = 'created' OR integration_row.glpi_status = 'failed') THEN 'create'
        WHEN integration_row.glpi_ticket_id IS NOT NULL THEN 'update'
        ELSE 'skip'
    END;
    should_notify := notification_row.email_status IN ('pending', 'failed')
        OR (glpi_action_value <> 'skip' AND notification_row.glpi_status IN ('pending', 'failed'));

    RETURN jsonb_build_object(
        'should_notify', should_notify,
        'send_email', notification_row.email_status IN ('pending', 'failed'),
        'sync_glpi', glpi_action_value <> 'skip' AND notification_row.glpi_status IN ('pending', 'failed'),
        'notification_id', notification_row.id,
        'event_type', event_type_value,
        'result_status', p_result_status,
        'incident_id', incident_row.id,
        'incident_key', incident_row.incident_key,
        'incident_title', incident_row.title,
        'incident_severity', incident_row.severity,
        'incident_status', incident_row.status,
        'incident_first_seen', incident_row.first_seen,
        'incident_resolved_at', incident_row.resolved_at,
        'incident_alert_count', incident_row.alert_count,
        'suspected_cause', incident_row.suspected_cause,
        'related_alerts', COALESCE(related_alerts_value, alert_row.alert_name),
        'email_subject', subject_value,
        'email_body', body_value,
        'suggested_action', suggested_action,
        'glpi_action', glpi_action_value,
        'glpi_ticket_id', integration_row.glpi_ticket_id,
        'glpi_priority', CASE incident_row.severity WHEN 'cao' THEN 5 WHEN 'trung_binh' THEN 3 ELSE 2 END
    );
END;
$$;

CREATE OR REPLACE FUNCTION bpo_mark_email(p_notification_id BIGINT, p_status TEXT)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_status NOT IN ('logged', 'sent', 'failed', 'skipped') THEN
        RAISE EXCEPTION 'Trạng thái email không hợp lệ';
    END IF;
    UPDATE notification_events
    SET email_status = p_status, updated_at = CURRENT_TIMESTAMP
    WHERE id = p_notification_id;
END;
$$;

CREATE OR REPLACE FUNCTION bpo_mark_email_content(
    p_notification_id BIGINT,
    p_status TEXT,
    p_email_body TEXT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM bpo_mark_email(p_notification_id, p_status);
    UPDATE notification_events
    SET email_body = COALESCE(p_email_body, email_body),
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_notification_id;
END;
$$;

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
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_notification_id;
END;
$$;
