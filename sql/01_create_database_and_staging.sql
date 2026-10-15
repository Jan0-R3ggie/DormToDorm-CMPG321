/* =====================================================================
   CMPG321 2026 - Group 36 (DormToDorm) - Phase 2
   Script 01: Create database and raw staging tables, bulk-load the CSVs
   DBMS: Microsoft SQL Server 2022
   ===================================================================== */
USE master;
GO
IF DB_ID('DormToDorm_RideDB') IS NOT NULL
BEGIN
    ALTER DATABASE DormToDorm_RideDB SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE DormToDorm_RideDB;
END
GO
CREATE DATABASE DormToDorm_RideDB;
GO
USE DormToDorm_RideDB;
GO
CREATE SCHEMA stg;   -- raw landing area: every column text, loaded as-is
GO
CREATE SCHEMA ride;  -- normalised, constrained production schema
GO

CREATE TABLE stg.sa_riders (
    rider_id NVARCHAR(20), first_name NVARCHAR(60), last_name NVARCHAR(60), age_band NVARCHAR(20),
    gender NVARCHAR(30), home_city NVARCHAR(40), province NVARCHAR(40), signup_date NVARCHAR(20),
    preferred_payment_method NVARCHAR(30), loyalty_tier NVARCHAR(20), rider_segment NVARCHAR(20),
    corporate_account_flag NVARCHAR(5), avg_rider_rating NVARCHAR(10), account_status NVARCHAR(20));

CREATE TABLE stg.sa_drivers (
    driver_id NVARCHAR(20), vehicle_id NVARCHAR(20), first_name NVARCHAR(60), last_name NVARCHAR(60),
    platform NVARCHAR(10), operating_city NVARCHAR(40), province NVARCHAR(40), onboarding_date NVARCHAR(20),
    driver_rating NVARCHAR(10), total_trips_lifetime NVARCHAR(10), acceptance_rate_pct NVARCHAR(10),
    cancellation_rate_pct NVARCHAR(10), commission_rate_pct NVARCHAR(10), driver_status NVARCHAR(20),
    background_check_status NVARCHAR(20));

CREATE TABLE stg.vehicles (
    vehicle_id NVARCHAR(20), make NVARCHAR(30), model NVARCHAR(40), model_year NVARCHAR(10),
    vehicle_age_years NVARCHAR(10), vehicle_category NVARCHAR(20), seats NVARCHAR(5), fuel_type NVARCHAR(20),
    colour NVARCHAR(20), licence_plate NVARCHAR(20), roadworthy_expiry NVARCHAR(20), inspection_status NVARCHAR(20));

CREATE TABLE stg.pricing_surge_zones (
    zone_id NVARCHAR(10), zone_name NVARCHAR(60), city NVARCHAR(40), province NVARCHAR(40), zone_type NVARCHAR(30),
    base_fare_zar NVARCHAR(10), per_km_rate_zar NVARCHAR(10), per_minute_rate_zar NVARCHAR(10),
    minimum_fare_zar NVARCHAR(10), booking_fee_zar NVARCHAR(10), avg_surge_multiplier NVARCHAR(10),
    max_surge_multiplier NVARCHAR(10), peak_window NVARCHAR(20), avg_driver_supply_index NVARCHAR(10),
    toll_route_flag NVARCHAR(5));

CREATE TABLE stg.trip_headers (
    trip_id NVARCHAR(20), rider_id NVARCHAR(20), driver_id NVARCHAR(20), vehicle_id NVARCHAR(20),
    platform NVARCHAR(10), ride_category NVARCHAR(30), request_timestamp NVARCHAR(30),
    pickup_timestamp NVARCHAR(30), dropoff_timestamp NVARCHAR(30), pickup_zone_id NVARCHAR(10),
    dropoff_zone_id NVARCHAR(10), city NVARCHAR(40), province NVARCHAR(40), trip_distance_km NVARCHAR(15),
    trip_duration_min NVARCHAR(15), wait_time_min NVARCHAR(15), surge_multiplier NVARCHAR(10),
    trip_status NVARCHAR(30), cancellation_reason NVARCHAR(40), payment_method NVARCHAR(30),
    day_of_week NVARCHAR(15), hour_of_day NVARCHAR(5), is_weekend NVARCHAR(5), is_airport_trip NVARCHAR(5));

CREATE TABLE stg.trip_fare_breakdown (
    fare_id NVARCHAR(20), trip_id NVARCHAR(20), base_fare_zar NVARCHAR(15), distance_charge_zar NVARCHAR(15),
    time_charge_zar NVARCHAR(15), surge_premium_zar NVARCHAR(15), booking_fee_zar NVARCHAR(15),
    toll_fee_zar NVARCHAR(15), waiting_charge_zar NVARCHAR(15), promo_discount_zar NVARCHAR(15),
    tip_amount_zar NVARCHAR(15), gross_fare_zar NVARCHAR(15), platform_commission_zar NVARCHAR(15),
    driver_net_payout_zar NVARCHAR(15), payment_method NVARCHAR(30), payment_status NVARCHAR(20),
    currency NVARCHAR(5), settlement_date NVARCHAR(20));

CREATE TABLE stg.trip_reviews (
    review_id NVARCHAR(20), trip_id NVARCHAR(20), rider_id NVARCHAR(20), driver_id NVARCHAR(20),
    rating_given NVARCHAR(5), review_timestamp NVARCHAR(30), review_comment NVARCHAR(400),
    review_category NVARCHAR(40), sentiment_label NVARCHAR(20), escalated_flag NVARCHAR(5));
GO

/* Bulk load - adjust @path to the folder holding the CSV files */
DECLARE @path NVARCHAR(260) = N'C:\CMPG321\Project Phase 1\dataset\';
DECLARE @t TABLE (tbl SYSNAME);
INSERT @t VALUES (N'sa_riders'),(N'sa_drivers'),(N'vehicles'),(N'pricing_surge_zones'),
                 (N'trip_headers'),(N'trip_fare_breakdown'),(N'trip_reviews');
DECLARE @tbl SYSNAME, @sql NVARCHAR(MAX);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT tbl FROM @t;
OPEN c; FETCH NEXT FROM c INTO @tbl;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'BULK INSERT stg.' + QUOTENAME(@tbl) + N' FROM ''' + @path + @tbl + N'.csv''
                WITH (FORMAT = ''CSV'', FIRSTROW = 2, CODEPAGE = ''65001'', FIELDQUOTE = ''"'',
                      ROWTERMINATOR = ''0x0a'', TABLOCK);';
    EXEC sp_executesql @sql;
    FETCH NEXT FROM c INTO @tbl;
END
CLOSE c; DEALLOCATE c;
GO

SELECT 'sa_riders' AS staging_table, COUNT(*) AS rows_loaded FROM stg.sa_riders UNION ALL
SELECT 'sa_drivers', COUNT(*) FROM stg.sa_drivers UNION ALL
SELECT 'vehicles', COUNT(*) FROM stg.vehicles UNION ALL
SELECT 'pricing_surge_zones', COUNT(*) FROM stg.pricing_surge_zones UNION ALL
SELECT 'trip_headers', COUNT(*) FROM stg.trip_headers UNION ALL
SELECT 'trip_fare_breakdown', COUNT(*) FROM stg.trip_fare_breakdown UNION ALL
SELECT 'trip_reviews', COUNT(*) FROM stg.trip_reviews;
GO
