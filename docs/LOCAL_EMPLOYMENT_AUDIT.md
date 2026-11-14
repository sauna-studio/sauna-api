# 社員ロール失効の監査

ローカルDBの `sauna_app` には監査表の照会・施設・利用者IDへの INSERT だけを付与し、失効時刻はDBが設定します。マイグレーション適用時は旧権限を取り消してから再付与します。閲覧は既存のローカルDB管理者に限ります。監査表は施設・利用者・照会の各Sauna内IDと失効時刻を記録します。

保持は自動削除なしを既定とします。本番の保存期間、閲覧者、削除の承認と実行頻度は Issue #36 で決めます。

保持処理の検証には、ネットワークを公開しない隔離PostgreSQL 18を起動するAtlasリプレイを使います。`migration_base` に信頼済みのmainのコミットSHAを設定してから実行してください。

```sh
.venv/bin/python scripts/migration_ci.py --runtime apple --base "$migration_base"
```

リプレイは専用の `sauna_audit_sandbox` DBに合成データだけを登録します。保持SQLは対象DB名・所有者・専用マーカーを確認し、プレビューで行を残すこと、期限切れの行を失効時刻順に指定件数まで削除すること、新しい行を残すことを検証します。既存の開発DBである `sauna_atlas_replay` と同じ名前のDBでも、保持SQLが実行を拒むことを隔離環境で確認します。

Atlasの隔離リプレイは、制限されたアプリ接続で監査の INSERT 成功と SELECT・UPDATE・DELETE・TRUNCATE と失効時刻指定の拒否を確認します。Swift全体の使い捨てDBでは監査の照合・片付けに必要な SELECT・DELETE をテスト用に追加します。起動スモークは `--restrict-employment-audit` を指定して INSERT のみに戻せます。
