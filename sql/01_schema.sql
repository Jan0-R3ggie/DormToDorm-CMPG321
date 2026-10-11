-- 1. VEHICLES
CREATE TABLE vehicles (
    vehicle_id            CHAR(6)         PRIMARY KEY,
    make                  VARCHAR(30)     NOT NULL,
    model                 VARCHAR(30)     NOT NULL,
    model_year            SMALLINT        NOT NULL,
    vehicle_age_years     SMALLINT        NOT NULL,
    vehicle_category      VARCHAR(20)     NOT NULL CHECK (vehicle_category IN ('Standard', 'Comfort', 'Economy', 'XL')),
    seats                 SMALLINT        NOT NULL CHECK (seats BETWEEN 2 AND 10),
    fuel_type             VARCHAR(20)     NOT NULL CHECK (fuel_type IN ('Petrol', 'Hybrid', 'Diesel', 'Electric')),
    colour                VARCHAR(20)     NOT NULL,
    licence_plate         VARCHAR(20)     NOT NULL UNIQUE,
    roadworthy_expiry     DATE            NOT NULL,
    inspection_status     VARCHAR(20)     NOT NULL CHECK (inspection_status IN ('Passed', 'Pending', 'Failed'))
);

-- 2. PRICING & SURGE ZONES
CREATE TABLE pricing_surge_zones (
    zone_id                 CHAR(5)         PRIMARY KEY,
    zone_name               VARCHAR(50)     NOT NULL,
    city                    VARCHAR(30)     NOT NULL,
    province                VARCHAR(30)     NOT NULL CHECK (province IN ('Gauteng', 'Western Cape', 'KwaZulu-Natal', 'Eastern Cape', 'North West')),
    zone_type               VARCHAR(30)     NOT NULL CHECK (zone_type IN ('Business District', 'Residential', 'Campus', 'Township', 'Airport', 'Nightlife', 'Retail Hub')),
    base_fare_zar           DECIMAL(6,2)    NOT NULL,
    per_km_rate_zar         DECIMAL(6,2)    NOT NULL,
    per_minute_rate_zar     DECIMAL(6,2)    NOT NULL,
    minimum_fare_zar        DECIMAL(6,2)    NOT NULL,
    booking_fee_zar         DECIMAL(6,2)    NOT NULL,
    avg_surge_multiplier    DECIMAL(4,2)    NOT NULL,
    max_surge_multiplier    DECIMAL(4,2)    NOT NULL,
    peak_window             VARCHAR(20)     NOT NULL,
    avg_driver_supply_index DECIMAL(4,2)    NOT NULL,
    toll_route_flag         CHAR(1)         NOT NULL CHECK (toll_route_flag IN ('Y', 'N'))
);

-- 3. SA DRIVERS
CREATE TABLE sa_drivers (
    driver_id               CHAR(6)         PRIMARY KEY,
    vehicle_id              CHAR(6)         NOT NULL UNIQUE REFERENCES vehicles(vehicle_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    first_name              VARCHAR(40)     NOT NULL,
    last_name               VARCHAR(40)     NOT NULL,
    platform                VARCHAR(10)     NOT NULL CHECK (platform IN ('Uber', 'Bolt')),
    operating_city          VARCHAR(30)     NOT NULL,
    province                VARCHAR(30)     NOT NULL,
    onboarding_date         DATE            NOT NULL,
    driver_rating           DECIMAL(3,2)    NOT NULL CHECK (driver_rating BETWEEN 1.00 AND 5.00),
    total_trips_lifetime    INT             NOT NULL,
    acceptance_rate_pct     DECIMAL(5,2)    NOT NULL,
    cancellation_rate_pct   DECIMAL(5,2)    NOT NULL,
    commission_rate_pct     DECIMAL(5,2)    NOT NULL,
    driver_status           VARCHAR(20)     NOT NULL CHECK (driver_status IN ('Active', 'Inactive', 'Deactivated')),
    background_check_status VARCHAR(20)     NOT NULL CHECK (background_check_status IN ('Cleared', 'Pending'))
);

-- 4. SA RIDERS
CREATE TABLE sa_riders (
    rider_id                 CHAR(7)         PRIMARY KEY,
    first_name               VARCHAR(40)     NOT NULL,
    last_name                VARCHAR(40)     NOT NULL,
    age_band                 VARCHAR(10)     NOT NULL CHECK (age_band IN ('18-24', '25-34', '35-44', '45-54', '55-64', '65+')),
    gender                   VARCHAR(25)     NOT NULL CHECK (gender IN ('Female', 'Male', 'Other/Undisclosed')),
    home_city                VARCHAR(30)     NOT NULL,
    province                 VARCHAR(30)     NOT NULL,
    signup_date              DATE            NOT NULL,
    preferred_payment_method VARCHAR(25)     NOT NULL,
    loyalty_tier             VARCHAR(15)     NOT NULL CHECK (loyalty_tier IN ('Bronze', 'Silver', 'Gold', 'Platinum')),
    rider_segment            VARCHAR(20)     NOT NULL CHECK (rider_segment IN ('Standard', 'Frequent', 'Corporate', 'Occasional')),
    corporate_account_flag   CHAR(1)         NOT NULL CHECK (corporate_account_flag IN ('Y', 'N')),
    avg_rider_rating         DECIMAL(3,2)    NOT NULL CHECK (avg_rider_rating BETWEEN 1.00 AND 5.00),
    account_status           VARCHAR(15)     NOT NULL CHECK (account_status IN ('Active', 'Dormant', 'Suspended'))
);

-- 5. TRIP HEADERS
CREATE TABLE trip_headers (
    trip_id                 CHAR(8)         PRIMARY KEY,
    rider_id                CHAR(7)         NOT NULL REFERENCES sa_riders(rider_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    driver_id               CHAR(6)         NOT NULL REFERENCES sa_drivers(driver_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    vehicle_id              CHAR(6)         NOT NULL REFERENCES vehicles(vehicle_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    platform                VARCHAR(10)     NOT NULL CHECK (platform IN ('Uber', 'Bolt')),
    ride_category           VARCHAR(25)     NOT NULL,
    request_timestamp       TIMESTAMP       NOT NULL,
    pickup_timestamp        TIMESTAMP       NULL,
    dropoff_timestamp       TIMESTAMP       NULL,
    pickup_zone_id          CHAR(5)         NOT NULL REFERENCES pricing_surge_zones(zone_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    dropoff_zone_id         CHAR(5)         NOT NULL REFERENCES pricing_surge_zones(zone_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    city                    VARCHAR(30)     NOT NULL,
    province                VARCHAR(30)     NOT NULL,
    trip_distance_km        DECIMAL(6,2)    NULL,
    trip_duration_min       DECIMAL(6,1)    NULL,
    wait_time_min           DECIMAL(4,1)    NOT NULL,
    surge_multiplier        DECIMAL(4,2)    NOT NULL,
    trip_status             VARCHAR(25)     NOT NULL CHECK (trip_status IN ('Completed', 'Cancelled by Rider', 'Cancelled by Driver', 'Payment Failed', 'No Driver Found')),
    cancellation_reason     VARCHAR(40)     NULL,
    payment_method          VARCHAR(25)     NOT NULL,
    day_of_week             VARCHAR(15)     NOT NULL,
    hour_of_day             SMALLINT        NOT NULL CHECK (hour_of_day BETWEEN 0 AND 23),
    is_weekend              CHAR(1)         NOT NULL CHECK (is_weekend IN ('Y', 'N')),
    is_airport_trip         CHAR(1)         NOT NULL CHECK (is_airport_trip IN ('Y', 'N'))
);

-- 6. TRIP FARE BREAKDOWN
CREATE TABLE trip_fare_breakdown (
    fare_id                 CHAR(8)         PRIMARY KEY,
    trip_id                 CHAR(8)         NOT NULL UNIQUE REFERENCES trip_headers(trip_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    base_fare_zar           DECIMAL(8,2)    NOT NULL,
    distance_charge_zar     DECIMAL(8,2)    NOT NULL,
    time_charge_zar         DECIMAL(8,2)    NOT NULL,
    surge_premium_zar       DECIMAL(8,2)    NOT NULL,
    booking_fee_zar         DECIMAL(6,2)    NOT NULL,
    toll_fee_zar            DECIMAL(6,2)    NOT NULL,
    waiting_charge_zar      DECIMAL(6,2)    NOT NULL,
    promo_discount_zar      DECIMAL(6,2)    NOT NULL,
    tip_amount_zar          DECIMAL(6,2)    NOT NULL,
    gross_fare_zar          DECIMAL(9,2)    NOT NULL,
    platform_commission_zar DECIMAL(8,2)    NOT NULL,
    driver_net_payout_zar   DECIMAL(9,2)    NOT NULL,
    payment_method          VARCHAR(25)     NOT NULL,
    payment_status          VARCHAR(15)     NOT NULL CHECK (payment_status IN ('Settled', 'Failed')),
    currency                CHAR(3)         NOT NULL DEFAULT 'ZAR' CHECK (currency = 'ZAR'),
    settlement_date         DATE            NULL
);

-- 7. TRIP REVIEWS
CREATE TABLE trip_reviews (
    review_id               CHAR(9)         PRIMARY KEY,
    trip_id                 CHAR(8)         NOT NULL UNIQUE REFERENCES trip_headers(trip_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    rider_id                CHAR(7)         NOT NULL REFERENCES sa_riders(rider_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    driver_id               CHAR(6)         NOT NULL REFERENCES sa_drivers(driver_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    rating_given            SMALLINT        NOT NULL CHECK (rating_given BETWEEN 1 AND 5),
    review_timestamp        TIMESTAMP       NOT NULL,
    review_comment          VARCHAR(150)    NOT NULL,
    review_category         VARCHAR(35)     NOT NULL CHECK (review_category IN ('Driver Behaviour', 'Pricing & Payment', 'Route & Navigation', 'Safety', 'Punctuality', 'Vehicle Condition')),
    sentiment_label         VARCHAR(15)     NOT NULL CHECK (sentiment_label IN ('Positive', 'Neutral', 'Negative')),
    escalated_flag          CHAR(1)         NOT NULL CHECK (escalated_flag IN ('Y', 'N'))
);