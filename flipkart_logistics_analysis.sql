-- CREATE DATABASE
-- =========================================

CREATE DATABASE flipkart_project;

USE flipkart_project;

DESC orders;

SHOW TABLES;

SELECT COUNT(*) FROM orders;

-- =========================================
-- CREATE TABLE
-- =========================================

CREATE TABLE orders (
    Order_ID VARCHAR(20),
    Customer_ID VARCHAR(20),
    Warehouse_ID VARCHAR(20),
    Route_ID VARCHAR(20),
    Agent_ID VARCHAR(20),
    Order_Date DATE,
    Expected_Delivery_Date DATE,
    Actual_Delivery_Date DATE,
    Traffic_Delay_Min INT,
    Order_Value DECIMAL(10,2),
    Delivery_Status VARCHAR(50),
    Date_Flag VARCHAR(20)
);

-- =========================================
-- CHECK TABLE
-- =========================================

DESC orders;

-- =========================================
-- TASK 1 : DATA CLEANING
-- =========================================

-- Remove duplicate Order_ID records

DELETE FROM orders
WHERE Order_ID IN (
    SELECT Order_ID
    FROM (
        SELECT 
            Order_ID,
            ROW_NUMBER() OVER (
                PARTITION BY Order_ID
                ORDER BY Order_ID
            ) AS rn
        FROM orders
    ) t
    WHERE rn > 1
);
SELECT * FROM orders;

-- Replace NULL Traffic_Delay_Min values

UPDATE orders o
JOIN (
    SELECT 
        Route_ID,
        AVG(Traffic_Delay_Min) AS Avg_Delay
    FROM orders
    WHERE Traffic_Delay_Min IS NOT NULL
    GROUP BY Route_ID
) r
ON o.Route_ID = r.Route_ID

SET o.Traffic_Delay_Min = r.Avg_Delay

WHERE o.Traffic_Delay_Min IS NULL;


SET SQL_SAFE_UPDATES = 0;

#Convert all date columns into YYYY-MM-DD format using SQL functions.#

SELECT 
    DATE_FORMAT(Order_Date, '%Y-%m-%d') AS Formatted_Order_Date,
    DATE_FORMAT(Expected_Delivery_Date, '%Y-%m-%d') AS Formatted_Expected_Date,
    DATE_FORMAT(Actual_Delivery_Date, '%Y-%m-%d') AS Formatted_Actual_Date
FROM orders;

-- Flag invalid dates

UPDATE orders
SET Date_Flag = 'INVALID'
WHERE Actual_Delivery_Date < Order_Date;

UPDATE orders
SET Date_Flag = 'VALID'
WHERE Actual_Delivery_Date >= Order_Date;


-- =========================================
-- TASK 2 : DELIVERY DELAY ANALYSIS
-- =========================================
-- Calculate delivery delay
SELECT 
    Order_ID,
    Warehouse_ID,
    Route_ID,
    Order_Date,
    Actual_Delivery_Date,
    DATEDIFF(Actual_Delivery_Date, Order_Date) AS Delay_Days
FROM orders;


-- Average delivery delay

SELECT 
    AVG(DATEDIFF(Actual_Delivery_Date, Order_Date)) 
    AS Avg_Delivery_Delay
FROM orders;

-- Top 10 delayed routes

SELECT 
    Route_ID,
    AVG(DATEDIFF(Actual_Delivery_Date, Order_Date)) 
    AS Avg_Delay
FROM orders
GROUP BY Route_ID
ORDER BY Avg_Delay DESC
LIMIT 10;

-- Rank orders within each warehouse

SELECT 
    Order_ID,
    Warehouse_ID,
    Route_ID,
    DATEDIFF(Actual_Delivery_Date, Order_Date) 
    AS Delay_Days,

    RANK() OVER (
        PARTITION BY Warehouse_ID
        ORDER BY DATEDIFF(
            Actual_Delivery_Date,
            Order_Date
        ) DESC
    ) AS Delay_Rank

FROM orders;

-- =========================================
-- TASK 3 : ROUTE OPTIMIZATION
-- =========================================
-- Average delivery time and traffic delay

SELECT 
    Route_ID,

    AVG(
        DATEDIFF(
            Actual_Delivery_Date,
            Order_Date
        )
    ) AS Avg_Delivery_Time_Days,

    AVG(Traffic_Delay_Min)
    AS Avg_Traffic_Delay_Min

FROM orders
GROUP BY Route_ID;

-- Efficiency ratio
-- (Proxy method because Distance_KM
-- and Travel_Time_Min were not available)

SELECT 
    Route_ID,

    AVG(Order_Value) /
    AVG(
        DATEDIFF(
            Actual_Delivery_Date,
            Order_Date
        )
    ) AS Efficiency_Ratio

FROM orders
GROUP BY Route_ID;

-- 3 worst efficiency routes

SELECT 
    Route_ID,

    AVG(Order_Value) /
    AVG(
        DATEDIFF(
            Actual_Delivery_Date,
            Order_Date
        )
    ) AS Efficiency_Ratio

FROM orders
GROUP BY Route_ID
ORDER BY Efficiency_Ratio ASC
LIMIT 3;

-- Routes with more than 20% delayed shipments
SELECT 
    Route_ID,

    COUNT(*) AS Total_Orders,

    SUM(
        CASE
            WHEN Actual_Delivery_Date >
                 Expected_Delivery_Date
            THEN 1
            ELSE 0
        END
    ) AS Delayed_Orders,

    (
        SUM(
            CASE
                WHEN Actual_Delivery_Date >
                     Expected_Delivery_Date
                THEN 1
                ELSE 0
            END
        ) * 100.0 / COUNT(*)
    ) AS Delay_Percentage

FROM orders

GROUP BY Route_ID

HAVING (
    SUM(
        CASE
            WHEN Actual_Delivery_Date >
                 Expected_Delivery_Date
            THEN 1
            ELSE 0
        END
    ) * 100.0 / COUNT(*)
) > 20;


-- RECOMMENDATION:
-- Routes with high delay percentage and
-- low efficiency ratio should be optimized
-- using better scheduling, traffic reduction,
-- and route planning strategies.

-- =========================================
-- TASK 4 : WAREHOUSE PERFORMANCE ANALYSIS

-- Top 3 warehouses with highest average processing time

SELECT 
    Warehouse_ID,

    AVG(
        DATEDIFF(
            Actual_Delivery_Date,
            Order_Date
        )
    ) AS Avg_Processing_Time

FROM orders

GROUP BY Warehouse_ID

ORDER BY Avg_Processing_Time DESC

LIMIT 3;

-- =========================================

-- Total vs delayed shipments for each warehouse

SELECT 
    Warehouse_ID,

    COUNT(*) AS Total_Shipments,

    SUM(
        CASE
            WHEN Actual_Delivery_Date >
                 Expected_Delivery_Date
            THEN 1
            ELSE 0
        END
    ) AS Delayed_Shipments

FROM orders

GROUP BY Warehouse_ID;

-- =========================================

-- Bottleneck warehouses using CTE
-- Processing time > global average

WITH Warehouse_Avg AS (

    SELECT 
        Warehouse_ID,

        AVG(
            DATEDIFF(
                Actual_Delivery_Date,
                Order_Date
            )
        ) AS Avg_Processing_Time

    FROM orders

    GROUP BY Warehouse_ID
),

Global_Avg AS (

    SELECT 
        AVG(
            DATEDIFF(
                Actual_Delivery_Date,
                Order_Date
            )
        ) AS Global_Avg_Time

    FROM orders
)

SELECT 
    w.Warehouse_ID,
    w.Avg_Processing_Time

FROM Warehouse_Avg w
JOIN Global_Avg g

ON w.Avg_Processing_Time >
   g.Global_Avg_Time;

-- =========================================

-- Rank warehouses by on-time delivery percentage

-- Top 3 warehouses with highest average processing time

SELECT 
    Warehouse_ID,

    AVG(
        DATEDIFF(
            Actual_Delivery_Date,
            Order_Date
        )
    ) AS Avg_Processing_Time

FROM orders

GROUP BY Warehouse_ID

ORDER BY Avg_Processing_Time DESC

LIMIT 3;

-- Total vs delayed shipments for each warehouse

SELECT 
    Warehouse_ID,

    COUNT(*) AS Total_Shipments,

    SUM(
        CASE
            WHEN Actual_Delivery_Date >
                 Expected_Delivery_Date
            THEN 1
            ELSE 0
        END
    ) AS Delayed_Shipments

FROM orders

GROUP BY Warehouse_ID;

-- Bottleneck warehouses using CTE
-- Processing time > global average

WITH Warehouse_Avg AS (

    SELECT 
        Warehouse_ID,

        AVG(
            DATEDIFF(
                Actual_Delivery_Date,
                Order_Date
            )
        ) AS Avg_Processing_Time

    FROM orders

    GROUP BY Warehouse_ID
),
Global_Avg AS (

    SELECT 
        AVG(
            DATEDIFF(
                Actual_Delivery_Date,
                Order_Date
            )
        ) AS Global_Avg_Time

    FROM orders
)

SELECT 
    w.Warehouse_ID,
    w.Avg_Processing_Time

FROM Warehouse_Avg w
JOIN Global_Avg g
ON w.Avg_Processing_Time >
   g.Global_Avg_Time;

-- =========================================
-- Rank warehouses by on-time delivery percentage

SELECT 
    Warehouse_ID,

    (
        SUM(
            CASE
                WHEN Actual_Delivery_Date <=
                     Expected_Delivery_Date
                THEN 1
                ELSE 0
            END
        ) * 100.0 / COUNT(*)
    ) AS On_Time_Delivery_Percentage,

    RANK() OVER (
        ORDER BY
        (
            SUM(
                CASE
                    WHEN Actual_Delivery_Date <=
                         Expected_Delivery_Date
                    THEN 1
                     ELSE 0
                END
            ) * 100.0 / COUNT(*)
        ) DESC
    ) AS Warehouse_Rank

FROM orders

GROUP BY Warehouse_ID;

-- =========================================

-- TASK 5 : DELIVERY AGENT PERFORMANCE
-- =========================================

-- Rank agents (per route)
-- by on-time delivery percentage

SELECT 
    Agent_ID,
    Route_ID,

    (
        SUM(
            CASE
                WHEN Actual_Delivery_Date <=
                     Expected_Delivery_Date
                THEN 1
                ELSE 0
            END
        ) * 100.0 / COUNT(*)
    ) AS On_Time_Percentage,
    RANK() OVER (
        PARTITION BY Route_ID
        ORDER BY
        (
            SUM(
                CASE
                    WHEN Actual_Delivery_Date <=
                         Expected_Delivery_Date
                    THEN 1
                    ELSE 0
                END
            ) * 100.0 / COUNT(*)
        ) DESC
    ) AS Agent_Rank

FROM orders
GROUP BY Agent_ID, Route_ID;

-- =========================================

-- Agents with on-time delivery percentage < 80%

SELECT 
    Agent_ID,
    Route_ID,

    (
        SUM(
            CASE
                WHEN Actual_Delivery_Date <=
                     Expected_Delivery_Date
                THEN 1
                ELSE 0
            END
             ) * 100.0 / COUNT(*)
    ) AS On_Time_Percentage

FROM orders

GROUP BY Agent_ID, Route_ID

HAVING On_Time_Percentage < 80;

-- =========================================

-- Compare average speed of
-- top 5 vs bottom 5 agents

-- Top 5 agents

SELECT 
    AVG(Avg_Delivery_Time)
    AS Top5_Avg_Speed
    FROM (

    SELECT 
        Agent_ID,

        AVG(
            DATEDIFF(
                Actual_Delivery_Date,
                Order_Date
            )
        ) AS Avg_Delivery_Time

    FROM orders

    GROUP BY Agent_ID

    ORDER BY Avg_Delivery_Time ASC

    LIMIT 5

) top_agents;
-- =========================================

-- Bottom 5 agents

SELECT 
    AVG(Avg_Delivery_Time)
    AS Bottom5_Avg_Speed

FROM (

    SELECT 
        Agent_ID,

        AVG(
            DATEDIFF(
                Actual_Delivery_Date,
                Order_Date
            )
        ) AS Avg_Delivery_Time

    FROM orders
    GROUP BY Agent_ID

    ORDER BY Avg_Delivery_Time DESC

    LIMIT 5

) bottom_agents;

-- =========================================

-- RECOMMENDATION:
-- Agents with low on-time delivery percentage
-- should receive additional training,
-- optimized workloads, and better route
-- allocation to improve delivery efficiency.

DESC orders;
-- =========================================

-- TASK 6 : SHIPMENT TRACKING ANALYTICS

-- List last checkpoint and checkpoint time
-- for each order

SELECT 
    Order_ID,
    Last_Checkpoint,
    Checkpoint_Time

FROM orders;
-- =========================================

-- Most common delay reasons
-- excluding 'None'

SELECT 
    Delay_Reason,
    COUNT(*) AS Total_Count

FROM orders

WHERE Delay_Reason IS NOT NULL
AND Delay_Reason <> 'None'

GROUP BY Delay_Reason

ORDER BY Total_Count DESC;
-- =========================================

-- Orders with more than
-- 2 delayed checkpoints

SELECT 
    Order_ID,
    Delayed_Checkpoints

FROM orders

WHERE Delayed_Checkpoints > 2;

-- =========================================
-- TASK 7 : FINAL BUSINESS INSIGHTS
-- =========================================

-- Total revenue generated

SELECT 
    SUM(Order_Value)
    AS Total_Revenue

FROM orders;

-- Monthly order trend

SELECT 
    MONTH(Order_Date) AS Month_No,

    COUNT(*) AS Total_Orders

FROM orders
GROUP BY MONTH(Order_Date)
ORDER BY Month_No;

-- Monthly revenue trend

SELECT 
    MONTH(Order_Date) AS Month_No,

    SUM(Order_Value)
    AS Monthly_Revenue

FROM orders
GROUP BY MONTH(Order_Date)
ORDER BY Month_No;

-- Highest revenue generating route

SELECT 
    Route_ID,

    SUM(Order_Value)
    AS Total_Revenue

FROM orders
GROUP BY Route_ID
ORDER BY Total_Revenue DESC
LIMIT 1;

-- Lowest revenue generating route

SELECT 
    Route_ID,

    SUM(Order_Value)
    AS Total_Revenue

FROM orders
GROUP BY Route_ID
ORDER BY Total_Revenue ASC
LIMIT 1;

