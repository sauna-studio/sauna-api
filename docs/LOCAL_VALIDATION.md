# ローカル検証 — 2026-11-01 JST

リモートpush/PR/GitHub Actions・本番deploy・課金資源作成は未実施。mainは変更せずlocal branchで実装した。

## 実施済み

- Hummingbird2.28.1 / OpenAPIHummingbird2.1.0 / PostgresNIO1.33.2のexact依存とlock
- macOS Swift build/test: Server10 + Database10 + Contract5、計25tests成功（parameterized caseを含む）
- 公開HTTP200/固定503/Accept406/404、PORT境界、実子processのSIGTERM exit0、入力値非echo
- Apple container上のarm64 Linux release build、nonroot/read-only/loopbackのruntimeでhealth/version実HTTP成功
- PostgreSQL18.6をApple containerで起動。SCRAM、app role非superuser/過剰権限なし、credentialは0700/0600私有ファイル
- 実PostgresNIO pool接続、SQL timeout/親cancel各1秒未満、自己backend切断後の新pool回復、接続拒否の固定エラー
- DB stop→診断失敗(固定1文のみ)→既存volume/credential保持のrestart→再接続成功
- Python16tests（OpenAPI7 + local environment9）と4examples成功
- 独立Review Agentがhost25tests/型・HTTP・DB・helperを再実行し成功。Security Reviewもsecret handling/権限/所有resource保護を確認

Linux arm64 release buildとfull Swift testコマンドも成功。25定義のうちDB実接続4件はsecretを渡さずskip、残り21件が成功した。skipした4件はhostで実PostgreSQLへ接続し成功している。

## 修正した指摘

- SwiftTesting runner argv位置への依存をBundle.module fixture anchorへ修正し、実process回帰で確認
- volume inspectのlabels階層とstopped container restartを実CLI1.5.0のshapeに合わせ修正
- existing roleの5権限flagを再検証し、不適合なら停止
- 正常なsynthetic password fixtureでhost/role/port拒否をテストし、ファイル不存在による偽陽性を除去
- timeoutのnested TaskGroupがcancelを遅らせたためpool/operation/timerを同groupにし、実rows消費+elapsed回帰で確認
- parent cancellationをunavailableへ誤分類しないよう優先し、実cancel回帰で確認

## 未実施

認証済sessionからの施設権限、Passkey、Stripe/Workspace等の外部APIは未実装。実顧客/個人情報は使っていない。接続成功を施設分離や業務機能の検証済みとは扱わない。

## schema/Atlas追加検証

Atlas CE1.3.0で初回migration生成、空replayへの適用と二度目差分なし、永続開発DBへのforward apply/schema一致を成功。実drift列の検出・自動修復しないこと・明示除去後の回復を確認した。実app接続SQLで21拒否、正常fixture、施設別filter、DDL/admin昇格不可を確認しROLLBACK。Pythonは既存16+guard10の計26tests成功。独立Review/Securityの実行結果と保証範囲はLOCAL_MIGRATIONS.mdを参照。remote CIにはまだ接続していない。

実Atlasで過去SQLを書き換えatlas.sumを再生成しvalidate成功となるケースをsynthetic Git repoで再現。その状態でもtrusted Git base guardが改変を拒否した。API sourceは変更していないが、schema適用後のhost Swift25testsも再実行し成功した。

## 施設アクセス・challenge追加段階

2施設のSwiftアクセス層とchallenge migrationを追加。host Swift38tests（Server10/Database23/Contract5）を実DBで検証。追加SQL8拒否と既存21拒否、Python26testsも成功。独立Review Agentも38件をskipなしで再実行し成功。外部moduleでのinitializer/Decodable生成拒否を、現行targetをbuildするscriptでも確認した。Security Reviewはdomain error型保持・secret非出力・実DB権限を確認しblocking指摘なし。最終sourceのApple container/Linux arm64 release build/testも成功。38定義のうちDB14件はsecret非渡しでskip、残り24件が成功。skipした14件はhostで実DB接続し成功している。署名/UV検証、session/Workspaceと公開業務HTTPは未実装。

swift-webauthnは隔離した公式beta1で上流38tests、修正済main固定commitで63tests成功。Sauna依存への追加は行わず、評価/未検証範囲はWEBAUTHN_EVALUATION.mdに記録した。

最終imageへのAPI再起動後にhealth/version、利用者/管理者Webからのapi:smoke、両WebのHTTP200を確認。Bunの最初の呼出は子process用PATH未設定で127終了し、workspace-local BunをPATHへ設定して両方を再実行し成功した（ソース変更なし）。

## blindlog-api固定参照の反映

user指定82a13ed73fff44984e8954781d669cf8320883eaのPackage/Sources/lockを確認し、共通の厳格swiftSettingsを自前production6targetsへ適用した。必要なpublic/direct importsを明示し、生成物は編集せず、認証subjectのconstructorはinternalのまま。host swift build/実DB込み38testsは警告なしで成功。独立Reviewも38testsと境界scriptを実行し成功、Security Reviewは厳格設定下の外部生成拒否を別moduleで確認した。Apple container上のLinux arm64 release build/testも成功（24実行成功、秘密を渡さないDB14件skip）。当該DB14件はhostで実接続し成功している。

Dependabotについては2026-11-01のユーザー指示により失敗・通知を対応対象/ブロッカーから除外した。#41はローカル運用記録へ反映し、GitHubのIssue状態や設定は今回変更していない。
