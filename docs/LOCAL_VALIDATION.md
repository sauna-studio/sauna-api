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
