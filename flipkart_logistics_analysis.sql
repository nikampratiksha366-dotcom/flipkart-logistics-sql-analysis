-- =========================================================
-- FLIPKART LOGISTICS SQL ANALYSIS
-- Database: MySQL 8.0+
-- ---------------------------------------------------------
-- Improvements applied:
-- 1. Safe reruns (DROP IF EXISTS)
-- 2. Raw + cleaned staging separation
-- 3. Data quality checks
-- 4. Indexes for performance
-- 5. Reusable views and robust KPI logic
-- =========================================================

CREATE DATABASE IF NOT EXISTS flipkart_project;
USE flipkart_project;

SET SQL_SAFE_UPDATES = 0;

-- =========================================================
-- PREPARE RAW DATA TABLE
-- =========================================================

CREATE TABLE IF NOT EXISTS orders_raw (
    Order_ID               VARCHAR(20),
    Customer_ID            VARCHAR(20),
    Warehouse_ID           VARCHAR(20),
    Route_ID               VARCHAR(20),
    Agent_ID               VARCHAR(20),
    Order_Date             DATE,
    Expected_Delivery_Date DATE,
    Actual_Delivery_Date   DATE,
    Traffic_Delay_Min      INT,
    Order_Value            DECIMAL(10,2),
    Delivery_Status        VARCHAR(50),
    Date_Flag              VARCHAR(20)
);

-- Optional CSV import example:
-- LOAD DATA INFILE '/path/to/flipkart_orders.csv'
-- INTO TABLE orders_raw
-- FIELDS TERMINATED BY ','
-- ENCLOSED BY '"'
-- LINES TERMINATED BY '\n'
-- IGNORE 1 LINES;

CREATE TABLE IF NOT EXISTS orders (
    Order_ID               VARCHAR(20),
    Customer_ID            VARCHAR(20),
    Warehouse_ID           VARCHAR(20),
    Route_ID               VARCHAR(20),
    Agent_ID               VARCHAR(20),
    Order_Date             DATE,
    Expected_Delivery_Date DATE,
    Actual_Delivery_Date   DATE,
    Traffic_Delay_Min      INT,
    Order_Value            DECIMAL(10,2),
    Delivery_Status        VARCHAR(50),
    Date_Flag              VARCHAR(20)
);

CREATE TABLE IF NOT EXISTS shipment_tracking (
    Order_ID            VARCHAR(20),
    Last_Checkpoint     VARCHAR(100),
    Checkpoint_Time     DATETIME,
    Delay_Reason        VARCHAR(100),
    Delayed_Checkpoints INT
);

-- Optional shipment tracking CSV import example:
-- LOAD DATA INFILE '/path/to/shipment_tracking.csv'
-- INTO TABLE shipment_tracking
-- FIELDS TERMINATED BY ','
-- ENCLOSED BY '"'
-- LINES TERMINATED BY '\n'
-- IGNORE 1 LINES;

-- =========================================================
-- DATA QUALITY CHECKS
-- =========================================================

SELECT
    'orders_raw' AS table_name,
    COUNT(*) AS total_rows,
    COUNT(DISTINCT Order_ID) AS distinct_order_ids,
    SUM(CASE WHEN Order_ID IS NULL THEN 1 ELSE 0 END) AS null_order_ids,
    SUM(CASE WHEN Order_Date IS NULL THEN 1 ELSE 0 END) AS null_order_dates,
    SUM(CASE WHEN Expected_Delivery_Date IS NULL THEN 1 ELSE 0 END) AS null_expected_dates,
    SUM(CASE WHEN Actual_Delivery_Date IS NULL THEN 1 ELSE 0 END) AS null_actual_dates
FROM orders_raw;

-- =========================================================
-- TASK 1: DATA CLEANING
-- =========================================================

-- MySQL DDL statements implicitly commit. The cleaning steps below are
-- therefore intentionally not wrapped in a transaction.
DROP TABLE IF EXISTS orders_dedup;
CREATE TABLE orders_dedup AS
SELECT Order_ID, Customer_ID, Warehouse_ID, Route_ID, Agent_ID,
       Order_Date, Expected_Delivery_Date, Actual_Delivery_Date,
       Traffic_Delay_Min, Order_Value, Delivery_Status, Date_Flag
FROM (
    SELECT o.*,
           ROW_NUMBER() OVER (
               PARTITION BY Order_ID
               ORDER BY Order_Date, Expected_Delivery_Date, Actual_Delivery_Date
           ) AS rn
    FROM orders_raw o
) t
WHERE rn = 1;

DROP TABLE IF EXISTS orders;
RENAME TABLE orders_dedup TO orders;

-- A primary key requires Order_ID to be both unique and non-NULL.
-- The preceding deduplication keeps one row for NULL IDs too, so remove
-- those rows before creating the key.
DELETE FROM orders WHERE Order_ID IS NULL;
ALTER TABLE orders ADD PRIMARY KEY (Order_ID);

-- Fill missing traffic delay using the route-wise average.
UPDATE orders o
JOIN (
    SELECT Route_ID,
           ROUND(AVG(Traffic_Delay_Min), 0) AS Avg_Delay
    FROM orders
    WHERE Traffic_Delay_Min IS NOT NULL
    GROUP BY Route_ID
) r ON o.Route_ID = r.Route_ID
SET o.Traffic_Delay_Min = r.Avg_Delay
WHERE o.Traffic_Delay_Min IS NULL;

-- Fallback for rows whose route has no known delay value.
UPDATE orders
SET Traffic_Delay_Min = (
    SELECT Avg_All_Delays
    FROM (
        SELECT ROUND(AVG(Traffic_Delay_Min), 0) AS Avg_All_Delays
        FROM orders
    ) AS delay_average
)
WHERE Traffic_Delay_Min IS NULL;

-- Flag missing or inconsistent dates.
UPDATE orders
SET Date_Flag = CASE
    WHEN Order_Date IS NULL
      OR Expected_Delivery_Date IS NULL
      OR Actual_Delivery_Date IS NULL
      OR Actual_Delivery_Date < Order_Date
      OR Expected_Delivery_Date < Order_Date
    THEN 'INVALID'
    ELSE 'VALID'
END;

SELECT Date_Flag, COUNT(*) AS Total_Orders
FROM orders
GROUP BY Date_Flag;

-- =========================================================
-- CREATE ANALYSIS VIEWS
-- =========================================================

CREATE OR REPLACE VIEW valid_orders AS
SELECT
    o.*,
    DATEDIFF(Actual_Delivery_Date, Order_Date) AS Delivery_Days,
    DATEDIFF(Actual_Delivery_Date, Expected_Delivery_Date) AS Delay_Days,
    CASE WHEN Actual_Delivery_Date > Expected_Delivery_Date THEN 1 ELSE 0 END AS Is_Delayed
FROM orders AS o
WHERE Date_Flag = 'VALID';

CREATE OR REPLACE VIEW shipment_summary AS
SELECT
    Order_ID,
    Last_Checkpoint,
    Checkpoint_Time,
    Delay_Reason,
    Delayed_Checkpoints,
    CASE WHEN Delayed_Checkpoints > 2 THEN 1 ELSE 0 END AS Is_Major_Delay
FROM shipment_tracking;

-- =========================================================
-- INDEXES FOR PERFORMANCE (MySQL-compatible, safe to rerun)
-- MySQL does not support CREATE INDEX IF NOT EXISTS. These conditional
-- statements check the index catalog before creating each index.
-- =========================================================

SET @create_index_sql = IF(
    (SELECT COUNT(*) FROM information_schema.statistics
     WHERE table_schema = DATABASE() AND table_name = 'orders' AND index_name = 'idx_orders_route_id') = 0,
    'CREATE INDEX idx_orders_route_id ON orders(Route_ID)',
    'SELECT 1'
);
PREPARE create_index_stmt FROM @create_index_sql;
EXECUTE create_index_stmt;
DEALLOCATE PREPARE create_index_stmt;

SET @create_index_sql = IF(
    (SELECT COUNT(*) FROM information_schema.statistics
     WHERE table_schema = DATABASE() AND table_name = 'orders' AND index_name = 'idx_orders_warehouse_id') = 0,
    'CREATE INDEX idx_orders_warehouse_id ON orders(Warehouse_ID)',
    'SELECT 1'
);
PREPARE create_index_stmt FROM @create_index_sql;
EXECUTE create_index_stmt;
DEALLOCATE PREPARE create_index_stmt;

SET @create_index_sql = IF(
    (SELECT COUNT(*) FROM information_schema.statistics
     WHERE table_schema = DATABASE() AND table_name = 'orders' AND index_name = 'idx_orders_agent_id') = 0,
    'CREATE INDEX idx_orders_agent_id ON orders(Agent_ID)',
    'SELECT 1'
);
PREPARE create_index_stmt FROM @create_index_sql;
EXECUTE create_index_stmt;
DEALLOCATE PREPARE create_index_stmt;

SET @create_index_sql = IF(
    (SELECT COUNT(*) FROM information_schema.statistics
     WHERE table_schema = DATABASE() AND table_name = 'orders' AND index_name = 'idx_orders_order_date') = 0,
    'CREATE INDEX idx_orders_order_date ON orders(Order_Date)',
    'SELECT 1'
);
PREPARE create_index_stmt FROM @create_index_sql;
EXECUTE create_index_stmt;
DEALLOCATE PREPARE create_index_stmt;

SET @create_index_sql = IF(
    (SELECT COUNT(*) FROM information_schema.statistics
     WHERE table_schema = DATABASE() AND table_name = 'orders' AND index_name = 'idx_orders_delivery_status') = 0,
    'CREATE INDEX idx_orders_delivery_status ON orders(Delivery_Status)',
    'SELECT 1'
);
PREPARE create_index_stmt FROM @create_index_sql;
EXECUTE create_index_stmt;
DEALLOCATE PREPARE create_index_stmt;

SET @create_index_sql = IF(
    (SELECT COUNT(*) FROM information_schema.statistics
     WHERE table_schema = DATABASE() AND table_name = 'shipment_tracking' AND index_name = 'idx_tracking_order_id') = 0,
    'CREATE INDEX idx_tracking_order_id ON shipment_tracking(Order_ID)',
    'SELECT 1'
);
PREPARE create_index_stmt FROM @create_index_sql;
EXECUTE create_index_stmt;
DEALLOCATE PREPARE create_index_stmt;

SET @create_index_sql = IF(
    (SELECT COUNT(*) FROM information_schema.statistics
     WHERE table_schema = DATABASE() AND table_name = 'shipment_tracking' AND index_name = 'idx_tracking_delay_reason') = 0,
    'CREATE INDEX idx_tracking_delay_reason ON shipment_tracking(Delay_Reason)',
    'SELECT 1'
);
PREPARE create_index_stmt FROM @create_index_sql;
EXECUTE create_index_stmt;
DEALLOCATE PREPARE create_index_stmt;

-- =========================================================
-- TASK 2: DELIVERY DELAY ANALYSIS
-- =========================================================

SELECT Order_ID, Warehouse_ID, Route_ID,
       Order_Date, Expected_Delivery_Date, Actual_Delivery_Date,
       Delivery_Days, Delay_Days
FROM valid_orders;

-- Average delivery time and delay for late orders only.
SELECT
    ROUND(AVG(CASE WHEN Delay_Days > 0 THEN Delivery_Days END), 2) AS Avg_Delivery_Days,
    ROUND(AVG(CASE WHEN Delay_Days > 0 THEN Delay_Days END), 2) AS Avg_Delay_Days
FROM valid_orders;

-- Top 10 delayed routes, based on late orders only.
SELECT Route_ID,
       ROUND(AVG(Delay_Days), 2) AS Avg_Delay_Days,
       COUNT(*) AS Total_Orders
FROM valid_orders
WHERE Delay_Days > 0
GROUP BY Route_ID
ORDER BY Avg_Delay_Days DESC
LIMIT 10;

SELECT Order_ID, Warehouse_ID, Route_ID, Delay_Days,
       RANK() OVER (PARTITION BY Warehouse_ID ORDER BY Delay_Days DESC) AS Delay_Rank
FROM valid_orders;

-- =========================================================
-- TASK 3: ROUTE OPTIMIZATION
-- =========================================================

SELECT Route_ID,
       ROUND(AVG(Delivery_Days), 2) AS Avg_Delivery_Time_Days,
       ROUND(AVG(Traffic_Delay_Min), 2) AS Avg_Traffic_Delay_Min
FROM valid_orders
GROUP BY Route_ID;

-- Efficiency proxy: average order value per delivery day.
SELECT Route_ID,
       ROUND(AVG(Order_Value) / NULLIF(AVG(Delivery_Days), 0), 2) AS Efficiency_Ratio
FROM valid_orders
GROUP BY Route_ID
ORDER BY Efficiency_Ratio DESC;

SELECT Route_ID,
       ROUND(AVG(Order_Value) / NULLIF(AVG(Delivery_Days), 0), 2) AS Efficiency_Ratio
FROM valid_orders
GROUP BY Route_ID
HAVING AVG(Order_Value) / NULLIF(AVG(Delivery_Days), 0) IS NOT NULL
ORDER BY Efficiency_Ratio ASC
LIMIT 3;

SELECT Route_ID,
       COUNT(*) AS Total_Orders,
       SUM(Is_Delayed) AS Delayed_Orders,
       ROUND(AVG(Is_Delayed) * 100, 2) AS Delay_Percentage
FROM valid_orders
GROUP BY Route_ID
HAVING ROUND(AVG(Is_Delayed) * 100, 2) > 20
ORDER BY Delay_Percentage DESC;

-- =========================================================
-- TASK 4: WAREHOUSE PERFORMANCE ANALYSIS
-- =========================================================

SELECT Warehouse_ID,
       ROUND(AVG(Delivery_Days), 2) AS Avg_Processing_Time
FROM valid_orders
GROUP BY Warehouse_ID
ORDER BY Avg_Processing_Time DESC
LIMIT 3;

SELECT Warehouse_ID,
       COUNT(*) AS Total_Shipments,
       SUM(Is_Delayed) AS Delayed_Shipments,
       ROUND(AVG(Is_Delayed) * 100, 2) AS Delayed_Percentage
FROM valid_orders
GROUP BY Warehouse_ID;

WITH Warehouse_Avg AS (
    SELECT Warehouse_ID, AVG(Delivery_Days) AS Avg_Processing_Time
    FROM valid_orders
    GROUP BY Warehouse_ID
),
Global_Avg AS (
    SELECT AVG(Delivery_Days) AS Global_Avg_Time
    FROM valid_orders
)
SELECT w.Warehouse_ID,
       ROUND(w.Avg_Processing_Time, 2) AS Avg_Processing_Time,
       ROUND(g.Global_Avg_Time, 2) AS Global_Avg_Time
FROM Warehouse_Avg AS w
CROSS JOIN Global_Avg AS g
WHERE w.Avg_Processing_Time > g.Global_Avg_Time
ORDER BY w.Avg_Processing_Time DESC;

WITH Warehouse_OnTime AS (
    SELECT Warehouse_ID,
           ROUND((1 - AVG(Is_Delayed)) * 100, 2) AS On_Time_Delivery_Percentage
    FROM valid_orders
    GROUP BY Warehouse_ID
)
SELECT Warehouse_ID,
       On_Time_Delivery_Percentage,
       RANK() OVER (ORDER BY On_Time_Delivery_Percentage DESC) AS Warehouse_Rank
FROM Warehouse_OnTime;

-- =========================================================
-- TASK 5: DELIVERY AGENT PERFORMANCE
-- =========================================================

WITH Agent_Route AS (
    SELECT Agent_ID, Route_ID,
           COUNT(*) AS Total_Orders,
           ROUND((1 - AVG(Is_Delayed)) * 100, 2) AS On_Time_Percentage
    FROM valid_orders
    GROUP BY Agent_ID, Route_ID
)
SELECT Agent_ID, Route_ID, Total_Orders, On_Time_Percentage,
       RANK() OVER (PARTITION BY Route_ID ORDER BY On_Time_Percentage DESC) AS Agent_Rank
FROM Agent_Route;

SELECT Agent_ID, Route_ID,
       COUNT(*) AS Total_Orders,
       ROUND((1 - AVG(Is_Delayed)) * 100, 2) AS On_Time_Percentage
FROM valid_orders
GROUP BY Agent_ID, Route_ID
HAVING ROUND((1 - AVG(Is_Delayed)) * 100, 2) < 80
ORDER BY On_Time_Percentage ASC;

WITH Agent_Speed AS (
    SELECT Agent_ID, AVG(Delivery_Days) AS Avg_Delivery_Time
    FROM valid_orders
    GROUP BY Agent_ID
),
Ranked AS (
    SELECT Agent_ID, Avg_Delivery_Time,
           ROW_NUMBER() OVER (ORDER BY Avg_Delivery_Time ASC, Agent_ID) AS fastest_rank,
           ROW_NUMBER() OVER (ORDER BY Avg_Delivery_Time DESC, Agent_ID) AS slowest_rank
    FROM Agent_Speed
)
SELECT
    ROUND(AVG(CASE WHEN fastest_rank <= 5 THEN Avg_Delivery_Time END), 2) AS Top5_Avg_Delivery_Days,
    ROUND(AVG(CASE WHEN slowest_rank <= 5 THEN Avg_Delivery_Time END), 2) AS Bottom5_Avg_Delivery_Days
FROM Ranked;

-- =========================================================
-- TASK 6: SHIPMENT TRACKING ANALYTICS
-- =========================================================

SELECT o.Order_ID, t.Last_Checkpoint, t.Checkpoint_Time
FROM orders AS o
LEFT JOIN shipment_tracking AS t ON o.Order_ID = t.Order_ID;

SELECT Delay_Reason, COUNT(*) AS Total_Count
FROM shipment_tracking
WHERE Delay_Reason IS NOT NULL
  AND TRIM(Delay_Reason) <> ''
  AND UPPER(TRIM(Delay_Reason)) <> 'NONE'
GROUP BY Delay_Reason
ORDER BY Total_Count DESC;

SELECT Order_ID, Delayed_Checkpoints
FROM shipment_tracking
WHERE Delayed_Checkpoints > 2
ORDER BY Delayed_Checkpoints DESC;

-- =========================================================
-- TASK 7: FINAL BUSINESS INSIGHTS
-- =========================================================

SELECT SUM(Order_Value) AS Total_Revenue
FROM orders;

SELECT DATE_FORMAT(Order_Date, '%Y-%m') AS Order_Month,
       COUNT(*) AS Total_Orders
FROM orders
GROUP BY DATE_FORMAT(Order_Date, '%Y-%m')
ORDER BY Order_Month;

SELECT DATE_FORMAT(Order_Date, '%Y-%m') AS Order_Month,
       SUM(Order_Value) AS Monthly_Revenue
FROM orders
GROUP BY DATE_FORMAT(Order_Date, '%Y-%m')
ORDER BY Order_Month;

SELECT Route_ID, SUM(Order_Value) AS Total_Revenue
FROM orders
GROUP BY Route_ID
ORDER BY Total_Revenue DESC
LIMIT 1;

SELECT Route_ID, SUM(Order_Value) AS Total_Revenue
FROM orders
GROUP BY Route_ID
ORDER BY Total_Revenue ASC
LIMIT 1;

-- =========================================================
-- OPTIONAL: FINAL KPI SUMMARY
-- =========================================================

SELECT
    COUNT(*) AS Total_Orders,
    SUM(CASE WHEN Date_Flag = 'VALID' THEN 1 ELSE 0 END) AS Valid_Orders,
    SUM(CASE WHEN Date_Flag = 'INVALID' THEN 1 ELSE 0 END) AS Invalid_Orders,
    ROUND(AVG(CASE WHEN Date_Flag = 'VALID' THEN DATEDIFF(Actual_Delivery_Date, Order_Date) END), 2) AS Avg_Delivery_Days,
    ROUND(SUM(CASE WHEN Actual_Delivery_Date > Expected_Delivery_Date THEN Order_Value ELSE 0 END), 2) AS Late_Delivery_Revenue,
    ROUND(SUM(Order_Value), 2) AS Total_Revenue
FROM orders;
