/* =====================================================================
   CMPG321 2026 - Group 36 (DormToDorm) - Phase 2
   Script 05: View, integrity trigger, transactional stored procedure,
              and a transaction demonstration (rolled back so data is unchanged)
   ===================================================================== */
USE DormToDorm_RideDB;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* ---------- 1. Reporting view: one row per request, fully enriched ---------- */
CREATE OR ALTER VIEW ride.v_trip_payment
AS
SELECT t.trip_id, t.rider_id, t.driver_id, rc.platform, rc.category_name, rc.service_tier,
       t.request_timestamp, t.request_date, t.hour_of_day, t.day_of_week_no, t.is_weekend, t.is_airport_trip,
       pz.zone_name AS pickup_zone, pz.zone_type AS pickup_zone_type, c.city_name, pr.province_name,
       t.trip_status, cr.reason_text AS cancellation_reason, cr.reason_group,
       p.method_name AS payment_method, p.channel_group, p.is_digital,
       t.trip_distance_km, t.surge_multiplier,
       f.gross_fare_zar, f.tip_amount_zar, f.promo_discount_zar, f.platform_commission_zar,
       f.driver_net_payout_zar, f.payment_status
FROM ride.trip t
JOIN ride.ride_category rc            ON rc.ride_category_id = t.ride_category_id
JOIN ride.zone pz                     ON pz.zone_id = t.pickup_zone_id
JOIN ride.city c                      ON c.city_id = pz.city_id
JOIN ride.province pr                 ON pr.province_code = c.province_code
JOIN ride.payment_method p            ON p.payment_method_id = t.payment_method_id
LEFT JOIN ride.cancellation_reason cr ON cr.cancellation_reason_id = t.cancellation_reason_id
LEFT JOIN ride.trip_fare f            ON f.trip_id = t.trip_id;   -- outer join keeps cancelled requests
GO

/* ---------- 2. Trigger: cross-table rule a CHECK constraint cannot express ----------
   A fare may only exist for a Completed trip (Settled) or a Payment Failed trip (Failed). */
CREATE OR ALTER TRIGGER ride.trg_trip_fare_status_guard
ON ride.trip_fare
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (
        SELECT 1
        FROM inserted i
        JOIN ride.trip t ON t.trip_id = i.trip_id
        WHERE NOT ((t.trip_status = 'Completed'      AND i.payment_status = 'Settled')
                OR (t.trip_status = 'Payment Failed' AND i.payment_status = 'Failed'))
    )
    BEGIN
        THROW 50010, 'Fare payment_status is inconsistent with the trip status.', 1;
    END
END;
GO

/* ---------- 3. Stored procedure: retry a failed payment on a new instrument ----------
   'Payment Failed' requests were declined at pre-authorisation, so the trip never ran and has
   no pickup data. A successful retry therefore records the trip execution details, moves the
   request to 'Completed', settles the fare and computes commission and payout - all-or-nothing. UPDLOCK + HOLDLOCK stop two concurrent retries of the same
   trip from both succeeding (no lost update / double settlement). */
CREATE OR ALTER PROCEDURE ride.usp_retry_failed_payment
    @trip_id            CHAR(8),
    @new_method_name    VARCHAR(15),
    @pickup_timestamp   DATETIME2(0),
    @dropoff_timestamp  DATETIME2(0),
    @trip_distance_km   DECIMAL(6,2),
    @settlement_date    DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @settlement_date = COALESCE(@settlement_date, CAST(SYSDATETIME() AS DATE));

    DECLARE @pm_id TINYINT, @status VARCHAR(20), @rate DECIMAL(4,1);

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @status = t.trip_status, @rate = d.commission_rate_pct
        FROM ride.trip t WITH (UPDLOCK, HOLDLOCK)
        JOIN ride.driver d ON d.driver_id = t.driver_id
        WHERE t.trip_id = @trip_id;

        IF @status IS NULL               THROW 50020, 'Trip does not exist.', 1;
        IF @status <> 'Payment Failed'   THROW 50021, 'Only trips with status Payment Failed can be retried.', 1;

        SELECT @pm_id = payment_method_id FROM ride.payment_method WHERE method_name = @new_method_name;
        IF @pm_id IS NULL                THROW 50022, 'Unknown payment method.', 1;

        -- Trip first, then fare: the trigger validates the final consistent state
        UPDATE ride.trip
        SET    trip_status            = 'Completed',
               cancellation_reason_id = NULL,
               payment_method_id      = @pm_id,
               pickup_timestamp       = @pickup_timestamp,
               dropoff_timestamp      = @dropoff_timestamp,
               trip_distance_km       = @trip_distance_km,
               trip_duration_min      = CAST(DATEDIFF(SECOND, @pickup_timestamp, @dropoff_timestamp) / 60.0 AS DECIMAL(6,1))
        WHERE  trip_id = @trip_id;

        UPDATE ride.trip_fare
        SET    payment_status          = 'Settled',
               settlement_date         = @settlement_date,
               platform_commission_zar = ROUND((gross_fare_zar - tip_amount_zar - toll_fee_zar) * @rate / 100, 2),
               driver_net_payout_zar   = gross_fare_zar - ROUND((gross_fare_zar - tip_amount_zar - toll_fee_zar) * @rate / 100, 2)
        WHERE  trip_id = @trip_id;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

/* ---------- 4. Transaction demonstration (everything is rolled back) ---------- */
SET NOCOUNT ON;
DECLARE @demo_trip CHAR(8) = (SELECT TOP (1) trip_id FROM ride.trip
                              WHERE trip_status = 'Payment Failed' ORDER BY trip_id);

PRINT '--- 4a. Before retry';
SELECT t.trip_id, t.trip_status, p.method_name, f.payment_status, f.gross_fare_zar,
       f.platform_commission_zar, f.driver_net_payout_zar, f.settlement_date
FROM ride.trip t
JOIN ride.payment_method p ON p.payment_method_id = t.payment_method_id
JOIN ride.trip_fare f      ON f.trip_id = t.trip_id
WHERE t.trip_id = @demo_trip;

BEGIN TRANSACTION demo;
    DECLARE @req DATETIME2(0) = (SELECT request_timestamp FROM ride.trip WHERE trip_id = @demo_trip);
    DECLARE @pu DATETIME2(0) = DATEADD(MINUTE, 6, @req), @do DATETIME2(0) = DATEADD(MINUTE, 22, @req);
    EXEC ride.usp_retry_failed_payment @trip_id = @demo_trip, @new_method_name = 'In-App Wallet',
                                       @pickup_timestamp = @pu, @dropoff_timestamp = @do,
                                       @trip_distance_km = 5.40, @settlement_date = '2026-07-02';
    PRINT '--- 4b. Inside the transaction, after the procedure';
    SELECT t.trip_id, t.trip_status, p.method_name, t.trip_distance_km, t.trip_duration_min, f.payment_status,
           f.gross_fare_zar, f.platform_commission_zar, f.driver_net_payout_zar, f.settlement_date
    FROM ride.trip t
    JOIN ride.payment_method p ON p.payment_method_id = t.payment_method_id
    JOIN ride.trip_fare f      ON f.trip_id = t.trip_id
    WHERE t.trip_id = @demo_trip;

    SAVE TRANSACTION before_bad_write;
    BEGIN TRY
        -- Violates the trigger rule: a Completed trip cannot carry a Failed fare
        UPDATE ride.trip_fare SET payment_status = 'Failed', settlement_date = NULL, driver_net_payout_zar = 0
        WHERE trip_id = @demo_trip;
    END TRY
    BEGIN CATCH
        PRINT '--- 4c. Bad write blocked: ' + ERROR_MESSAGE();
        IF XACT_STATE() = 1 ROLLBACK TRANSACTION before_bad_write;  -- undo only to the savepoint
    END CATCH
IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;                          -- demo: leave the dataset untouched

PRINT '--- 4d. After rollback (original state restored)';
SELECT t.trip_id, t.trip_status, p.method_name, f.payment_status, f.gross_fare_zar,
       f.platform_commission_zar, f.driver_net_payout_zar, f.settlement_date
FROM ride.trip t
JOIN ride.payment_method p ON p.payment_method_id = t.payment_method_id
JOIN ride.trip_fare f      ON f.trip_id = t.trip_id
WHERE t.trip_id = @demo_trip;

PRINT '--- 4e. Business-rule check: retrying a completed trip is refused';
BEGIN TRY
    EXEC ride.usp_retry_failed_payment @trip_id = 'T0000001', @new_method_name = 'Cash',
         @pickup_timestamp = '2026-01-26 01:07:18', @dropoff_timestamp = '2026-01-26 01:30:36', @trip_distance_km = 9.53;
END TRY
BEGIN CATCH
    PRINT 'Refused: ' + ERROR_MESSAGE();
END CATCH;
GO
