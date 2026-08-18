/*
目的:
    配送遅延およびレビュー低評価の分析に利用する、
    顧客・購入月・商品カテゴリ単位の特徴量テーブルを作成する。

想定環境:
    Snowflake

出力粒度:
    customer_unique_id
    × purchase_month
    × product_category_name_english

注意:
    このSQLは既存担当者が作成した分析用SQLである。
    仕様書は完全には残っていない。
*/

WITH delivered_orders AS (
    SELECT
        o.order_id,
        o.customer_id,
        o.order_status,
        o.order_purchase_timestamp,
        o.order_approved_at,
        o.order_delivered_carrier_date,
        o.order_delivered_customer_date,
        o.order_estimated_delivery_date,

        DATE_TRUNC(
            'MONTH',
            o.order_purchase_timestamp
        ) AS purchase_month,

        DATEDIFF(
            'DAY',
            o.order_purchase_timestamp,
            o.order_approved_at
        ) AS approval_days,

        DATEDIFF(
            'DAY',
            o.order_purchase_timestamp,
            o.order_delivered_customer_date
        ) AS delivery_days,

        DATEDIFF(
            'DAY',
            o.order_estimated_delivery_date,
            o.order_delivered_customer_date
        ) AS estimated_delivery_diff_days,

        CASE
            WHEN o.order_delivered_customer_date
                     > o.order_estimated_delivery_date
                THEN 1
            ELSE 0
        END AS is_late_delivery

    FROM raw.olist_orders_dataset AS o

    WHERE o.order_status = 'delivered'
      AND o.order_purchase_timestamp IS NOT NULL
      AND o.order_delivered_customer_date IS NOT NULL
),

customer_orders AS (
    SELECT
        d.order_id,
        d.customer_id,
        c.customer_unique_id,
        c.customer_city,
        c.customer_state,
        c.customer_zip_code_prefix,

        d.order_status,
        d.order_purchase_timestamp,
        d.order_approved_at,
        d.order_delivered_carrier_date,
        d.order_delivered_customer_date,
        d.order_estimated_delivery_date,
        d.purchase_month,
        d.approval_days,
        d.delivery_days,
        d.estimated_delivery_diff_days,
        d.is_late_delivery

    FROM delivered_orders AS d

    LEFT JOIN raw.olist_customers_dataset AS c
        ON d.customer_id = c.customer_id
),

items_with_product AS (
    SELECT
        oi.order_id,
        oi.order_item_id,
        oi.product_id,
        oi.seller_id,
        oi.shipping_limit_date,
        oi.price,
        oi.freight_value,

        p.product_category_name,
        p.product_name_lenght,
        p.product_description_lenght,
        p.product_photos_qty,
        p.product_weight_g,
        p.product_length_cm,
        p.product_height_cm,
        p.product_width_cm,

        t.product_category_name_english,

        s.seller_city,
        s.seller_state,
        s.seller_zip_code_prefix

    FROM raw.olist_order_items_dataset AS oi

    LEFT JOIN raw.olist_products_dataset AS p
        ON oi.product_id = p.product_id

    LEFT JOIN raw.product_category_name_translation AS t
        ON p.product_category_name = t.product_category_name

    LEFT JOIN raw.olist_sellers_dataset AS s
        ON oi.seller_id = s.seller_id
),

payments AS (
    SELECT
        order_id,
        payment_sequential,
        payment_type,
        payment_installments,
        payment_value

    FROM raw.olist_order_payments_dataset
),

reviews AS (
    SELECT
        order_id,
        review_id,
        review_score,
        review_comment_title,
        review_comment_message,
        review_creation_date,
        review_answer_timestamp

    FROM raw.olist_order_reviews_dataset
),

base_data AS (
    SELECT
        co.customer_unique_id,
        co.customer_id,
        co.customer_city,
        co.customer_state,
        co.customer_zip_code_prefix,

        co.order_id,
        co.purchase_month,
        co.order_purchase_timestamp,
        co.order_approved_at,
        co.order_delivered_customer_date,
        co.order_estimated_delivery_date,
        co.approval_days,
        co.delivery_days,
        co.estimated_delivery_diff_days,
        co.is_late_delivery,

        ip.order_item_id,
        ip.product_id,
        ip.seller_id,
        ip.product_category_name,
        COALESCE(
            ip.product_category_name_english,
            'unknown'
        ) AS product_category_name_english,

        ip.price,
        ip.freight_value,
        ip.product_name_lenght,
        ip.product_description_lenght,
        ip.product_photos_qty,
        ip.product_weight_g,
        ip.product_length_cm,
        ip.product_height_cm,
        ip.product_width_cm,
        ip.seller_city,
        ip.seller_state,

        p.payment_sequential,
        p.payment_type,
        p.payment_installments,
        p.payment_value,

        r.review_id,
        r.review_score,
        r.review_comment_title,
        r.review_comment_message,
        r.review_creation_date,
        r.review_answer_timestamp,

        CASE
            WHEN r.review_comment_message IS NOT NULL
                THEN 1
            ELSE 0
        END AS has_review_comment,

        CASE
            WHEN r.review_score <= 2
                THEN 1
            ELSE 0
        END AS is_low_review,

        CASE
            WHEN co.customer_state = ip.seller_state
                THEN 1
            ELSE 0
        END AS is_same_state,

        CASE
            WHEN p.payment_type = 'credit_card'
                THEN 1
            ELSE 0
        END AS is_credit_card

    FROM customer_orders AS co

    INNER JOIN items_with_product AS ip
        ON co.order_id = ip.order_id

    LEFT JOIN payments AS p
        ON co.order_id = p.order_id

    LEFT JOIN reviews AS r
        ON co.order_id = r.order_id
),

monthly_customer_category AS (
    SELECT
        customer_unique_id,
        purchase_month,
        product_category_name_english,

        MAX(customer_state) AS customer_state,

        COUNT(DISTINCT order_id) AS order_count,
        COUNT(order_item_id) AS item_count,
        COUNT(DISTINCT product_id) AS unique_product_count,
        COUNT(DISTINCT seller_id) AS unique_seller_count,

        SUM(price) AS total_product_value,
        SUM(freight_value) AS total_freight_value,
        SUM(price + freight_value) AS total_order_value,
        SUM(payment_value) AS total_payment_value,

        AVG(price) AS average_item_price,
        AVG(freight_value) AS average_freight_value,
        AVG(payment_installments) AS average_payment_installments,

        MAX(payment_installments) AS maximum_payment_installments,

        AVG(approval_days) AS average_approval_days,
        AVG(delivery_days) AS average_delivery_days,
        AVG(estimated_delivery_diff_days)
            AS average_estimated_delivery_diff_days,

        SUM(is_late_delivery) AS late_delivery_count,
        AVG(is_late_delivery) AS late_delivery_rate,

        AVG(review_score) AS average_review_score,
        MIN(review_score) AS minimum_review_score,
        MAX(review_score) AS maximum_review_score,

        SUM(is_low_review) AS low_review_count,
        AVG(is_low_review) AS low_review_rate,

        SUM(has_review_comment) AS review_comment_count,
        AVG(has_review_comment) AS review_comment_rate,

        AVG(is_same_state) AS same_state_rate,
        AVG(is_credit_card) AS credit_card_rate,

        AVG(product_photos_qty) AS average_product_photos_qty,
        AVG(product_weight_g) AS average_product_weight_g,

        COUNT(
            DISTINCT CASE
                WHEN is_late_delivery = 1
                 AND is_low_review = 1
                    THEN order_id
            END
        ) AS late_and_low_review_order_count

    FROM base_data

    GROUP BY
        customer_unique_id,
        purchase_month,
        product_category_name_english
),

customer_month_summary AS (
    SELECT
        customer_unique_id,
        purchase_month,

        SUM(order_count) AS monthly_order_count,
        SUM(item_count) AS monthly_item_count,
        SUM(total_order_value) AS monthly_order_value,

        COUNT(
            DISTINCT product_category_name_english
        ) AS monthly_category_count,

        AVG(average_delivery_days)
            AS monthly_average_delivery_days,

        AVG(average_review_score)
            AS monthly_average_review_score

    FROM monthly_customer_category

    GROUP BY
        customer_unique_id,
        purchase_month
),

final_data AS (
    SELECT
        m.customer_unique_id,
        m.purchase_month,
        m.product_category_name_english,
        m.customer_state,

        m.order_count,
        m.item_count,
        m.unique_product_count,
        m.unique_seller_count,

        m.total_product_value,
        m.total_freight_value,
        m.total_order_value,
        m.total_payment_value,

        m.average_item_price,
        m.average_freight_value,
        m.average_payment_installments,
        m.maximum_payment_installments,

        m.average_approval_days,
        m.average_delivery_days,
        m.average_estimated_delivery_diff_days,

        m.late_delivery_count,
        m.late_delivery_rate,

        m.average_review_score,
        m.minimum_review_score,
        m.maximum_review_score,
        m.low_review_count,
        m.low_review_rate,

        m.review_comment_count,
        m.review_comment_rate,
        m.same_state_rate,
        m.credit_card_rate,

        m.average_product_photos_qty,
        m.average_product_weight_g,
        m.late_and_low_review_order_count,

        cms.monthly_order_count,
        cms.monthly_item_count,
        cms.monthly_order_value,
        cms.monthly_category_count,
        cms.monthly_average_delivery_days,
        cms.monthly_average_review_score,

        m.total_order_value
            / NULLIF(cms.monthly_order_value, 0)
            AS category_sales_share,

        m.order_count
            / NULLIF(cms.monthly_order_count, 0)
            AS category_order_share,

        CASE
            WHEN m.average_review_score < 3
                THEN 'high_risk'
            WHEN m.average_review_score < 4
                THEN 'medium_risk'
            ELSE 'low_risk'
        END AS customer_experience_risk

    FROM monthly_customer_category AS m

    LEFT JOIN customer_month_summary AS cms
        ON m.customer_unique_id = cms.customer_unique_id
       AND m.purchase_month = cms.purchase_month
)

SELECT
    *

FROM final_data

ORDER BY
    purchase_month,
    customer_unique_id,
    total_order_value DESC;
    