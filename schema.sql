DROP TABLE IF EXISTS defect_images CASCADE;
DROP TABLE IF EXISTS maintenance_actions CASCADE;
DROP TABLE IF EXISTS defects CASCADE;
DROP TABLE IF EXISTS inspections CASCADE;
DROP TABLE IF EXISTS segments CASCADE;
DROP TABLE IF EXISTS inspectors CASCADE;
DROP FUNCTION IF EXISTS compute_rci_for_inspection(BIGINT);
DROP FUNCTION IF EXISTS trg_update_rci_after_defect() CASCADE;
DROP MATERIALIZED VIEW IF EXISTS urgent_segments_mv;
DROP VIEW IF EXISTS latest_inspection_view;

-- ====================================================
-- 1. Core tables
-- ====================================================
CREATE TABLE inspectors (
    inspector_id   SERIAL PRIMARY KEY,
    name           TEXT NOT NULL,
    phone          TEXT,
    email          TEXT,
    created_at     TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE segments (
    segment_id     SERIAL PRIMARY KEY,
    segment_code   TEXT UNIQUE NOT NULL,
    name           TEXT,
    start_lat      DOUBLE PRECISION,
    start_lon      DOUBLE PRECISION,
    end_lat        DOUBLE PRECISION,
    end_lon        DOUBLE PRECISION,
    length_m       NUMERIC,
    created_at     TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE inspections (
    inspection_id  BIGSERIAL PRIMARY KEY,
    segment_id     INT NOT NULL REFERENCES segments(segment_id) ON DELETE CASCADE,
    inspector_id   INT REFERENCES inspectors(inspector_id) ON DELETE SET NULL,
    inspected_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    surface_condition TEXT,
    rci            NUMERIC(4,1),        -- Road Condition Index 0.0 - 10.0
    notes          TEXT,
    created_at     TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE defects (
    defect_id      BIGSERIAL PRIMARY KEY,
    inspection_id  BIGINT NOT NULL REFERENCES inspections(inspection_id) ON DELETE CASCADE,
    defect_type    TEXT NOT NULL,       -- 'pothole','crack','rutting','fading_markings', etc.
    severity       SMALLINT NOT NULL CHECK (severity >= 1 AND severity <= 5),  -- 1..5
    length_m       NUMERIC,             -- for cracks (optional)
    width_m        NUMERIC,
    depth_cm       NUMERIC,             -- for potholes
    location_lat   DOUBLE PRECISION,
    location_lon   DOUBLE PRECISION,
    comments       TEXT,
    created_at     TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE defect_images (
    image_id       BIGSERIAL PRIMARY KEY,
    defect_id      BIGINT REFERENCES defects(defect_id) ON DELETE CASCADE,
    image_url      TEXT NOT NULL,
    caption        TEXT,
    uploaded_at    TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE maintenance_actions (
    action_id      BIGSERIAL PRIMARY KEY,
    segment_id     INT REFERENCES segments(segment_id) ON DELETE CASCADE,
    planned_date   DATE,
    performed_date DATE,
    action_type    TEXT,                 -- 'patching','resurfacing','reconstruction','line_painting'
    cost           NUMERIC,
    status         TEXT DEFAULT 'PLANNED', -- PLANNED,IN_PROGRESS,COMPLETED,CANCELLED
    notes          TEXT,
    created_at     TIMESTAMPTZ DEFAULT now()
);

-- ====================================================
-- 2. Indexes (performance)
-- ====================================================
CREATE INDEX idx_inspections_segment_time ON inspections(segment_id, inspected_at DESC);
CREATE INDEX idx_defects_inspection ON defects(inspection_id);
CREATE INDEX idx_defects_type_severity ON defects(defect_type, severity);
CREATE INDEX idx_maintenance_status ON maintenance_actions(status);
CREATE INDEX idx_segments_code ON segments(segment_code);

-- ====================================================
-- 3. Function: compute_rci_for_inspection
--    - Simple weighted penalty-based RCI on scale 0..10 (higher better)
--    - Tunable weights in code comments
-- ====================================================
CREATE OR REPLACE FUNCTION compute_rci_for_inspection(p_inspection_id BIGINT)
RETURNS NUMERIC LANGUAGE plpgsql AS $$
DECLARE
    rec RECORD;
    base NUMERIC := 10.0;
    penalty NUMERIC := 0.0;
    -- weights: tune these to change sensitivity
    w_pothole_depth  NUMERIC := 0.8;  -- weight multiplier for pothole depth contribution
    w_crack_length   NUMERIC := 0.5;  -- weight multiplier for crack length contribution
    w_rutting        NUMERIC := 0.7;  -- weight multiplier for rutting
    w_default        NUMERIC := 0.4;  -- fallback weight
    total_penalty    NUMERIC := 0.0;
BEGIN
    -- Iterate defects in the inspection and accumulate penalty
    FOR rec IN
        SELECT defect_type, severity, COALESCE(length_m,0) AS length_m, COALESCE(depth_cm,0) AS depth_cm
        FROM defects
        WHERE inspection_id = p_inspection_id
    LOOP
        IF rec.defect_type ILIKE 'pothole%' THEN
            -- deeper potholes are more severe; severity 1..5 scale
            penalty := penalty + (rec.severity * (COALESCE(rec.depth_cm,1) / 10.0)) * w_pothole_depth;
        ELSIF rec.defect_type ILIKE 'crack%' THEN
            -- long cracks matter; normalize by some factor (length in m)
            penalty := penalty + (rec.severity * (GREATEST(rec.length_m,1) / 10.0)) * w_crack_length;
        ELSIF rec.defect_type ILIKE 'rutting%' THEN
            penalty := penalty + (rec.severity * 0.7) * w_rutting;
        ELSE
            -- other defects (markings, surface wear)
            penalty := penalty + (rec.severity * 0.5) * w_default;
        END IF;
    END LOOP;

    total_penalty := penalty;

    -- compute RCI
    base := base - total_penalty;

    -- clamp between 0 and 10
    IF base < 0 THEN base := 0; END IF;
    IF base > 10 THEN base := 10; END IF;

    -- persist rounded rci to inspections table
    UPDATE inspections SET rci = ROUND(base::numeric,1) WHERE inspection_id = p_inspection_id;

    RETURN ROUND(base::numeric,1);
END;
$$;

-- ====================================================
-- 4. Trigger: recalc RCI after defects inserted/updated/deleted for an inspection
--    This trigger calls compute_rci_for_inspection for the relevant inspection_id.
-- ====================================================
CREATE OR REPLACE FUNCTION trg_update_rci_after_defect()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_inspection_id BIGINT;
BEGIN
    IF TG_OP = 'DELETE' THEN
        v_inspection_id := OLD.inspection_id;
    ELSE
        v_inspection_id := NEW.inspection_id;
    END IF;

    PERFORM compute_rci_for_inspection(v_inspection_id);
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_defect_after_insert
AFTER INSERT ON defects
FOR EACH ROW EXECUTE FUNCTION trg_update_rci_after_defect();

CREATE TRIGGER trg_defect_after_update
AFTER UPDATE ON defects
FOR EACH ROW EXECUTE FUNCTION trg_update_rci_after_defect();

CREATE TRIGGER trg_defect_after_delete
AFTER DELETE ON defects
FOR EACH ROW EXECUTE FUNCTION trg_update_rci_after_defect();

-- ====================================================
-- 5. Materialized view and helper view
--    - latest_inspection_view: shows latest inspection per segment
--    - urgent_segments_mv: cached list of segments with low RCI
-- ====================================================
CREATE OR REPLACE VIEW latest_inspection_view AS
SELECT s.segment_id, s.segment_code, s.name AS segment_name,
       i.inspection_id, i.rci, i.inspected_at, i.notes
FROM segments s
LEFT JOIN LATERAL (
    SELECT * FROM inspections WHERE segment_id = s.segment_id ORDER BY inspected_at DESC LIMIT 1
) i ON true;

CREATE MATERIALIZED VIEW urgent_segments_mv AS
SELECT segment_id, segment_code, segment_name, rci, inspected_at
FROM latest_inspection_view
WHERE rci IS NOT NULL AND rci <= 3.5
ORDER BY rci ASC, inspected_at DESC;

-- To refresh materialized view periodically:
-- REFRESH MATERIALIZED VIEW CONCURRENTLY urgent_segments_mv;

-- ====================================================
-- 6. Sample data (inspectors, segments, inspections, defects)
-- ====================================================
-- Insert inspectors
INSERT INTO inspectors (name, phone, email) VALUES
('R. Kumar', '+919876543210', 'rkumar@example.com'),
('S. Mehta', '+919812345678', 'smehta@example.com');

-- Insert segments
INSERT INTO segments (segment_code, name, start_lat, start_lon, end_lat, end_lon, length_m)
VALUES
('SEG-001', 'Main Avenue - A', 17.4470, 78.3790, 17.4490, 78.3810, 450),
('SEG-002', 'Market Road - B', 17.4500, 78.3820, 17.4520, 78.3850, 600),
('SEG-003', 'River Side - C', 17.4535, 78.3865, 17.4555, 78.3885, 700);

-- Insert inspections (note: rci will be calculated after defects inserted)
INSERT INTO inspections (segment_id, inspector_id, inspected_at, surface_condition, notes)
VALUES
(1, 1, now() - interval '12 days', 'Multiple potholes and cracks', 'Observed near junction'),
(2, 2, now() - interval '8 days', 'Surface wear and faded markings', 'Need line painting'),
(3, 1, now() - interval '20 days', 'Severe potholes', 'High traffic area');

-- Insert defects for inspection 1 (SEG-001)
-- find inspection_id for segment 1 (latest)
WITH t AS (SELECT inspection_id FROM inspections WHERE segment_id = 1 ORDER BY inspected_at DESC LIMIT 1)
INSERT INTO defects (inspection_id, defect_type, severity, depth_cm, location_lat, location_lon, comments)
SELECT t.inspection_id, 'pothole', 4, 12, 17.4485, 78.3802, 'Large pothole near lamp post' FROM t;

INSERT INTO defects (inspection_id, defect_type, severity, length_m, location_lat, location_lon, comments)
SELECT t.inspection_id, 'crack', 3, 5.0, 17.4489, 78.3807, 'Long transverse cracks' FROM t;

-- Insert defects for inspection 2 (SEG-002)
WITH t AS (SELECT inspection_id FROM inspections WHERE segment_id = 2 ORDER BY inspected_at DESC LIMIT 1)
INSERT INTO defects (inspection_id, defect_type, severity, location_lat, location_lon, comments)
SELECT t.inspection_id, 'fading_markings', 2, 17.4515, 78.3835, 'Lane markings faded' FROM t;

-- Insert defects for inspection 3 (SEG-003)
WITH t AS (SELECT inspection_id FROM inspections WHERE segment_id = 3 ORDER BY inspected_at DESC LIMIT 1)
INSERT INTO defects (inspection_id, defect_type, severity, depth_cm, location_lat, location_lon, comments)
SELECT t.inspection_id, 'pothole', 5, 18, 17.4545, 78.3875, 'Multiple deep potholes' FROM t;

-- After insertion triggers will compute and store RCI automatically

-- ====================================================
-- 7. Example maintenance actions (sample)
-- ====================================================
INSERT INTO maintenance_actions (segment_id, planned_date, action_type, cost, status, notes)
VALUES
(1, current_date + 7, 'patching', 18000, 'PLANNED', 'Temporary patching for potholes'),
(3, current_date + 14, 'resurfacing', 250000, 'PLANNED', 'Major resurfacing required');

-- ====================================================
-- 8. Useful example queries (run these in psql / client)
--    - included as comments; remove comments to run directly
-- ====================================================

/*
-- 8.1: View latest inspection per segment
SELECT * FROM latest_inspection_view ORDER BY rci NULLS LAST;

-- 8.2: Show all defects for a given segment (most recent inspection)
SELECT d.* FROM defects d
JOIN inspections i ON i.inspection_id = d.inspection_id
WHERE i.segment_id = 1
ORDER BY d.created_at DESC;

-- 8.3: Segments needing urgent maintenance (RCI <= 3.5)
SELECT * FROM urgent_segments_mv;

-- 8.4: Recompute RCI for a specific inspection manually
SELECT compute_rci_for_inspection( (SELECT inspection_id FROM inspections WHERE segment_id=1 ORDER BY inspected_at DESC LIMIT 1) );

-- 8.5: Segments sorted by RCI (ascending -> worst first)
SELECT s.segment_id, s.segment_code, s.name, i.rci, i.inspected_at
FROM segments s
LEFT JOIN LATERAL (SELECT * FROM inspections WHERE segment_id = s.segment_id ORDER BY inspected_at DESC LIMIT 1) i ON true
ORDER BY COALESCE(i.rci, 0) ASC NULLS LAST;

-- 8.6: Defect summary for each segment (last inspection)
SELECT s.segment_id, s.segment_code, s.name,
       COUNT(d.defect_id) AS defect_count,
       AVG(d.severity)::numeric(3,2) AS avg_severity
FROM segments s
LEFT JOIN inspections i ON i.segment_id = s.segment_id
LEFT JOIN defects d ON d.inspection_id = i.inspection_id
WHERE i.inspection_id = (SELECT inspection_id FROM inspections WHERE segment_id = s.segment_id ORDER BY inspected_at DESC LIMIT 1)
GROUP BY s.segment_id, s.segment_code, s.name
ORDER BY avg_severity DESC;

-- 8.7: Insert a new inspection and defects (example)
BEGIN;
INSERT INTO inspections(segment_id, inspector_id, inspected_at, surface_condition, notes)
VALUES (1, 2, now(), 'Check after rains', 'Follow up inspection') RETURNING inspection_id;
-- assume returned id = 100
INSERT INTO defects(inspection_id, defect_type, severity, depth_cm, location_lat, location_lon, comments)
VALUES (100, 'pothole', 3, 10, 17.4480, 78.3800, 'Small pothole');
COMMIT;
-- trigger will compute RCI automatically
*/

-- ====================================================
-- 9. Convenience: refresh materialized view once to populate urgent list
-- ====================================================
REFRESH MATERIALIZED VIEW urgent_segments_mv;

-- ====================================================
-- 10. Final informational SELECTs (optional)
-- ====================================================
-- show segments and their latest RCI
-- SELECT s.segment_code, s.name, i.rci, i.inspected_at FROM segments s
-- LEFT JOIN LATERAL (SELECT * FROM inspections WHERE segment_id = s.segment_id ORDER BY inspected_at DESC LIMIT 1) i ON true
-- ORDER BY COALESCE(i.rci,0) ASC;
