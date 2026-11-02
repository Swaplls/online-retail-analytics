-- 1. Выручка по странам
SELECT
    c.country,
    ROUND(SUM(f.lineamount), 2) AS total_amount
FROM staging.fact_sales f
JOIN staging.dim_customer c
    ON f.customer_id = c.customer_id
GROUP BY c.country
ORDER BY total_amount DESC
LIMIT 10;


-- 2. Динамика по месяцам
SELECT
    d.year,
    d.month,
    ROUND(SUM(f.lineamount), 2) AS total_amount
FROM staging.fact_sales f
JOIN staging.dim_date d
    ON f.sale_date = d.full_date
GROUP BY d.year, d.month
ORDER BY d.year, d.month;


-- 3. Операции по типам
SELECT
    transaction_type,
    COUNT(*) AS operations,
    ROUND(SUM(lineamount), 2) AS total_amount
FROM staging.fact_sales
GROUP BY transaction_type
ORDER BY operations DESC;

-- проверяем возвраты
SELECT
    transactiontype,
    quantity,
    unitprice,
    lineamount,
    invoiceno,
    invoicedate
FROM staging.online_retail_raw
WHERE transactiontype = 'Return'
LIMIT 10;

-- строки не в нужной категории
SELECT
    transactiontype,
    COUNT(*) AS rows_count,
    COUNT(*) FILTER (WHERE quantity < 0) AS negative_quantity,
    COUNT(*) FILTER (WHERE unitprice = 0) AS zero_price,
    COUNT(*) FILTER (WHERE unitprice > 0) AS positive_price,
    ROUND(SUM(lineamount), 2) AS total_amount
FROM staging.online_retail_raw
GROUP BY transactiontype
ORDER BY transactiontype;

-- нужно ли менять правила классификации в Python
SELECT
    COUNT(*) AS negative_quantity_rows,
    COUNT(*) FILTER (WHERE unitprice > 0) AS with_positive_price,
    COUNT(*) FILTER (WHERE unitprice = 0) AS with_zero_price,
    COUNT(*) FILTER (WHERE unitprice < 0) AS with_negative_price
FROM staging.online_retail_raw
WHERE quantity < 0
  AND invoiceno NOT LIKE 'C%';
  
-- Cancellation  
SELECT
    COUNT(*) AS cancellation_rows,
    COUNT(*) FILTER (WHERE quantity < 0) AS negative_quantity,
    COUNT(*) FILTER (WHERE lineamount < 0) AS negative_amount,
    ROUND(SUM(lineamount), 2) AS total_amount
FROM staging.online_retail_raw
WHERE transactiontype = 'Cancellation';


--сумма продаж по месяцам отдельно
SELECT
    d.year,
    d.month,
    ROUND(SUM(f.lineamount) FILTER (
        WHERE f.transaction_type = 'Sale'
    ), 2) AS sales_amount,
    ROUND(SUM(f.lineamount) FILTER (
        WHERE f.transaction_type = 'Cancellation'
    ), 2) AS cancellation_amount
FROM staging.fact_sales f
JOIN staging.dim_date d
    ON f.sale_date = d.full_date
GROUP BY d.year, d.month
ORDER BY d.year, d.month;

-- Средняя сумма счета Sale
SELECT
    COUNT(DISTINCT invoice_no) AS total_invoices,
    ROUND(
        SUM(lineamount) /
        NULLIF(COUNT(DISTINCT invoice_no), 0),
        2
    ) AS average_invoice_amount
FROM staging.fact_sales
WHERE transaction_type = 'Sale';

-- Повторные покупки клиентов
SELECT
    customer_id,
    COUNT(DISTINCT invoice_no) AS orders_count,
    ROUND(SUM(lineamount), 2) AS total_amount
FROM staging.fact_sales
WHERE transaction_type = 'Sale'
  AND customer_id IS NOT NULL
GROUP BY customer_id
HAVING COUNT(DISTINCT invoice_no) > 1
ORDER BY orders_count DESC
LIMIT 10;

-- 3 показателя
WITH customer_orders AS (
    SELECT
        customer_id,
        COUNT(DISTINCT invoice_no) AS orders_count
    FROM staging.fact_sales
    WHERE transaction_type = 'Sale'
      AND customer_id IS NOT NULL
    GROUP BY customer_id
)
SELECT
    COUNT(*) AS total_customers,
    COUNT(*) FILTER (
        WHERE orders_count > 1
    ) AS repeat_customers,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE orders_count > 1)
        / NULLIF(COUNT(*), 0),
        2
    ) AS repeat_customer_percent
FROM customer_orders;

-- Динамика продаж с LAG
WITH monthly_sales AS (
    SELECT
        d.year,
        d.month,
        SUM(f.lineamount) AS sales_amount
    FROM staging.fact_sales f
    JOIN staging.dim_date d
        ON f.sale_date = d.full_date
    WHERE f.transaction_type = 'Sale'
    GROUP BY d.year, d.month
),
sales_comparison AS (
    SELECT
        year,
        month,
        sales_amount,
        LAG(sales_amount) OVER (
            ORDER BY year, month
        ) AS previous_month_sales
    FROM monthly_sales
)
SELECT
    year,
    month,
    ROUND(sales_amount, 2) AS sales_amount,
    ROUND(previous_month_sales, 2) AS previous_month_sales,
    ROUND(
        100.0 * (sales_amount - previous_month_sales)
        / NULLIF(previous_month_sales, 0),
        2
    ) AS growth_percent
FROM sales_comparison
ORDER BY year, month;

-- Последняя покупка каждого клиента
WITH customer_orders AS (
    SELECT
        customer_id,
        invoice_no,
        MAX(sale_date) AS order_date,
        SUM(lineamount) AS order_amount
    FROM staging.fact_sales
    WHERE transaction_type = 'Sale'
      AND customer_id IS NOT NULL
    GROUP BY customer_id, invoice_no
),
ranked_orders AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY customer_id
            ORDER BY order_date DESC, invoice_no DESC
        ) AS rn
    FROM customer_orders
)
SELECT
    customer_id,
    invoice_no,
    order_date,
    ROUND(order_amount, 2) AS order_amount
FROM ranked_orders
WHERE rn = 1
ORDER BY order_date DESC;

-- Рейтинг товаров с RANK
WITH product_sales AS (
    SELECT
        product_id,
        SUM(lineamount) AS sales_amount
    FROM staging.fact_sales
    WHERE transaction_type = 'Sale'
    GROUP BY product_id
),
ranked_products AS (
    SELECT
        product_id,
        sales_amount,
        RANK() OVER (
            ORDER BY sales_amount DESC
        ) AS product_rank
    FROM product_sales
)
SELECT
    product_id,
    ROUND(sales_amount, 2) AS sales_amount,
    product_rank
FROM ranked_products
WHERE product_rank <= 10
ORDER BY product_rank;