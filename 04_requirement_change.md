# 課題4: 分析要件の追加

## データサイエンティストからの追加依頼

配送遅延の予測と顧客行動の変化を分析するため、課題3で整理した特徴量へ時系列特徴を追加してください。既存列を利用している分析があるため、既存の対象行、粒度、列名、値は維持してください。

## 追加要件

### 要件1: 顧客ライフサイクル

次の列を追加してください。

| 列 | 定義 |
|---|---|
| `first_purchase_month` | 現在のSQLの分析対象注文集合における顧客の最初の購入月 |
| `months_since_first_purchase` | 初回購入月から現在行の購入月までの暦月差。初回月は0 |
| `customer_purchase_type` | 初回購入月は `new`、それ以外は `repeat` |

初回月に複数カテゴリの行がある場合、その月の各カテゴリ行を `new` とします。

### 要件2: 直前の購入観測との比較

同一 `customer_unique_id × product_category_name_english` 内で、現在行より前に存在する直近の購入月を使用します。暦上の前月に行がなければ、さらに前の最後の観測を使います。

| 列 | 定義 |
|---|---|
| `previous_observed_purchase_month` | 直前に出力行が存在した購入月。最初の観測はNULL |
| `previous_observed_order_count` | 直前観測の `order_count`。最初の観測はNULL |
| `order_count_change_from_previous_observation` | 現在の `order_count` − 直前観測の `order_count` |

### 要件3: 配送遅延率の移動平均

`customer_unique_id × product_category_name_english` 内で、現在行を含む直近3購入観測の `late_delivery_rate` の単純平均を `trailing_3_observations_average_late_delivery_rate` として追加してください。3観測未満では存在する観測だけを使います。3暦月ではなく3購入観測であることに注意してください。

## 分析上の利用目的

- 新規顧客とリピート顧客で配送・レビュー傾向を分ける。
- カテゴリ別の購入頻度変化を特徴として使う。
- 少数注文による単月遅延率の振れをならし、継続的な傾向を捉える。

## 入力と制約

- 自分の `student_workspace/task_03/refactored.sql` を `student_workspace/task_04/extended.sql` へコピーする。
- `legacy.sql` と課題2・3の成果物は変更しない。
- 既存の出力キー、行数、既存列の値を変更しない。
- 追加列の期間、パーティション、並び順、最初の観測のNULLを説明する。
- 新しいJOINを使う場合は多重度を確認する。
- AIが提案したウィンドウ句を小さなデータ範囲で再計算する。

## 成果物

```text
student_workspace/task_04/extended.sql
student_workspace/task_04/acceptance_check.sql
student_workspace/task_04/report.md
```

[課題4テンプレート](../templates/task_04_report.md) を利用できます。

## 結果確認

`acceptance_check.sql` に、少なくとも次を確認するSQLを記載してください。

- 課題3と課題4の行数、キー、既存列が一致する。
- `first_purchase_month` が現在月より後にならない。
- 経過月数が0以上で、新規・リピート区分と一致する。
- 直前観測月が現在月より前である。
- 直前注文件数と変化量を再計算できる。
- 1人以上の顧客・カテゴリについて時系列を並べ、3観測移動平均を手計算と比較できる。
- 追加列に想定外のNULLがない。

## report.mdに含める内容

- 要件の解釈
- 変更方針
- 影響範囲
- 既存出力粒度との整合性
- 新規カラムの定義と分析上の意味
- 結果の確認方法と実行結果
- 既存指標への影響確認
- AIに確認した内容、採用・不採用、理由、検証方法
- 残っている懸念事項

完了後に [課題4の模範解答](../solutions/task_04/explanation.md) を確認します。
