-- Correlation dua tren cua so thoi gian, alert mapping va quan he ancestor.

ALTER TABLE incidents
    ADD COLUMN IF NOT EXISTS topology_node_id BIGINT,
    ADD COLUMN IF NOT EXISTS correlation_method TEXT NOT NULL DEFAULT 'legacy',
    ADD COLUMN IF NOT EXISTS candidate_root_cause TEXT,
    ADD COLUMN IF NOT EXISTS correlation_window_seconds INTEGER NOT NULL DEFAULT 120,
    ADD COLUMN IF NOT EXISTS evidence JSONB NOT NULL DEFAULT '{}'::JSONB;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'incidents_topology_node_fk'
    ) THEN
        ALTER TABLE incidents
            ADD CONSTRAINT incidents_topology_node_fk
            FOREIGN KEY (topology_node_id) REFERENCES topology_nodes(id) ON DELETE SET NULL;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'incidents_correlation_window_positive'
    ) THEN
        ALTER TABLE incidents
            ADD CONSTRAINT incidents_correlation_window_positive
            CHECK (correlation_window_seconds > 0);
    END IF;
END;
$$;

CREATE INDEX IF NOT EXISTS idx_incidents_topology_open
    ON incidents (topology_node_id, status, last_seen DESC);

UPDATE incidents incident
SET topology_node_id = node.id,
    candidate_root_cause = COALESCE(incident.candidate_root_cause, node.node_key),
    evidence = incident.evidence || jsonb_build_object('migration_mapping', node.node_key)
FROM topology_nodes node
WHERE incident.topology_node_id IS NULL
  AND node.node_key = CASE
      WHEN incident.incident_key = 'wan-total' THEN 'r1'
      WHEN incident.incident_key = 'wan-fpt' THEN 'isp_fpt'
      WHEN incident.incident_key = 'service-crm' THEN 'srv_crm'
      WHEN incident.incident_key = 'service-cfono' THEN 'srv_cfono'
      WHEN incident.incident_key = 'wan-quality:fpt' THEN 'isp_fpt'
      WHEN incident.incident_key = 'wan-quality:viettel' THEN 'isp_viettel'
  END;

CREATE OR REPLACE FUNCTION bpo_topology_is_ancestor(
    p_ancestor_id BIGINT,
    p_descendant_id BIGINT
)
RETURNS BOOLEAN
LANGUAGE SQL
STABLE
AS $$
    WITH RECURSIVE parent(node_id, path) AS (
        SELECT p_descendant_id, ARRAY[p_descendant_id]
        UNION ALL
        SELECT edge.parent_node_id, parent.path || edge.parent_node_id
        FROM parent
        JOIN topology_edges edge ON edge.child_node_id = parent.node_id
        WHERE NOT edge.parent_node_id = ANY(parent.path)
    )
    SELECT COALESCE(bool_or(node_id = p_ancestor_id), FALSE) FROM parent;
$$;

-- Giu ham cu lam buoc chuan hoa/ghi raw; wrapper ben duoi chi thay routing correlation.
DO $$
BEGIN
    IF to_regprocedure('process_bpo_alert_legacy(jsonb)') IS NULL THEN
        ALTER FUNCTION process_bpo_alert(JSONB) RENAME TO process_bpo_alert_legacy;
    END IF;
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
    legacy_result RECORD;
    alert_node RECORD;
    candidate RECORD;
    dependent RECORD;
    source_incident_id BIGINT;
    target_incident_id BIGINT;
    target_incident_key TEXT;
    event_time TIMESTAMPTZ := COALESCE(
        NULLIF(input_data->>'starts_at', '')::TIMESTAMPTZ,
        CURRENT_TIMESTAMP
    );
    window_seconds CONSTANT INTEGER := 120;
    window_interval INTERVAL := make_interval(secs => window_seconds);
    active_count INTEGER;
    dependency_found BOOLEAN := FALSE;
BEGIN
    -- ponytail: mot khoa toan cuc phu hop lab; doi sang khoa theo subgraph neu throughput lon.
    IF input_data->>'status' = 'firing' THEN
        PERFORM pg_advisory_xact_lock(hashtext('bpo-topology-correlation'));
    END IF;

    SELECT * INTO legacy_result FROM process_bpo_alert_legacy(input_data);

    IF legacy_result.result_status IN ('duplicate', 'resolved')
       OR legacy_result.result_incident_id IS NULL THEN
        RETURN QUERY SELECT
            legacy_result.result_status::TEXT,
            legacy_result.raw_alert_id::BIGINT,
            legacy_result.result_incident_id::BIGINT,
            legacy_result.result_incident_key::TEXT,
            legacy_result.message::TEXT;
        RETURN;
    END IF;

    source_incident_id := legacy_result.result_incident_id;
    target_incident_id := source_incident_id;
    target_incident_key := legacy_result.result_incident_key;

    SELECT node.id, node.node_key, node.display_name, node.node_type
    INTO alert_node
    FROM alert_entity_mapping mapping
    JOIN topology_nodes node ON node.id = mapping.node_id
    WHERE mapping.alert_name = input_data->>'alert_name'
      AND (mapping.provider IS NULL OR mapping.provider = NULLIF(lower(input_data->>'provider'), ''))
      AND (mapping.service IS NULL OR mapping.service = NULLIF(lower(input_data->>'service'), ''))
    ORDER BY
        (mapping.provider IS NOT NULL)::INTEGER +
        (mapping.service IS NOT NULL)::INTEGER DESC
    LIMIT 1;

    IF alert_node.id IS NULL THEN
        UPDATE incidents
        SET correlation_method = 'safe_fallback',
            candidate_root_cause = NULL,
            correlation_window_seconds = window_seconds,
            evidence = jsonb_build_object(
                'mapping_found', FALSE,
                'alert_name', input_data->>'alert_name'
            ),
            updated_at = CURRENT_TIMESTAMP
        WHERE id = target_incident_id;

        RETURN QUERY SELECT
            legacy_result.result_status::TEXT,
            legacy_result.raw_alert_id::BIGINT,
            target_incident_id,
            target_incident_key,
            'Canh bao khong co mapping; da dung fallback an toan.'::TEXT;
        RETURN;
    END IF;

    UPDATE incidents
    SET topology_node_id = COALESCE(topology_node_id, alert_node.id),
        correlation_method = 'alert_mapping',
        candidate_root_cause = COALESCE(candidate_root_cause, alert_node.node_key),
        correlation_window_seconds = window_seconds,
        evidence = jsonb_build_object(
            'mapping_found', TRUE,
            'alert_node', alert_node.node_key
        ),
        updated_at = CURRENT_TIMESTAMP
    WHERE id = target_incident_id;

    -- Neu mot root dang mo la ancestor cua alert moi, dua alert vao root do.
    SELECT incident.id, incident.incident_key, incident.topology_node_id,
           node.node_key AS root_node
    INTO candidate
    FROM incidents incident
    JOIN topology_nodes node ON node.id = incident.topology_node_id
    WHERE incident.status = 'open'
      AND incident.last_seen >= event_time - window_interval
      AND incident.first_seen <= event_time + window_interval
      AND bpo_topology_is_ancestor(incident.topology_node_id, alert_node.id)
    ORDER BY bpo_severity_rank(incident.severity) DESC,
             (incident.id = target_incident_id) DESC,
             incident.id
    LIMIT 1;

    IF candidate.id IS NOT NULL THEN
        target_incident_id := candidate.id;
        target_incident_key := candidate.incident_key;

        IF source_incident_id <> target_incident_id THEN
            INSERT INTO incident_alerts (incident_id, alert_id)
            VALUES (target_incident_id, legacy_result.raw_alert_id)
            ON CONFLICT DO NOTHING;
            DELETE FROM incident_alerts
            WHERE incident_id = source_incident_id
              AND alert_id = legacy_result.raw_alert_id;

            SELECT count(*) INTO active_count
            FROM raw_alerts firing_alert
            JOIN incident_alerts link ON link.alert_id = firing_alert.id
            WHERE link.incident_id = source_incident_id
              AND firing_alert.status = 'firing'
              AND NOT EXISTS (
                  SELECT 1 FROM raw_alerts resolved_alert
                  WHERE resolved_alert.status = 'resolved'
                    AND resolved_alert.fingerprint = firing_alert.fingerprint
                    AND resolved_alert.starts_at IS NOT DISTINCT FROM firing_alert.starts_at
              );

            UPDATE incidents
            SET status = CASE WHEN active_count = 0 THEN 'resolved' ELSE status END,
                resolved_at = CASE WHEN active_count = 0 THEN event_time ELSE resolved_at END,
                alert_count = (
                    SELECT count(DISTINCT alert.fingerprint)
                    FROM incident_alerts link
                    JOIN raw_alerts alert ON alert.id = link.alert_id
                    WHERE link.incident_id = source_incident_id
                ),
                updated_at = CURRENT_TIMESTAMP
            WHERE id = source_incident_id;
        END IF;

        IF candidate.topology_node_id <> alert_node.id THEN
            UPDATE incidents
            SET correlation_method = 'time_window+alert_mapping+topology_dependency',
                candidate_root_cause = candidate.root_node,
                correlation_window_seconds = window_seconds,
                evidence = jsonb_build_object(
                    'root_node', candidate.root_node,
                    'dependent_node', alert_node.node_key,
                    'window_seconds', window_seconds
                ),
                updated_at = CURRENT_TIMESTAMP
            WHERE id = target_incident_id;
            dependency_found := TRUE;
        ELSIF source_incident_id <> target_incident_id THEN
            UPDATE incidents
            SET correlation_method = 'time_window+alert_mapping',
                candidate_root_cause = candidate.root_node,
                correlation_window_seconds = window_seconds,
                evidence = jsonb_build_object(
                    'root_node', candidate.root_node,
                    'same_entity', TRUE,
                    'window_seconds', window_seconds
                ),
                updated_at = CURRENT_TIMESTAMP
            WHERE id = target_incident_id;
        END IF;
    END IF;

    -- Neu alert moi la root, gom cac incident descendant trong cung cua so.
    FOR dependent IN
        SELECT incident.id, incident.incident_key, incident.topology_node_id,
               node.node_key
        FROM incidents incident
        JOIN topology_nodes node ON node.id = incident.topology_node_id
        WHERE incident.id <> target_incident_id
          AND incident.status = 'open'
          AND incident.last_seen >= event_time - window_interval
          AND incident.first_seen <= event_time + window_interval
          AND bpo_topology_is_ancestor(alert_node.id, incident.topology_node_id)
    LOOP
        INSERT INTO incident_alerts (incident_id, alert_id)
        SELECT target_incident_id, link.alert_id
        FROM incident_alerts link
        JOIN raw_alerts alert ON alert.id = link.alert_id
        WHERE link.incident_id = dependent.id
          AND COALESCE(alert.starts_at, alert.received_at)
              BETWEEN event_time - window_interval AND event_time + window_interval
        ON CONFLICT DO NOTHING;

        DELETE FROM incident_alerts link
        USING raw_alerts alert
        WHERE link.incident_id = dependent.id
          AND alert.id = link.alert_id
          AND COALESCE(alert.starts_at, alert.received_at)
              BETWEEN event_time - window_interval AND event_time + window_interval;

        SELECT count(*) INTO active_count
        FROM raw_alerts firing_alert
        JOIN incident_alerts link ON link.alert_id = firing_alert.id
        WHERE link.incident_id = dependent.id
          AND firing_alert.status = 'firing'
          AND NOT EXISTS (
              SELECT 1 FROM raw_alerts resolved_alert
              WHERE resolved_alert.status = 'resolved'
                AND resolved_alert.fingerprint = firing_alert.fingerprint
                AND resolved_alert.starts_at IS NOT DISTINCT FROM firing_alert.starts_at
          );

        UPDATE incidents
        SET status = CASE WHEN active_count = 0 THEN 'resolved' ELSE status END,
            resolved_at = CASE WHEN active_count = 0 THEN event_time ELSE resolved_at END,
            alert_count = (
                SELECT count(DISTINCT alert.fingerprint)
                FROM incident_alerts link
                JOIN raw_alerts alert ON alert.id = link.alert_id
                WHERE link.incident_id = dependent.id
            ),
            updated_at = CURRENT_TIMESTAMP
        WHERE id = dependent.id;

        INSERT INTO incident_events (incident_id, event_type, description, event_data)
        VALUES (
            dependent.id,
            'merged',
            'Incident duoc gom vao candidate root cause theo topology dependency.',
            jsonb_build_object('target_incident_id', target_incident_id, 'root_node', alert_node.node_key)
        );

        UPDATE incidents
        SET topology_node_id = alert_node.id,
            correlation_method = 'time_window+alert_mapping+topology_dependency',
            candidate_root_cause = alert_node.node_key,
            correlation_window_seconds = window_seconds,
            evidence = jsonb_build_object(
                'root_node', alert_node.node_key,
                'dependent_node', dependent.node_key,
                'window_seconds', window_seconds
            ),
            updated_at = CURRENT_TIMESTAMP
        WHERE id = target_incident_id;
        dependency_found := TRUE;
    END LOOP;

    -- Legacy co the da merge truoc wrapper; suy ra evidence tu alert da lien ket.
    IF NOT dependency_found THEN
        SELECT node.id, node.node_key
        INTO dependent
        FROM incident_alerts link
        JOIN raw_alerts alert ON alert.id = link.alert_id
        JOIN alert_entity_mapping mapping
          ON mapping.alert_name = alert.alert_name
         AND (mapping.provider IS NULL OR mapping.provider = alert.provider)
         AND (mapping.service IS NULL OR mapping.service = alert.service)
        JOIN topology_nodes node ON node.id = mapping.node_id
        JOIN incidents root ON root.id = target_incident_id
        WHERE node.id <> root.topology_node_id
          AND bpo_topology_is_ancestor(root.topology_node_id, node.id)
          AND COALESCE(alert.starts_at, alert.received_at)
              BETWEEN event_time - window_interval AND event_time + window_interval
        ORDER BY alert.received_at DESC
        LIMIT 1;

        IF dependent.id IS NOT NULL THEN
            UPDATE incidents root
            SET correlation_method = 'time_window+alert_mapping+topology_dependency',
                candidate_root_cause = root_node.node_key,
                correlation_window_seconds = window_seconds,
                evidence = jsonb_build_object(
                    'root_node', root_node.node_key,
                    'dependent_node', dependent.node_key,
                    'window_seconds', window_seconds
                ),
                updated_at = CURRENT_TIMESTAMP
            FROM topology_nodes root_node
            WHERE root.id = target_incident_id
              AND root_node.id = root.topology_node_id;
        END IF;
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
        legacy_result.result_status::TEXT,
        legacy_result.raw_alert_id::BIGINT,
        target_incident_id,
        target_incident_key,
        CASE
            WHEN dependency_found THEN 'Da correlation bang time window, alert mapping va topology dependency.'
            ELSE 'Da anh xa alert vao candidate root cause; khong gom chi vi gan thoi gian.'
        END::TEXT;
END;
$$;
