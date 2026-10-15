/* =====================================================================
   CMPG321 2026 - Group 36 (DormToDorm) - Phase 2
   Script 04: Analytical query set - answers research questions RQ1-RQ19
   Focus area: Rider Purchasing Patterns & Payment Channel Preferences
   Each block starts with a "-- #### Qnn" marker so it can be run on its own.
   Definitions used throughout:
     settled revenue  = SUM(gross_fare_zar) where payment_status = 'Settled'
     request          = one row in ride.trip, whatever its outcome
   ===================================================================== */
USE DormToDorm_RideDB;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

-- #### Q01  RQ1 - Payment mix: share of requests and settled revenue, per platform and overall
-- Techniques: 4-table join, LEFT OUTER JOIN, conditional aggregation, GROUPING SETS, window SUM() OVER
WITH mix AS (
    SELECT p.method_name,
           ISNULL(rc.platform, 'All')                                             AS platform,
           COUNT(*)                                                               AS requests,
           SUM(CASE WHEN t.trip_status = 'Completed' THEN 1 ELSE 0 END)           AS completed_trips,
           SUM(CASE WHEN f.payment_status = 'Settled' THEN f.gross_fare_zar ELSE 0 END) AS settled_revenue_zar
    FROM ride.trip t
    JOIN ride.payment_method p  ON p.payment_method_id = t.payment_method_id
    JOIN ride.ride_category rc  ON rc.ride_category_id = t.ride_category_id
    LEFT JOIN ride.trip_fare f  ON f.trip_id = t.trip_id
    GROUP BY GROUPING SETS ((p.method_name, rc.platform), (p.method_name))
)
SELECT platform, method_name, requests,
       CAST(100.0 * requests / SUM(requests) OVER (PARTITION BY platform) AS DECIMAL(5,2))                       AS pct_of_requests,
       CAST(100.0 * completed_trips / requests AS DECIMAL(5,2))                                                  AS completion_rate_pct,
       settled_revenue_zar,
       CAST(100.0 * settled_revenue_zar / SUM(settled_revenue_zar) OVER (PARTITION BY platform) AS DECIMAL(5,2)) AS pct_of_settled_revenue
FROM mix
ORDER BY CASE platform WHEN 'All' THEN 0 WHEN 'Uber' THEN 1 ELSE 2 END, settled_revenue_zar DESC;
GO

-- #### Q02  RQ2 - Cash dependency by city and by pickup-zone type, ranked
-- Techniques: 5-table join (role-playing zone dimension), GROUPING SETS + GROUPING(), HAVING, RANK()
SELECT CASE WHEN GROUPING(c.city_name) = 0 THEN 'City' ELSE 'Zone type' END             AS grouping_level,
       COALESCE(c.city_name, z.zone_type)                                                AS segment,
       COUNT(*)                                                                          AS requests,
       CAST(100.0 * SUM(CASE WHEN p.is_digital = 0 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS cash_share_pct,
       CAST(AVG(z.avg_driver_supply_index) AS DECIMAL(4,2))                              AS avg_supply_index,
       CAST(AVG(CASE WHEN f.payment_status = 'Settled' THEN f.gross_fare_zar END) AS DECIMAL(8,2)) AS avg_settled_fare_zar,
       RANK() OVER (PARTITION BY GROUPING(c.city_name)
                    ORDER BY 1.0 * SUM(CASE WHEN p.is_digital = 0 THEN 1 ELSE 0 END) / COUNT(*) DESC) AS cash_rank
FROM ride.trip t
JOIN ride.zone z            ON z.zone_id = t.pickup_zone_id
JOIN ride.city c            ON c.city_id = z.city_id
JOIN ride.payment_method p  ON p.payment_method_id = t.payment_method_id
LEFT JOIN ride.trip_fare f  ON f.trip_id = t.trip_id
GROUP BY GROUPING SETS ((c.city_name), (z.zone_type))
HAVING COUNT(*) >= 500
ORDER BY grouping_level, cash_rank;
GO

-- #### Q02b RQ2 - Migration readiness per city: cash share vs the failure rate riders would face on digital
-- Techniques: CTE, conditional aggregation over a role split (cash vs digital), derived "readiness" metric, ROW_NUMBER()
WITH city_pay AS (
    SELECT c.city_name, pr.province_name,
           COUNT(*)                                                                         AS requests,
           SUM(CASE WHEN p.is_digital = 0 THEN 1 ELSE 0 END)                                AS cash_requests,
           SUM(CASE WHEN p.channel_group = 'Card' THEN 1 ELSE 0 END)                        AS card_requests,
           SUM(CASE WHEN p.channel_group = 'Card' AND t.trip_status = 'Payment Failed' THEN 1 ELSE 0 END) AS card_failures,
           SUM(CASE WHEN p.channel_group IN ('Mobile Wallet','In-App Wallet') THEN 1 ELSE 0 END) AS wallet_requests,
           SUM(CASE WHEN p.channel_group IN ('Mobile Wallet','In-App Wallet') AND t.trip_status = 'Payment Failed' THEN 1 ELSE 0 END) AS wallet_failures
    FROM ride.trip t
    JOIN ride.zone z            ON z.zone_id = t.pickup_zone_id
    JOIN ride.city c            ON c.city_id = z.city_id
    JOIN ride.province pr       ON pr.province_code = c.province_code
    JOIN ride.payment_method p  ON p.payment_method_id = t.payment_method_id
    GROUP BY c.city_name, pr.province_name
)
SELECT ROW_NUMBER() OVER (ORDER BY 1.0 * cash_requests / requests DESC)          AS priority,
       city_name, province_name, requests, cash_requests,
       CAST(100.0 * cash_requests / requests AS DECIMAL(5,2))                    AS cash_share_pct,
       CAST(100.0 * card_failures / NULLIF(card_requests, 0) AS DECIMAL(5,2))    AS card_failure_pct,
       CAST(100.0 * wallet_failures / NULLIF(wallet_requests, 0) AS DECIMAL(5,2)) AS wallet_failure_pct,
       CAST(1.0 * cash_requests * (1.0 * card_failures / NULLIF(card_requests, 0)
                                 - 1.0 * wallet_failures / NULLIF(wallet_requests, 0)) AS DECIMAL(8,1)) AS failures_avoided_wallet_vs_card
FROM city_pay
ORDER BY priority;
GO

-- #### Q03  RQ3 - Stated vs revealed cash preference by rider demographic (ROLLUP-style grouping sets)
-- Techniques: derived table (pre-aggregated trip behaviour), LEFT JOIN, GROUPING SETS with grand total, GROUPING_ID()
WITH rider_behaviour AS (
    SELECT t.rider_id,
           COUNT(*)                                                     AS requests,
           SUM(CASE WHEN p.is_digital = 0 THEN 1 ELSE 0 END)            AS cash_requests
    FROM ride.trip t
    JOIN ride.payment_method p ON p.payment_method_id = t.payment_method_id
    GROUP BY t.rider_id
)
SELECT CASE GROUPING_ID(r.age_band, r.loyalty_tier, r.rider_segment, r.gender)
            WHEN 7  THEN 'Age band' WHEN 11 THEN 'Loyalty tier' WHEN 13 THEN 'Rider segment'
            WHEN 14 THEN 'Gender'   ELSE 'All riders' END                                    AS dimension,
       COALESCE(r.age_band, r.loyalty_tier, r.rider_segment, r.gender, 'Total')              AS dimension_value,
       COUNT(*)                                                                               AS riders,
       CAST(100.0 * SUM(CASE WHEN pp.method_name = 'Cash' THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2))     AS stated_cash_pref_pct,
       CAST(100.0 * SUM(CASE WHEN pp.channel_group = 'Card' THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2))   AS stated_card_pref_pct,
       CAST(100.0 * SUM(CASE WHEN pp.channel_group IN ('Mobile Wallet','QR Code','In-App Wallet') THEN 1 ELSE 0 END)
            / COUNT(*) AS DECIMAL(5,2))                                                                     AS stated_wallet_qr_pref_pct,
       CAST(100.0 * SUM(rb.cash_requests) / NULLIF(SUM(rb.requests), 0) AS DECIMAL(5,2))                    AS revealed_cash_share_pct
FROM ride.rider r
JOIN ride.payment_method pp    ON pp.payment_method_id = r.preferred_payment_method_id
LEFT JOIN rider_behaviour rb   ON rb.rider_id = r.rider_id
GROUP BY GROUPING SETS ((r.age_band), (r.loyalty_tier), (r.rider_segment), (r.gender), ())
ORDER BY dimension, dimension_value;
GO

-- #### Q04  RQ4 - Substitution matrix: stated preference (rows) vs instrument actually used (columns), row %
-- Techniques: self-referencing lookup join (payment_method used twice), window SUM, PIVOT operator
WITH pairs AS (
    SELECT pp.method_name AS preferred_method, up.method_name AS used_method, COUNT(*) AS n
    FROM ride.trip t
    JOIN ride.rider r            ON r.rider_id = t.rider_id
    JOIN ride.payment_method pp  ON pp.payment_method_id = r.preferred_payment_method_id
    JOIN ride.payment_method up  ON up.payment_method_id = t.payment_method_id
    GROUP BY pp.method_name, up.method_name
), pct AS (
    SELECT preferred_method, used_method,
           CAST(100.0 * n / SUM(n) OVER (PARTITION BY preferred_method) AS DECIMAL(5,1)) AS row_pct
    FROM pairs
)
SELECT preferred_method, [Cash], [Credit Card], [Debit Card], [In-App Wallet], [SnapScan], [Zapper], [Apple Pay], [Google Pay]
FROM pct
PIVOT (MAX(row_pct) FOR used_method IN ([Cash], [Credit Card], [Debit Card], [In-App Wallet],
                                        [SnapScan], [Zapper], [Apple Pay], [Google Pay])) AS pv
ORDER BY [Cash] DESC;
GO

-- #### Q04b RQ4 - Headline: share of requests made on the stated preferred instrument
SELECT COUNT(*) AS requests,
       SUM(CASE WHEN t.payment_method_id = r.preferred_payment_method_id THEN 1 ELSE 0 END) AS on_preferred,
       CAST(100.0 * SUM(CASE WHEN t.payment_method_id = r.preferred_payment_method_id THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS match_rate_pct,
       CAST(100.0 * SUM(CASE WHEN pp.is_digital = 0 AND up.is_digital = 1 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS cash_pref_paid_digital_pct,
       CAST(100.0 * SUM(CASE WHEN pp.is_digital = 1 AND up.is_digital = 0 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS digital_pref_paid_cash_pct
FROM ride.trip t
JOIN ride.rider r           ON r.rider_id = t.rider_id
JOIN ride.payment_method pp ON pp.payment_method_id = r.preferred_payment_method_id
JOIN ride.payment_method up ON up.payment_method_id = t.payment_method_id;
GO

-- #### Q05  RQ5 - Migration: first vs last instrument for riders who used more than one instrument
-- Techniques: FIRST_VALUE / LAST_VALUE with explicit window frame, COUNT(DISTINCT) filter in CTE, CASE classification
WITH ordered AS (
    SELECT t.rider_id,
           FIRST_VALUE(p.is_digital) OVER (PARTITION BY t.rider_id ORDER BY t.request_timestamp
                                           ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS first_is_digital,
           LAST_VALUE(p.is_digital)  OVER (PARTITION BY t.rider_id ORDER BY t.request_timestamp
                                           ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS last_is_digital
    FROM ride.trip t
    JOIN ride.payment_method p ON p.payment_method_id = t.payment_method_id
), per_rider AS (
    SELECT DISTINCT rider_id, first_is_digital, last_is_digital FROM ordered
), multi AS (
    SELECT rider_id FROM ride.trip GROUP BY rider_id HAVING COUNT(DISTINCT payment_method_id) > 1
)
SELECT CASE WHEN pr.first_is_digital = 0 AND pr.last_is_digital = 1 THEN 'Cash -> Digital'
            WHEN pr.first_is_digital = 1 AND pr.last_is_digital = 0 THEN 'Digital -> Cash'
            WHEN pr.first_is_digital = 0 THEN 'Cash -> Cash'
            ELSE 'Digital -> Digital' END                         AS transition,
       COUNT(*)                                                    AS riders,
       CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,2)) AS pct_of_multi_instrument_riders
FROM per_rider pr
JOIN multi m ON m.rider_id = pr.rider_id
GROUP BY CASE WHEN pr.first_is_digital = 0 AND pr.last_is_digital = 1 THEN 'Cash -> Digital'
              WHEN pr.first_is_digital = 1 AND pr.last_is_digital = 0 THEN 'Digital -> Cash'
              WHEN pr.first_is_digital = 0 THEN 'Cash -> Cash'
              ELSE 'Digital -> Digital' END
ORDER BY riders DESC;
GO

-- #### Q05b RQ5 - Monthly cash share trend with month-on-month change
-- Techniques: date truncation, LAG() window, running (cumulative) average window frame
WITH monthly AS (
    SELECT DATEFROMPARTS(YEAR(t.request_date), MONTH(t.request_date), 1) AS month_start,
           COUNT(*) AS requests,
           100.0 * SUM(CASE WHEN p.is_digital = 0 THEN 1 ELSE 0 END) / COUNT(*) AS cash_share_pct
    FROM ride.trip t
    JOIN ride.payment_method p ON p.payment_method_id = t.payment_method_id
    GROUP BY DATEFROMPARTS(YEAR(t.request_date), MONTH(t.request_date), 1)
)
SELECT FORMAT(month_start, 'yyyy-MM') AS month, requests,
       CAST(cash_share_pct AS DECIMAL(5,2))                                                         AS cash_share_pct,
       CAST(cash_share_pct - LAG(cash_share_pct) OVER (ORDER BY month_start) AS DECIMAL(5,2))       AS mom_change_pp,
       CAST(AVG(cash_share_pct) OVER (ORDER BY month_start ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) AS DECIMAL(5,2)) AS rolling_3m_cash_pct
FROM monthly
ORDER BY month_start;
GO

-- #### Q06  RQ6 - Fare distribution per settled trip by province (quartiles, median)
-- Techniques: PERCENTILE_CONT ... WITHIN GROUP ... OVER (PARTITION BY), DISTINCT over window results
SELECT DISTINCT pr.province_name,
       COUNT(*)                     OVER (PARTITION BY pr.province_name)                                    AS settled_trips,
       CAST(AVG(f.gross_fare_zar)   OVER (PARTITION BY pr.province_name) AS DECIMAL(8,2))                   AS mean_fare_zar,
       CAST(PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY f.gross_fare_zar) OVER (PARTITION BY pr.province_name) AS DECIMAL(8,2)) AS p25_zar,
       CAST(PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY f.gross_fare_zar) OVER (PARTITION BY pr.province_name) AS DECIMAL(8,2)) AS median_zar,
       CAST(PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY f.gross_fare_zar) OVER (PARTITION BY pr.province_name) AS DECIMAL(8,2)) AS p75_zar,
       CAST(PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY f.gross_fare_zar) OVER (PARTITION BY pr.province_name) AS DECIMAL(8,2)) AS p90_zar,
       CAST(SUM(f.gross_fare_zar)   OVER (PARTITION BY pr.province_name)
            / SUM(t.trip_distance_km) OVER (PARTITION BY pr.province_name) AS DECIMAL(6,2))                AS zar_per_km
FROM ride.trip_fare f
JOIN ride.trip t      ON t.trip_id = f.trip_id
JOIN ride.zone z      ON z.zone_id = t.pickup_zone_id
JOIN ride.city c      ON c.city_id = z.city_id
JOIN ride.province pr ON pr.province_code = c.province_code
WHERE f.payment_status = 'Settled'
ORDER BY median_zar DESC;
GO

-- #### Q06b RQ6 - Fare distribution per settled trip by ride category
SELECT DISTINCT rc.platform, rc.category_name, rc.service_tier,
       COUNT(*) OVER (PARTITION BY rc.category_name)                                                         AS settled_trips,
       CAST(PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY f.gross_fare_zar) OVER (PARTITION BY rc.category_name) AS DECIMAL(8,2)) AS p25_zar,
       CAST(PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY f.gross_fare_zar) OVER (PARTITION BY rc.category_name) AS DECIMAL(8,2)) AS median_zar,
       CAST(PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY f.gross_fare_zar) OVER (PARTITION BY rc.category_name) AS DECIMAL(8,2)) AS p75_zar,
       CAST(AVG(f.gross_fare_zar) OVER (PARTITION BY rc.category_name) AS DECIMAL(8,2))                       AS mean_fare_zar
FROM ride.trip_fare f
JOIN ride.trip t           ON t.trip_id = f.trip_id
JOIN ride.ride_category rc ON rc.ride_category_id = t.ride_category_id
WHERE f.payment_status = 'Settled'
ORDER BY median_zar;
GO

-- #### Q07  RQ7 - Fare composition (% of gross fare) by service tier
-- Techniques: multi-column aggregation, ratio-of-sums, CROSS APPLY to unpivot components for charting
SELECT rc.service_tier,
       COUNT(*) AS settled_trips,
       CAST(100.0 * SUM(f.base_fare_zar)       / SUM(f.gross_fare_zar) AS DECIMAL(5,2)) AS base_pct,
       CAST(100.0 * SUM(f.distance_charge_zar) / SUM(f.gross_fare_zar) AS DECIMAL(5,2)) AS distance_pct,
       CAST(100.0 * SUM(f.time_charge_zar)     / SUM(f.gross_fare_zar) AS DECIMAL(5,2)) AS time_pct,
       CAST(100.0 * SUM(f.surge_premium_zar)   / SUM(f.gross_fare_zar) AS DECIMAL(5,2)) AS surge_pct,
       CAST(100.0 * SUM(f.booking_fee_zar)     / SUM(f.gross_fare_zar) AS DECIMAL(5,2)) AS booking_pct,
       CAST(100.0 * SUM(f.toll_fee_zar)        / SUM(f.gross_fare_zar) AS DECIMAL(5,2)) AS toll_pct,
       CAST(100.0 * SUM(f.waiting_charge_zar)  / SUM(f.gross_fare_zar) AS DECIMAL(5,2)) AS waiting_pct,
       CAST(100.0 * SUM(f.tip_amount_zar)      / SUM(f.gross_fare_zar) AS DECIMAL(5,2)) AS tip_pct,
       CAST(-100.0 * SUM(f.promo_discount_zar) / SUM(f.gross_fare_zar) AS DECIMAL(5,2)) AS promo_pct,
       CAST(AVG(f.gross_fare_zar) AS DECIMAL(8,2))                                      AS avg_gross_zar
FROM ride.trip_fare f
JOIN ride.trip t           ON t.trip_id = f.trip_id
JOIN ride.ride_category rc ON rc.ride_category_id = t.ride_category_id
WHERE f.payment_status = 'Settled'
GROUP BY rc.service_tier
ORDER BY avg_gross_zar;
GO

-- #### Q08  RQ8 - Spend efficiency (R/km) by distance band, with marginal change between bands
-- Techniques: CASE bucketing inside CROSS APPLY, ratio-of-sums, LAG() to find where R/km stops falling
WITH banded AS (
    SELECT b.band_no, b.band_label, t.trip_distance_km, f.gross_fare_zar - f.tip_amount_zar AS fare_ex_tip
    FROM ride.trip_fare f
    JOIN ride.trip t ON t.trip_id = f.trip_id
    CROSS APPLY (SELECT CASE WHEN t.trip_distance_km < 2  THEN 1 WHEN t.trip_distance_km < 5  THEN 2
                             WHEN t.trip_distance_km < 10 THEN 3 WHEN t.trip_distance_km < 15 THEN 4
                             WHEN t.trip_distance_km < 20 THEN 5 WHEN t.trip_distance_km < 30 THEN 6
                             WHEN t.trip_distance_km < 50 THEN 7 ELSE 8 END AS band_no) n
    CROSS APPLY (SELECT CHOOSE(n.band_no, '0-2 km','2-5 km','5-10 km','10-15 km','15-20 km','20-30 km','30-50 km','50+ km') AS band_label,
                        n.band_no) b
    WHERE f.payment_status = 'Settled'
)
SELECT band_label, COUNT(*) AS settled_trips,
       CAST(AVG(fare_ex_tip) AS DECIMAL(8,2))                                   AS avg_fare_ex_tip_zar,
       CAST(SUM(fare_ex_tip) / SUM(trip_distance_km) AS DECIMAL(6,2))           AS zar_per_km,
       CAST(SUM(fare_ex_tip) / SUM(trip_distance_km)
            - LAG(SUM(fare_ex_tip) / SUM(trip_distance_km)) OVER (ORDER BY band_no) AS DECIMAL(6,2)) AS change_vs_prev_band
FROM banded
GROUP BY band_no, band_label
ORDER BY band_no;
GO

-- #### Q09  RQ9 - Spend by hour of day (all requests and settled spend)
-- Techniques: persisted computed column (indexed), LEFT JOIN, HAVING minimum volume
SELECT t.hour_of_day,
       COUNT(*)                                                                         AS requests,
       SUM(CASE WHEN f.payment_status = 'Settled' THEN 1 ELSE 0 END)                    AS settled_trips,
       CAST(AVG(CASE WHEN f.payment_status = 'Settled' THEN f.gross_fare_zar END) AS DECIMAL(8,2)) AS avg_settled_fare_zar,
       CAST(SUM(CASE WHEN f.payment_status = 'Settled' THEN f.gross_fare_zar ELSE 0 END) AS DECIMAL(12,2)) AS settled_revenue_zar,
       CAST(AVG(t.surge_multiplier) AS DECIMAL(4,2))                                   AS avg_surge
FROM ride.trip t
LEFT JOIN ride.trip_fare f ON f.trip_id = t.trip_id
GROUP BY t.hour_of_day
HAVING COUNT(*) >= 100
ORDER BY t.hour_of_day;
GO

-- #### Q09b RQ9 - Top 10 highest-value day x hour windows (minimum 150 settled trips)
-- Techniques: GROUP BY on two computed columns, HAVING, DENSE_RANK(), CHOOSE() for labels
WITH win AS (
    SELECT t.day_of_week_no, t.hour_of_day, COUNT(*) AS settled_trips,
           AVG(f.gross_fare_zar) AS avg_fare, SUM(f.gross_fare_zar) AS revenue
    FROM ride.trip t
    JOIN ride.trip_fare f ON f.trip_id = t.trip_id AND f.payment_status = 'Settled'
    GROUP BY t.day_of_week_no, t.hour_of_day
    HAVING COUNT(*) >= 150
)
SELECT TOP (10)
       DENSE_RANK() OVER (ORDER BY revenue DESC)                                                       AS revenue_rank,
       CHOOSE(day_of_week_no, 'Mon','Tue','Wed','Thu','Fri','Sat','Sun')                              AS day_name,
       FORMAT(hour_of_day, '00') + ':00'                                                               AS hour_start,
       settled_trips, CAST(avg_fare AS DECIMAL(8,2)) AS avg_fare_zar, CAST(revenue AS DECIMAL(12,2)) AS revenue_zar
FROM win
ORDER BY revenue DESC;
GO

-- #### Q09c RQ9 - Weekday vs weekend vs public holiday (supplementary holiday table)
-- Techniques: LEFT JOIN to supplementary reference table, CASE precedence, per-day normalisation with COUNT(DISTINCT)
SELECT CASE WHEN h.holiday_date IS NOT NULL THEN 'Public holiday'
            WHEN t.is_weekend = 1           THEN 'Weekend'
            ELSE 'Weekday' END                                                         AS day_type,
       COUNT(DISTINCT t.request_date)                                                  AS calendar_days,
       COUNT(*)                                                                        AS requests,
       CAST(1.0 * COUNT(*) / COUNT(DISTINCT t.request_date) AS DECIMAL(8,1))           AS requests_per_day,
       CAST(AVG(CASE WHEN f.payment_status = 'Settled' THEN f.gross_fare_zar END) AS DECIMAL(8,2)) AS avg_settled_fare_zar,
       CAST(100.0 * SUM(CASE WHEN p.is_digital = 0 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2))  AS cash_share_pct
FROM ride.trip t
JOIN ride.payment_method p     ON p.payment_method_id = t.payment_method_id
LEFT JOIN ride.public_holiday h ON h.holiday_date = t.request_date
LEFT JOIN ride.trip_fare f      ON f.trip_id = t.trip_id
GROUP BY CASE WHEN h.holiday_date IS NOT NULL THEN 'Public holiday'
              WHEN t.is_weekend = 1           THEN 'Weekend'
              ELSE 'Weekday' END;
GO

-- #### Q10  RQ10 - Revenue concentration by rider spend decile
-- Techniques: CTE, NTILE(10), window SUM for share and cumulative share
WITH spend AS (
    SELECT t.rider_id, SUM(f.gross_fare_zar) AS lifetime_spend, COUNT(*) AS settled_trips
    FROM ride.trip t
    JOIN ride.trip_fare f ON f.trip_id = t.trip_id
    WHERE f.payment_status = 'Settled'
    GROUP BY t.rider_id
), dec AS (
    SELECT *, NTILE(10) OVER (ORDER BY lifetime_spend DESC) AS spend_decile FROM spend
)
SELECT spend_decile, COUNT(*) AS riders,
       CAST(AVG(lifetime_spend) AS DECIMAL(10,2))                                                     AS avg_spend_zar,
       CAST(AVG(1.0 * settled_trips) AS DECIMAL(6,1))                                                 AS avg_trips,
       CAST(100.0 * SUM(lifetime_spend) / SUM(SUM(lifetime_spend)) OVER () AS DECIMAL(5,2))           AS pct_of_revenue,
       CAST(100.0 * SUM(SUM(lifetime_spend)) OVER (ORDER BY spend_decile ROWS UNBOUNDED PRECEDING)
            / SUM(SUM(lifetime_spend)) OVER () AS DECIMAL(5,2))                                        AS cumulative_pct
FROM dec
GROUP BY spend_decile
ORDER BY spend_decile;
GO

-- #### Q10b RQ10 - Profile of the top decile vs the rest
-- Techniques: CTE reuse, join back to dimension, conditional aggregation, comparison of two cohorts
WITH spend AS (
    SELECT t.rider_id, SUM(f.gross_fare_zar) AS lifetime_spend, COUNT(*) AS settled_trips,
           SUM(CASE WHEN t.is_airport_trip = 1 THEN 1 ELSE 0 END) AS airport_trips
    FROM ride.trip t
    JOIN ride.trip_fare f ON f.trip_id = t.trip_id
    WHERE f.payment_status = 'Settled'
    GROUP BY t.rider_id
), dec AS (
    SELECT *, NTILE(10) OVER (ORDER BY lifetime_spend DESC) AS spend_decile FROM spend
)
SELECT CASE WHEN d.spend_decile = 1 THEN 'Top 10%' ELSE 'Other 90%' END                       AS cohort,
       COUNT(*)                                                                               AS riders,
       CAST(AVG(1.0 * d.settled_trips) AS DECIMAL(6,1))                                       AS avg_trips,
       CAST(SUM(d.lifetime_spend) / SUM(d.settled_trips) AS DECIMAL(8,2))                     AS avg_fare_zar,
       CAST(100.0 * SUM(d.airport_trips) / SUM(d.settled_trips) AS DECIMAL(5,2))              AS airport_trip_pct,
       CAST(100.0 * SUM(CASE WHEN r.rider_segment = 'Frequent'  THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS frequent_pct,
       CAST(100.0 * SUM(CASE WHEN r.rider_segment = 'Corporate' THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS corporate_pct,
       CAST(100.0 * SUM(CASE WHEN r.loyalty_tier IN ('Gold','Platinum') THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS gold_plat_pct,
       CAST(100.0 * SUM(CASE WHEN pp.is_digital = 0 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS cash_pref_pct
FROM dec d
JOIN ride.rider r           ON r.rider_id = d.rider_id
JOIN ride.payment_method pp ON pp.payment_method_id = r.preferred_payment_method_id
GROUP BY CASE WHEN d.spend_decile = 1 THEN 'Top 10%' ELSE 'Other 90%' END;
GO

-- #### Q11  RQ11 - Airport vs non-airport trips
-- Techniques: LEFT JOIN, conditional aggregates for rates, NULLIF divide-by-zero guard
SELECT CASE t.is_airport_trip WHEN 1 THEN 'Airport' ELSE 'Non-airport' END                    AS trip_type,
       COUNT(*)                                                                               AS requests,
       CAST(AVG(t.trip_distance_km) AS DECIMAL(6,2))                                          AS avg_km,
       CAST(AVG(CASE WHEN f.payment_status = 'Settled' THEN f.gross_fare_zar END) AS DECIMAL(8,2)) AS avg_settled_fare_zar,
       CAST(100.0 * SUM(CASE WHEN p.is_digital = 1 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2))  AS digital_share_pct,
       CAST(100.0 * SUM(CASE WHEN f.payment_status = 'Settled' AND f.tip_amount_zar > 0 THEN 1 ELSE 0 END)
            / NULLIF(SUM(CASE WHEN f.payment_status = 'Settled' THEN 1 ELSE 0 END), 0) AS DECIMAL(5,2)) AS tip_rate_pct,
       CAST(100.0 * SUM(CASE WHEN t.trip_status = 'Payment Failed' THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS payment_fail_pct,
       CAST(100.0 * SUM(CASE WHEN t.trip_status = 'Completed' THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2))      AS completion_pct
FROM ride.trip t
JOIN ride.payment_method p ON p.payment_method_id = t.payment_method_id
LEFT JOIN ride.trip_fare f ON f.trip_id = t.trip_id
GROUP BY t.is_airport_trip;
GO

-- #### Q12  RQ12 - Tip attachment and value by payment method, and impact on driver take-home
-- Techniques: conditional aggregation, zero-inflation handled (avg tip when tipped vs per trip), window AVG baseline
SELECT p.method_name,
       COUNT(*)                                                                                AS settled_trips,
       CAST(100.0 * SUM(CASE WHEN f.tip_amount_zar > 0 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS tip_attach_pct,
       CAST(AVG(CASE WHEN f.tip_amount_zar > 0 THEN f.tip_amount_zar END) AS DECIMAL(6,2))     AS avg_tip_when_tipped_zar,
       CAST(AVG(f.tip_amount_zar) AS DECIMAL(6,2))                                             AS avg_tip_per_trip_zar,
       CAST(100.0 * SUM(f.tip_amount_zar) / SUM(f.driver_net_payout_zar) AS DECIMAL(5,2))      AS tips_pct_of_driver_payout,
       CAST(AVG(f.tip_amount_zar) - AVG(AVG(f.tip_amount_zar)) OVER () AS DECIMAL(6,2))        AS diff_vs_avg_method_zar
FROM ride.trip_fare f
JOIN ride.trip t           ON t.trip_id = f.trip_id
JOIN ride.payment_method p ON p.payment_method_id = t.payment_method_id
WHERE f.payment_status = 'Settled'
GROUP BY p.method_name
ORDER BY tip_attach_pct DESC;
GO

-- #### Q13  RQ13 - Tip rate by rating given, controlled for cash vs digital
-- Techniques: 4-table INNER join (only reviewed trips), PIVOT of rating into columns
WITH base AS (
    SELECT CASE p.is_digital WHEN 1 THEN 'Digital' ELSE 'Cash' END AS channel,
           rv.rating_given,
           CASE WHEN f.tip_amount_zar > 0 THEN 100.0 ELSE 0.0 END AS tipped_pct
    FROM ride.trip_review rv
    JOIN ride.trip t           ON t.trip_id = rv.trip_id
    JOIN ride.trip_fare f      ON f.trip_id = t.trip_id AND f.payment_status = 'Settled'
    JOIN ride.payment_method p ON p.payment_method_id = t.payment_method_id
)
SELECT channel,
       CAST([1] AS DECIMAL(5,2)) AS rating_1, CAST([2] AS DECIMAL(5,2)) AS rating_2, CAST([3] AS DECIMAL(5,2)) AS rating_3,
       CAST([4] AS DECIMAL(5,2)) AS rating_4, CAST([5] AS DECIMAL(5,2)) AS rating_5
FROM base
PIVOT (AVG(tipped_pct) FOR rating_given IN ([1],[2],[3],[4],[5])) pv
ORDER BY channel;
GO

-- #### Q13b RQ13 - Review volume and average tip value by rating
SELECT rv.rating_given, COUNT(*) AS reviewed_trips,
       CAST(AVG(f.tip_amount_zar) AS DECIMAL(6,2)) AS avg_tip_zar,
       CAST(100.0 * SUM(CASE WHEN f.tip_amount_zar > 0 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS tip_rate_pct,
       CAST(100.0 * SUM(CASE WHEN rv.review_category = 'Pricing & Payment' THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS pricing_payment_review_pct
FROM ride.trip_review rv
JOIN ride.trip_fare f ON f.trip_id = rv.trip_id AND f.payment_status = 'Settled'
GROUP BY rv.rating_given
ORDER BY rv.rating_given;
GO

-- #### Q14  RQ14 - Does surge suppress tipping? Tip rate per surge band vs a no-surge baseline subquery
-- Techniques: CASE bucketing, scalar subquery baseline, index ratio
SELECT CASE WHEN t.surge_multiplier = 1.00 THEN '1  No surge'
            WHEN t.surge_multiplier <= 1.25 THEN '2  1.01-1.25'
            WHEN t.surge_multiplier <= 1.50 THEN '3  1.26-1.50'
            WHEN t.surge_multiplier <= 2.00 THEN '4  1.51-2.00'
            ELSE '5  >2.00' END                                                                 AS surge_band,
       COUNT(*)                                                                                 AS settled_trips,
       CAST(100.0 * SUM(CASE WHEN f.tip_amount_zar > 0 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS tip_rate_pct,
       CAST(AVG(f.tip_amount_zar) AS DECIMAL(6,2))                                              AS avg_tip_zar,
       CAST(AVG(f.gross_fare_zar) AS DECIMAL(8,2))                                              AS avg_fare_zar,
       CAST((100.0 * SUM(CASE WHEN f.tip_amount_zar > 0 THEN 1 ELSE 0 END) / COUNT(*))
            / (SELECT 100.0 * SUM(CASE WHEN f2.tip_amount_zar > 0 THEN 1 ELSE 0 END) / COUNT(*)
               FROM ride.trip_fare f2 JOIN ride.trip t2 ON t2.trip_id = f2.trip_id
               WHERE f2.payment_status = 'Settled' AND t2.surge_multiplier = 1.00) AS DECIMAL(5,3)) AS index_vs_no_surge
FROM ride.trip_fare f
JOIN ride.trip t ON t.trip_id = f.trip_id
WHERE f.payment_status = 'Settled'
GROUP BY CASE WHEN t.surge_multiplier = 1.00 THEN '1  No surge'
              WHEN t.surge_multiplier <= 1.25 THEN '2  1.01-1.25'
              WHEN t.surge_multiplier <= 1.50 THEN '3  1.26-1.50'
              WHEN t.surge_multiplier <= 2.00 THEN '4  1.51-2.00'
              ELSE '5  >2.00' END
ORDER BY surge_band;
GO

-- #### Q15  RQ15 - Payment failure rate and rand value lost per instrument
-- Techniques: 4-table join incl. LEFT JOIN fact-to-fact, conditional SUMs, window share of total loss.
-- Failed fares carry R0 commission in the data, so lost platform revenue is estimated from the
-- driver's contractual commission rate applied to the commissionable fare (gross less tip and toll).
SELECT p.method_name, p.channel_group,
       COUNT(*)                                                                                  AS requests,
       SUM(CASE WHEN t.trip_status = 'Payment Failed' THEN 1 ELSE 0 END)                         AS failed_payments,
       CAST(100.0 * SUM(CASE WHEN t.trip_status = 'Payment Failed' THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS failure_rate_pct,
       CAST(SUM(CASE WHEN f.payment_status = 'Failed' THEN f.gross_fare_zar ELSE 0 END) AS DECIMAL(12,2))         AS value_lost_zar,
       CAST(SUM(CASE WHEN f.payment_status = 'Failed'
                     THEN (f.gross_fare_zar - f.tip_amount_zar - f.toll_fee_zar) * d.commission_rate_pct / 100
                     ELSE 0 END) AS DECIMAL(12,2))                                                AS est_commission_lost_zar,
       CAST(100.0 * SUM(CASE WHEN f.payment_status = 'Failed' THEN f.gross_fare_zar ELSE 0 END)
            / SUM(SUM(CASE WHEN f.payment_status = 'Failed' THEN f.gross_fare_zar ELSE 0 END)) OVER () AS DECIMAL(5,2)) AS pct_of_total_loss
FROM ride.trip t
JOIN ride.payment_method p ON p.payment_method_id = t.payment_method_id
JOIN ride.driver d         ON d.driver_id = t.driver_id
LEFT JOIN ride.trip_fare f ON f.trip_id = t.trip_id
GROUP BY p.method_name, p.channel_group
ORDER BY failure_rate_pct DESC;
GO

-- #### Q16  RQ16 - What riders do in the 30 days after a payment failure (vs after a completed trip)
-- Techniques: LEAD() over each rider's ordered history, DATEDIFF, outcome classification, cohort comparison
WITH hist AS (
    SELECT t.rider_id, t.trip_status, t.payment_method_id, t.request_timestamp,
           LEAD(t.request_timestamp)  OVER (PARTITION BY t.rider_id ORDER BY t.request_timestamp) AS next_ts,
           LEAD(t.payment_method_id)  OVER (PARTITION BY t.rider_id ORDER BY t.request_timestamp) AS next_pm
    FROM ride.trip t
), classified AS (
    SELECT h.trip_status,
           CASE WHEN h.next_ts IS NULL OR DATEDIFF(DAY, h.request_timestamp, h.next_ts) > 30 THEN 'No trip within 30 days'
                WHEN h.next_pm = h.payment_method_id THEN 'Returned - same instrument'
                WHEN np.is_digital = 0                THEN 'Returned - switched to cash'
                ELSE 'Returned - switched to other digital' END AS outcome
    FROM hist h
    LEFT JOIN ride.payment_method np ON np.payment_method_id = h.next_pm
    WHERE h.trip_status IN ('Payment Failed', 'Completed')
      AND h.request_timestamp < '2026-06-01'          -- leave a full 30-day observation window
)
SELECT trip_status AS after_event, outcome, COUNT(*) AS events,
       CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY trip_status) AS DECIMAL(5,2)) AS pct_of_events
FROM classified
GROUP BY trip_status, outcome
ORDER BY trip_status DESC, outcome;
GO

-- #### Q17  RQ17 - Zones where surge drives rider cancellations, and the revenue that walks away
-- Techniques: CTEs, 4-table join, filtered aggregation via reason_group, correlated estimate of lost value, RANK()
WITH zone_stats AS (
    SELECT z.zone_id, z.zone_name, c.city_name, z.zone_type, z.avg_driver_supply_index,
           COUNT(*)                                                                         AS requests,
           AVG(t.surge_multiplier)                                                          AS avg_surge,
           SUM(CASE WHEN t.trip_status = 'Cancelled by Rider' AND cr.reason_group = 'Price' THEN 1 ELSE 0 END) AS surge_rider_cancels,
           SUM(CASE WHEN t.trip_status = 'No Driver Found' THEN 1 ELSE 0 END)               AS no_supply_events
    FROM ride.trip t
    JOIN ride.zone z ON z.zone_id = t.pickup_zone_id
    JOIN ride.city c ON c.city_id = z.city_id
    LEFT JOIN ride.cancellation_reason cr ON cr.cancellation_reason_id = t.cancellation_reason_id
    GROUP BY z.zone_id, z.zone_name, c.city_name, z.zone_type, z.avg_driver_supply_index
), zone_fare AS (
    SELECT t.pickup_zone_id, AVG(f.gross_fare_zar) AS avg_settled_fare
    FROM ride.trip t JOIN ride.trip_fare f ON f.trip_id = t.trip_id
    WHERE f.payment_status = 'Settled'
    GROUP BY t.pickup_zone_id
)
SELECT TOP (10)
       RANK() OVER (ORDER BY zs.surge_rider_cancels * zf.avg_settled_fare DESC)          AS loss_rank,
       zs.zone_name, zs.city_name, zs.zone_type, zs.requests,
       CAST(zs.avg_surge AS DECIMAL(4,2))                                                AS avg_surge,
       zs.surge_rider_cancels,
       CAST(100.0 * zs.surge_rider_cancels / zs.requests AS DECIMAL(5,2))                AS surge_cancel_rate_pct,
       zs.avg_driver_supply_index                                                        AS supply_index,
       CAST(zs.surge_rider_cancels * zf.avg_settled_fare AS DECIMAL(12,2))               AS est_revenue_lost_zar
FROM zone_stats zs
JOIN zone_fare zf ON zf.pickup_zone_id = zs.zone_id
ORDER BY loss_rank;
GO

-- #### Q17b RQ17 - Rider surge-cancellation rate by surge band (price elasticity signal)
SELECT CASE WHEN t.surge_multiplier = 1.00 THEN '1  No surge'
            WHEN t.surge_multiplier <= 1.25 THEN '2  1.01-1.25'
            WHEN t.surge_multiplier <= 1.50 THEN '3  1.26-1.50'
            WHEN t.surge_multiplier <= 2.00 THEN '4  1.51-2.00'
            ELSE '5  >2.00' END                                                                  AS surge_band,
       COUNT(*)                                                                                  AS requests,
       CAST(100.0 * SUM(CASE WHEN t.trip_status = 'Cancelled by Rider' AND t.cancellation_reason_id = 1 THEN 1 ELSE 0 END)
            / COUNT(*) AS DECIMAL(5,2))                                                          AS rider_surge_cancel_pct,
       CAST(100.0 * SUM(CASE WHEN t.trip_status = 'Completed' THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS completion_pct
FROM ride.trip t
GROUP BY CASE WHEN t.surge_multiplier = 1.00 THEN '1  No surge'
              WHEN t.surge_multiplier <= 1.25 THEN '2  1.01-1.25'
              WHEN t.surge_multiplier <= 1.50 THEN '3  1.26-1.50'
              WHEN t.surge_multiplier <= 2.00 THEN '4  1.51-2.00'
              ELSE '5  >2.00' END
ORDER BY surge_band;
GO

-- #### Q18  RQ18 - Promotions: penetration, cost and whether discounted riders return sooner
-- Techniques: LEAD() over settled history, DATEDIFF, cohort comparison, EXISTS-free conditional logic
WITH settled AS (
    SELECT t.rider_id, t.request_timestamp, f.gross_fare_zar, f.promo_discount_zar,
           CASE WHEN f.promo_discount_zar > 0 THEN 'Discounted' ELSE 'Full price' END AS cohort,
           LEAD(t.request_timestamp) OVER (PARTITION BY t.rider_id ORDER BY t.request_timestamp) AS next_trip_ts
    FROM ride.trip t
    JOIN ride.trip_fare f ON f.trip_id = t.trip_id
    WHERE f.payment_status = 'Settled'
)
SELECT cohort,
       COUNT(*)                                                                                     AS settled_trips,
       CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,2))                               AS pct_of_trips,
       CAST(SUM(promo_discount_zar) AS DECIMAL(12,2))                                               AS promo_cost_zar,
       CAST(AVG(CASE WHEN promo_discount_zar > 0 THEN promo_discount_zar END) AS DECIMAL(6,2))      AS avg_discount_zar,
       CAST(AVG(gross_fare_zar) AS DECIMAL(8,2))                                                    AS avg_fare_zar,
       CAST(AVG(1.0 * DATEDIFF(HOUR, request_timestamp, next_trip_ts)) / 24 AS DECIMAL(6,2))        AS avg_days_to_next_trip,
       CAST(100.0 * SUM(CASE WHEN DATEDIFF(DAY, request_timestamp, next_trip_ts) <= 30 THEN 1 ELSE 0 END)
            / SUM(CASE WHEN request_timestamp < '2026-06-01' THEN 1 ELSE 0 END) AS DECIMAL(5,2))     AS repeat_within_30d_pct
FROM settled
GROUP BY cohort;
GO

-- #### Q19  RQ19 - RFM segmentation and payment behaviour per segment
-- Techniques: chained CTEs, NTILE(5) scoring on R/F/M, CASE segment rules, LEFT JOIN of failure history
DECLARE @as_of DATE = '2026-07-01';
WITH rfm_raw AS (
    SELECT t.rider_id,
           DATEDIFF(DAY, MAX(t.request_timestamp), @as_of)           AS recency_days,
           COUNT(*)                                                   AS frequency,
           SUM(f.gross_fare_zar)                                      AS monetary
    FROM ride.trip t
    JOIN ride.trip_fare f ON f.trip_id = t.trip_id AND f.payment_status = 'Settled'
    GROUP BY t.rider_id
), scored AS (
    SELECT *,
           NTILE(5) OVER (ORDER BY recency_days DESC) AS r_score,      -- 5 = most recent
           NTILE(5) OVER (ORDER BY frequency)         AS f_score,      -- 5 = most frequent
           NTILE(5) OVER (ORDER BY monetary)          AS m_score       -- 5 = highest spend
    FROM rfm_raw
), segmented AS (
    SELECT *,
           CASE WHEN r_score >= 4 AND f_score >= 4 AND m_score >= 4 THEN '1 Champions'
                WHEN f_score >= 4 AND m_score >= 3                  THEN '2 Loyal high-value'
                WHEN r_score >= 4 AND f_score <= 2                  THEN '3 New / promising'
                WHEN r_score <= 2 AND f_score >= 3                  THEN '4 At risk'
                WHEN r_score <= 2 AND f_score <= 2                  THEN '5 Hibernating'
                ELSE '6 Needs attention' END AS rfm_segment
    FROM scored
), behaviour AS (
    SELECT t.rider_id,
           COUNT(*)                                                     AS requests,
           SUM(CASE WHEN p.is_digital = 0 THEN 1 ELSE 0 END)            AS cash_requests,
           SUM(CASE WHEN t.trip_status = 'Payment Failed' THEN 1 ELSE 0 END) AS failed
    FROM ride.trip t JOIN ride.payment_method p ON p.payment_method_id = t.payment_method_id
    GROUP BY t.rider_id
)
SELECT s.rfm_segment, COUNT(*) AS riders,
       CAST(AVG(1.0 * s.recency_days) AS DECIMAL(6,1))                                       AS avg_recency_days,
       CAST(AVG(1.0 * s.frequency) AS DECIMAL(6,1))                                          AS avg_trips,
       CAST(AVG(s.monetary) AS DECIMAL(10,2))                                                AS avg_spend_zar,
       CAST(100.0 * SUM(s.monetary) / SUM(SUM(s.monetary)) OVER () AS DECIMAL(5,2))          AS pct_of_revenue,
       CAST(100.0 * SUM(b.cash_requests) / SUM(b.requests) AS DECIMAL(5,2))                  AS cash_share_pct,
       CAST(100.0 * SUM(b.failed) / SUM(b.requests) AS DECIMAL(5,2))                         AS payment_fail_pct
FROM segmented s
LEFT JOIN behaviour b ON b.rider_id = s.rider_id
GROUP BY s.rfm_segment
ORDER BY s.rfm_segment;
GO
