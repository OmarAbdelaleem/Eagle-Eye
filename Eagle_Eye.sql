{{ config(
    schema = 'sales_data',
    alias = 'After_Sales_Eagle_Eye',
    materialized = 'table',
    tags=["internal"]
) }}

WITH base_extraction AS (
    SELECT DISTINCT
        orders.updated_at AS updated_date,
        CAST(orders.payload:"orderID" AS varchar) AS order_id,
        CAST(orders.payload:"sales_repID" AS varchar) AS sales_rep_id,
        TRIM(CAST(orders.payload:"status" AS varchar)) AS order_status,
        CAST(orders.created_at AS date) AS order_creation_date,
        CAST(orders.payload:"country" AS varchar) AS country,
        CAST((
            CAST(
                after_sale_request.value:"createdAt":"$date" AS varchar
            ) AS numeric) / 1000
        ) AS timestamp) AS request_date,
        CAST((
            CAST(
                CAST(
                    orders.payload:"deliveryDate":"$date" AS varchar
                ) AS numeric
            )
            / 1000
        ) AS timestamp) AS order_delivery_date,
        'Customer ' || HASH(orders.payload:"customerInformation":"customerName", 'sha256') AS customer_name,
        'XXXXXXXXXX' AS customer_number, -- Anonymizing customer numbers
        CASE
            WHEN CAST(after_sale_request.value:"status" AS varchar) IN (
                'failed', 'succeeded', 'cancelled'
            )
            THEN CAST(orders.updated_at AS date)
        END AS closed_at,
        CASE
            WHEN CAST(after_sale_request.value:"status" AS varchar) IN (
                'failed', 'succeeded', 'cancelled'
            )
            THEN DATEDIFF(Dd, request_date, updated_date)
        END AS request_to_closed_sla,
        CAST(after_sale_request.value:"requestId" AS varchar) AS request_id,
        CAST(
            events.value:"afterSalesRequest":"agentId" AS varchar
        ) AS agent_id,
        CAST(orderlines.value:"productId" AS varchar) AS product_id,
        CAST(orderlines.value:"productName" AS varchar) AS product_name,
        CAST(after_sale_request.value:"type" AS varchar) AS req_type,
        CAST(res.value:"reason" AS varchar) AS reason,
        CAST(res.value:"quantity" AS number) AS quantity,
        CAST(orderlines.value:"orderLineId" AS varchar) AS orderline_id,
        CAST(res.value:"issueSummary" AS varchar) AS summary,
        CAST(after_sale_request.value:"status" AS varchar) AS req_status,
        CAST(orderlines.value:"type" AS varchar) AS orderlines_type,
        CAST(orderlines.value:"status" AS varchar) AS orderlines_status,
        CAST(
            after_sale_request.value:"bankInformation":"bankName" AS varchar
        ) AS first_bank_name,
        CAST(
            after_sale_request.value:"bankInformation":"iBan" AS varchar
        ) AS first_iban,
        CAST(
            after_sale_request.value:"bankInformation":"fullName" AS varchar
        ) AS first_cst_bank_name,
        CAST(
            after_sale_request.value:"cashOnDelivery" AS varchar
        ) AS cost,
        FIRST_VALUE(first_bank_name) OVER (
            PARTITION BY order_id
            ORDER BY
                orders.updated_at ASC
        ) AS final_bank_name,
        FIRST_VALUE(first_iban) OVER (
            PARTITION BY order_id
            ORDER BY
                orders.updated_at ASC
        ) AS final_iban,
        FIRST_VALUE(first_cst_bank_name) OVER (
            PARTITION BY order_id
            ORDER BY
                orders.updated_at ASC
        ) AS final_cst_name,
        CASE
            WHEN orderlines_type = 'after_sales'
            THEN CAST(orderlines.value:"trackingNumber" AS varchar)
            WHEN orderlines_type IS NULL
            THEN CAST(orderlines.value:"trackingNumber" AS varchar)
        END AS aftersale_awb,
        ROW_NUMBER() OVER (
            PARTITION BY
                order_id,
                request_id,
                agent_id
            ORDER BY
                orders.updated_at DESC
        ) AS rn
    FROM
        {{ source('mongo_db_landing','orders_src') }} AS orders,
        Lateral FLATTEN(payload:"afterSalesRequests") AS after_sale_request,
        Lateral FLATTEN(after_sale_request.value:"requestedLines") AS res,
        Lateral FLATTEN(payload:"orderLines") AS orderlines,
        Lateral FLATTEN(payload:"events") AS events
    WHERE
        orderlines_type != 'initial'
        AND agent_id IS NOT NULL
    QUALIFY rn = 1
)

SELECT
    base_extraction.order_id AS order_id,
    base_extraction.sales_rep_id AS sales_rep_id,
    base_extraction.order_status AS order_status,
    base_extraction.order_creation_date AS order_creation_date,
    base_extraction.order_delivery_date AS order_delivery_date,
    base_extraction.country AS country,
    base_extraction.request_date AS request_date,
    base_extraction.request_to_closed_sla AS request_to_closed_sla,
    base_extraction.customer_number AS customer_number,
    base_extraction.closed_at AS closed_at,
    base_extraction.request_id AS request_id,
    base_extraction.product_id AS product_id,
    base_extraction.product_name AS product_name,
    base_extraction.req_type AS req_type,
    base_extraction.reason AS reason,
    base_extraction.quantity AS quantity,
    base_extraction.req_status AS req_status,
    base_extraction.orderlines_status AS orderlines_status,
    base_extraction.aftersale_awb AS aftersale_awb,
    COALESCE(base_extraction.agent_id, -1) AS agent_id,
    base_extraction.customer_name AS customer_name,
    Coalesce(base_extraction.final_bank_name, 'No Bank Name') AS bank_name,
    Coalesce(base_extraction.final_iban, 'NO IBAN') AS iban,
    Coalesce(base_extraction.cost, 'No Bank Cost') AS cost,
    Coalesce(base_extraction.final_cst_name, 'No Bank Name')
        AS customer_bank_name,
    COALESCE(base_extraction.summary, 'No summary') AS summary
FROM
    base_extraction
QUALIFY Row_Number() OVER (
    PARTITION BY base_extraction.order_id
    ORDER BY
        base_extraction.updated_date DESC
) = 1
