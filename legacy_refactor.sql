/*
■ クエリ修正報告

【概要】
base_data における 1対多 JOIN によるデータの重複（売上・件数の二重計上バグ）の防止、およびデータ粒度の適正化を行いました。

【主な修正内容】
1. base_data の粒度統一（1行＝1注文明細：order_id × order_item_id）
   ・payments：order_id × payment_type 単位から order_id 単位（1注文1行）へ事前集約して JOIN。
   ・reviews：order_id × review_id 単位から order_id 単位（1注文1行）へ事前集約して JOIN。
   ➔ 結果として、base_data の行数が 115,715行 ➔ 110,189行（正しい商品明細件数）へ正常化し、データ膨張を防止しました。

2. 支払金額（order_total_amount）の集計除外と代用設定
   ・明細単位の base_data に対して「1注文全体の決済額（order_total_amount）」を保持して SUM すると数値が倍増するため、これを削除しました。
   ・商品カテゴリ別の金額集計には、明細単位で正確な `SUM(price + freight_value)` を使用します。

※（備考）今後、クーポン適用後などの「実際の決済額ベース」での分析が必要になった場合は、明細に持たせるのではなく以下のような 1注文1行の別CTE（customer_monthly_payments）の追加・結合を検討します。

------------------------------------------------------------------------------
*/

USE ROLE SYSADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE OLIST;
USE SCHEMA RAW;

-- 1, 配達済みの注文を抽出する。
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

-- 配達済の注文に、顧客情報を左結合する。
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

-- 注文ごとの商品一覧に対して、商品情報、商品名の翻訳（ポルトガル語→英語）、販売者情報を結合する。
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

-- 注文ごとの支払い方法、金額等を抽出する（1注文＝1行に事前集約）。
payments AS (
    SELECT
        order_id,
        MAX(payment_sequential) AS num_payment_methods, -- 支払い方法の数
        MAX(CASE WHEN payment_type='credit_card' THEN 1 ELSE 0 END) AS is_credit_card, -- クレジットカードを含む支払い＝１、他＝０
        MAX(payment_installments) AS max_payment_installments
        -- SUM(payment_value) AS order_total_amount -- 明細単位でのSUM倍増を防ぐため除外
    FROM raw.olist_order_payments_dataset
    GROUP BY order_id
),

-- 注文に対するレビューを抽出する（1注文＝1行に事前集約）。
reviews AS (
    SELECT
        order_id,
        MIN(review_score) AS review_score, -- 複数ある場合は最低スコアを採用
        MAX(CASE WHEN review_comment_message IS NOT NULL THEN 1 ELSE 0 END) AS has_review_comment, -- 1つでもコメントがあれば1
        MAX(CASE WHEN review_score <= 2 THEN 1 ELSE 0 END) AS is_low_review -- 1つでも★2以下があれば1
    FROM raw.olist_order_reviews_dataset
    GROUP BY order_id
),

-- 注文と顧客情報に対して、注文に関する、商品情報（商品名翻訳含む）、販売者情報、支払い情報、レビュー情報を結合する。
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
        ) AS product_category_name_english, -- 英名＝NULLはunknownとする。

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

        p.num_payment_methods,
        p.is_credit_card,
        p.max_payment_installments,

        r.review_score,
        r.has_review_comment,
        r.is_low_review,

        CASE
            WHEN co.customer_state = ip.seller_state
                THEN 1
            ELSE 0
        END AS is_same_state -- （顧客居住州＝＝販売者所在州） ＝ 1、他０

    FROM customer_orders AS co

    INNER JOIN items_with_product AS ip
        ON co.order_id = ip.order_id

    LEFT JOIN payments AS p
        ON co.order_id = p.order_id

    LEFT JOIN reviews AS r
        ON co.order_id = r.order_id
),

-- 統合した上のテーブルから、ユニークな顧客ごとに、注文月ごとに、商品名（英名）ごとにまとめて、集計する。
monthly_customer_category AS (
    SELECT
        customer_unique_id,
        purchase_month,
        product_category_name_english,

        MAX(customer_state) AS customer_state, -- 顧客が多い州

        COUNT(DISTINCT order_id) AS order_count, -- ユニークな注文件数
        COUNT(order_item_id) AS item_count, -- 商品個数
        COUNT(DISTINCT product_id) AS unique_product_count, -- ユニークな商品数
        COUNT(DISTINCT seller_id) AS unique_seller_count, -- ユニークな販売者数

        SUM(price) AS total_product_value, -- 商品単価の合計
        SUM(freight_value) AS total_freight_value, -- 送料の合計
        SUM(price + freight_value) AS total_order_value, -- 商品単価と送料を足して、合計

        AVG(price) AS average_item_price, -- 商品単価の平均
        AVG(freight_value) AS average_freight_value, -- 送料の平均
        AVG(max_payment_installments) AS average_payment_installments, -- 分割払い回数の平均
        MAX(max_payment_installments) AS maximum_payment_installments, -- 最大分割払い回数

        AVG(approval_days) AS average_approval_days,
        AVG(delivery_days) AS average_delivery_days,
        AVG(estimated_delivery_diff_days)
            AS average_estimated_delivery_diff_days,

        SUM(is_late_delivery) AS late_delivery_count,
        AVG(is_late_delivery) AS late_delivery_rate,

        AVG(review_score) AS average_review_score,         -- 注文ごとのスコアの平均
        MIN(review_score) AS minimum_review_score,         -- 最低スコア
        MAX(review_score) AS maximum_review_score,         -- 最高スコア

        SUM(is_low_review) AS low_review_count,            -- 低評価だった「注文数」
        AVG(is_low_review) AS low_review_rate,             -- 低評価だった「注文の割合」

        SUM(has_review_comment) AS review_comment_count,   -- コメントがついた「注文数」
        AVG(has_review_comment) AS review_comment_rate,    -- コメントがついた「注文の割合」

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

-- ユニークな顧客×月別で集計する
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
        -- m.customer_monthly_amount, -- 存在しないため除外

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