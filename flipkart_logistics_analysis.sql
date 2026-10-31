-- =========================================================
-- FLIPKART LOGISTICS SQL ANALYSIS
-- Database: MySQL 8.0+
-- =========================================================

CREATE DATABASE IF NOT EXISTS flipkart_project;
USE flipkart_project;

-- Needed for the UPDATE statements below (must run BEFORE them)
SET SQL_SAFE_UPDATES = 0;

-- =========================================================
-- CREATE TABLES
-- =========================================================

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

-- Task 6 needs shipment tracking data. These columns were NOT in the
-- orders table, so they live in a separate table (one row per order).
-- Load your tracking data into this table before running Task 6.
CREATE TABLE IF NOT EXISTS shipment_tracking (
    Order_ID            VARCHAR(20),
    Last_Checkpoint     VARCHAR(100),
    Checkpoint_Time     DATETIME,
    Delay_Reason        VARCHAR(100),
    Delayed_Checkpoints INT
);

-- Load data (Table Data Import Wizard or LOAD DATA INFILE) at this point.

DESC orders;

-- =========================================================
-- TASK 1 : DATA CLEANING
-- =========================================================

-- 1a. Remove duplicate Order_IDs (keep exactly ONE row per Order_ID).
-- The original DELETE ... WHERE Order_ID IN (rn > 1) removed every copy,
-- including the one to keep. Rebuild the table instead.
CREATE TABLE orders_dedup AS
SELECT Order_ID, Customer_ID, Warehouse_ID, Route_ID, Agent_ID,
       Order_Date, Expected_Delivery_Date, Actual_Delivery_Date,
       Traffic_Delay_Min, Order_Value, Delivery_Status, Date_Flag
FROM (
    SELECT o.*,
           ROW_NUMBER() OVER (
               PARTITION BY Order_ID
               ORDER BY Order_Date
           ) AS rn
    FROM orders o
) t
WHERE rn = 1;

DROP TABLE orders;
RENAME TABLE orders_dedup TO orders;

ALTER TABLE orders ADD PRIMARY KEY (Order_ID);

-- 1b. Replace NULL Traffic_Delay_Min with the route average
UPDATE orders o
JOIN (
    SELECT Route_ID, ROUND(AVG(Traffic_Delay_Min)) AS Avg_Delay
    FROM orders
    WHERE Traffic_Delay_Min IS NOT NULL
    GROUP BY Route_ID
) r ON o.Route_ID = r.Route_ID
SET o.Traffic_Delay_Min = r.Avg_Delay
WHERE o.Traffic_Delay_Min IS NULL;

-- Fallback: routes where every value was NULL get the overall average
UPDATE orders
SET Traffic_Delay_Min = (
    SELECT avg_all FROM (
        SELECT ROUND(AVG(Traffic_Delay_Min)) AS avg_all FROM orders
    ) x
)
WHERE Traffic_Delay_Min IS NULL;

-- 1c. Date format check.
-- DATE columns are already stored as YYYY-MM-DD. If the raw file was
-- imported as text (e.g. 15-03-2024), convert it first with:
--   UPDATE orders SET Order_Date = STR_TO_DATE(Order_Date, '%d-%m-%Y');
SELECT
    DATE_FORMAT(Order_Date, '%Y-%m-%d')             AS Formatted_Order_Date,
    DATE_FORMAT(Expected_Delivery_Date, '%Y-%m-%d') AS Formatted_Expected_Date,
    DATE_FORMAT(Actual_Delivery_Date, '%Y-%m-%d')   AS Formatted_Actual_Date
FROM orders
LIMIT 20;

-- 1d. Flag invalid dates (single pass, also catches NULL dates)
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

-- Analysis view: valid rows only, with reusable calculated columns.
--   Delivery_Days = Actual - Order date   (total delivery time)
--   Delay_Days    = Actual - Expected     (negative = early, positive = late)
CREATE OR REPLACE VIEW valid_orders AS
SELECT
    o.*,
    DATEDIFF(Actual_Delivery_Date, Order_Date)             AS Delivery_Days,
    DATEDIFF(Actual_Delivery_Date, Expected_Delivery_Date) AS Delay_Days,
    CASE WHEN Actual_Delivery_Date > Expected_Delivery_Date
         THEN 1 ELSE 0 END                                 AS Is_Delayed
FROM orders o
WHERE Date_Flag = 'VALID';

-- =========================================================
-- TASK 2 : DELIVERY DELAY ANALYSIS
-- =========================================================

-- Delay per order (Delay_Days > 0 means late)
SELECT Order_ID, Warehouse_ID, Route_ID,
       Order_Date, Expected_Delivery_Date, Actual_Delivery_Date,
       Delivery_Days, Delay_Days
FROM valid_orders;

-- Average delivery time and average delay
SELECT
    ROUND(AVG(Delivery_Days), 2) AS Avg_Delivery_Days,
    ROUND(AVG(Delay_Days), 2)    AS Avg_Delay_Days
FROM valid_orders;

-- Top 10 delayed routes
SELECT Route_ID,
       ROUND(AVG(Delay_Days), 2) AS Avg_Delay_Days,
       COUNT(*)                  AS Total_Orders
FROM valid_orders
GROUP BY Route_ID
ORDER BY Avg_Delay_Days DESC
LIMIT 10;

-- Rank orders by delay within each warehouse
SELECT Order_ID, Warehouse_ID, Route_ID, Delay_Days,
       RANK() OVER (
           PARTITION BY Warehouse_ID
           ORDER BY Delay_Days DESC
       ) AS Delay_Rank
FROM valid_orders;

-- =========================================================
-- TASK 3 : ROUTE OPTIMIZATION
-- =========================================================

-- Average delivery time and traffic delay per route
SELECT Route_ID,
       ROUND(AVG(Delivery_Days), 2)      AS Avg_Delivery_Time_Days,
       ROUND(AVG(Traffic_Delay_Min), 2)  AS Avg_Traffic_Delay_Min
FROM valid_orders
GROUP BY Route_ID;

-- Efficiency ratio.
-- PROXY: Distance_KM and Travel_Time_Min are not in the dataset, so
-- efficiency = average order value per day of delivery time.
SELECT Route_ID,
       ROUND(AVG(Order_Value) / NULLIF(AVG(Delivery_Days), 0), 2) AS Efficiency_Ratio
FROM valid_orders
GROUP BY Route_ID
ORDER BY Efficiency_Ratio DESC;

-- 3 worst-efficiency routes
SELECT Route_ID,
       ROUND(AVG(Order_Value) / NULLIF(AVG(Delivery_Days), 0), 2) AS Efficiency_Ratio
FROM valid_orders
GROUP BY Route_ID
HAVING Efficiency_Ratio IS NOT NULL
ORDER BY Efficiency_Ratio ASC
LIMIT 3;

-- Routes with more than 20% delayed shipments
SELECT Route_ID,
       COUNT(*)                          AS Total_Orders,
       SUM(Is_Delayed)                   AS Delayed_Orders,
       ROUND(AVG(Is_Delayed) * 100, 2)   AS Delay_Percentage
FROM valid_orders
GROUP BY Route_ID
HAVING Delay_Percentage > 20
ORDER BY Delay_Percentage DESC;

-- RECOMMENDATION:
-- Routes with a high delay percentage and a low efficiency ratio should be
-- prioritised for better scheduling, traffic avoidance, and route planning.

-- =========================================================
-- TASK 4 : WAREHOUSE PERFORMANCE ANALYSIS
-- =========================================================
-- "Processing time" is proxied by Delivery_Days (order date to delivery),
-- because warehouse dispatch timestamps are not in the dataset.

-- Top 3 warehouses with highest average processing time
SELECT Warehouse_ID,
       ROUND(AVG(Delivery_Days), 2) AS Avg_Processing_Time
FROM valid_orders
GROUP BY Warehouse_ID
ORDER BY Avg_Processing_Time DESC
LIMIT 3;

-- Total vs delayed shipments per warehouse
SELECT Warehouse_ID,
       COUNT(*)                        AS Total_Shipments,
       SUM(Is_Delayed)                 AS Delayed_Shipments,
       ROUND(AVG(Is_Delayed) * 100, 2) AS Delayed_Percentage
FROM valid_orders
GROUP BY Warehouse_ID;

-- Bottleneck warehouses (CTE): processing time above the global average
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
       ROUND(g.Global_Avg_Time, 2)     AS Global_Avg_Time
FROM Warehouse_Avg w
CROSS JOIN Global_Avg g
WHERE w.Avg_Processing_Time > g.Global_Avg_Time
ORDER BY w.Avg_Processing_Time DESC;

-- Rank warehouses by on-time delivery percentage
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
-- TASK 5 : DELIVERY AGENT PERFORMANCE
-- =========================================================

-- Rank agents within each route by on-time delivery percentage
WITH Agent_Route AS (
    SELECT Agent_ID, Route_ID,
           COUNT(*) AS Total_Orders,
           ROUND((1 - AVG(Is_Delayed)) * 100, 2) AS On_Time_Percentage
    FROM valid_orders
    GROUP BY Agent_ID, Route_ID
)
SELECT Agent_ID, Route_ID, Total_Orders, On_Time_Percentage,
       RANK() OVER (
           PARTITION BY Route_ID
           ORDER BY On_Time_Percentage DESC
       ) AS Agent_Rank
FROM Agent_Route;

-- Agents with on-time delivery percentage below 80%
-- (Total_Orders shown because small samples make percentages unreliable)
SELECT Agent_ID, Route_ID,
       COUNT(*) AS Total_Orders,
       ROUND((1 - AVG(Is_Delayed)) * 100, 2) AS On_Time_Percentage
FROM valid_orders
GROUP BY Agent_ID, Route_ID
HAVING On_Time_Percentage < 80
ORDER BY On_Time_Percentage ASC;

-- Average delivery time: top 5 (fastest) vs bottom 5 (slowest) agents
WITH Agent_Speed AS (
    SELECT Agent_ID, AVG(Delivery_Days) AS Avg_Delivery_Time
    FROM valid_orders
    GROUP BY Agent_ID
),
Ranked AS (
    SELECT Agent_ID, Avg_Delivery_Time,
           ROW_NUMBER() OVER (ORDER BY Avg_Delivery_Time ASC,  Agent_ID) AS fastest_rank,
           ROW_NUMBER() OVER (ORDER BY Avg_Delivery_Time DESC, Agent_ID) AS slowest_rank
    FROM Agent_Speed
)
SELECT
    ROUND(AVG(CASE WHEN fastest_rank <= 5 THEN Avg_Delivery_Time END), 2) AS Top5_Avg_Delivery_Days,
    ROUND(AVG(CASE WHEN slowest_rank <= 5 THEN Avg_Delivery_Time END), 2) AS Bottom5_Avg_Delivery_Days
FROM Ranked;

-- RECOMMENDATION:
-- Agents with low on-time delivery percentage should receive additional
-- training, balanced workloads, and better route allocation.

-- =========================================================
-- TASK 6 : SHIPMENT TRACKING ANALYTICS
-- (requires data in the shipment_tracking table)
-- =========================================================

-- Last checkpoint and checkpoint time for each order
SELECT o.Order_ID, t.Last_Checkpoint, t.Checkpoint_Time
FROM orders o
LEFT JOIN shipment_tracking t ON o.Order_ID = t.Order_ID;

-- Most common delay reasons (excluding 'None')
SELECT Delay_Reason, COUNT(*) AS Total_Count
FROM shipment_tracking
WHERE Delay_Reason IS NOT NULL
  AND Delay_Reason <> 'None'
GROUP BY Delay_Reason
ORDER BY Total_Count DESC;

-- Orders with more than 2 delayed checkpoints
SELECT Order_ID, Delayed_Checkpoints
FROM shipment_tracking
WHERE Delayed_Checkpoints > 2
ORDER BY Delayed_Checkpoints DESC;

-- =========================================================
-- TASK 7 : FINAL BUSINESS INSIGHTS
-- (uses all de-duplicated orders)
-- =========================================================

-- Total revenue
SELECT SUM(Order_Value) AS Total_Revenue
FROM orders;

-- Monthly order trend (year + month, so different years are not merged)
SELECT DATE_FORMAT(Order_Date, '%Y-%m') AS Order_Month,
       COUNT(*) AS Total_Orders
FROM orders
GROUP BY DATE_FORMAT(Order_Date, '%Y-%m')
ORDER BY Order_Month;

-- Monthly revenue trend
SELECT DATE_FORMAT(Order_Date, '%Y-%m') AS Order_Month,
       SUM(Order_Value) AS Monthly_Revenue
FROM orders
GROUP BY DATE_FORMAT(Order_Date, '%Y-%m')
ORDER BY Order_Month;

-- Highest revenue generating route
SELECT Route_ID, SUM(Order_Value) AS Total_Revenue
FROM orders
GROUP BY Route_ID
ORDER BY Total_Revenue DESC
LIMIT 1;

-- Lowest revenue generating route
SELECT Route_ID, SUM(Order_Value) AS Total_Revenue
FROM orders
GROUP BY Route_ID
ORDER BY Total_Revenue ASC
LIMIT 1;
