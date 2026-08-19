\set ON_ERROR_STOP on

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'incidents' AND column_name = 'correlation_method'
    ) THEN
        RAISE EXCEPTION 'Thiếu metadata correlation Phase 8.';
    END IF;
END;
$$;

CREATE TEMP TABLE phase8_result (
    event_key TEXT PRIMARY KEY,
    incident_id BIGINT,
    incident_key TEXT,
    result_status TEXT
);

CREATE TEMP TABLE phase8_ground_truth (
    left_event TEXT,
    right_event TEXT,
    should_group BOOLEAN,
    expected_root TEXT
);

CREATE OR REPLACE FUNCTION pg_temp.send_alert(
    p_event_key TEXT,
    p_fingerprint TEXT,
    p_status TEXT,
    p_alert_name TEXT,
    p_starts_at TIMESTAMPTZ,
    p_provider TEXT DEFAULT NULL,
    p_service TEXT DEFAULT NULL,
    p_ends_at TIMESTAMPTZ DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO phase8_result
    SELECT p_event_key, result_incident_id, result_incident_key, result_status
    FROM process_bpo_alert(jsonb_build_object(
        'event_key', p_event_key,
        'fingerprint', p_fingerprint,
        'status', p_status,
        'alert_name', p_alert_name,
        'severity', CASE WHEN p_alert_name = 'BothWANDown' THEN 'cao' ELSE 'trung_binh' END,
        'provider', p_provider,
        'service', p_service,
        'starts_at', p_starts_at,
        'ends_at', p_ends_at,
        'received_at', COALESCE(p_ends_at, p_starts_at) + INTERVAL '1 second',
        'payload', '{}'::JSONB
    ));
END;
$$;

-- Service den truoc root: root den sau van phai gom bang topology.
SELECT pg_temp.send_alert('p8-race-crm', 'p8-race-crm', 'firing', 'CRMDown',
    '2035-01-01 00:00:00+00', NULL, 'crm');
SELECT pg_temp.send_alert('p8-race-wan', 'p8-race-wan', 'firing', 'BothWANDown',
    '2035-01-01 00:00:01+00');
INSERT INTO phase8_ground_truth VALUES ('p8-race-crm', 'p8-race-wan', TRUE, 'r1');

-- Root den truoc service phu thuoc.
SELECT pg_temp.send_alert('p8-wan', 'p8-wan', 'firing', 'BothWANDown',
    '2035-01-01 00:05:00+00');
SELECT pg_temp.send_alert('p8-wan-crm', 'p8-wan-crm', 'firing', 'CRMDown',
    '2035-01-01 00:05:05+00', NULL, 'crm');
INSERT INTO phase8_ground_truth VALUES ('p8-wan', 'p8-wan-crm', TRUE, 'r1');

-- Hai service chi co chung ancestor, khong phai ancestor cua nhau.
SELECT pg_temp.send_alert('p8-crm-independent', 'p8-crm-independent', 'firing', 'CRMDown',
    '2035-01-01 00:10:00+00', NULL, 'crm');
SELECT pg_temp.send_alert('p8-cfono-independent', 'p8-cfono-independent', 'firing', 'CFONODown',
    '2035-01-01 00:10:01+00', NULL, 'cfono');
INSERT INTO phase8_ground_truth VALUES
    ('p8-crm-independent', 'p8-cfono-independent', FALSE, NULL);

-- Incident tai su dung phai xoa metadata correlation cu khi alert moi doc lap.
UPDATE incidents
SET correlation_method = 'time_window+alert_mapping+topology_dependency',
    evidence = '{"root_node":"r1","dependent_node":"srv_crm"}'::JSONB
WHERE id = (
    SELECT link.incident_id FROM raw_alerts alert
    JOIN incident_alerts link ON link.alert_id = alert.id
    WHERE alert.event_key = 'p8-crm-independent'
);
SELECT pg_temp.send_alert('p8-crm-independent-repeat', 'p8-crm-independent-repeat',
    'firing', 'CRMDown', '2035-01-01 00:10:02+00', NULL, 'crm');

-- Alert khong mapping phai fallback tach biet du xay ra gan nhau.
SELECT pg_temp.send_alert('p8-unmapped-a', 'p8-unmapped-a', 'firing', 'Phase8UnknownA',
    '2035-01-01 00:15:00+00');
SELECT pg_temp.send_alert('p8-unmapped-b', 'p8-unmapped-b', 'firing', 'Phase8UnknownB',
    '2035-01-01 00:15:01+00');
INSERT INTO phase8_ground_truth VALUES ('p8-unmapped-a', 'p8-unmapped-b', FALSE, NULL);

-- Event key lap lai phai tra duplicate va khong tao row thu hai.
SELECT pg_temp.send_alert('p8-duplicate', 'p8-duplicate', 'firing', 'CRMDown',
    '2035-01-01 00:20:00+00', NULL, 'crm');
INSERT INTO phase8_result
SELECT 'p8-duplicate-second', result_incident_id, result_incident_key, result_status
FROM process_bpo_alert(jsonb_build_object(
    'event_key', 'p8-duplicate', 'fingerprint', 'p8-duplicate', 'status', 'firing',
    'alert_name', 'CRMDown', 'severity', 'trung_binh', 'service', 'crm',
    'starts_at', '2035-01-01T00:20:00Z', 'received_at', '2035-01-01T00:20:01Z',
    'payload', '{}'::JSONB
));

-- Firing/resolved phai lien ket cung incident va dong khi het alert active.
SELECT pg_temp.send_alert('p8-resolve-fire', 'p8-resolve', 'firing', 'Phase8Resolve',
    '2035-01-01 00:25:00+00');
SELECT pg_temp.send_alert('p8-resolve-done', 'p8-resolve', 'resolved', 'Phase8Resolve',
    '2035-01-01 00:25:00+00', NULL, NULL, '2035-01-01 00:25:10+00');

DO $$
DECLARE
    false_grouping_rate NUMERIC;
    missed_grouping_rate NUMERIC;
    root_cause_accuracy NUMERIC;
BEGIN
    IF EXISTS (
        SELECT 1
        FROM phase8_ground_truth truth
        JOIN raw_alerts left_alert ON left_alert.event_key = truth.left_event
        JOIN incident_alerts left_link ON left_link.alert_id = left_alert.id
        JOIN raw_alerts right_alert ON right_alert.event_key = truth.right_event
        JOIN incident_alerts right_link ON right_link.alert_id = right_alert.id
        WHERE (left_link.incident_id = right_link.incident_id) IS DISTINCT FROM truth.should_group
    ) THEN
        RAISE EXCEPTION 'Ket qua grouping khong khop ground truth.';
    END IF;

    IF (SELECT result_status FROM phase8_result WHERE event_key = 'p8-duplicate-second') <> 'duplicate'
       OR (SELECT count(*) FROM raw_alerts WHERE event_key = 'p8-duplicate') <> 1 THEN
        RAISE EXCEPTION 'Duplicate/idempotency khong dung.';
    END IF;

    IF (SELECT incident_id FROM phase8_result WHERE event_key = 'p8-resolve-fire') <>
       (SELECT incident_id FROM phase8_result WHERE event_key = 'p8-resolve-done')
       OR NOT EXISTS (
           SELECT 1 FROM incidents incident
           JOIN phase8_result result ON result.incident_id = incident.id
           WHERE result.event_key = 'p8-resolve-done' AND incident.status = 'resolved'
       ) THEN
        RAISE EXCEPTION 'Firing/resolved khong dung.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM incidents incident
        JOIN phase8_result result ON result.incident_id = incident.id
        WHERE result.event_key = 'p8-wan-crm'
          AND incident.correlation_method = 'time_window+alert_mapping+topology_dependency'
          AND incident.candidate_root_cause = 'r1'
          AND incident.correlation_window_seconds = 120
          AND incident.evidence @> '{"root_node":"r1","dependent_node":"srv_crm"}'::JSONB
    ) THEN
        RAISE EXCEPTION 'Thieu metadata/evidence correlation topology.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM incidents incident
        JOIN phase8_result result ON result.incident_id = incident.id
        WHERE result.event_key = 'p8-unmapped-a'
          AND incident.correlation_method = 'safe_fallback'
          AND incident.candidate_root_cause IS NULL
    ) THEN
        RAISE EXCEPTION 'Fallback cho alert khong mapping khong an toan.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM incidents incident
        JOIN raw_alerts alert ON alert.event_key = 'p8-crm-independent'
        JOIN incident_alerts link ON link.alert_id = alert.id AND link.incident_id = incident.id
        WHERE incident.correlation_method = 'alert_mapping'
          AND incident.candidate_root_cause = 'srv_crm'
    ) THEN
        RAISE EXCEPTION 'Incident service doc lap bi gan sai topology dependency.';
    END IF;

    WITH measured AS (
        SELECT truth.*,
               left_link.incident_id = right_link.incident_id AS grouped,
               incident.candidate_root_cause
        FROM phase8_ground_truth truth
        JOIN raw_alerts left_alert ON left_alert.event_key = truth.left_event
        JOIN incident_alerts left_link ON left_link.alert_id = left_alert.id
        JOIN raw_alerts right_alert ON right_alert.event_key = truth.right_event
        JOIN incident_alerts right_link ON right_link.alert_id = right_alert.id
        LEFT JOIN incidents incident ON incident.id = left_link.incident_id
    )
    SELECT
        COALESCE(count(*) FILTER (WHERE NOT should_group AND grouped)::NUMERIC /
                 NULLIF(count(*) FILTER (WHERE grouped), 0), 0),
        COALESCE(count(*) FILTER (WHERE should_group AND NOT grouped)::NUMERIC /
                 NULLIF(count(*) FILTER (WHERE should_group), 0), 0),
        COALESCE(count(*) FILTER (WHERE expected_root IS NOT NULL AND candidate_root_cause = expected_root)::NUMERIC /
                 NULLIF(count(*) FILTER (WHERE expected_root IS NOT NULL), 0), 0)
    INTO false_grouping_rate, missed_grouping_rate, root_cause_accuracy
    FROM measured;

    IF false_grouping_rate <> 0 OR missed_grouping_rate <> 0 OR root_cause_accuracy <> 1 THEN
        RAISE EXCEPTION 'Metric ground truth sai: FGR=%, MGR=%, RCA=%',
            false_grouping_rate, missed_grouping_rate, root_cause_accuracy;
    END IF;

    RAISE NOTICE 'Ground truth: False Grouping Rate=%, Missed Grouping Rate=%, Root Cause Accuracy=%',
        false_grouping_rate, missed_grouping_rate, root_cause_accuracy;
END;
$$;
