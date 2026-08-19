\set ON_ERROR_STOP on

DO $$
BEGIN
    IF to_regclass('public.incident_occurrences') IS NULL THEN
        RAISE EXCEPTION 'Thieu bang incident_occurrences Phase 9.';
    END IF;
END;
$$;
CREATE OR REPLACE FUNCTION pg_temp.send_alert(
    p_event_key TEXT,
    p_fingerprint TEXT,
    p_status TEXT,
    p_alert_name TEXT,
    p_starts_at TIMESTAMPTZ,
    p_service TEXT DEFAULT NULL,
    p_ends_at TIMESTAMPTZ DEFAULT NULL
)
RETURNS TABLE (result_status TEXT, incident_id BIGINT)
LANGUAGE SQL
AS $$
    SELECT result_status, result_incident_id
    FROM process_bpo_alert(jsonb_build_object(
        'event_key', p_event_key,
        'fingerprint', p_fingerprint,
        'status', p_status,
        'alert_name', p_alert_name,
        'severity', CASE WHEN p_alert_name = 'BothWANDown' THEN 'cao' ELSE 'trung_binh' END,
        'service', p_service,
        'starts_at', p_starts_at,
        'ends_at', p_ends_at,
        'received_at', COALESCE(p_ends_at, p_starts_at) + INTERVAL '1 second',
        'payload', '{}'::JSONB
    ));
$$;

-- Lan xay ra thu nhat.
SELECT * FROM pg_temp.send_alert(
    'p9-crm-fire-1', 'p9-crm-1', 'firing', 'CRMDown',
    '2036-01-01 00:00:00+00', 'crm'
);
-- Webhook lap khong duoc tao occurrence moi.
SELECT * FROM pg_temp.send_alert(
    'p9-crm-fire-1', 'p9-crm-1', 'firing', 'CRMDown',
    '2036-01-01 00:00:00+00', 'crm'
);
SELECT * FROM pg_temp.send_alert(
    'p9-crm-resolve-1', 'p9-crm-1', 'resolved', 'CRMDown',
    '2036-01-01 00:00:00+00', 'crm', '2036-01-01 00:00:10+00'
);

-- Sau khi resolved, firing moi phai tao occurrence thu hai.
SELECT * FROM pg_temp.send_alert(
    'p9-crm-fire-2a', 'p9-crm-2a', 'firing', 'CRMDown',
    '2036-01-01 01:00:00+00', 'crm'
);
SELECT * FROM pg_temp.send_alert(
    'p9-crm-fire-2b', 'p9-crm-2b', 'firing', 'CRMDown',
    '2036-01-01 01:00:05+00', 'crm'
);
SELECT * FROM pg_temp.send_alert(
    'p9-crm-resolve-2a', 'p9-crm-2a', 'resolved', 'CRMDown',
    '2036-01-01 01:00:00+00', 'crm', '2036-01-01 01:00:20+00'
);

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM incident_occurrences occurrence
        JOIN incidents incident ON incident.id = occurrence.incident_id
        WHERE incident.incident_key = 'service-crm'
          AND occurrence.occurrence_number = 2
          AND occurrence.status = 'open'
    ) THEN
        RAISE EXCEPTION 'Occurrence thu hai dong qua som khi con alert active.';
    END IF;
END;
$$;

SELECT * FROM pg_temp.send_alert(
    'p9-crm-resolve-2b', 'p9-crm-2b', 'resolved', 'CRMDown',
    '2036-01-01 01:00:05+00', 'crm', '2036-01-01 01:00:30+00'
);

-- Khi topology merge service vao WAN, occurrence nguon khong duoc de open.
SELECT * FROM pg_temp.send_alert(
    'p9-cfono-fire', 'p9-cfono', 'firing', 'CFONODown',
    '2036-01-01 02:00:00+00', 'cfono'
);
SELECT * FROM pg_temp.send_alert(
    'p9-wan-fire', 'p9-wan', 'firing', 'BothWANDown',
    '2036-01-01 02:00:01+00'
);

DO $$
DECLARE
    crm_incident_id BIGINT;
    occurrence_count INTEGER;
    mttr NUMERIC;
BEGIN
    SELECT id INTO crm_incident_id FROM incidents WHERE incident_key = 'service-crm';

    IF (SELECT count(*) FROM incidents WHERE incident_key = 'service-crm') <> 1 THEN
        RAISE EXCEPTION 'Mat compatibility: tao nhieu row incidents cho cung incident_key.';
    END IF;

    SELECT count(*), round(avg(duration_seconds), 3)
    INTO occurrence_count, mttr
    FROM incident_occurrences
    WHERE incident_id = crm_incident_id;

    IF occurrence_count <> 2 OR mttr <> 20.000 THEN
        RAISE EXCEPTION 'Sai occurrence/MTTR: count=%, mttr=%', occurrence_count, mttr;
    END IF;

    IF EXISTS (
        SELECT 1 FROM incident_occurrences
        WHERE incident_id = crm_incident_id
          AND (status <> 'resolved' OR ended_at IS NULL OR duration_seconds IS NULL)
    ) THEN
        RAISE EXCEPTION 'Khong truy van duoc start/end/duration tung occurrence.';
    END IF;

    IF (SELECT count(*) FROM raw_alerts WHERE event_key = 'p9-crm-fire-1') <> 1 THEN
        RAISE EXCEPTION 'Duplicate tao them raw event.';
    END IF;

    IF EXISTS (
        SELECT 1 FROM incident_occurrences occurrence
        JOIN incidents incident ON incident.id = occurrence.incident_id
        WHERE incident.incident_key = 'service-cfono' AND occurrence.status = 'open'
    ) THEN
        RAISE EXCEPTION 'Occurrence service bi merge van con open.';
    END IF;

    RAISE NOTICE 'CRM occurrences=%, MTTR=% giay; duplicate khong tao occurrence.',
        occurrence_count, mttr;
END;
$$;
