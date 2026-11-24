-- ICT371 Advanced Database | Question 9: Farmer Cooperative Maize Deliveries
-- PostgreSQL. Run the whole file in one go (psql -f, or the pgAdmin Query Tool).

DROP SCHEMA IF EXISTS q9_maize CASCADE;
CREATE SCHEMA q9_maize;
SET search_path = q9_maize, public;

------------------------------------------------------------------
-- (a) Database
------------------------------------------------------------------
CREATE TABLE farmers (
    farmer_id     SERIAL PRIMARY KEY,
    farmer_number VARCHAR(20)  NOT NULL UNIQUE,
    full_name     VARCHAR(100) NOT NULL
);

CREATE TABLE deliveries (
    delivery_id  SERIAL PRIMARY KEY,
    farmer_id    INT           NOT NULL REFERENCES farmers(farmer_id),
    grade        CHAR(1)       NOT NULL CHECK (grade IN ('A', 'B', 'C')),
    weight_kg    NUMERIC(10,2) NOT NULL CHECK (weight_kg > 0),
    -- unit_rate and total_value are always filled in by the BEFORE trigger
    unit_rate    NUMERIC(10,2) NOT NULL,
    total_value  NUMERIC(14,2) NOT NULL,
    delivered_on DATE          NOT NULL,
    is_paid      BOOLEAN       NOT NULL DEFAULT FALSE
);

CREATE TABLE daily_purchases (
    purchase_date DATE PRIMARY KEY,
    total_weight  NUMERIC(14,2) NOT NULL,
    total_value   NUMERIC(14,2) NOT NULL
);

------------------------------------------------------------------
-- (b) Function: fn_maize_rate (A = K5, B = K4, C = K3 per kg)
------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade TEXT)
RETURNS NUMERIC
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_rate NUMERIC;
BEGIN
    IF p_grade IS NULL THEN
        RAISE EXCEPTION 'Grade is required';
    END IF;

    v_rate := CASE p_grade WHEN 'A' THEN 5 WHEN 'B' THEN 4 WHEN 'C' THEN 3 END;

    IF v_rate IS NULL THEN
        RAISE EXCEPTION 'Unsupported grade: % (use A, B or C)', p_grade;
    END IF;

    RETURN v_rate;
END;
$$;

------------------------------------------------------------------
-- (d) Trigger: one pricing rule for every insert/update, direct or not
------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_price_delivery()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = q9_maize, public
AS $$
BEGIN
    IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
        RAISE EXCEPTION 'Weight must be positive, got %', NEW.weight_kg;
    END IF;

    NEW.unit_rate   := fn_maize_rate(NEW.grade);
    NEW.total_value := ROUND(NEW.weight_kg * NEW.unit_rate, 2);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_price_delivery
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW
EXECUTE FUNCTION trg_fn_price_delivery();

------------------------------------------------------------------
-- (c) Procedure: pr_receive_delivery
------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_receive_delivery(p_farmer_id INT, p_grade TEXT,
                                                p_weight NUMERIC, p_date DATE)
LANGUAGE plpgsql
SET search_path = q9_maize, public
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM farmers WHERE farmer_id = p_farmer_id) THEN
        RAISE EXCEPTION 'Unknown farmer: %', p_farmer_id;
    END IF;
    IF p_weight IS NULL OR p_weight <= 0 THEN
        RAISE EXCEPTION 'Weight must be positive, got %', p_weight;
    END IF;
    IF p_date IS NULL THEN
        RAISE EXCEPTION 'Delivery date is required';
    END IF;
    PERFORM fn_maize_rate(p_grade);   -- clear error for a NULL or unsupported grade

    -- Only the basic fields: the trigger supplies unit_rate and total_value
    INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid)
    VALUES (p_farmer_id, p_grade, p_weight, p_date, FALSE);
END;
$$;

------------------------------------------------------------------
-- (a, continued) Seed data, loaded after the trigger exists
------------------------------------------------------------------
INSERT INTO farmers (farmer_number, full_name) VALUES
 ('F001', 'Lameck Mulenga'),
 ('F002', 'Mercy Kabwe'),
 ('F003', 'Nelson Zimba');   -- ends with no unpaid deliveries

-- Direct inserts of the basic fields (trigger prices them)
INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid) VALUES
 (1, 'A', 200.00, CURRENT_DATE - 2, TRUE),
 (1, 'B', 150.50, CURRENT_DATE - 1, FALSE),
 (2, 'C', 300.00, CURRENT_DATE - 1, FALSE),
 (3, 'A',  80.00, CURRENT_DATE - 1, TRUE);

-- Two more through the procedure (always unpaid)
CALL pr_receive_delivery(2, 'A', 120.00, CURRENT_DATE);
CALL pr_receive_delivery(1, 'C',  75.25, CURRENT_DATE);

SELECT * FROM deliveries ORDER BY delivery_id;

------------------------------------------------------------------
-- (e) View: v_farmer_amount_due (zero for farmers with nothing unpaid)
------------------------------------------------------------------
CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT f.farmer_number,
       f.full_name,
       COALESCE(SUM(d.total_value) FILTER (WHERE NOT d.is_paid), 0) AS amount_due
  FROM farmers f
  LEFT JOIN deliveries d ON d.farmer_id = f.farmer_id
 GROUP BY f.farmer_id, f.farmer_number, f.full_name;

SELECT * FROM v_farmer_amount_due ORDER BY farmer_number;

------------------------------------------------------------------
-- (f) Composite index: a farmer's deliveries between two dates
------------------------------------------------------------------
-- Equality column (farmer_id) first, range column (delivered_on) second.
CREATE INDEX idx_deliveries_farmer_date ON deliveries (farmer_id, delivered_on);
ANALYZE deliveries;

SET enable_seqscan = off;
EXPLAIN
SELECT delivery_id, grade, weight_kg, total_value, delivered_on
  FROM deliveries
 WHERE farmer_id = 1
   AND delivered_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;

------------------------------------------------------------------
-- (g) Scheduled job
------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_purchases(p_day DATE)
LANGUAGE plpgsql
SET search_path = q9_maize, public
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'p_day is required';
    END IF;

    INSERT INTO daily_purchases (purchase_date, total_weight, total_value)
    SELECT p_day, COALESCE(SUM(weight_kg), 0), COALESCE(SUM(total_value), 0)
      FROM deliveries
     WHERE delivered_on = p_day
    ON CONFLICT (purchase_date) DO UPDATE
       SET total_weight = EXCLUDED.total_weight,   -- replace, do not add
           total_value  = EXCLUDED.total_value;
END;
$$;

-- pg_cron: daily at 01:30 for the previous day.
--   CREATE EXTENSION IF NOT EXISTS pg_cron;   (one-off, superuser)
SELECT cron.schedule(
    'maize-daily-purchases',
    '30 1 * * *',
    $$CALL q9_maize.pr_refresh_purchases((CURRENT_DATE - 1))$$
);
SELECT jobid, jobname, schedule, command FROM cron.job;

------------------------------------------------------------------
-- Tests
------------------------------------------------------------------
CALL pr_refresh_purchases(CURRENT_DATE - 1);
CALL pr_refresh_purchases(CURRENT_DATE - 1);   -- rerun: totals not doubled
CALL pr_refresh_purchases(CURRENT_DATE);
SELECT * FROM daily_purchases ORDER BY purchase_date;

SELECT fn_maize_rate('A') AS a, fn_maize_rate('B') AS b, fn_maize_rate('C') AS c;

DO $$ BEGIN PERFORM fn_maize_rate(NULL);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_maize_rate('D');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_delivery(99, 'A', 10, CURRENT_DATE);     -- unknown farmer
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_delivery(1, 'A', 0, CURRENT_DATE);       -- bad weight
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_delivery(1, 'Z', 10, CURRENT_DATE);      -- bad grade
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;

-- Direct SQL follows the same pricing rule, even if the caller supplies wrong values
INSERT INTO deliveries (farmer_id, grade, weight_kg, unit_rate, total_value, delivered_on)
VALUES (3, 'B', 10, 999, 999, CURRENT_DATE);
SELECT grade, weight_kg, unit_rate, total_value FROM deliveries ORDER BY delivery_id DESC LIMIT 1;  -- 4 and 40

DO $$ BEGIN
    INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on)
    VALUES (3, 'A', -5, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;

-- Changing the grade or weight re-prices the row
UPDATE deliveries SET grade = 'A' WHERE delivery_id = 3;
SELECT delivery_id, grade, weight_kg, unit_rate, total_value FROM deliveries WHERE delivery_id = 3;
