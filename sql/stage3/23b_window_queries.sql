-- Daily net sales and running total. One row per date with actual sales;
-- no synthetic rows for dates without sales. The window does not change row count.
WITH daily AS (
    SELECT CONVERT(DATE, completed_at) AS sale_date,
           SUM(net_amount) AS sales_amount
    FROM dbo.v_settled_sales_line
    GROUP BY CONVERT(DATE, completed_at)
)
SELECT sale_date, sales_amount,
       SUM(sales_amount) OVER (ORDER BY sale_date ROWS UNBOUNDED PRECEDING) AS cumulative_sales_amount
FROM daily
ORDER BY sale_date;
