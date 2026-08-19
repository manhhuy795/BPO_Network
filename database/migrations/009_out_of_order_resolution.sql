-- Hoa giai resolved den truoc firing; event_key lap van idempotent.

DO $$
BEGIN
    IF to_regprocedure('process_bpo_alert_occurrences(jsonb)') IS NULL THEN
        ALTER FUNCTION process_bpo_alert(JSONB) RENAME TO process_bpo_alert_occurrences;
    END IF;
END;
$$;

-- Duplicate cu chi retry outbox da failed/pending qua 5 giay; duplicate dong thoi khong retry.
DO $$
BEGIN
    IF to_regprocedure('bpo_prepare_notification_legacy(bigint,text,bigint)') IS NULL THEN
        ALTER FUNCTION bpo_prepare_notification(BIGINT, TEXT, BIGINT)
            RENAME TO bpo_prepare_notification_legacy;
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION bpo_prepare_notification(
    p_raw_alert_id BIGINT,
    p_result_status TEXT,
    p_incident_id BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    replay_incident_id BIGINT;
    replay_status TEXT;
    notification notification_events%ROWTYPE;
BEGIN
    IF p_result_status <> 'duplicate' OR p_raw_alert_id IS NULL THEN
        RETURN bpo_prepare_notification_legacy(
            p_raw_alert_id, p_result_status, p_incident_id
        );
    END IF;

    PERFORM pg_advisory_xact_lock(p_raw_alert_id);
    SELECT incident_id INTO replay_incident_id
    FROM incident_alerts
    WHERE alert_id = p_raw_alert_id
    ORDER BY incident_id
    LIMIT 1;

    IF replay_incident_id IS NULL THEN
        RETURN bpo_prepare_notification_legacy(
            p_raw_alert_id, p_result_status, p_incident_id
        );
    END IF;

    SELECT * INTO notification
    FROM notification_events
    WHERE raw_alert_id = p_raw_alert_id
    ORDER BY id
    LIMIT 1;

    IF notification.id IS NOT NULL
       AND notification.email_status <> 'failed'
       AND notification.glpi_status <> 'failed'
       AND NOT (
           (notification.email_status = 'pending' OR notification.glpi_status = 'pending')
           AND notification.updated_at < CURRENT_TIMESTAMP - INTERVAL '5 seconds'
       ) THEN
        RETURN bpo_prepare_notification_legacy(
            p_raw_alert_id, 'duplicate', replay_incident_id
        );
    END IF;

    IF notification.id IS NOT NULL THEN
        replay_status := CASE notification.event_type
            WHEN 'created' THEN 'created'
            WHEN 'resolved' THEN 'resolved'
            ELSE 'updated'
        END;
        UPDATE notification_events
        SET email_status = CASE WHEN email_status = 'failed' THEN 'pending' ELSE email_status END,
            glpi_status = CASE WHEN glpi_status = 'failed' THEN 'pending' ELSE glpi_status END,
            updated_at = CURRENT_TIMESTAMP
        WHERE id = notification.id;
    ELSE
        SELECT CASE event.event_type
            WHEN 'opened' THEN 'created'
            WHEN 'reopened' THEN 'created'
            WHEN 'resolved' THEN 'resolved'
            ELSE 'updated'
        END
        INTO replay_status
        FROM incident_events event
        WHERE event.incident_id = replay_incident_id
          AND event.event_data->>'raw_alert_id' = p_raw_alert_id::TEXT
        ORDER BY event.id
        LIMIT 1;
        replay_status := COALESCE(replay_status, 'updated');
    END IF;

    -- Execution co the bi dung sau khi tao integration nhung truoc khi GLPI
    -- tra ticket. Danh dau lan pending qua han la failed de logic hien co
    -- thuc hien lai action=create; ticket da co khong bao gio bi tao lai.
    UPDATE incident_integrations
    SET glpi_status = 'failed',
        updated_at = CURRENT_TIMESTAMP
    WHERE incident_id = replay_incident_id
      AND glpi_ticket_id IS NULL
      AND glpi_status = 'pending';

    RETURN bpo_prepare_notification_legacy(
        p_raw_alert_id, replay_status, replay_incident_id
    );
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
    prior_resolved RECORD;
    active_count INTEGER;
BEGIN
    SELECT * INTO processed FROM process_bpo_alert_occurrences(input_data);

    IF input_data->>'status' = 'firing'
       AND processed.result_status <> 'duplicate'
       AND processed.result_incident_id IS NOT NULL THEN
        SELECT id, ends_at, received_at
        INTO prior_resolved
        FROM raw_alerts
        WHERE status = 'resolved'
          AND fingerprint = input_data->>'fingerprint'
          AND starts_at IS NOT DISTINCT FROM NULLIF(input_data->>'starts_at', '')::TIMESTAMPTZ
        ORDER BY received_at, id
        LIMIT 1;

        IF prior_resolved.id IS NOT NULL THEN
            INSERT INTO incident_alerts (incident_id, alert_id)
            VALUES (processed.result_incident_id, prior_resolved.id)
            ON CONFLICT DO NOTHING;

            SELECT count(*) INTO active_count
            FROM raw_alerts firing_alert
            JOIN incident_alerts link ON link.alert_id = firing_alert.id
            WHERE link.incident_id = processed.result_incident_id
              AND firing_alert.status = 'firing'
              AND NOT EXISTS (
                  SELECT 1 FROM raw_alerts resolved_alert
                  WHERE resolved_alert.status = 'resolved'
                    AND resolved_alert.fingerprint = firing_alert.fingerprint
                    AND resolved_alert.starts_at IS NOT DISTINCT FROM firing_alert.starts_at
              );

            INSERT INTO incident_events (incident_id, event_type, description, event_data)
            VALUES (
                processed.result_incident_id,
                'out_of_order_resolved',
                'Ban resolved den truoc firing da duoc hoa giai theo fingerprint va starts_at.',
                jsonb_build_object(
                    'firing_raw_alert_id', processed.raw_alert_id,
                    'resolved_raw_alert_id', prior_resolved.id
                )
            );

            IF active_count = 0 THEN
                UPDATE incidents
                SET status = 'resolved',
                    resolved_at = COALESCE(prior_resolved.ends_at, prior_resolved.received_at),
                    last_seen = GREATEST(last_seen, COALESCE(prior_resolved.ends_at, prior_resolved.received_at)),
                    updated_at = CURRENT_TIMESTAMP
                WHERE id = processed.result_incident_id;

                UPDATE incident_occurrences
                SET status = 'resolved',
                    ended_at = COALESCE(prior_resolved.ends_at, prior_resolved.received_at),
                    duration_seconds = GREATEST(
                        0,
                        EXTRACT(EPOCH FROM COALESCE(prior_resolved.ends_at, prior_resolved.received_at) - started_at)
                    ),
                    updated_at = CURRENT_TIMESTAMP
                WHERE incident_id = processed.result_incident_id
                  AND status = 'open';

                processed.result_status := 'resolved';
                processed.message := 'Firing da duoc hoa giai bang ban resolved den truoc.';
            END IF;
        END IF;
    END IF;

    -- Chi resolved lam occurrence chuyen open -> resolved moi duoc phat notification.
    IF input_data->>'status' = 'resolved'
       AND processed.result_status = 'resolved'
       AND processed.result_incident_id IS NOT NULL
       AND NOT EXISTS (
           SELECT 1 FROM incident_occurrences occurrence
           WHERE occurrence.incident_id = processed.result_incident_id
             AND occurrence.status = 'resolved'
             AND occurrence.updated_at = CURRENT_TIMESTAMP
       ) THEN
        processed.result_status := 'updated';
        processed.message := 'Resolved da duoc ghi nhan; incident chua chuyen trang thai trong event nay.';
    END IF;

    RETURN QUERY SELECT
        processed.result_status::TEXT,
        processed.raw_alert_id::BIGINT,
        processed.result_incident_id::BIGINT,
        processed.result_incident_key::TEXT,
        processed.message::TEXT;
END;
$$;
