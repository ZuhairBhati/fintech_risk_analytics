
# 1. Which cohort is the worst performer at MOB6?
SELECT 
	cohort_label,
    cohort_size,
    dpd30_rate_pct,
    dpd60_rate_pct,
    dpd90_rate_pct
FROM fintech_risk.vw_vintage_dpd
WHERE mob = 6
AND is_mature = 1
ORDER BY dpd30_rate_pct DESC;

# 2. Is the portfolio getting better or worse over time? (MOB Trend)
SELECT
	cohort_label,
    dpd30_rate_pct AS mob6_dpd30,
    LAG(dpd30_rate_pct) OVER(ORDER BY cohort_month) AS prev_cohort_mob,
    ROUND(dpd30_rate_pct - LAG(dpd30_rate_pct) OVER (ORDER BY cohort_month),2) AS delta_vs_prev_cohort
FROM fintech_risk.vw_vintage_dpd
WHERE mob = 6 
AND is_mature = 1
ORDER BY cohort_month;

# 3. DPD30 → NPA roll-through rate
SELECT
	cohort_label,
    dpd30_rate_pct AS mob12_dpd30,
    dpd90_rate_pct AS mob12_dpd90,
    ROUND(dpd90_rate_pct / NULLIF(dpd30_rate_pct,0) * 100,1) AS pct_rolling_to_npa
FROM fintech_risk.vw_vintage_dpd
WHERE mob = 12 
AND is_mature = 1
ORDER BY pct_rolling_to_npa DESC;

# 4. Partial payment leading indicator - as early warning signal
SELECT 
	cohort_label, 
    mob, 
    partial_pay_rate_pct, 
    dpd30_rate_pct,
    CASE WHEN partial_pay_rate_pct>dpd30_rate_pct*2 THEN 'early_warning' ELSE 'normal' END AS flag
FROM vw_vintage_dpd 
WHERE mob BETWEEN 2 AND 6 
ORDER BY mob;

# 5. Fastest deteriorating immature cohort (MoM acceleration)
SELECT 
	cohort_label, 
    mob, 
    dpd30_rate_pct, 
    mom_dpd30_delta
FROM vw_vintage_dpd 
WHERE is_mature=0 AND mob>=2
ORDER BY mom_dpd30_delta DESC 
LIMIT 10;