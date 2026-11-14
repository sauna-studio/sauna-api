# 社員ロール失効の監査

ローカルDBの `sauna_app` には監査表の照会・施設・利用者IDへの INSERT だけを付与し、失効時刻はDBが設定します。マイグレーション適用時は旧権限を取り消してから再付与します。閲覧と削除は既存のローカルDB管理者に限ります。監査表は施設・利用者・照会の各Sauna内IDと失効時刻を記録します。

保持は自動削除なしを既定とします。ローカル管理者は対象日数と1回の最大行数を明示し、最初に候補件数を確認します。以下の数値は使い捨てデータでの操作例です。本番の保存期間、閲覧者、削除の承認と実行頻度は Issue #36 で決めます。

```sh
python3 scripts/local_employment_audit.py --keep-days 30 --batch-size 100
python3 scripts/local_employment_audit.py --keep-days 30 --batch-size 100 --apply
```

対象はツールが所有するローカルPostgreSQL内の、所有者と専用マーカーを検証済みの使い捨て `sauna_atlas_replay` DBです。未作成の場合は、使い捨てDBを初期化する `python3 scripts/local_migrations.py test` を明示的に実行します。保持コマンド自体はDBを作成・初期化しません。操作結果は件数だけを表示します。毎回、その時点で指定日数より古い行を失効時刻順に最大指定件数まで処理します。実行時に競合ロックのある行は次の処理へ持ち越します。

Atlasの隔離リプレイは、制限されたアプリ接続で監査の INSERT 成功と SELECT・UPDATE・DELETE・TRUNCATE と失効時刻指定の拒否を確認します。保持処理ではマーカーなしの拒否、プレビューで行を保持すること、期限切れの行を指定件数まで削除すること、新しい行を残すことを確認します。Swift全体の使い捨てDBでは監査の照合・片付けに必要な SELECT・DELETE をテスト用に追加します。起動スモークは `--restrict-employment-audit` を指定して INSERT のみに戻せます。
