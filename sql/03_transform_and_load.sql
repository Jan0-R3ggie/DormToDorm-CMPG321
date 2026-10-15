/* =====================================================================
   CMPG321 2026 - Group 36 (DormToDorm) - Phase 2
   Script 03: Cleanse staging data and load the production schema.
   The whole load is ONE transaction: if any constraint fails or the
   row-count reconciliation does not balance, everything rolls back.
   ===================================================================== */
USE DormToDorm_RideDB;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
SET XACT_ABORT ON;   -- any run-time error dooms the transaction
GO

/* ---- Cleansing step 1: the CSVs use CRLF line endings, so the last column of each file
        carries a trailing carriage return. Strip it in staging. ---- */
UPDATE stg.sa_riders           SET account_status          = REPLACE(account_status, CHAR(13), '');
UPDATE stg.sa_drivers          SET background_check_status = REPLACE(background_check_status, CHAR(13), '');
UPDATE stg.vehicles            SET inspection_status       = REPLACE(inspection_status, CHAR(13), '');
UPDATE stg.pricing_surge_zones SET toll_route_flag         = REPLACE(toll_route_flag, CHAR(13), '');
UPDATE stg.trip_headers        SET is_airport_trip         = REPLACE(is_airport_trip, CHAR(13), '');
UPDATE stg.trip_fare_breakdown SET settlement_date         = REPLACE(settlement_date, CHAR(13), '');
UPDATE stg.trip_reviews        SET escalated_flag          = REPLACE(escalated_flag, CHAR(13), '');
GO

BEGIN TRY
    BEGIN TRANSACTION load_production;

    /* ---------- Lookup tables ---------- */
    INSERT ride.province (province_code, province_name) VALUES
        ('GP','Gauteng'), ('WC','Western Cape'), ('KZN','KwaZulu-Natal'), ('EC','Eastern Cape'), ('NW','North West');

    INSERT ride.city (city_name, province_code)
    SELECT DISTINCT z.city, p.province_code
    FROM stg.pricing_surge_zones z
    JOIN ride.province p ON p.province_name = z.province;

    INSERT ride.payment_method (payment_method_id, method_name, channel_group, is_digital) VALUES
        (1,'Cash','Cash',0), (2,'Credit Card','Card',1), (3,'Debit Card','Card',1), (4,'In-App Wallet','In-App Wallet',1),
        (5,'SnapScan','QR Code',1), (6,'Zapper','QR Code',1), (7,'Apple Pay','Mobile Wallet',1), (8,'Google Pay','Mobile Wallet',1);

    INSERT ride.ride_category (ride_category_id, category_name, platform, service_tier, base_fare_zar)
    SELECT ROW_NUMBER() OVER (ORDER BY MIN(CAST(f.base_fare_zar AS DECIMAL(6,2)))),
           t.ride_category, t.platform,
           CASE WHEN t.ride_category IN ('UberGo','Bolt Go')            THEN 'Economy'
                WHEN t.ride_category IN ('UberX','Bolt Economy')        THEN 'Standard'
                WHEN t.ride_category IN ('Uber Comfort','Bolt Comfort') THEN 'Comfort'
                ELSE 'XL' END,
           MIN(CAST(f.base_fare_zar AS DECIMAL(6,2)))
    FROM stg.trip_headers t
    JOIN stg.trip_fare_breakdown f ON f.trip_id = t.trip_id
    GROUP BY t.ride_category, t.platform;

    INSERT ride.cancellation_reason (cancellation_reason_id, reason_text, reason_group) VALUES
        (1,'Surge Price Friction','Price'), (2,'Driver Too Far','Supply'), (3,'No Supply In Zone','Supply'),
        (4,'Rider No-Show','Rider'), (5,'Rider Changed Plans','Rider'), (6,'Wrong Pickup Location','Rider'),
        (7,'Driver Unresponsive','Driver'), (8,'Vehicle Mismatch','Driver'), (9,'Traffic Delay','Operational'),
        (10,'Card Declined','Payment');

    /* ---------- Dimensions ---------- */
    INSERT ride.zone (zone_id, zone_name, city_id, zone_type, base_fare_zar, per_km_rate_zar, per_minute_rate_zar,
                      minimum_fare_zar, booking_fee_zar, avg_surge_multiplier, max_surge_multiplier, peak_window,
                      avg_driver_supply_index, toll_route_flag)
    SELECT z.zone_id, z.zone_name, c.city_id, z.zone_type,
           CAST(z.base_fare_zar AS DECIMAL(6,2)), CAST(z.per_km_rate_zar AS DECIMAL(6,2)),
           CAST(z.per_minute_rate_zar AS DECIMAL(6,2)), CAST(z.minimum_fare_zar AS DECIMAL(6,2)),
           CAST(z.booking_fee_zar AS DECIMAL(6,2)), CAST(z.avg_surge_multiplier AS DECIMAL(4,2)),
           CAST(z.max_surge_multiplier AS DECIMAL(4,2)), z.peak_window,
           CAST(z.avg_driver_supply_index AS DECIMAL(4,2)), CASE z.toll_route_flag WHEN 'Y' THEN 1 ELSE 0 END
    FROM stg.pricing_surge_zones z
    JOIN ride.city c ON c.city_name = z.city;

    INSERT ride.vehicle (vehicle_id, make, model, model_year, vehicle_age_years, vehicle_category, seats,
                         fuel_type, colour, licence_plate, roadworthy_expiry, inspection_status)
    SELECT vehicle_id, make, model, CAST(model_year AS SMALLINT), CAST(vehicle_age_years AS TINYINT), vehicle_category,
           CAST(seats AS TINYINT), fuel_type, colour, licence_plate, CAST(roadworthy_expiry AS DATE), inspection_status
    FROM stg.vehicles;

    INSERT ride.driver (driver_id, vehicle_id, first_name, last_name, platform, operating_city_id, onboarding_date,
                        driver_rating, total_trips_lifetime, acceptance_rate_pct, cancellation_rate_pct,
                        commission_rate_pct, driver_status, background_check_status)
    SELECT d.driver_id, d.vehicle_id, d.first_name, d.last_name, d.platform, c.city_id, CAST(d.onboarding_date AS DATE),
           CAST(d.driver_rating AS DECIMAL(3,2)), CAST(d.total_trips_lifetime AS INT),
           CAST(d.acceptance_rate_pct AS DECIMAL(5,2)), CAST(d.cancellation_rate_pct AS DECIMAL(5,2)),
           CAST(d.commission_rate_pct AS DECIMAL(4,1)), d.driver_status, d.background_check_status
    FROM stg.sa_drivers d
    JOIN ride.city c ON c.city_name = d.operating_city;

    INSERT ride.rider (rider_id, first_name, last_name, age_band, gender, home_city_id, signup_date,
                       preferred_payment_method_id, loyalty_tier, rider_segment, corporate_account_flag,
                       avg_rider_rating, account_status)
    SELECT r.rider_id, r.first_name, r.last_name, r.age_band, r.gender, c.city_id, CAST(r.signup_date AS DATE),
           pm.payment_method_id, r.loyalty_tier, r.rider_segment,
           CASE r.corporate_account_flag WHEN 'Y' THEN 1 ELSE 0 END,
           CAST(r.avg_rider_rating AS DECIMAL(3,2)), r.account_status
    FROM stg.sa_riders r
    JOIN ride.city c            ON c.city_name    = r.home_city
    JOIN ride.payment_method pm ON pm.method_name = r.preferred_payment_method;

    /* ---------- Facts (empty strings normalised to NULL with NULLIF) ---------- */
    INSERT ride.trip (trip_id, rider_id, driver_id, ride_category_id, request_timestamp, pickup_timestamp,
                      dropoff_timestamp, pickup_zone_id, dropoff_zone_id, trip_distance_km, trip_duration_min,
                      wait_time_min, surge_multiplier, trip_status, cancellation_reason_id, payment_method_id,
                      is_airport_trip)
    SELECT t.trip_id, t.rider_id, t.driver_id, rc.ride_category_id,
           CAST(t.request_timestamp AS DATETIME2(0)),
           CAST(NULLIF(t.pickup_timestamp,  '') AS DATETIME2(0)),
           CAST(NULLIF(t.dropoff_timestamp, '') AS DATETIME2(0)),
           t.pickup_zone_id, t.dropoff_zone_id,
           CAST(NULLIF(t.trip_distance_km,  '') AS DECIMAL(6,2)),
           CAST(NULLIF(t.trip_duration_min, '') AS DECIMAL(6,1)),
           CAST(t.wait_time_min AS DECIMAL(4,1)), CAST(t.surge_multiplier AS DECIMAL(4,2)),
           t.trip_status, cr.cancellation_reason_id, pm.payment_method_id,
           CASE t.is_airport_trip WHEN 'Y' THEN 1 ELSE 0 END
    FROM stg.trip_headers t
    JOIN ride.ride_category  rc ON rc.category_name = t.ride_category
    JOIN ride.payment_method pm ON pm.method_name   = t.payment_method
    LEFT JOIN ride.cancellation_reason cr ON cr.reason_text = NULLIF(t.cancellation_reason, '');

    INSERT ride.trip_fare (fare_id, trip_id, base_fare_zar, distance_charge_zar, time_charge_zar, surge_premium_zar,
                           booking_fee_zar, toll_fee_zar, waiting_charge_zar, promo_discount_zar, tip_amount_zar,
                           gross_fare_zar, platform_commission_zar, driver_net_payout_zar, payment_status,
                           currency, settlement_date)
    SELECT fare_id, trip_id,
           CAST(base_fare_zar AS DECIMAL(8,2)), CAST(distance_charge_zar AS DECIMAL(8,2)),
           CAST(time_charge_zar AS DECIMAL(8,2)), CAST(surge_premium_zar AS DECIMAL(8,2)),
           CAST(booking_fee_zar AS DECIMAL(6,2)), CAST(toll_fee_zar AS DECIMAL(6,2)),
           CAST(waiting_charge_zar AS DECIMAL(6,2)), CAST(promo_discount_zar AS DECIMAL(6,2)),
           CAST(tip_amount_zar AS DECIMAL(6,2)), CAST(gross_fare_zar AS DECIMAL(9,2)),
           CAST(platform_commission_zar AS DECIMAL(8,2)), CAST(driver_net_payout_zar AS DECIMAL(9,2)),
           payment_status, currency, CAST(NULLIF(settlement_date, '') AS DATE)
    FROM stg.trip_fare_breakdown;

    INSERT ride.trip_review (review_id, trip_id, rating_given, review_timestamp, review_comment, review_category,
                             sentiment_label, escalated_flag)
    SELECT review_id, trip_id, CAST(rating_given AS TINYINT), CAST(review_timestamp AS DATETIME2(0)),
           NULLIF(review_comment, ''), review_category, sentiment_label,
           CASE escalated_flag WHEN 'Y' THEN 1 ELSE 0 END
    FROM stg.trip_reviews;

    /* ---------- Supplementary data: SA public holidays inside the analysis window ---------- */
    INSERT ride.public_holiday (holiday_date, holiday_name) VALUES
        ('2025-08-09','National Women''s Day'), ('2025-09-24','Heritage Day'), ('2025-12-16','Day of Reconciliation'),
        ('2025-12-25','Christmas Day'), ('2025-12-26','Day of Goodwill'), ('2026-01-01','New Year''s Day'),
        ('2026-03-21','Human Rights Day'), ('2026-04-03','Good Friday'), ('2026-04-06','Family Day'),
        ('2026-04-27','Freedom Day'), ('2026-05-01','Workers'' Day'), ('2026-06-16','Youth Day');

    /* ---------- Reconciliation: production must match staging exactly ---------- */
    IF (SELECT COUNT(*) FROM ride.rider)       <> (SELECT COUNT(*) FROM stg.sa_riders)
    OR (SELECT COUNT(*) FROM ride.driver)      <> (SELECT COUNT(*) FROM stg.sa_drivers)
    OR (SELECT COUNT(*) FROM ride.vehicle)     <> (SELECT COUNT(*) FROM stg.vehicles)
    OR (SELECT COUNT(*) FROM ride.zone)        <> (SELECT COUNT(*) FROM stg.pricing_surge_zones)
    OR (SELECT COUNT(*) FROM ride.trip)        <> (SELECT COUNT(*) FROM stg.trip_headers)
    OR (SELECT COUNT(*) FROM ride.trip_fare)   <> (SELECT COUNT(*) FROM stg.trip_fare_breakdown)
    OR (SELECT COUNT(*) FROM ride.trip_review) <> (SELECT COUNT(*) FROM stg.trip_reviews)
        THROW 50001, 'Row-count reconciliation failed - load rolled back.', 1;

    IF (SELECT SUM(gross_fare_zar) FROM ride.trip_fare)
       <> (SELECT SUM(CAST(gross_fare_zar AS DECIMAL(12,2))) FROM stg.trip_fare_breakdown)
        THROW 50002, 'Monetary reconciliation failed - load rolled back.', 1;

    COMMIT TRANSACTION load_production;
    PRINT 'Load committed successfully.';
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    PRINT 'Load failed and was rolled back: ' + ERROR_MESSAGE();
    THROW;
END CATCH;
GO

/* ---- Post-load verification ---- */
SELECT 'province' AS table_name, COUNT(*) AS row_count FROM ride.province UNION ALL
SELECT 'city', COUNT(*) FROM ride.city UNION ALL
SELECT 'zone', COUNT(*) FROM ride.zone UNION ALL
SELECT 'payment_method', COUNT(*) FROM ride.payment_method UNION ALL
SELECT 'ride_category', COUNT(*) FROM ride.ride_category UNION ALL
SELECT 'cancellation_reason', COUNT(*) FROM ride.cancellation_reason UNION ALL
SELECT 'rider', COUNT(*) FROM ride.rider UNION ALL
SELECT 'vehicle', COUNT(*) FROM ride.vehicle UNION ALL
SELECT 'driver', COUNT(*) FROM ride.driver UNION ALL
SELECT 'trip', COUNT(*) FROM ride.trip UNION ALL
SELECT 'trip_fare', COUNT(*) FROM ride.trip_fare UNION ALL
SELECT 'trip_review', COUNT(*) FROM ride.trip_review UNION ALL
SELECT 'public_holiday', COUNT(*) FROM ride.public_holiday;
GO

/* ---- Post-load maintenance: compress the columnstore delta store and refresh statistics ---- */
ALTER INDEX ncci_trip_fare ON ride.trip_fare REORGANIZE WITH (COMPRESS_ALL_ROW_GROUPS = ON);
ALTER INDEX ncci_trip_fare ON ride.trip_fare REORGANIZE;   -- second pass removes the tombstoned delta rowgroups
EXEC sp_updatestats;
GO
