/*
代表的な修正例。

出力粒度:
    customer_unique_id × purchase_month × product_category_name_english

設計意図:
    明細、決済、レビューを生のまま同時に結合しない。
    明細指標は明細粒度、配送・レビュー指標は注文カテゴリ粒度で集計する。
    注文決済額は、注文内の商品カテゴリ別の商品・送料合計の比率で配賦する。
*/

WITH delivered_orders AS (
    SELECT
        o.order_id,
        o.customer_id,
        o.order_purchase_timestamp,
        o.order_approved_at,
        o.order_delivered_customer_date,
        o.order_estimated_delivery_date,
        DATE_TRUNC('MONTH', o.order_purchase_timestamp)::DATE AS purchase_month,
        DATEDIFF('DAY', o.order_purchase_timestamp, o.order_approved_at) AS approval_days,
        DATEDIFF('DAY', o.order_purchase_timestamp, o.order_delivered_customer_date) AS delivery_days,
        DATEDIFF(
            'DAY',
            o.order_estimated_delivery_date,
            o.order_delivered_customer_date
        ) AS estimated_delivery_diff_days,
        IFF(
            o.order_delivered_customer_date > o.order_estimated_delivery_date,
            1,
            0
        ) AS is_late_delivery
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
        c.customer_state,
        d.order_purchase_timestamp,
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
        oi.price,
        oi.freight_value,
        COALESCE(t.product_category_name_english, 'unknown')
            AS product_category_name_english,
        p.product_photos_qty,
        p.product_weight_g,
        s.seller_state
    FROM raw.olist_order_items_dataset AS oi
    LEFT JOIN raw.olist_products_dataset AS p
        ON oi.product_id = p.product_id
    LEFT JOIN raw.product_category_name_translation AS t
        ON p.product_category_name = t.product_category_name
    LEFT JOIN raw.olist_sellers_dataset AS s
        ON oi.seller_id = s.seller_id
),

payments_by_order AS (
    SELECT
        order_id,
        SUM(payment_value) AS order_payment_value,
        AVG(payment_installments) AS order_average_payment_installments,
        MAX(payment_installments) AS order_maximum_payment_installments,
        MAX(IFF(payment_type = 'credit_card', 1, 0)) AS order_used_credit_card
    FROM raw.olist_order_payments_dataset
    GROUP BY order_id
),

reviews_by_order AS (
    SELECT
        order_id,
        AVG(review_score) AS order_review_score,
        MIN(review_score) AS order_minimum_review_score,
        MAX(review_score) AS order_maximum_review_score,
        IFF(AVG(review_score) <= 2, 1, 0) AS is_low_review,
        MAX(IFF(review_comment_message IS NOT NULL, 1, 0)) AS has_review_comment
    FROM raw.olist_order_reviews_dataset
    GROUP BY order_id
),

order_item_totals AS (
    SELECT
        order_id,
        COUNT(*) AS order_item_count,
        SUM(price + freight_value) AS order_item_value
    FROM items_with_product
    GROUP BY order_id
),

order_category_items AS (
    SELECT
        co.customer_unique_id,
        co.purchase_month,
        co.customer_state,
        co.order_id,
        i.product_category_name_english,
        COUNT(i.order_item_id) AS item_count,
        COUNT(DISTINCT i.product_id) AS unique_product_count,
        COUNT(DISTINCT i.seller_id) AS unique_seller_count,
        SUM(i.price) AS total_product_value,
        SUM(i.freight_value) AS total_freight_value,
        SUM(i.price + i.freight_value) AS total_order_value,
        AVG(i.price) AS average_item_price,
        AVG(i.freight_value) AS average_freight_value,
        AVG(IFF(co.customer_state = i.seller_state, 1, 0)) AS same_state_rate,
        AVG(i.product_photos_qty) AS average_product_photos_qty,
        AVG(i.product_weight_g) AS average_product_weight_g
    FROM customer_orders AS co
    INNER JOIN items_with_product AS i
        ON co.order_id = i.order_id
    GROUP BY
        co.customer_unique_id,
        co.purchase_month,
        co.customer_state,
        co.order_id,
        i.product_category_name_english
),

order_category_facts AS (
    SELECT
        oci.customer_unique_id,
        oci.purchase_month,
        oci.customer_state,
        oci.order_id,
        oci.product_category_name_english,
        oci.item_count,
        oci.unique_product_count,
        oci.unique_seller_count,
        oci.total_product_value,
        oci.total_freight_value,
        oci.total_order_value,
        oci.average_item_price,
        oci.average_freight_value,
        oci.same_state_rate,
        oci.average_product_photos_qty,
        oci.average_product_weight_g,
        CASE
            WHEN p.order_payment_value IS NULL THEN NULL
            WHEN oit.order_item_value <> 0
                THEN p.order_payment_value * oci.total_order_value / oit.order_item_value
            ELSE p.order_payment_value * oci.item_count / NULLIF(oit.order_item_count, 0)
        END AS allocated_payment_value,
        p.order_average_payment_installments,
        p.order_maximum_payment_installments,
        COALESCE(p.order_used_credit_card, 0) AS order_used_credit_card,
        co.approval_days,
        co.delivery_days,
        co.estimated_delivery_diff_days,
        co.is_late_delivery,
        r.order_review_score,
        r.order_minimum_review_score,
        r.order_maximum_review_score,
        r.is_low_review,
        r.has_review_comment
    FROM order_category_items AS oci
    INNER JOIN customer_orders AS co
        ON oci.order_id = co.order_id
    INNER JOIN order_item_totals AS oit
        ON oci.order_id = oit.order_id
    LEFT JOIN payments_by_order AS p
        ON oci.order_id = p.order_id
    LEFT JOIN reviews_by_order AS r
        ON oci.order_id = r.order_id
),

monthly_item_metrics AS (
    SELECT
        co.customer_unique_id,
        co.purchase_month,
        i.product_category_name_english,
        MAX(co.customer_state) AS customer_state,
        COUNT(i.order_item_id) AS item_count,
        COUNT(DISTINCT i.product_id) AS unique_product_count,
        COUNT(DISTINCT i.seller_id) AS unique_seller_count,
        SUM(i.price) AS total_product_value,
        SUM(i.freight_value) AS total_freight_value,
        SUM(i.price + i.freight_value) AS total_order_value,
        AVG(i.price) AS average_item_price,
        AVG(i.freight_value) AS average_freight_value,
        AVG(IFF(co.customer_state = i.seller_state, 1, 0)) AS same_state_rate,
        AVG(i.product_photos_qty) AS average_product_photos_qty,
        AVG(i.product_weight_g) AS average_product_weight_g
    FROM customer_orders AS co
    INNER JOIN items_with_product AS i
        ON co.order_id = i.order_id
    GROUP BY
        co.customer_unique_id,
        co.purchase_month,
        i.product_category_name_english
),

monthly_order_metrics AS (
    SELECT
        customer_unique_id,
        purchase_month,
        product_category_name_english,
        COUNT(order_id) AS order_count,
        SUM(allocated_payment_value) AS total_payment_value,
        AVG(order_average_payment_installments) AS average_payment_installments,
        MAX(order_maximum_payment_installments) AS maximum_payment_installments,
        AVG(approval_days) AS average_approval_days,
        AVG(delivery_days) AS average_delivery_days,
        AVG(estimated_delivery_diff_days) AS average_estimated_delivery_diff_days,
        SUM(is_late_delivery) AS late_delivery_count,
        AVG(is_late_delivery) AS late_delivery_rate,
        AVG(order_review_score) AS average_review_score,
        MIN(order_minimum_review_score) AS minimum_review_score,
        MAX(order_maximum_review_score) AS maximum_review_score,
        COUNT(IFF(is_low_review = 1, 1, NULL)) AS low_review_count,
        AVG(is_low_review) AS low_review_rate,
        COUNT(IFF(has_review_comment = 1, 1, NULL)) AS review_comment_count,
        AVG(has_review_comment) AS review_comment_rate,
        AVG(order_used_credit_card) AS credit_card_rate,
        COUNT(IFF(is_late_delivery = 1 AND is_low_review = 1, 1, NULL))
            AS late_and_low_review_order_count
    FROM order_category_facts
    GROUP BY
        customer_unique_id,
        purchase_month,
        product_category_name_english
),

monthly_customer_category AS (
    SELECT
        i.customer_unique_id,
        i.purchase_month,
        i.product_category_name_english,
        i.customer_state,
        o.order_count,
        i.item_count,
        i.unique_product_count,
        i.unique_seller_count,
        i.total_product_value,
        i.total_freight_value,
        i.total_order_value,
        o.total_payment_value,
        i.average_item_price,
        i.average_freight_value,
        o.average_payment_installments,
        o.maximum_payment_installments,
        o.average_approval_days,
        o.average_delivery_days,
        o.average_estimated_delivery_diff_days,
        o.late_delivery_count,
        o.late_delivery_rate,
        o.average_review_score,
        o.minimum_review_score,
        o.maximum_review_score,
        o.low_review_count,
        o.low_review_rate,
        o.review_comment_count,
        o.review_comment_rate,
        i.same_state_rate,
        o.credit_card_rate,
        i.average_product_photos_qty,
        i.average_product_weight_g,
        o.late_and_low_review_order_count
    FROM monthly_item_metrics AS i
    INNER JOIN monthly_order_metrics AS o
        ON EQUAL_NULL(i.customer_unique_id, o.customer_unique_id)
       AND i.purchase_month = o.purchase_month
       AND i.product_category_name_english = o.product_category_name_english
),

customer_order_facts AS (
    SELECT
        co.customer_unique_id,
        co.purchase_month,
        co.order_id,
        oit.order_item_count,
        oit.order_item_value,
        co.delivery_days,
        r.order_review_score
    FROM customer_orders AS co
    INNER JOIN order_item_totals AS oit
        ON co.order_id = oit.order_id
    LEFT JOIN reviews_by_order AS r
        ON co.order_id = r.order_id
),

customer_month_categories AS (
    SELECT
        customer_unique_id,
        purchase_month,
        COUNT(*) AS monthly_category_count
    FROM monthly_item_metrics
    GROUP BY
        customer_unique_id,
        purchase_month
),

customer_month_summary AS (
    SELECT
        cof.customer_unique_id,
        cof.purchase_month,
        COUNT(cof.order_id) AS monthly_order_count,
        SUM(cof.order_item_count) AS monthly_item_count,
        SUM(cof.order_item_value) AS monthly_order_value,
        MAX(cmc.monthly_category_count) AS monthly_category_count,
        AVG(cof.delivery_days) AS monthly_average_delivery_days,
        AVG(cof.order_review_score) AS monthly_average_review_score
    FROM customer_order_facts AS cof
    INNER JOIN customer_month_categories AS cmc
        ON EQUAL_NULL(cof.customer_unique_id, cmc.customer_unique_id)
       AND cof.purchase_month = cmc.purchase_month
    GROUP BY
        cof.customer_unique_id,
        cof.purchase_month
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
        m.total_order_value / NULLIF(cms.monthly_order_value, 0) AS category_sales_share,
        m.order_count / NULLIF(cms.monthly_order_count, 0) AS category_order_share,
        CASE
            WHEN m.average_review_score < 3 THEN 'high_risk'
            WHEN m.average_review_score < 4 THEN 'medium_risk'
            ELSE 'low_risk'
        END AS customer_experience_risk
    FROM monthly_customer_category AS m
    LEFT JOIN customer_month_summary AS cms
        ON EQUAL_NULL(m.customer_unique_id, cms.customer_unique_id)
       AND m.purchase_month = cms.purchase_month
)

SELECT
    customer_unique_id,
    purchase_month,
    product_category_name_english,
    customer_state,
    order_count,
    item_count,
    unique_product_count,
    unique_seller_count,
    total_product_value,
    total_freight_value,
    total_order_value,
    total_payment_value,
    average_item_price,
    average_freight_value,
    average_payment_installments,
    maximum_payment_installments,
    average_approval_days,
    average_delivery_days,
    average_estimated_delivery_diff_days,
    late_delivery_count,
    late_delivery_rate,
    average_review_score,
    minimum_review_score,
    maximum_review_score,
    low_review_count,
    low_review_rate,
    review_comment_count,
    review_comment_rate,
    same_state_rate,
    credit_card_rate,
    average_product_photos_qty,
    average_product_weight_g,
    late_and_low_review_order_count,
    monthly_order_count,
    monthly_item_count,
    monthly_order_value,
    monthly_category_count,
    monthly_average_delivery_days,
    monthly_average_review_score,
    category_sales_share,
    category_order_share,
    customer_experience_risk
FROM final_data
ORDER BY
    purchase_month,
    customer_unique_id,
    total_order_value DESC;
