-- ============================================================
-- VIEW: vw_roll_rates
-- Purpose : Roll-rate matrix — month-over-month transition
--           probabilities between DPD buckets (Current, DPD1-29,
--           DPD30, DPD60, DPD90) using LAG() to compare each
--           loan's bucket against its own prior month.
-- Grain   : One row per (prior_bucket, current_bucket) pair
-- Usage   : Power BI roll-rate matrix page, collections
--           efficiency monitoring, early intervention triggers
-- ============================================================

CREATE OR REPLACE VIEW fintech_risk.vw_roll_rates AS

-- Query 1: DPD bucket assignment per loan per MOB
-- Every repayment row gets classified into exactly one bucket based on its dpd value.
-- These bucket boundaries must be mutually exclusive and collectively exhaustive —
-- every loan-month falls into exactly one bucket, no gaps, no overlaps.
WITH loan_buckets AS (
	SELECT
		l.loan_id,
		l.customer_id,
		DATE_TRUNC(l.disbursal_date, MONTH) AS cohort_month,
		r.repayment_id,
		r.due_date,
		r.dpd,
		DATE_DIFF(r.due_date, l.disbursal_date, MONTH) AS mob,
		CASE WHEN r.dpd = 0 THEN 'Current'
			 WHEN r.dpd BETWEEN 1 AND 29 THEN 'DPD1-29'
			 WHEN r.dpd BETWEEN 30 AND 59 THEN 'DPD30'
			 WHEN r.dpd BETWEEN 60 AND 89 THEN 'DPD60'
			 WHEN r.dpd >= 90 THEN 'DPD90'
		END AS dpd_bucket,
		CASE WHEN r.dpd = 0 THEN 0
			 WHEN r.dpd BETWEEN 1 AND 29 THEN 1
			 WHEN r.dpd BETWEEN 30 AND 59 THEN 2
			 WHEN r.dpd BETWEEN 60 AND 89 THEN 3
			 WHEN r.dpd >= 90 THEN 4
		END AS bucket_rank
	FROM fintech_risk.loans l
	JOIN fintech_risk.repayments r
	ON l.loan_id = r.loan_id
	WHERE DATE_DIFF(r.due_date, l.disbursal_date, MONTH) BETWEEN 1 AND 18
	ORDER BY l.loan_id, mob
),

-- Query 2: Pull prior MOB's bucket into the current row using LAG()
-- This is the single transformation that makes a "transition" visible.
-- Without LAG, each row is a snapshot. With LAG, each row becomes an edge
-- in the state machine: prior_bucket -> current_bucket.
loan_transitions AS (
	SELECT
		loan_id,
		customer_id,
		cohort_month,
		mob,
		dpd_bucket AS current_bucket,
		bucket_rank AS current_rank,
		LAG(dpd_bucket) OVER(PARTITION BY loan_id ORDER BY mob) AS prior_bucket,
		LAG(bucket_rank) OVER(PARTITION BY loan_id ORDER BY mob) AS prior_rank
	FROM loan_buckets
),

-- ── CTE 3: Filter to valid transitions only ─────────────────
-- MOB1 always has prior_bucket = NULL since there is no prior
-- month to compare against. These rows cannot be transitions
-- and must be excluded before any aggregation.
valid_transitions AS  (
	SELECT 
		*,
		CASE WHEN current_rank > prior_rank THEN 'roll_forward'
			 WHEN current_rank < prior_rank THEN 'cure'
			 ELSE 'stay' 
		END AS transition_type
	FROM loan_transitions
	WHERE prior_bucket IS NOT NULL
),

-- ── CTE 4: Denominator — total loan-months per starting bucket ─
-- This is the base every percentage in a prior_bucket's row
-- divides into. Calculated once, independent of which
-- current_bucket each loan ended up in.
bucket_totals AS (
	SELECT 
		prior_bucket,
        COUNT(*) AS total_in_bucket
	FROM valid_transitions
    GROUP BY prior_bucket
)

SELECT 
	vt.prior_bucket,
    vt.current_bucket,
    vt.transition_type,
    COUNT(*) AS transition_count,
    bt.total_in_bucket,
    ROUND(COUNT(*) * 100.0 / bt.total_in_bucket,2) AS transition_pct,
    CASE vt.prior_bucket 
		WHEN 'Current' THEN 0
        WHEN 'DPD1-29' THEN 1
        WHEN 'DPD30' THEN 2
        WHEN 'DPD60' THEN 3
        WHEN 'DPD90' THEN 4
	END AS prior_sort_order,
    CASE vt.current_bucket 
		WHEN 'Current' THEN 0
        WHEN 'DPD1-29' THEN 1
        WHEN 'DPD30' THEN 2
        WHEN 'DPD60' THEN 3
        WHEN 'DPD90' THEN 4
	END AS current_sort_order,
    CASE WHEN ABS(
		CASE vt.current_bucket WHEN 'Current' THEN 0 WHEN 'DPD1-29' THEN 1 WHEN 'DPD30' THEN 2 WHEN 'DPD60' THEN 3 ELSE 4 END -
        CASE vt.prior_bucket  WHEN 'Current' THEN 0 WHEN 'DPD1-29' THEN 1 WHEN 'DPD30' THEN 2 WHEN 'DPD60' THEN 3 ELSE 4 END
    )>1 THEN 1 ELSE 0 END AS is_multi_bucket_jump
FROM valid_transitions vt
JOIN bucket_totals bt
ON vt.prior_bucket = bt.prior_bucket
GROUP BY vt.prior_bucket, vt.current_bucket, vt.transition_type, bt.total_in_bucket
ORDER BY prior_sort_order, current_sort_order;