# 課題1 模範解説

この解説は代表的な読解例です。実データの多重度やNULL件数はSnowflakeで確認してください。

## SQL全体の目的と出力粒度

`legacy.sql` は、配送完了注文を対象に、配送遅延やレビュー低評価の分析に使う特徴量を作成しています。想定利用者はデータサイエンティストや分析担当者です。

最終出力の宣言上の粒度は `customer_unique_id × purchase_month × product_category_name_english` です。1行は、ある顧客がある購入月に購入した、ある英語カテゴリについての集計結果を表します。`customer_unique_id` がNULLの場合も `GROUP BY` では1グループになるため、顧客マスタとの未結合行が混在する可能性があります。

## CTEの役割と粒度

| CTE | 入力 | 1行が表すもの | 主な処理 | 注意点 |
|---|---|---|---|---|
| `delivered_orders` | orders | 配送完了注文 | 日付差、購入月、遅延フラグを作成 | 承認日時や予定日はNULLの可能性がある |
| `customer_orders` | delivered_orders, customers | 配送完了注文 | 顧客識別子と所在地を付与 | customersがキー一意なら1対1 |
| `items_with_product` | items, products, translation, sellers | 注文明細 | 商品、英語カテゴリ、販売者属性を付与 | マスタ側キー重複があると明細が増える |
| `payments` | payments | 決済レコード | 列の選択のみ | 1注文に複数行を許す粒度 |
| `reviews` | reviews | レビューレコード | 列の選択のみ | 1注文に複数行となり得る |
| `base_data` | customer_orders, items_with_product, payments, reviews | 注文内の明細×決済×レビューの組み合わせ | 全入力を注文IDで結合しフラグを作成 | ここで多対多化し得る |
| `monthly_customer_category` | base_data | 顧客×購入月×英語カテゴリ | 金額、件数、平均、比率を集計 | 指標ごとに本来の分母が異なる |
| `customer_month_summary` | monthly_customer_category | 顧客×購入月 | カテゴリ別結果を再集計 | 複数カテゴリ注文を再度数える可能性がある |
| `final_data` | monthly_customer_category, customer_month_summary | 顧客×購入月×英語カテゴリ | 月次値、構成比、リスク区分を付与 | 左右がキー一意なら行数不変 |

## データフロー

```text
orders ─ customers
   │
   └─ customer_orders ───────────────┐
                                     │
items ─ products ─ translation       ├─ base_data
  └── sellers ─ items_with_product ──┤   注文明細×決済×レビュー
payments ────────────────────────────┤
reviews ─────────────────────────────┘
                                     │
                          monthly_customer_category
                                     │
                          customer_month_summary
                                     │
                                 final_data
```

## JOINの多重度

| 結合 | 種別 | 期待される関係 | 行数増加の可能性 | NULLの意味 |
|---|---|---|---|---|
| delivered_orders → customers | LEFT | 多対1 | customer_id重複時 | 顧客マスタ未結合 |
| items → products | LEFT | 多対1 | product_id重複時 | 商品マスタ未結合 |
| products → translation | LEFT | 多対1 | 翻訳キー重複時 | 英語カテゴリなし |
| items → sellers | LEFT | 多対1 | seller_id重複時 | 販売者マスタ未結合 |
| customer_orders → items_with_product | INNER | 1対多 | 意図した明細展開 | 明細のない注文は除外 |
| baseの注文・明細 → payments | LEFT | 多対多になり得る | 決済件数分だけ明細を複製 | 決済なし |
| baseの注文・明細・決済 → reviews | LEFT | 多対多になり得る | レビュー件数分だけさらに複製 | レビューなし |
| monthly_customer_category → customer_month_summary | LEFT | 多対1 | summaryキー重複時 | 月次集計なし |

注文 `o` の明細数を `I`、決済数を `P`、レビュー数を `R` とすると、`base_data` の当該注文の行数は概ね `I × max(P, 1) × max(R, 1)` です。LEFT JOINなのでゼロ件側も1行相当として残ります。

## 主要指標の定義と論点

| 指標 | legacy.sql上の計算 | 実際の重み・注意点 |
|---|---|---|
| `order_count` | `COUNT(DISTINCT order_id)` | カテゴリ内では重複を抑えるが、カテゴリ間では同じ注文を数える |
| `item_count` | `COUNT(order_item_id)` | 明細数ではなく結合後行数になる |
| `total_product_value` | `SUM(price)` | 決済数とレビュー数により明細金額が重複する |
| `total_freight_value` | `SUM(freight_value)` | 同上 |
| `total_order_value` | `SUM(price + freight_value)` | 名前は注文金額だが計算元は明細。多重化の影響を受ける |
| `total_payment_value` | `SUM(payment_value)` | 各決済が明細数とレビュー数だけ重複する |
| `average_item_price` | `AVG(price)` | 結合後行を分母とする。注文ごとの決済・レビュー件数で重みが変わる |
| 配送日数の平均 | `AVG(delivery_days)` | 注文値を結合後行数で重み付けしている |
| `late_delivery_count` | `SUM(is_late_delivery)` | 遅延注文件数ではなく、遅延注文の結合後行数 |
| `late_delivery_rate` | `AVG(is_late_delivery)` | 明細・決済・レビューで重み付けされた率 |
| レビュー平均・低評価率 | review列のAVGまたはフラグのAVG | 複数明細・決済でレビューが複製される。レビューなしは低評価フラグ0になる |
| `late_and_low_review_order_count` | 条件付き `COUNT(DISTINCT order_id)` | カテゴリ内では注文重複を抑える |
| `monthly_order_count` | カテゴリ別 `order_count` のSUM | 複数カテゴリ注文をカテゴリ数だけ数える |
| `monthly_average_delivery_days` | カテゴリ平均の単純AVG | 注文件数による加重平均ではない |
| `category_sales_share` | カテゴリ金額÷カテゴリ金額の月次合計 | 分子・分母が同じ誤った重みなら合計1でも金額自体は正しくない |
| `category_order_share` | カテゴリ注文件数÷カテゴリ注文件数の合計 | 分母が顧客月のユニーク注文件数ではない |

`approval_days` は承認日時がNULLならNULLです。`estimated_delivery_diff_days` は予定日がNULLならNULLです。AVGはNULLを除外します。一方、遅延、低評価、コメント、同一州、カードのCASE式は比較対象がNULLでも多くの場合0になるため、「不明」を「該当しない」と扱っています。`NULLIF` により構成比はゼロ除算時にNULLとなります。

## 代表的なコードレビュー指摘

- 明細、決済、レビューを注文IDだけで同時結合し、多対多化している。
- `item_count` と金額合計は結合後の重複を直接受ける。
- 注文単位の配送値を結合後行単位で平均・合計している。
- 複数カテゴリ注文を顧客月次へ戻す際、注文件数を重複計上する。
- カテゴリ平均の単純平均は、カテゴリごとの注文件数を反映しない。
- レビュー欠損と低評価でない状態、決済欠損とカード以外を区別していない。
- `MAX(customer_state)` はキー異常を隠し得る。
- `SELECT *` と多数の未使用列が依存関係を見えにくくしている。
- `ORDER BY` は特徴量生成そのものには不要で、大量出力では追加コストになり得る。
- `customer_experience_risk` はレビューがNULLでも `low_risk` になる。

## データで追加確認すべき事項

- 各マスタ結合キーの一意性
- 注文別の明細、決済、レビュー件数分布
- JOIN前後の注文別行数と `I × P × R` の関係
- 元明細金額・元決済金額とlegacy出力合計の差
- 出力キーの重複とNULL
- 複数カテゴリ注文の件数
- レビューなし、予定配送日なし、承認日時なしの件数
- `monthly_order_count` と顧客月別 `COUNT(DISTINCT order_id)` の差
- カテゴリ構成比の合計と、同じ注文をカテゴリへ割り当てる業務定義

## AIが誤りやすい論点

- Olistではレビューが必ず1注文1件だと、確認せず断定すること
- `COUNT(DISTINCT order_id)` があれば他のSUMやAVGも安全だと判断すること
- `DISTINCT` を追加すれば金額重複を解消できると提案すること
- 決済額を各カテゴリへ全額付与しても加算可能だと扱うこと
- 複数カテゴリ注文の正しい配賦方法がデータだけで一意に決まると考えること
- NULLをすべて0へ変換すること
- SQLを実行せず、具体的な件数や差額を生成すること

別の読解や修正案でも、粒度、指標定義、多重度、NULLの意味を説明し、データで確認できていれば妥当になり得ます。
