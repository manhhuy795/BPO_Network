-- Mo hinh dependency toi thieu, bam sat topology_v2_dual_wan.py.

CREATE TABLE IF NOT EXISTS topology_nodes (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    node_key TEXT NOT NULL UNIQUE,
    display_name TEXT NOT NULL,
    node_type TEXT NOT NULL
        CHECK (node_type IN ('router', 'switch', 'host', 'service')),
    ip_address INET,
    vlan INTEGER CHECK (vlan IS NULL OR vlan BETWEEN 1 AND 4094),
    metadata JSONB NOT NULL DEFAULT '{}'::JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS topology_edges (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    parent_node_id BIGINT NOT NULL REFERENCES topology_nodes(id) ON DELETE CASCADE,
    child_node_id BIGINT NOT NULL REFERENCES topology_nodes(id) ON DELETE CASCADE,
    dependency_type TEXT NOT NULL DEFAULT 'network',
    metadata JSONB NOT NULL DEFAULT '{}'::JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT topology_edges_no_self_loop CHECK (parent_node_id <> child_node_id),
    CONSTRAINT topology_edges_unique UNIQUE (parent_node_id, child_node_id, dependency_type)
);

CREATE INDEX IF NOT EXISTS idx_topology_edges_child
    ON topology_edges (child_node_id);

CREATE TABLE IF NOT EXISTS alert_entity_mapping (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    alert_name TEXT NOT NULL,
    provider TEXT,
    service TEXT,
    node_id BIGINT NOT NULL REFERENCES topology_nodes(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT alert_entity_mapping_unique
        UNIQUE NULLS NOT DISTINCT (alert_name, provider, service)
);

CREATE INDEX IF NOT EXISTS idx_alert_entity_mapping_node
    ON alert_entity_mapping (node_id);

INSERT INTO topology_nodes (node_key, display_name, node_type, ip_address, vlan) VALUES
    ('r1', 'Router doanh nghiep', 'router', NULL, NULL),
    ('isp_fpt', 'Router ISP FPT', 'router', NULL, NULL),
    ('isp_viettel', 'Router ISP Viettel', 'router', NULL, NULL),
    ('r_internet', 'Router Internet mo phong', 'router', NULL, NULL),
    ('s_core', 'Core switch', 'switch', NULL, NULL),
    ('s_dist', 'Distribution switch', 'switch', NULL, NULL),
    ('s_outside', 'Outside switch', 'switch', NULL, NULL),
    ('s_a20', 'Access switch VLAN 20', 'switch', NULL, 20),
    ('s_a30', 'Access switch VLAN 30', 'switch', NULL, 30),
    ('s_a40', 'Access switch VLAN 40', 'switch', NULL, 40),
    ('s_a50', 'Access switch VLAN 50', 'switch', NULL, 50),
    ('s_a60', 'Access switch VLAN 60', 'switch', NULL, 60),
    ('pc_du_an_1', 'PC du an 1', 'host', '10.10.20.10', 20),
    ('pc_du_an_2', 'PC du an 2', 'host', '10.10.30.10', 30),
    ('pc_du_an_3', 'PC du an 3', 'host', '10.10.40.10', 40),
    ('pc_du_an_4', 'PC du an 4', 'host', '10.10.50.10', 50),
    ('pc_it', 'PC IT', 'host', '10.10.60.10', 60),
    ('pc_office', 'PC Office', 'host', '10.10.60.20', 60),
    ('srv_crm', 'CRM phia doi tac', 'service', '172.16.100.10', NULL),
    ('srv_cfono', 'CFONO phia doi tac', 'service', '172.16.100.20', NULL)
ON CONFLICT (node_key) DO UPDATE SET
    display_name = EXCLUDED.display_name,
    node_type = EXCLUDED.node_type,
    ip_address = EXCLUDED.ip_address,
    vlan = EXCLUDED.vlan;

WITH edge(parent_key, child_key) AS (
    VALUES
        ('r1', 's_core'),
        ('s_core', 's_dist'),
        ('s_dist', 's_a20'),
        ('s_dist', 's_a30'),
        ('s_dist', 's_a40'),
        ('s_dist', 's_a50'),
        ('s_dist', 's_a60'),
        ('s_a20', 'pc_du_an_1'),
        ('s_a30', 'pc_du_an_2'),
        ('s_a40', 'pc_du_an_3'),
        ('s_a50', 'pc_du_an_4'),
        ('s_a60', 'pc_it'),
        ('s_a60', 'pc_office'),
        ('r1', 'isp_fpt'),
        ('r1', 'isp_viettel'),
        ('isp_fpt', 'r_internet'),
        ('isp_viettel', 'r_internet'),
        ('r_internet', 's_outside'),
        ('s_outside', 'srv_crm'),
        ('s_outside', 'srv_cfono')
)
INSERT INTO topology_edges (parent_node_id, child_node_id)
SELECT parent.id, child.id
FROM edge
JOIN topology_nodes parent ON parent.node_key = edge.parent_key
JOIN topology_nodes child ON child.node_key = edge.child_key
ON CONFLICT (parent_node_id, child_node_id, dependency_type) DO NOTHING;

WITH mapping(alert_name, provider, service, node_key) AS (
    VALUES
        ('FPTDownViettelAvailable', NULL, NULL, 'isp_fpt'),
        ('BothWANDown', NULL, NULL, 'r1'),
        ('WANMonitorDown', NULL, NULL, 'r1'),
        ('WANStatusStale', NULL, NULL, 'r1'),
        ('CRMDown', NULL, 'crm', 'srv_crm'),
        ('CRMProcessDown', NULL, 'crm', 'srv_crm'),
        ('CRMHttpUnavailable', NULL, 'crm', 'srv_crm'),
        ('CFONODown', NULL, 'cfono', 'srv_cfono'),
        ('CFONOProcessDown', NULL, 'cfono', 'srv_cfono'),
        ('CFONOHttpUnavailable', NULL, 'cfono', 'srv_cfono'),
        ('HighPacketLoss', 'fpt', NULL, 'isp_fpt'),
        ('HighPacketLoss', 'viettel', NULL, 'isp_viettel'),
        ('HighLatency', 'fpt', NULL, 'isp_fpt'),
        ('HighLatency', 'viettel', NULL, 'isp_viettel')
)
INSERT INTO alert_entity_mapping (alert_name, provider, service, node_id)
SELECT mapping.alert_name, mapping.provider, mapping.service, node.id
FROM mapping
JOIN topology_nodes node ON node.node_key = mapping.node_key
ON CONFLICT (alert_name, provider, service) DO UPDATE
SET node_id = EXCLUDED.node_id;

CREATE OR REPLACE FUNCTION bpo_topology_parents(p_node_key TEXT)
RETURNS TABLE (node_key TEXT, display_name TEXT, node_type TEXT)
LANGUAGE SQL
STABLE
AS $$
    SELECT parent.node_key, parent.display_name, parent.node_type
    FROM topology_nodes child
    JOIN topology_edges edge ON edge.child_node_id = child.id
    JOIN topology_nodes parent ON parent.id = edge.parent_node_id
    WHERE child.node_key = p_node_key
    ORDER BY parent.node_key;
$$;

CREATE OR REPLACE FUNCTION bpo_topology_ancestors(p_node_key TEXT)
RETURNS TABLE (node_key TEXT, display_name TEXT, node_type TEXT, depth INTEGER)
LANGUAGE SQL
STABLE
AS $$
    WITH RECURSIVE ancestor(node_id, depth, path) AS (
        SELECT edge.parent_node_id, 1, ARRAY[edge.child_node_id, edge.parent_node_id]
        FROM topology_nodes child
        JOIN topology_edges edge ON edge.child_node_id = child.id
        WHERE child.node_key = p_node_key
        UNION ALL
        SELECT edge.parent_node_id, ancestor.depth + 1, ancestor.path || edge.parent_node_id
        FROM ancestor
        JOIN topology_edges edge ON edge.child_node_id = ancestor.node_id
        WHERE NOT edge.parent_node_id = ANY(ancestor.path)
    )
    SELECT DISTINCT ON (node.id)
        node.node_key, node.display_name, node.node_type, ancestor.depth
    FROM ancestor
    JOIN topology_nodes node ON node.id = ancestor.node_id
    ORDER BY node.id, ancestor.depth;
$$;

CREATE OR REPLACE FUNCTION bpo_map_alert_entity(
    p_alert_name TEXT,
    p_provider TEXT DEFAULT NULL,
    p_service TEXT DEFAULT NULL
)
RETURNS TABLE (node_key TEXT, display_name TEXT, node_type TEXT)
LANGUAGE SQL
STABLE
AS $$
    SELECT node.node_key, node.display_name, node.node_type
    FROM alert_entity_mapping mapping
    JOIN topology_nodes node ON node.id = mapping.node_id
    WHERE mapping.alert_name = p_alert_name
      AND (mapping.provider IS NULL OR mapping.provider = lower(p_provider))
      AND (mapping.service IS NULL OR mapping.service = lower(p_service))
    ORDER BY
        (mapping.provider IS NOT NULL)::INTEGER +
        (mapping.service IS NOT NULL)::INTEGER DESC
    LIMIT 1;
$$;
