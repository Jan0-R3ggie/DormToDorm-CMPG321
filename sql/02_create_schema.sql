/* =====================================================================
   CMPG321 2026 - Group 36 (DormToDorm) - Phase 2
   Script 02: Normalised production schema (3NF) with keys, constraints,
              domains, computed columns and indexes
   ===================================================================== */
USE DormToDorm_RideDB;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* ---------- Geography (removes the city -> province transitive dependency) ---------- */
CREATE TABLE ride.province (
    province_code   CHAR(3)      NOT NULL CONSTRAINT pk_province PRIMARY KEY,
    province_name   VARCHAR(20)  NOT NULL CONSTRAINT uq_province_name UNIQUE
);

CREATE TABLE ride.city (
    city_id         TINYINT      NOT NULL IDENTITY(1,1) CONSTRAINT pk_city PRIMARY KEY,
    city_name       VARCHAR(20)  NOT NULL CONSTRAINT uq_city_name UNIQUE,
    province_code   CHAR(3)      NOT NULL CONSTRAINT fk_city_province REFERENCES ride.province(province_code)
);

CREATE TABLE ride.zone (
    zone_id                 CHAR(5)      NOT NULL CONSTRAINT pk_zone PRIMARY KEY,
    zone_name               VARCHAR(30)  NOT NULL,
    city_id                 TINYINT      NOT NULL CONSTRAINT fk_zone_city REFERENCES ride.city(city_id),
    zone_type               VARCHAR(20)  NOT NULL CONSTRAINT ck_zone_type CHECK (zone_type IN
                            ('Business District','Residential','Airport','Nightlife','Campus','Township','Retail Hub')),
    base_fare_zar           DECIMAL(6,2) NOT NULL CONSTRAINT ck_zone_base CHECK (base_fare_zar > 0),
    per_km_rate_zar         DECIMAL(6,2) NOT NULL CONSTRAINT ck_zone_km   CHECK (per_km_rate_zar > 0),
    per_minute_rate_zar     DECIMAL(6,2) NOT NULL CONSTRAINT ck_zone_min  CHECK (per_minute_rate_zar > 0),
    minimum_fare_zar        DECIMAL(6,2) NOT NULL CONSTRAINT ck_zone_minf CHECK (minimum_fare_zar > 0),
    booking_fee_zar         DECIMAL(6,2) NOT NULL CONSTRAINT ck_zone_book CHECK (booking_fee_zar >= 0),
    avg_surge_multiplier    DECIMAL(4,2) NOT NULL,
    max_surge_multiplier    DECIMAL(4,2) NOT NULL,
    peak_window             VARCHAR(11)  NOT NULL CONSTRAINT ck_zone_peak CHECK (peak_window IN
                            ('06:00-09:00','16:00-19:00','21:00-02:00','All Day')),
    avg_driver_supply_index DECIMAL(4,2) NOT NULL CONSTRAINT ck_zone_supply CHECK (avg_driver_supply_index > 0),
    toll_route_flag         BIT          NOT NULL,
    CONSTRAINT uq_zone_name_city UNIQUE (zone_name, city_id),
    CONSTRAINT ck_zone_surge CHECK (avg_surge_multiplier >= 1.00 AND max_surge_multiplier >= avg_surge_multiplier)
);

/* ---------- Lookup / domain tables ---------- */
CREATE TABLE ride.payment_method (
    payment_method_id   TINYINT      NOT NULL CONSTRAINT pk_payment_method PRIMARY KEY,
    method_name         VARCHAR(15)  NOT NULL CONSTRAINT uq_payment_method_name UNIQUE,
    channel_group       VARCHAR(13)  NOT NULL CONSTRAINT ck_pm_group CHECK (channel_group IN ('Cash','Card','Mobile Wallet','In-App Wallet','QR Code')),
    is_digital          BIT          NOT NULL,
    CONSTRAINT ck_pm_cash_not_digital CHECK (NOT (channel_group = 'Cash' AND is_digital = 1))
);

CREATE TABLE ride.ride_category (
    ride_category_id    TINYINT      NOT NULL CONSTRAINT pk_ride_category PRIMARY KEY,
    category_name       VARCHAR(15)  NOT NULL CONSTRAINT uq_ride_category_name UNIQUE,
    platform            VARCHAR(5)   NOT NULL CONSTRAINT ck_rc_platform CHECK (platform IN ('Uber','Bolt')),
    service_tier        VARCHAR(10)  NOT NULL CONSTRAINT ck_rc_tier CHECK (service_tier IN ('Economy','Standard','Comfort','XL')),
    base_fare_zar       DECIMAL(6,2) NOT NULL CONSTRAINT ck_rc_base CHECK (base_fare_zar > 0)
);

CREATE TABLE ride.cancellation_reason (
    cancellation_reason_id TINYINT     NOT NULL CONSTRAINT pk_cancellation_reason PRIMARY KEY,
    reason_text            VARCHAR(25) NOT NULL CONSTRAINT uq_cancellation_reason UNIQUE,
    reason_group           VARCHAR(11) NOT NULL CONSTRAINT ck_cr_group CHECK (reason_group IN ('Price','Supply','Rider','Driver','Payment','Operational'))
);

/* ---------- Party dimensions ---------- */
CREATE TABLE ride.rider (
    rider_id                    CHAR(7)      NOT NULL CONSTRAINT pk_rider PRIMARY KEY,
    first_name                  VARCHAR(40)  NOT NULL,
    last_name                   VARCHAR(40)  NOT NULL,
    age_band                    VARCHAR(6)   NOT NULL CONSTRAINT ck_rider_age CHECK (age_band IN ('18-24','25-34','35-44','45-54','55-64','65+')),
    gender                      VARCHAR(20)  NOT NULL CONSTRAINT ck_rider_gender CHECK (gender IN ('Female','Male','Other/Undisclosed')),
    home_city_id                TINYINT      NOT NULL CONSTRAINT fk_rider_city REFERENCES ride.city(city_id),
    signup_date                 DATE         NOT NULL,
    preferred_payment_method_id TINYINT      NOT NULL CONSTRAINT fk_rider_pm REFERENCES ride.payment_method(payment_method_id),
    loyalty_tier                VARCHAR(10)  NOT NULL CONSTRAINT ck_rider_tier CHECK (loyalty_tier IN ('Bronze','Silver','Gold','Platinum')),
    rider_segment               VARCHAR(12)  NOT NULL CONSTRAINT ck_rider_segment CHECK (rider_segment IN ('Standard','Frequent','Corporate','Occasional')),
    corporate_account_flag      BIT          NOT NULL,
    avg_rider_rating            DECIMAL(3,2) NOT NULL CONSTRAINT ck_rider_rating CHECK (avg_rider_rating BETWEEN 1.00 AND 5.00),
    account_status              VARCHAR(10)  NOT NULL CONSTRAINT ck_rider_status CHECK (account_status IN ('Active','Dormant','Suspended')),
    CONSTRAINT ck_rider_id_format CHECK (rider_id LIKE 'R[0-9][0-9][0-9][0-9][0-9][0-9]')
);

CREATE TABLE ride.vehicle (
    vehicle_id          CHAR(6)      NOT NULL CONSTRAINT pk_vehicle PRIMARY KEY,
    make                VARCHAR(20)  NOT NULL,
    model               VARCHAR(30)  NOT NULL,
    model_year          SMALLINT     NOT NULL CONSTRAINT ck_vehicle_year CHECK (model_year BETWEEN 2000 AND 2030),
    vehicle_age_years   TINYINT      NOT NULL,
    vehicle_category    VARCHAR(10)  NOT NULL CONSTRAINT ck_vehicle_cat CHECK (vehicle_category IN ('Economy','Standard','Comfort','XL')),
    seats               TINYINT      NOT NULL CONSTRAINT ck_vehicle_seats CHECK (seats BETWEEN 2 AND 9),
    fuel_type           VARCHAR(10)  NOT NULL CONSTRAINT ck_vehicle_fuel CHECK (fuel_type IN ('Petrol','Diesel','Hybrid','Electric')),
    colour              VARCHAR(15)  NOT NULL,
    licence_plate       VARCHAR(12)  NOT NULL CONSTRAINT uq_vehicle_plate UNIQUE,
    roadworthy_expiry   DATE         NOT NULL,
    inspection_status   VARCHAR(8)   NOT NULL CONSTRAINT ck_vehicle_insp CHECK (inspection_status IN ('Passed','Failed','Pending'))
);

CREATE TABLE ride.driver (
    driver_id               CHAR(6)      NOT NULL CONSTRAINT pk_driver PRIMARY KEY,
    vehicle_id              CHAR(6)      NOT NULL CONSTRAINT fk_driver_vehicle REFERENCES ride.vehicle(vehicle_id)
                                                  CONSTRAINT uq_driver_vehicle UNIQUE,      -- enforces the 1:1 driver-vehicle rule
    first_name              VARCHAR(40)  NOT NULL,
    last_name               VARCHAR(40)  NOT NULL,
    platform                VARCHAR(5)   NOT NULL CONSTRAINT ck_driver_platform CHECK (platform IN ('Uber','Bolt')),
    operating_city_id       TINYINT      NOT NULL CONSTRAINT fk_driver_city REFERENCES ride.city(city_id),
    onboarding_date         DATE         NOT NULL,
    driver_rating           DECIMAL(3,2) NOT NULL CONSTRAINT ck_driver_rating CHECK (driver_rating BETWEEN 1.00 AND 5.00),
    total_trips_lifetime    INT          NOT NULL CONSTRAINT ck_driver_trips CHECK (total_trips_lifetime >= 0),
    acceptance_rate_pct     DECIMAL(5,2) NOT NULL CONSTRAINT ck_driver_acc  CHECK (acceptance_rate_pct BETWEEN 0 AND 100),
    cancellation_rate_pct   DECIMAL(5,2) NOT NULL CONSTRAINT ck_driver_canc CHECK (cancellation_rate_pct BETWEEN 0 AND 100),
    commission_rate_pct     DECIMAL(4,1) NOT NULL CONSTRAINT ck_driver_comm CHECK (commission_rate_pct BETWEEN 0 AND 50),
    driver_status           VARCHAR(12)  NOT NULL CONSTRAINT ck_driver_status CHECK (driver_status IN ('Active','Inactive','Deactivated')),
    background_check_status VARCHAR(8)   NOT NULL CONSTRAINT ck_driver_bg CHECK (background_check_status IN ('Cleared','Pending'))
);

/* ---------- Facts ---------- */
CREATE TABLE ride.trip (
    trip_id                 CHAR(8)       NOT NULL CONSTRAINT pk_trip PRIMARY KEY,
    rider_id                CHAR(7)       NOT NULL CONSTRAINT fk_trip_rider    REFERENCES ride.rider(rider_id),
    driver_id               CHAR(6)       NOT NULL CONSTRAINT fk_trip_driver   REFERENCES ride.driver(driver_id),
    ride_category_id        TINYINT       NOT NULL CONSTRAINT fk_trip_category REFERENCES ride.ride_category(ride_category_id),
    request_timestamp       DATETIME2(0)  NOT NULL,
    pickup_timestamp        DATETIME2(0)  NULL,
    dropoff_timestamp       DATETIME2(0)  NULL,
    pickup_zone_id          CHAR(5)       NOT NULL CONSTRAINT fk_trip_pickup_zone  REFERENCES ride.zone(zone_id),
    dropoff_zone_id         CHAR(5)       NOT NULL CONSTRAINT fk_trip_dropoff_zone REFERENCES ride.zone(zone_id),
    trip_distance_km        DECIMAL(6,2)  NULL CONSTRAINT ck_trip_dist CHECK (trip_distance_km > 0),
    trip_duration_min       DECIMAL(6,1)  NULL CONSTRAINT ck_trip_dur  CHECK (trip_duration_min > 0),
    wait_time_min           DECIMAL(4,1)  NOT NULL CONSTRAINT ck_trip_wait CHECK (wait_time_min >= 0),
    surge_multiplier        DECIMAL(4,2)  NOT NULL CONSTRAINT ck_trip_surge CHECK (surge_multiplier BETWEEN 1.00 AND 5.00),
    trip_status             VARCHAR(20)   NOT NULL CONSTRAINT ck_trip_status CHECK (trip_status IN
                            ('Completed','Cancelled by Rider','Cancelled by Driver','Payment Failed','No Driver Found')),
    cancellation_reason_id  TINYINT       NULL CONSTRAINT fk_trip_reason REFERENCES ride.cancellation_reason(cancellation_reason_id),
    payment_method_id       TINYINT       NOT NULL CONSTRAINT fk_trip_pm REFERENCES ride.payment_method(payment_method_id),
    is_airport_trip         BIT           NOT NULL,
    -- Derived calendar attributes: deterministic expressions, PERSISTED so they can be indexed.
    -- Day 0 (1900-01-01) was a Monday, so day_of_week_no runs 1 = Monday ... 7 = Sunday.
    hour_of_day             AS CONVERT(TINYINT, DATEPART(HOUR, request_timestamp)) PERSISTED,
    day_of_week_no          AS CONVERT(TINYINT, DATEDIFF(DAY, CONVERT(DATETIME2(0), '19000101', 112), request_timestamp) % 7 + 1) PERSISTED,
    is_weekend              AS CONVERT(BIT, CASE WHEN DATEDIFF(DAY, CONVERT(DATETIME2(0), '19000101', 112), request_timestamp) % 7 >= 5 THEN 1 ELSE 0 END) PERSISTED,
    request_date            AS CONVERT(DATE, request_timestamp) PERSISTED,
    -- Business rules
    CONSTRAINT ck_trip_reason_rule CHECK ((trip_status = 'Completed' AND cancellation_reason_id IS NULL)
                                       OR (trip_status <> 'Completed' AND cancellation_reason_id IS NOT NULL)),
    CONSTRAINT ck_trip_completed_cols CHECK (trip_status <> 'Completed'
                                       OR (pickup_timestamp IS NOT NULL AND dropoff_timestamp IS NOT NULL
                                           AND trip_distance_km IS NOT NULL AND trip_duration_min IS NOT NULL)),
    CONSTRAINT ck_trip_time_order CHECK (pickup_timestamp IS NULL OR
                                        (pickup_timestamp >= request_timestamp AND (dropoff_timestamp IS NULL OR dropoff_timestamp > pickup_timestamp))),
    CONSTRAINT ck_trip_id_format CHECK (trip_id LIKE 'T[0-9][0-9][0-9][0-9][0-9][0-9][0-9]')
);

CREATE TABLE ride.trip_fare (
    fare_id                 CHAR(8)       NOT NULL CONSTRAINT pk_trip_fare PRIMARY KEY,
    trip_id                 CHAR(8)       NOT NULL CONSTRAINT fk_fare_trip REFERENCES ride.trip(trip_id)
                                                   CONSTRAINT uq_fare_trip UNIQUE,          -- enforces 1:0..1 with trip
    base_fare_zar           DECIMAL(8,2)  NOT NULL CONSTRAINT ck_fare_base  CHECK (base_fare_zar >= 0),
    distance_charge_zar     DECIMAL(8,2)  NOT NULL CONSTRAINT ck_fare_dist  CHECK (distance_charge_zar >= 0),
    time_charge_zar         DECIMAL(8,2)  NOT NULL CONSTRAINT ck_fare_time  CHECK (time_charge_zar >= 0),
    surge_premium_zar       DECIMAL(8,2)  NOT NULL CONSTRAINT ck_fare_surge CHECK (surge_premium_zar >= 0),
    booking_fee_zar         DECIMAL(6,2)  NOT NULL CONSTRAINT ck_fare_book  CHECK (booking_fee_zar >= 0),
    toll_fee_zar            DECIMAL(6,2)  NOT NULL CONSTRAINT df_fare_toll  DEFAULT 0 CONSTRAINT ck_fare_toll  CHECK (toll_fee_zar >= 0),
    waiting_charge_zar      DECIMAL(6,2)  NOT NULL CONSTRAINT df_fare_wait  DEFAULT 0 CONSTRAINT ck_fare_wait  CHECK (waiting_charge_zar >= 0),
    promo_discount_zar      DECIMAL(6,2)  NOT NULL CONSTRAINT df_fare_promo DEFAULT 0 CONSTRAINT ck_fare_promo CHECK (promo_discount_zar >= 0),
    tip_amount_zar          DECIMAL(6,2)  NOT NULL CONSTRAINT df_fare_tip   DEFAULT 0 CONSTRAINT ck_fare_tip   CHECK (tip_amount_zar >= 0),
    gross_fare_zar          DECIMAL(9,2)  NOT NULL CONSTRAINT ck_fare_gross CHECK (gross_fare_zar > 0),
    platform_commission_zar DECIMAL(8,2)  NOT NULL CONSTRAINT ck_fare_comm  CHECK (platform_commission_zar >= 0),
    driver_net_payout_zar   DECIMAL(9,2)  NOT NULL CONSTRAINT ck_fare_payout CHECK (driver_net_payout_zar >= 0),
    payment_status          VARCHAR(8)    NOT NULL CONSTRAINT ck_fare_status CHECK (payment_status IN ('Settled','Failed')),
    currency                CHAR(3)       NOT NULL CONSTRAINT df_fare_currency DEFAULT 'ZAR' CONSTRAINT ck_fare_currency CHECK (currency = 'ZAR'),
    settlement_date         DATE          NULL,
    CONSTRAINT ck_fare_settlement_rule CHECK ((payment_status = 'Settled' AND settlement_date IS NOT NULL)
                                           OR (payment_status = 'Failed'  AND settlement_date IS NULL AND driver_net_payout_zar = 0))
);

CREATE TABLE ride.trip_review (
    review_id           CHAR(9)       NOT NULL CONSTRAINT pk_trip_review PRIMARY KEY,
    trip_id             CHAR(8)       NOT NULL CONSTRAINT fk_review_trip REFERENCES ride.trip(trip_id)
                                               CONSTRAINT uq_review_trip UNIQUE,            -- enforces 1:0..1 with trip
    rating_given        TINYINT       NOT NULL CONSTRAINT ck_review_rating CHECK (rating_given BETWEEN 1 AND 5),
    review_timestamp    DATETIME2(0)  NOT NULL,
    review_comment      VARCHAR(200)  NULL,
    review_category     VARCHAR(20)   NOT NULL CONSTRAINT ck_review_cat CHECK (review_category IN
                        ('Punctuality','Pricing & Payment','Driver Behaviour','Route & Navigation','Safety','Vehicle Condition')),
    sentiment_label     VARCHAR(8)    NOT NULL CONSTRAINT ck_review_sent CHECK (sentiment_label IN ('Positive','Neutral','Negative')),
    escalated_flag      BIT           NOT NULL
);

/* ---------- Supplementary reference data (Phase 1, section 2.5) ---------- */
CREATE TABLE ride.public_holiday (
    holiday_date    DATE         NOT NULL CONSTRAINT pk_public_holiday PRIMARY KEY,
    holiday_name    VARCHAR(40)  NOT NULL
);
GO

/* ---------- Indexes that support the Phase 2 query workload ---------- */
-- Rider trip history (LAG/LEAD, FIRST_VALUE, RFM): seek by rider, ordered by time
CREATE NONCLUSTERED INDEX ix_trip_rider_time ON ride.trip (rider_id, request_timestamp)
    INCLUDE (payment_method_id, trip_status, pickup_zone_id);
-- Payment-mix and failure analysis
CREATE NONCLUSTERED INDEX ix_trip_pm_status ON ride.trip (payment_method_id, trip_status)
    INCLUDE (ride_category_id, pickup_zone_id, surge_multiplier);
-- Zone analysis (RQ2, RQ17)
CREATE NONCLUSTERED INDEX ix_trip_pickup_zone ON ride.trip (pickup_zone_id)
    INCLUDE (trip_status, cancellation_reason_id, surge_multiplier, payment_method_id);
-- Filtered index: only the ~18% of rows that were not completed (cancellation / leakage queries)
CREATE NONCLUSTERED INDEX ix_trip_not_completed ON ride.trip (trip_status, cancellation_reason_id)
    INCLUDE (pickup_zone_id, surge_multiplier, payment_method_id)
    WHERE trip_status <> 'Completed';
-- Time-of-day analysis (RQ9) on the persisted computed columns
CREATE NONCLUSTERED INDEX ix_trip_calendar ON ride.trip (day_of_week_no, hour_of_day) INCLUDE (trip_status);
-- Foreign-key support indexes
CREATE NONCLUSTERED INDEX ix_trip_driver ON ride.trip (driver_id);
CREATE NONCLUSTERED INDEX ix_rider_city  ON ride.rider (home_city_id) INCLUDE (age_band, loyalty_tier, rider_segment);
CREATE NONCLUSTERED INDEX ix_zone_city   ON ride.zone (city_id);
-- Column-store index for wide monetary aggregations over the fare fact
CREATE NONCLUSTERED COLUMNSTORE INDEX ncci_trip_fare ON ride.trip_fare
    (trip_id, base_fare_zar, distance_charge_zar, time_charge_zar, surge_premium_zar, booking_fee_zar,
     toll_fee_zar, waiting_charge_zar, promo_discount_zar, tip_amount_zar, gross_fare_zar,
     platform_commission_zar, driver_net_payout_zar, payment_status);
GO
