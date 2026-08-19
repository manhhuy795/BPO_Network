-- Theo doi tung lan tai dien ma van giu mot row incidents tuong thich he thong cu.

CREATE TABLE IF NOT EXISTS incident_occurrences (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    incident_id BIGINT NOT NULL REFERENCES incidents(id) ON DELETE CASCADE,
    occurrence_number INTEGER NOT NULL CHECK (occurrence_number > 0),
    status TEXT NOT NULL CHECK (status IN ('open', 'resolved')),
    started_at TIMESTAMPTZ NOT NULL,
    ended_at TIMESTAMPTZ,
    duration_seconds NUMERIC CHECK (duration_seconds IS NULL OR duration_seconds >= 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (incident_id, occurrence_number),
    CHECK (
        (status = 'open' AND ended_at IS NULL AND duration_seconds IS NULL)
        OR (status = 'resolved' AND ended_at IS NOT NULL AND duration_seconds IS NOT NULL)
    )
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_incident_occurrences_one_open
    ON incident_occurrences (incident_id) WHERE status = 'open';
CREATE INDEX IF NOT EXISTS idx_incident_occurrences_timeline
    ON incident_occurrences (incident_id, occurrence_number DESC);

-- Moi incident lich su duoc backfill thanh occurrence dau tien, khong sua du lieu cu.
INSERT INTO incident_occurrences (
    incident_id, occurrence_number, status, started_at, ended_at, duration_seconds
)
SELECT incident.id, 1, incident.status, incident.first_seen, incident.resolved_at,
       CASE WHEN incident.resolved_at IS NULL THEN NULL
            ELSE GREATEST(0, EXTRACT(EPOCH FROM incident.resolved_at - incident.first_seen))
       END
FROM incidents incident
WHERE NOT EXISTS (
    SELECT 1 FROM incident_occurrences occurrence
    WHERE occurrence.incident_id = incident.id
)
ON CONFLICT (incident_id, occurrence_number) DO NOTHING;

CREATE OR REPLACE VIEW incident_occurrence_metrics AS
SELECT incident.id AS incident_id,
       incident.incident_key,
       count(occurrence.id) AS occurrence_count,
       count(occurrence.id) FILTER (WHERE occurrence.status = 'resolved') AS resolved_count,
       avg(occurrence.duration_seconds)
           FILTER (WHERE occurrence.status = 'resolved') AS mttr_seconds
FROM incidents incident
LEFT JOIN incident_occurrences occurrence ON occurrence.incident_id = incident.id
GROUP BY incident.id, incident.incident_key;

-- Bao quanh correlation Phase 8; duplicate khong di qua nhanh tao occurrence.
DO $$
BEGIN
    IF to_regprocedure('process_bpo_alert_topology(jsonb)') IS NULL THEN
        ALTER FUNCTION process_bpo_alert(JSONB) RENAME TO process_bpo_alert_topology;
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
    processed RECORD;
    event_time TIMESTAMPTZ := COALESCE(
        NULLIF(input_data->>'starts_at', '')::TIMESTAMPTZ,
        CURRENT_TIMESTAMP
    );
    end_time TIMESTAMPTZ := COALESCE(
        NULLIF(input_data->>'ends_at', '')::TIMESTAMPTZ,
        NULLIF(input_data->>'received_at', '')::TIMESTAMPTZ,
        CURRENT_TIMESTAMP
    );
BEGIN
    SELECT * INTO processed FROM process_bpo_alert_topology(input_data);

    IF processed.result_status = 'duplicate' THEN
        RETURN QUERY SELECT
            processed.result_status::TEXT,
            processed.raw_alert_id::BIGINT,
            processed.result_incident_id::BIGINT,
            processed.result_incident_key::TEXT,
            processed.message::TEXT;
        RETURN;
    END IF;

    -- Phase 8 co the resolve incident nguon khi merge; dong occurrence nguon cung transaction.
    UPDATE incident_occurrences occurrence
    SET status = 'resolved',
        ended_at = incident.resolved_at,
        duration_seconds = GREATEST(
            0,
            EXTRACT(EPOCH FROM incident.resolved_at - occurrence.started_at)
        ),
        updated_at = CURRENT_TIMESTAMP
    FROM incidents incident
    WHERE occurrence.incident_id = incident.id
      AND occurrence.status = 'open'
      AND incident.status = 'resolved'
      AND incident.resolved_at IS NOT NULL;

    IF processed.result_incident_id IS NOT NULL THEN
        PERFORM pg_advisory_xact_lock(processed.result_incident_id);

        IF input_data->>'status' = 'firing' THEN
            INSERT INTO incident_occurrences (
                incident_id, occurrence_number, status, started_at
            )
            SELECT processed.result_incident_id,
                   COALESCE(max(occurrence.occurrence_number), 0) + 1,
                   'open', event_time
            FROM incident_occurrences occurrence
            WHERE occurrence.incident_id = processed.result_incident_id
            HAVING NOT EXISTS (
                SELECT 1 FROM incident_occurrences open_occurrence
                WHERE open_occurrence.incident_id = processed.result_incident_id
                  AND open_occurrence.status = 'open'
            );
        ELSIF input_data->>'status' = 'resolved'
              AND EXISTS (
                  SELECT 1 FROM incidents incident
                  WHERE incident.id = processed.result_incident_id
                    AND incident.status = 'resolved'
              ) THEN
            UPDATE incident_occurrences occurrence
            SET status = 'resolved',
                ended_at = end_time,
                duration_seconds = GREATEST(
                    0,
                    EXTRACT(EPOCH FROM end_time - occurrence.started_at)
                ),
                updated_at = CURRENT_TIMESTAMP
            WHERE occurrence.incident_id = processed.result_incident_id
              AND occurrence.status = 'open';
        END IF;
    END IF;

    RETURN QUERY SELECT
        processed.result_status::TEXT,
        processed.raw_alert_id::BIGINT,
        processed.result_incident_id::BIGINT,
        processed.result_incident_key::TEXT,
        processed.message::TEXT;
END;
$$;
