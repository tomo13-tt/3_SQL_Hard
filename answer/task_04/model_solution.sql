/*
課題3の既存列を維持し、顧客ライフサイクル、直前の購入実績、
直近3購入期間の配送遅延率を追加する実装例。
*/

WITH eligible_order AS (
    -- 1行は分析対象の配送完了注文。顧客属性をここで一度だけ付与する。
    SELECT
        o.order_id,
        c.customer_unique_id,
        c.customer_state,
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
    LEFT JOIN raw.olist_customers_dataset AS c
        ON o.customer_id = c.customer_id
    WHERE o.order_status = 'delivered'
      AND o.order_purchase_timestamp IS NOT NULL
      AND o.order_delivered_customer_date IS NOT NULL
),

item_detail AS (
    -- 1行は注文明細。カテゴリ欠損は出力キーを失わないため unknown にそろえる。
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

payment_order AS (
    -- 1行は注文。決済レコード数に左右されない注文単位の特徴へ変換する。
    SELECT
        order_id,
        SUM(payment_value) AS payment_value,
        AVG(payment_installments) AS average_payment_installments,
        MAX(payment_installments) AS maximum_payment_installments,
        MAX(IFF(payment_type = 'credit_card', 1, 0)) AS used_credit_card
    FROM raw.olist_order_payments_dataset
    GROUP BY order_id
),

review_order AS (
    -- 1行は注文。複数レビューがある場合は平均スコアを注文代表値とする。
    SELECT
        order_id,
        AVG(review_score) AS review_score,
        MIN(review_score) AS minimum_review_score,
        MAX(review_score) AS maximum_review_score,
        IFF(AVG(review_score) <= 2, 1, 0) AS is_low_review,
        MAX(IFF(review_comment_message IS NOT NULL, 1, 0)) AS has_review_comment
    FROM raw.olist_order_reviews_dataset
    GROUP BY order_id
),

order_item_control AS (
    -- 1行は注文。配賦の分母と顧客月次のコントロールトータルに使う。
    SELECT
        order_id,
        COUNT(*) AS item_count,
        SUM(price + freight_value) AS order_value
    FROM item_detail
    GROUP BY order_id
),

order_category_item AS (
    -- 1行は注文×カテゴリ。決済額をカテゴリへ配賦できる粒度へ縮約する。
    SELECT
        order_id,
        product_category_name_english,
        COUNT(order_item_id) AS item_count,
        SUM(price + freight_value) AS category_order_value
    FROM item_detail
    GROUP BY
        order_id,
        product_category_name_english
),

order_category_experience AS (
    -- 1行は対象注文×カテゴリ。配送・レビューは各カテゴリで注文1件として扱う。
    SELECT
        eo.customer_unique_id,
        eo.purchase_month,
        oci.order_id,
        oci.product_category_name_english,
        CASE
            WHEN po.payment_value IS NULL THEN NULL
            WHEN oic.order_value <> 0
                THEN po.payment_value * oci.category_order_value / oic.order_value
            ELSE po.payment_value * oci.item_count / NULLIF(oic.item_count, 0)
        END AS allocated_payment_value,
        po.average_payment_installments,
        po.maximum_payment_installments,
        COALESCE(po.used_credit_card, 0) AS used_credit_card,
        eo.approval_days,
        eo.delivery_days,
        eo.estimated_delivery_diff_days,
        eo.is_late_delivery,
        ro.review_score,
        ro.minimum_review_score,
        ro.maximum_review_score,
        ro.is_low_review,
        ro.has_review_comment
    FROM eligible_order AS eo
    INNER JOIN order_category_item AS oci
        ON eo.order_id = oci.order_id
    INNER JOIN order_item_control AS oic
        ON eo.order_id = oic.order_id
    LEFT JOIN payment_order AS po
        ON eo.order_id = po.order_id
    LEFT JOIN review_order AS ro
        ON eo.order_id = ro.order_id
),

category_item_month AS (
    -- 1行は顧客×購入月×カテゴリ。明細を分母とする指標だけを計算する。
    SELECT
        eo.customer_unique_id,
        eo.purchase_month,
        i.product_category_name_english,
        MAX(eo.customer_state) AS customer_state,
        COUNT(i.order_item_id) AS item_count,
        COUNT(DISTINCT i.product_id) AS unique_product_count,
        COUNT(DISTINCT i.seller_id) AS unique_seller_count,
        SUM(i.price) AS total_product_value,
        SUM(i.freight_value) AS total_freight_value,
        SUM(i.price + i.freight_value) AS total_order_value,
        AVG(i.price) AS average_item_price,
        AVG(i.freight_value) AS average_freight_value,
        AVG(IFF(eo.customer_state = i.seller_state, 1, 0)) AS same_state_rate,
        AVG(i.product_photos_qty) AS average_product_photos_qty,
        AVG(i.product_weight_g) AS average_product_weight_g
    FROM eligible_order AS eo
    INNER JOIN item_detail AS i
        ON eo.order_id = i.order_id
    GROUP BY
        eo.customer_unique_id,
        eo.purchase_month,
        i.product_category_name_english
),

category_order_month AS (
    -- 1行は顧客×購入月×カテゴリ。注文を分母とする指標だけを計算する。
    SELECT
        customer_unique_id,
        purchase_month,
        product_category_name_english,
        COUNT(order_id) AS order_count,
        SUM(allocated_payment_value) AS total_payment_value,
        AVG(average_payment_installments) AS average_payment_installments,
        MAX(maximum_payment_installments) AS maximum_payment_installments,
        AVG(approval_days) AS average_approval_days,
        AVG(delivery_days) AS average_delivery_days,
        AVG(estimated_delivery_diff_days) AS average_estimated_delivery_diff_days,
        SUM(is_late_delivery) AS late_delivery_count,
        AVG(is_late_delivery) AS late_delivery_rate,
        AVG(review_score) AS average_review_score,
        MIN(minimum_review_score) AS minimum_review_score,
        MAX(maximum_review_score) AS maximum_review_score,
        COUNT(IFF(is_low_review = 1, 1, NULL)) AS low_review_count,
        AVG(is_low_review) AS low_review_rate,
        COUNT(IFF(has_review_comment = 1, 1, NULL)) AS review_comment_count,
        AVG(has_review_comment) AS review_comment_rate,
        AVG(used_credit_card) AS credit_card_rate,
        COUNT(IFF(is_late_delivery = 1 AND is_low_review = 1, 1, NULL))
            AS late_and_low_review_order_count
    FROM order_category_experience
    GROUP BY
        customer_unique_id,
        purchase_month,
        product_category_name_english
),

category_month_feature AS (
    -- 同じ出力キーで一意な明細系と注文系を結合するため、行数は増えない。
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
    FROM category_item_month AS i
    INNER JOIN category_order_month AS o
        ON EQUAL_NULL(i.customer_unique_id, o.customer_unique_id)
       AND i.purchase_month = o.purchase_month
       AND i.product_category_name_english = o.product_category_name_english
),

customer_order AS (
    -- 1行は対象注文。カテゴリを経由せず顧客月次指標を計算する。
    SELECT
        eo.customer_unique_id,
        eo.purchase_month,
        eo.order_id,
        oic.item_count,
        oic.order_value,
        eo.delivery_days,
        ro.review_score
    FROM eligible_order AS eo
    INNER JOIN order_item_control AS oic
        ON eo.order_id = oic.order_id
    LEFT JOIN review_order AS ro
        ON eo.order_id = ro.order_id
),

customer_month_category_count AS (
    SELECT
        customer_unique_id,
        purchase_month,
        COUNT(*) AS monthly_category_count
    FROM category_item_month
    GROUP BY
        customer_unique_id,
        purchase_month
),

customer_month_feature AS (
    -- 1行は顧客×購入月。複数カテゴリ注文も注文1件として数える。
    SELECT
        co.customer_unique_id,
        co.purchase_month,
        COUNT(co.order_id) AS monthly_order_count,
        SUM(co.item_count) AS monthly_item_count,
        SUM(co.order_value) AS monthly_order_value,
        MAX(cmcc.monthly_category_count) AS monthly_category_count,
        AVG(co.delivery_days) AS monthly_average_delivery_days,
        AVG(co.review_score) AS monthly_average_review_score
    FROM customer_order AS co
    INNER JOIN customer_month_category_count AS cmcc
        ON EQUAL_NULL(co.customer_unique_id, cmcc.customer_unique_id)
       AND co.purchase_month = cmcc.purchase_month
    GROUP BY
        co.customer_unique_id,
        co.purchase_month
),

final_feature AS (
    SELECT
        c.customer_unique_id,
        c.purchase_month,
        c.product_category_name_english,
        c.customer_state,
        c.order_count,
        c.item_count,
        c.unique_product_count,
        c.unique_seller_count,
        c.total_product_value,
        c.total_freight_value,
        c.total_order_value,
        c.total_payment_value,
        c.average_item_price,
        c.average_freight_value,
        c.average_payment_installments,
        c.maximum_payment_installments,
        c.average_approval_days,
        c.average_delivery_days,
        c.average_estimated_delivery_diff_days,
        c.late_delivery_count,
        c.late_delivery_rate,
        c.average_review_score,
        c.minimum_review_score,
        c.maximum_review_score,
        c.low_review_count,
        c.low_review_rate,
        c.review_comment_count,
        c.review_comment_rate,
        c.same_state_rate,
        c.credit_card_rate,
        c.average_product_photos_qty,
        c.average_product_weight_g,
        c.late_and_low_review_order_count,
        m.monthly_order_count,
        m.monthly_item_count,
        m.monthly_order_value,
        m.monthly_category_count,
        m.monthly_average_delivery_days,
        m.monthly_average_review_score,
        c.total_order_value / NULLIF(m.monthly_order_value, 0) AS category_sales_share,
        c.order_count / NULLIF(m.monthly_order_count, 0) AS category_order_share,
        CASE
            WHEN c.average_review_score < 3 THEN 'high_risk'
            WHEN c.average_review_score < 4 THEN 'medium_risk'
            ELSE 'low_risk'
        END AS customer_experience_risk,
        MIN(c.purchase_month) OVER (
            PARTITION BY c.customer_unique_id
        ) AS first_purchase_month,
        DATEDIFF(
            'MONTH',
            MIN(c.purchase_month) OVER (
                PARTITION BY c.customer_unique_id
            ),
            c.purchase_month
        ) AS months_since_first_purchase,
        CASE
            WHEN c.purchase_month = MIN(c.purchase_month) OVER (
                PARTITION BY c.customer_unique_id
            ) THEN 'new'
            ELSE 'repeat'
        END AS customer_purchase_type,
        LAG(c.purchase_month) OVER (
            PARTITION BY c.customer_unique_id, c.product_category_name_english
            ORDER BY c.purchase_month
        ) AS previous_observed_purchase_month,
        LAG(c.order_count) OVER (
            PARTITION BY c.customer_unique_id, c.product_category_name_english
            ORDER BY c.purchase_month
        ) AS previous_observed_order_count,
        c.order_count - LAG(c.order_count) OVER (
            PARTITION BY c.customer_unique_id, c.product_category_name_english
            ORDER BY c.purchase_month
        ) AS order_count_change_from_previous_observation,
        AVG(c.late_delivery_rate) OVER (
            PARTITION BY c.customer_unique_id, c.product_category_name_english
            ORDER BY c.purchase_month
            ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
        ) AS trailing_3_observations_average_late_delivery_rate
    FROM category_month_feature AS c
    LEFT JOIN customer_month_feature AS m
        ON EQUAL_NULL(c.customer_unique_id, m.customer_unique_id)
       AND c.purchase_month = m.purchase_month
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
    customer_experience_risk,
    first_purchase_month,
    months_since_first_purchase,
    customer_purchase_type,
    previous_observed_purchase_month,
    previous_observed_order_count,
    order_count_change_from_previous_observation,
    trailing_3_observations_average_late_delivery_rate
FROM final_feature
ORDER BY
    purchase_month,
    customer_unique_id,
    total_order_value DESC;
