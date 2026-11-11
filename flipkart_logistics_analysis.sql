-- Flipkart logistics analysis (MySQL 8)
-- Source tables are in flipkart_project (imported from CSV): flipkart_orders and
-- flipkart_shipmenttracking. This script only reads them.
-- Everything it creates goes into flipkart_project_v2, so it is safe to re-run.

CREATE DATABASE IF NOT EXISTS flipkart_project_v2;
USE flipkart_project_v2;

SET SQL_SAFE_UPDATES = 0;

-- a date that cannot be read becomes NULL (and is flagged below) instead of stopping the script
SET SESSION sql_mode = REPLACE(REPLACE(@@sql_mode, 'STRICT_TRANS_TABLES', ''), 'STRICT_ALL_TABLES', '');

-- check the source data first
SELECT COUNT(*) AS source_orders, COUNT(DISTINCT Order_ID) AS distinct_order_ids
FROM flipkart_project.flipkart_orders;

SELECT Status, COUNT(*) AS total
FROM flipkart_project.flipkart_orders
GROUP BY Status;

-- Task 1: cleaning

-- dates are stored as text in the source, so convert them here
-- handles yyyy-mm-dd, dd-mm-yyyy and dd/mm/yyyy (day first). Anything else becomes NULL.
-- one row per Order_ID (if an id is repeated, keep the earliest order date)
DROP VIEW IF EXISTS valid_orders;
DROP TABLE IF EXISTS orders;

CREATE TABLE orders (
    Order_ID               VARCHAR(20) PRIMARY KEY,
    Warehouse_ID           VARCHAR(20),
    Route_ID               VARCHAR(20),
    Agent_ID               VARCHAR(20),
    Order_Date             DATE,
    Expected_Delivery_Date DATE,
    Actual_Delivery_Date   DATE,
    Delivery_Status        VARCHAR(50),
    Order_Value            DECIMAL(12,2),
    Date_Flag              VARCHAR(20),
    KEY idx_route (Route_ID),
    KEY idx_warehouse (Warehouse_ID),
    KEY idx_agent (Agent_ID),
    KEY idx_order_date (Order_Date)
);

INSERT INTO orders
SELECT Order_ID, Warehouse_ID, Route_ID, Agent_ID,
       Order_Date, Expected_Delivery_Date, Actual_Delivery_Date,
       Status, Order_Value, NULL
FROM (
    SELECT TRIM(Order_ID) AS Order_ID,
           Warehouse_ID, Route_ID, Agent_ID,
           CASE WHEN TRIM(Order_Date) REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN STR_TO_DATE(TRIM(Order_Date), '%Y-%m-%d')
                WHEN TRIM(Order_Date) REGEXP '^[0-9]{2}-[0-9]{2}-[0-9]{4}$' THEN STR_TO_DATE(TRIM(Order_Date), '%d-%m-%Y')
                WHEN TRIM(Order_Date) REGEXP '^[0-9]{2}/[0-9]{2}/[0-9]{4}$' THEN STR_TO_DATE(TRIM(Order_Date), '%d/%m/%Y')
                ELSE NULL END AS Order_Date,
           CASE WHEN TRIM(Expected_Delivery_Date) REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN STR_TO_DATE(TRIM(Expected_Delivery_Date), '%Y-%m-%d')
                WHEN TRIM(Expected_Delivery_Date) REGEXP '^[0-9]{2}-[0-9]{2}-[0-9]{4}$' THEN STR_TO_DATE(TRIM(Expected_Delivery_Date), '%d-%m-%Y')
                WHEN TRIM(Expected_Delivery_Date) REGEXP '^[0-9]{2}/[0-9]{2}/[0-9]{4}$' THEN STR_TO_DATE(TRIM(Expected_Delivery_Date), '%d/%m/%Y')
                ELSE NULL END AS Expected_Delivery_Date,
           CASE WHEN TRIM(Actual_Delivery_Date) REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN STR_TO_DATE(TRIM(Actual_Delivery_Date), '%Y-%m-%d')
                WHEN TRIM(Actual_Delivery_Date) REGEXP '^[0-9]{2}-[0-9]{2}-[0-9]{4}$' THEN STR_TO_DATE(TRIM(Actual_Delivery_Date), '%d-%m-%Y')
                WHEN TRIM(Actual_Delivery_Date) REGEXP '^[0-9]{2}/[0-9]{2}/[0-9]{4}$' THEN STR_TO_DATE(TRIM(Actual_Delivery_Date), '%d/%m/%Y')
                ELSE NULL END AS Actual_Delivery_Date,
           Status, Order_Value,
           ROW_NUMBER() OVER (PARTITION BY TRIM(Order_ID) ORDER BY Order_Date) AS rn
    FROM flipkart_project.flipkart_orders
    WHERE Order_ID IS NOT NULL AND TRIM(Order_ID) <> ''
) t
WHERE rn = 1;

-- mark rows with a missing date or a delivery before the order
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

SELECT Date_Flag, COUNT(*) AS total_orders
FROM orders
GROUP BY Date_Flag;

-- tracking table with a proper datetime column
DROP TABLE IF EXISTS shipment_tracking;

CREATE TABLE shipment_tracking (
    Tracking_ID     VARCHAR(20),
    Order_ID        VARCHAR(20),
    Checkpoint      VARCHAR(100),
    Checkpoint_Time DATETIME,
    Delay_Reason    VARCHAR(100),
    Delay_Minutes   INT,
    KEY idx_tracking_order (Order_ID)
);

INSERT INTO shipment_tracking
SELECT Tracking_ID, TRIM(Order_ID), Checkpoint,
       CASE WHEN TRIM(Checkpoint_Time) REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$'
            THEN STR_TO_DATE(TRIM(Checkpoint_Time), '%Y-%m-%d %H:%i:%s') ELSE NULL END,
       Delay_Reason, Delay_Minutes
FROM flipkart_project.flipkart_shipmenttracking;

-- views used below

CREATE OR REPLACE VIEW valid_orders AS
SELECT o.*,
       DATEDIFF(Actual_Delivery_Date, Order_Date) AS Delivery_Days,
       DATEDIFF(Actual_Delivery_Date, Expected_Delivery_Date) AS Delay_Days,
       CASE WHEN Actual_Delivery_Date > Expected_Delivery_Date THEN 1 ELSE 0 END AS Is_Delayed
FROM orders AS o
WHERE Date_Flag = 'VALID';

-- one row per order: latest checkpoint and how many checkpoints were delayed
CREATE OR REPLACE VIEW shipment_summary AS
SELECT Order_ID,
       MAX(CASE WHEN rn = 1 THEN Checkpoint END) AS Last_Checkpoint,
       MAX(CASE WHEN rn = 1 THEN Checkpoint_Time END) AS Checkpoint_Time,
       SUM(CASE WHEN Delay_Minutes > 0 THEN 1 ELSE 0 END) AS Delayed_Checkpoints,
       SUM(COALESCE(Delay_Minutes, 0)) AS Total_Delay_Min
FROM (
    SELECT t.*,
           ROW_NUMBER() OVER (PARTITION BY Order_ID ORDER BY Checkpoint_Time DESC) AS rn
    FROM shipment_tracking t
) x
GROUP BY Order_ID;

-- Task 2: delivery delays

SELECT Order_ID, Warehouse_ID, Route_ID,
       Order_Date, Expected_Delivery_Date, Actual_Delivery_Date,
       Delivery_Days, Delay_Days
FROM valid_orders;

-- average for late orders only
SELECT ROUND(AVG(CASE WHEN Delay_Days > 0 THEN Delivery_Days END), 2) AS Avg_Delivery_Days,
       ROUND(AVG(CASE WHEN Delay_Days > 0 THEN Delay_Days END), 2) AS Avg_Delay_Days
FROM valid_orders;

-- top 10 routes by delay (late orders only)
SELECT Route_ID,
       ROUND(AVG(Delay_Days), 2) AS Avg_Delay_Days,
       COUNT(*) AS Late_Orders
FROM valid_orders
WHERE Delay_Days > 0
GROUP BY Route_ID
ORDER BY Avg_Delay_Days DESC
LIMIT 10;

SELECT Order_ID, Warehouse_ID, Route_ID, Delay_Days,
       RANK() OVER (PARTITION BY Warehouse_ID ORDER BY Delay_Days DESC) AS Delay_Rank
FROM valid_orders;

-- Task 3: routes

-- tracking delay comes from the shipment_tracking table (Delay_Minutes)
SELECT v.Route_ID,
       ROUND(AVG(v.Delivery_Days), 2) AS Avg_Delivery_Days,
       ROUND(AVG(s.Total_Delay_Min), 2) AS Avg_Tracking_Delay_Min
FROM valid_orders v
LEFT JOIN shipment_summary s ON v.Order_ID = s.Order_ID
GROUP BY v.Route_ID;

-- no distance data, so efficiency = avg order value / avg delivery days
SELECT Route_ID,
       ROUND(AVG(Order_Value) / NULLIF(AVG(Delivery_Days), 0), 2) AS Efficiency_Ratio
FROM valid_orders
GROUP BY Route_ID
ORDER BY Efficiency_Ratio DESC;

-- 3 least efficient routes
SELECT Route_ID,
       ROUND(AVG(Order_Value) / NULLIF(AVG(Delivery_Days), 0), 2) AS Efficiency_Ratio
FROM valid_orders
GROUP BY Route_ID
HAVING AVG(Order_Value) / NULLIF(AVG(Delivery_Days), 0) IS NOT NULL
ORDER BY Efficiency_Ratio ASC
LIMIT 3;

-- routes with more than 20% late orders
SELECT Route_ID,
       COUNT(*) AS Total_Orders,
       SUM(Is_Delayed) AS Delayed_Orders,
       ROUND(AVG(Is_Delayed) * 100, 2) AS Delay_Percentage
FROM valid_orders
GROUP BY Route_ID
HAVING AVG(Is_Delayed) * 100 > 20
ORDER BY Delay_Percentage DESC;

-- Task 4: warehouses

-- 3 warehouses with the longest average delivery time
SELECT Warehouse_ID,
       ROUND(AVG(Delivery_Days), 2) AS Avg_Delivery_Days
FROM valid_orders
GROUP BY Warehouse_ID
ORDER BY Avg_Delivery_Days DESC
LIMIT 3;

SELECT Warehouse_ID,
       COUNT(*) AS Total_Shipments,
       SUM(Is_Delayed) AS Delayed_Shipments,
       ROUND(AVG(Is_Delayed) * 100, 2) AS Delayed_Percentage
FROM valid_orders
GROUP BY Warehouse_ID;

-- warehouses slower than the overall average
WITH Warehouse_Avg AS (
    SELECT Warehouse_ID, AVG(Delivery_Days) AS Avg_Days
    FROM valid_orders
    GROUP BY Warehouse_ID
),
Global_Avg AS (
    SELECT AVG(Delivery_Days) AS Global_Days
    FROM valid_orders
)
SELECT w.Warehouse_ID,
       ROUND(w.Avg_Days, 2) AS Avg_Days,
       ROUND(g.Global_Days, 2) AS Overall_Avg_Days
FROM Warehouse_Avg w
CROSS JOIN Global_Avg g
WHERE w.Avg_Days > g.Global_Days
ORDER BY w.Avg_Days DESC;

-- warehouse ranking by on-time %
WITH Warehouse_OnTime AS (
    SELECT Warehouse_ID,
           ROUND((1 - AVG(Is_Delayed)) * 100, 2) AS On_Time_Percentage
    FROM valid_orders
    GROUP BY Warehouse_ID
)
SELECT Warehouse_ID, On_Time_Percentage,
       RANK() OVER (ORDER BY On_Time_Percentage DESC) AS Warehouse_Rank
FROM Warehouse_OnTime;

-- Task 5: agents

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

-- agents below 80% on-time
SELECT Agent_ID, Route_ID,
       COUNT(*) AS Total_Orders,
       ROUND((1 - AVG(Is_Delayed)) * 100, 2) AS On_Time_Percentage
FROM valid_orders
GROUP BY Agent_ID, Route_ID
HAVING (1 - AVG(Is_Delayed)) * 100 < 80
ORDER BY On_Time_Percentage ASC;

-- average delivery time: 5 fastest agents vs 5 slowest
WITH Agent_Speed AS (
    SELECT Agent_ID, AVG(Delivery_Days) AS Avg_Delivery_Days
    FROM valid_orders
    GROUP BY Agent_ID
),
Ranked AS (
    SELECT Agent_ID, Avg_Delivery_Days,
           ROW_NUMBER() OVER (ORDER BY Avg_Delivery_Days ASC, Agent_ID) AS fastest_rank,
           ROW_NUMBER() OVER (ORDER BY Avg_Delivery_Days DESC, Agent_ID) AS slowest_rank
    FROM Agent_Speed
)
SELECT ROUND(AVG(CASE WHEN fastest_rank <= 5 THEN Avg_Delivery_Days END), 2) AS Top5_Avg_Days,
       ROUND(AVG(CASE WHEN slowest_rank <= 5 THEN Avg_Delivery_Days END), 2) AS Bottom5_Avg_Days
FROM Ranked;

-- Task 6: shipment tracking

-- last checkpoint for every order
SELECT o.Order_ID, s.Last_Checkpoint, s.Checkpoint_Time
FROM orders o
LEFT JOIN shipment_summary s ON o.Order_ID = s.Order_ID;

-- most common delay reasons (ignoring 'None')
SELECT Delay_Reason, COUNT(*) AS Total_Count, SUM(Delay_Minutes) AS Total_Delay_Min
FROM shipment_tracking
WHERE Delay_Reason IS NOT NULL
  AND TRIM(Delay_Reason) <> ''
  AND UPPER(TRIM(Delay_Reason)) <> 'NONE'
GROUP BY Delay_Reason
ORDER BY Total_Count DESC;

-- orders with more than 2 delayed checkpoints
SELECT Order_ID, Delayed_Checkpoints, Total_Delay_Min
FROM shipment_summary
WHERE Delayed_Checkpoints > 2
ORDER BY Delayed_Checkpoints DESC;

-- Task 7: revenue and trends

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

-- best and worst route by revenue
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

-- overall summary
SELECT COUNT(*) AS Total_Orders,
       SUM(CASE WHEN Date_Flag = 'VALID' THEN 1 ELSE 0 END) AS Valid_Orders,
       SUM(CASE WHEN Date_Flag = 'INVALID' THEN 1 ELSE 0 END) AS Invalid_Orders,
       ROUND(AVG(CASE WHEN Date_Flag = 'VALID' THEN DATEDIFF(Actual_Delivery_Date, Order_Date) END), 2) AS Avg_Delivery_Days,
       ROUND(SUM(CASE WHEN Actual_Delivery_Date > Expected_Delivery_Date THEN Order_Value ELSE 0 END), 2) AS Late_Delivery_Revenue,
       ROUND(SUM(Order_Value), 2) AS Total_Revenue
FROM orders;
