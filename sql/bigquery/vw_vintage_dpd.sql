-- ============================================================
-- VIEW: vw_vintage_dpd
-- Purpose : Vintage analysis — cumulative DPD30/60/90+ rate
--           per disbursal-month cohort × months on book (MOB)
-- Grain   : One row per cohort_month × mob (1 through 12)
-- Usage   : Power BI cohort heatmap, risk review decks,
--           underwriting policy monitoring
-- Updated : Append-safe — new repayment rows auto-reflect
--           in the view without any schema changes
-- ============================================================

CREATE OR REPLACE VIEW fintech_risk.vw_vintage_dpd AS


-- ── CTE 1: Cohort label + MOB per repayment row ─────────────
-- Joins loans to repayments and stamps each EMI row with:
--   cohort_month : first day of the disbursal month (GROUP BY key)
--   cohort_label : 'YYYY-MM' string for dashboard display
--   mob          : how many months old this loan was at due_date

WITH loan_mob AS (
    SELECT l.loan_id, l.credit_score_band, l.city,
        DATE_TRUNC(l.disbursal_date,MONTH)     AS cohort_month,
        FORMAT_DATE('%Y-%m',l.disbursal_date) AS cohort_label,
        r.repayment_id, r.dpd, r.paid_amount, r.emi_amount,
        DATE_DIFF(r.due_date,l.disbursal_date,MONTH) AS mob
    FROM fintech_risk.loans l JOIN fintech_risk.repayments r ON r.loan_id=l.loan_id
    WHERE DATE_DIFF(r.due_date,l.disbursal_date,MONTH) BETWEEN 1 AND 12
),

-- ── CTE 2: Cumulative DPD flags per loan per MOB ────────────
-- For each loan × MOB row, flags whether that loan has EVER
-- breached DPD30 / DPD60 / DPD90 at any point from MOB1
-- up to and including the current MOB.
-- MAX() as a window function over UNBOUNDED PRECEDING → CURRENT ROW
-- ensures the flag is sticky: once a loan hits DPD30+, it stays 1
-- for all subsequent MOBs even if the borrower self-cures.
-- All three thresholds computed in one pass — no repeated scans.

dpd_flags AS (
    SELECT *,
        MAX(CASE WHEN dpd>=30 THEN 1 ELSE 0 END) OVER(PARTITION BY loan_id ORDER BY mob ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS is_ever_dpd30,
        MAX(CASE WHEN dpd>=60 THEN 1 ELSE 0 END) OVER(PARTITION BY loan_id ORDER BY mob ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS is_ever_dpd60,
        MAX(CASE WHEN dpd>=90 THEN 1 ELSE 0 END) OVER(PARTITION BY loan_id ORDER BY mob ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS is_ever_dpd90
    FROM loan_mob
),

-- ── CTE 3: Fixed cohort denominators ────────────────────────
-- Cohort size is the total number of loans disbursed in that month.
-- This is the fixed denominator for every MOB in that cohort.
-- Calculated once here and joined in — never recalculated per MOB.
-- Using COUNT(DISTINCT loan_id) guards against any accidental
-- duplicate loan rows in the source table.

cohort_sizes AS (
    SELECT DATE_TRUNC(disbursal_date,MONTH) AS cohort_month,
           COUNT(DISTINCT loan_id) AS cohort_size,
           ROUND(AVG(loan_amount),0) AS avg_loan_amount
    FROM fintech_risk.loans GROUP BY 1
),

-- ── CTE 4: Cohort × MOB aggregation ─────────────────────────
-- Collapses dpd_flags to one row per cohort_month × mob.
-- SUM(is_ever_dpd30) counts loans that have ever been stressed
-- at or before this MOB — always an increasing number per cohort.

vintage_matrix AS (
    SELECT d.cohort_month, d.cohort_label, d.mob, cs.cohort_size, cs.avg_loan_amount,
        SUM(d.is_ever_dpd30) AS ever_dpd30_count,
        ROUND(SUM(d.is_ever_dpd30)/cs.cohort_size*100,2) AS dpd30_rate_pct,
        ROUND(SUM(d.is_ever_dpd60)/cs.cohort_size*100,2) AS dpd60_rate_pct,
        ROUND(SUM(d.is_ever_dpd90)/cs.cohort_size*100,2) AS dpd90_rate_pct,
        ROUND(COUNTIF(d.paid_amount<d.emi_amount*0.95)/COUNT(d.repayment_id)*100,2) AS partial_pay_rate_pct,
        ROUND(AVG(d.dpd),1) AS avg_dpd
    FROM dpd_flags d JOIN cohort_sizes cs ON cs.cohort_month=d.cohort_month
    GROUP BY d.cohort_month,d.cohort_label,d.mob,cs.cohort_size,cs.avg_loan_amount
)

-- ── Final SELECT ─────────────────────────────────────────────
-- Adds two derived columns that are useful in Power BI
--
--   mob_label      : 'MOB01' .. 'MOB12' — sorts correctly as a string
--                    because of zero-padding (MOB09 < MOB10, not MOB9 > MOB10)
--
--   is_mature      : 1 if this cohort has reached MOB12, 0 if still growing.
--                    Use this in Power BI to grey out or filter immature cohorts
--                    so stakeholders don't compare a MOB4 cohort to a MOB12 one.
--
--   mom_dpd30_delta: month-over-month change in dpd30_rate_pct for this cohort.
--                    Positive = getting worse. Useful for early warning alerts.

SELECT *,
    CONCAT('MOB',LPAD(CAST(mob AS STRING),2,'0')) AS mob_label,
    ROUND(dpd30_rate_pct-LAG(dpd30_rate_pct) OVER(PARTITION BY cohort_month ORDER BY mob),2) AS mom_dpd30_delta,
    CASE WHEN MAX(mob) OVER(PARTITION BY cohort_month)=12 THEN 1 ELSE 0 END AS is_mature
FROM vintage_matrix ORDER BY cohort_month, mob