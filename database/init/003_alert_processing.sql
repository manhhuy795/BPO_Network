-- Xử lý mỗi cảnh báo trong một giao dịch PostgreSQL.

CREATE OR REPLACE FUNCTION bpo_severity_rank(value TEXT)
RETURNS INTEGER
LANGUAGE SQL
IMMUTABLE
AS $$
    SELECT CASE lower(COALESCE(value, ''))
        WHEN 'cao' THEN 3
        WHEN 'trung_binh' THEN 2
        WHEN 'thap' THEN 1
        ELSE 0
    END;
$$;

CREATE OR REPLACE FUNCTION bpo_max_severity(left_value TEXT, right_value TEXT)
RETURNS TEXT
LANGUAGE SQL
IMMUTABLE
AS $$
    SELECT CASE
        WHEN bpo_severity_rank(left_value) >= bpo_severity_rank(right_value)
            THEN COALESCE(left_value, 'thap')
        ELSE COALESCE(right_value, 'thap')
    END;
$$;

CREATE OR REPLACE FUNCTION process_bpo_alert(input_data JSONB)
RETURNS TABLE (
    result_status TEXT,
    raw_alert_id BIGINT,
    result_incident_id BIGINT,
    result_incident_key TEXT,
    message TEXT
)
LANGUAGE plpgsql
AS $$
DECLARE
    new_raw_id BIGINT;
    target_incident_id BIGINT;
    target_incident_key TEXT;
    existing_status TEXT;
    existing_severity TEXT;
    event_status TEXT := input_data->>'status';
    alert_name_value TEXT := input_data->>'alert_name';
    fingerprint_value TEXT := input_data->>'fingerprint';
    severity_value TEXT := COALESCE(input_data->>'severity', 'thap');
    provider_value TEXT := NULLIF(lower(input_data->>'provider'), '');
    service_value TEXT := NULLIF(lower(input_data->>'service'), '');
    vlan_value TEXT := NULLIF(input_data->>'vlan', '');
    project_value TEXT := NULLIF(input_data->>'project_name', '');
    instance_value TEXT := NULLIF(input_data->>'instance', '');
    event_time TIMESTAMPTZ := COALESCE(NULLIF(input_data->>'starts_at', '')::TIMESTAMPTZ, CURRENT_TIMESTAMP);
    starts_time TIMESTAMPTZ := NULLIF(input_data->>'starts_at', '')::TIMESTAMPTZ;
    ends_time TIMESTAMPTZ := NULLIF(input_data->>'ends_at', '')::TIMESTAMPTZ;
    received_time TIMESTAMPTZ := COALESCE(NULLIF(input_data->>'received_at', '')::TIMESTAMPTZ, CURRENT_TIMESTAMP);
    title_value TEXT;
    cause_value TEXT;
    scope_value TEXT;
    created_new BOOLEAN := FALSE;
    active_count INTEGER;
    merged RECORD;
BEGIN
    IF event_status NOT IN ('firing', 'resolved')
       OR COALESCE(alert_name_value, '') = ''
       OR COALESCE(fingerprint_value, '') = ''
       OR COALESCE(input_data->>'event_key', '') = '' THEN
        RAISE EXCEPTION 'Dữ liệu cảnh báo đã chuẩn hóa không hợp lệ';
    END IF;

    -- Khóa theo fingerprint giúp hai webhook đồng thời không chèn trùng.
    PERFORM pg_advisory_xact_lock(hashtext(fingerprint_value));

    INSERT INTO raw_alerts (
        event_key, fingerprint, status, alert_name, severity, provider,
        service, vlan, project_name, starts_at, ends_at, received_at, payload
    ) VALUES (
        input_data->>'event_key', fingerprint_value, event_status, alert_name_value,
        severity_value, provider_value, service_value, vlan_value, project_value,
        starts_time, ends_time, received_time, COALESCE(input_data->'payload', '{}'::JSONB)
    )
    ON CONFLICT (event_key) DO NOTHING
    RETURNING id INTO new_raw_id;

    IF new_raw_id IS NULL THEN
        SELECT id INTO new_raw_id
        FROM raw_alerts
        WHERE event_key = input_data->>'event_key';

        RETURN QUERY SELECT
            'duplicate'::TEXT, new_raw_id, NULL::BIGINT, NULL::TEXT,
            'Sự kiện đã tồn tại, không ghi trùng.'::TEXT;
        RETURN;
    END IF;

    IF event_status = 'resolved' THEN
        SELECT ia.incident_id
        INTO target_incident_id
        FROM raw_alerts firing_alert
        JOIN incident_alerts ia ON ia.alert_id = firing_alert.id
        WHERE firing_alert.status = 'firing'
          AND firing_alert.fingerprint = fingerprint_value
          AND firing_alert.starts_at IS NOT DISTINCT FROM starts_time
        ORDER BY firing_alert.received_at DESC
        LIMIT 1;

        IF target_incident_id IS NULL THEN
            RETURN QUERY SELECT
                'resolved'::TEXT, new_raw_id, NULL::BIGINT, NULL::TEXT,
                'Không tìm thấy sự cố đang mở tương ứng; chỉ lưu bản ghi phục hồi.'::TEXT;
            RETURN;
        END IF;

        PERFORM pg_advisory_xact_lock(target_incident_id);
        INSERT INTO incident_alerts (incident_id, alert_id)
        VALUES (target_incident_id, new_raw_id)
        ON CONFLICT DO NOTHING;

        INSERT INTO incident_events (incident_id, event_type, description, event_data)
        VALUES (
            target_incident_id,
            'alert_resolved',
            format('Cảnh báo %s đã phục hồi.', alert_name_value),
            jsonb_build_object('raw_alert_id', new_raw_id, 'fingerprint', fingerprint_value)
        );

        SELECT count(*) INTO active_count
        FROM raw_alerts firing_alert
        JOIN incident_alerts ia ON ia.alert_id = firing_alert.id
        WHERE ia.incident_id = target_incident_id
          AND firing_alert.status = 'firing'
          AND NOT EXISTS (
              SELECT 1
              FROM raw_alerts resolved_alert
              WHERE resolved_alert.status = 'resolved'
                AND resolved_alert.fingerprint = firing_alert.fingerprint
                AND resolved_alert.starts_at IS NOT DISTINCT FROM firing_alert.starts_at
          );

        IF active_count = 0 THEN
            UPDATE incidents
            SET status = 'resolved',
                resolved_at = COALESCE(ends_time, received_time),
                last_seen = GREATEST(last_seen, COALESCE(ends_time, received_time)),
                updated_at = CURRENT_TIMESTAMP
            WHERE id = target_incident_id;

            INSERT INTO incident_events (incident_id, event_type, description, event_data)
            VALUES (
                target_incident_id,
                'resolved',
                'Tất cả cảnh báo thành phần đã phục hồi; sự cố được đóng.',
                jsonb_build_object('resolved_at', COALESCE(ends_time, received_time))
            );
        ELSE
            UPDATE incidents
            SET last_seen = GREATEST(last_seen, COALESCE(ends_time, received_time)),
                updated_at = CURRENT_TIMESTAMP
            WHERE id = target_incident_id;
        END IF;

        SELECT incident_key INTO target_incident_key
        FROM incidents WHERE id = target_incident_id;

        RETURN QUERY SELECT
            'resolved'::TEXT, new_raw_id, target_incident_id, target_incident_key,
            CASE WHEN active_count = 0
                THEN 'Sự cố đã phục hồi.'
                ELSE 'Cảnh báo đã phục hồi nhưng sự cố vẫn còn thành phần đang xảy ra.'
            END::TEXT;
        RETURN;
    END IF;

    IF alert_name_value = 'BothWANDown' THEN
        target_incident_key := 'wan-total';
    ELSIF alert_name_value IN ('FPTDownViettelAvailable', 'CRMDown', 'CFONODown', 'HighLatency', 'HighPacketLoss')
       AND EXISTS (
           SELECT 1 FROM incidents
           WHERE incident_key = 'wan-total'
             AND status = 'open'
             AND last_seen >= event_time - INTERVAL '120 seconds'
             AND first_seen <= event_time + INTERVAL '120 seconds'
       ) THEN
        target_incident_key := 'wan-total';
    ELSIF alert_name_value = 'FPTDownViettelAvailable' THEN
        target_incident_key := 'wan-fpt';
    ELSIF alert_name_value = 'CRMDown' THEN
        target_incident_key := 'service-crm';
    ELSIF alert_name_value = 'CFONODown' THEN
        target_incident_key := 'service-cfono';
    ELSIF alert_name_value IN ('HighLatency', 'HighPacketLoss') THEN
        target_incident_key := 'wan-quality:' || COALESCE(provider_value, 'unknown');
    ELSIF alert_name_value = 'BPOExporterDown' THEN
        target_incident_key := 'monitoring-exporter';
    ELSE
        scope_value := COALESCE(provider_value, service_value, vlan_value, project_value, instance_value, 'global');
        target_incident_key := 'other:'
            || lower(regexp_replace(alert_name_value, '[^a-zA-Z0-9_-]+', '-', 'g'))
            || ':' || lower(regexp_replace(scope_value, '[^a-zA-Z0-9_.:-]+', '-', 'g'));
    END IF;

    CASE target_incident_key
        WHEN 'wan-total' THEN
            title_value := 'Mất toàn bộ kết nối Internet';
            severity_value := 'cao';
            cause_value := 'Có thể mất cả hai đường truyền hoặc xảy ra lỗi tại router, firewall hay thiết bị biên.';
        WHEN 'wan-fpt' THEN
            title_value := 'Đường truyền FPT gặp sự cố';
            severity_value := 'trung_binh';
            cause_value := 'Đường truyền FPT không phản hồi, hệ thống đang sử dụng Viettel dự phòng.';
        WHEN 'service-crm' THEN
            title_value := 'Dịch vụ CRM phía đối tác không truy cập được';
            severity_value := 'trung_binh';
            cause_value := 'Có thể dịch vụ CRM phía đối tác dừng hoặc đường kết nối tới dịch vụ gặp lỗi.';
        WHEN 'service-cfono' THEN
            title_value := 'Dịch vụ CFONO phía đối tác không truy cập được';
            severity_value := 'trung_binh';
            cause_value := 'Có thể dịch vụ CFONO phía đối tác dừng hoặc đường kết nối tới dịch vụ gặp lỗi.';
        WHEN 'monitoring-exporter' THEN
            title_value := 'Không thu thập được dữ liệu từ Ubuntu exporter';
            severity_value := 'cao';
            cause_value := 'Nghi ngờ exporter Ubuntu dừng hoặc Windows không còn truy cập được cổng 9105.';
        ELSE
            IF target_incident_key LIKE 'wan-quality:%' THEN
                title_value := 'Chất lượng đường truyền ' || upper(COALESCE(provider_value, 'không xác định')) || ' suy giảm';
                cause_value := 'Đường truyền có độ trễ cao, mất gói hoặc chất lượng không ổn định.';
            ELSE
                title_value := 'Cảnh báo chưa phân loại: ' || alert_name_value;
                cause_value := 'Chưa có đủ quy tắc để xác định nguyên nhân nghi ngờ.';
            END IF;
    END CASE;

    PERFORM pg_advisory_xact_lock(hashtext(target_incident_key));
    SELECT id, status, severity
    INTO target_incident_id, existing_status, existing_severity
    FROM incidents
    WHERE incident_key = target_incident_key;

    IF target_incident_id IS NULL THEN
        INSERT INTO incidents (
            incident_key, title, severity, status, suspected_cause,
            first_seen, last_seen, resolved_at, alert_count
        ) VALUES (
            target_incident_key, title_value, severity_value, 'open', cause_value,
            event_time, event_time, NULL, 0
        )
        RETURNING id INTO target_incident_id;
        created_new := TRUE;

        INSERT INTO incident_events (incident_id, event_type, description, event_data)
        VALUES (
            target_incident_id, 'opened', 'Tạo sự cố từ cảnh báo đầu tiên.',
            jsonb_build_object('alert_name', alert_name_value, 'raw_alert_id', new_raw_id)
        );
    ELSE
        UPDATE incidents
        SET title = title_value,
            severity = bpo_max_severity(existing_severity, severity_value),
            status = 'open',
            suspected_cause = cause_value,
            first_seen = LEAST(first_seen, event_time),
            last_seen = GREATEST(last_seen, event_time),
            resolved_at = NULL,
            updated_at = CURRENT_TIMESTAMP
        WHERE id = target_incident_id;

        INSERT INTO incident_events (incident_id, event_type, description, event_data)
        VALUES (
            target_incident_id,
            CASE WHEN existing_status = 'resolved' THEN 'reopened' ELSE 'updated' END,
            CASE WHEN existing_status = 'resolved'
                THEN 'Sự cố tái diễn do có cảnh báo mới.'
                ELSE 'Cập nhật sự cố bằng cảnh báo mới.'
            END,
            jsonb_build_object('alert_name', alert_name_value, 'raw_alert_id', new_raw_id)
        );
    END IF;

    INSERT INTO incident_alerts (incident_id, alert_id)
    VALUES (target_incident_id, new_raw_id)
    ON CONFLICT DO NOTHING;

    IF alert_name_value = 'BothWANDown' THEN
        FOR merged IN
            SELECT id, incident_key
            FROM incidents
            WHERE id <> target_incident_id
              AND status = 'open'
              AND (incident_key IN ('wan-fpt', 'service-crm', 'service-cfono')
                   OR incident_key LIKE 'wan-quality:%')
              AND last_seen >= event_time - INTERVAL '120 seconds'
              AND first_seen <= event_time + INTERVAL '120 seconds'
        LOOP
            INSERT INTO incident_alerts (incident_id, alert_id)
            SELECT target_incident_id, alert_id
            FROM incident_alerts
            WHERE incident_id = merged.id
            ON CONFLICT DO NOTHING;

            DELETE FROM incident_alerts WHERE incident_id = merged.id;

            UPDATE incidents
            SET status = 'resolved', resolved_at = event_time,
                last_seen = GREATEST(last_seen, event_time), alert_count = 0,
                updated_at = CURRENT_TIMESTAMP
            WHERE id = merged.id;

            INSERT INTO incident_events (incident_id, event_type, description, event_data)
            VALUES (
                merged.id, 'merged',
                'Sự cố được gộp vào sự cố mất toàn bộ Internet.',
                jsonb_build_object('target_incident_id', target_incident_id, 'target_key', 'wan-total')
            );
        END LOOP;
    END IF;

    UPDATE incidents incident
    SET alert_count = (
            SELECT count(DISTINCT alert.fingerprint)
            FROM incident_alerts link
            JOIN raw_alerts alert ON alert.id = link.alert_id
            WHERE link.incident_id = incident.id
        ),
        updated_at = CURRENT_TIMESTAMP
    WHERE incident.id = target_incident_id;

    RETURN QUERY SELECT
        CASE WHEN created_new THEN 'created' ELSE 'updated' END::TEXT,
        new_raw_id,
        target_incident_id,
        target_incident_key,
        CASE WHEN created_new
            THEN 'Cảnh báo đã được lưu và tạo sự cố.'
            ELSE 'Cảnh báo đã được lưu và cập nhật sự cố.'
        END::TEXT;
END;
$$;
