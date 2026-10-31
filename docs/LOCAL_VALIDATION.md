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

業務schema/Atlas、施設権限、Passkey、Stripe/Workspace等の外部APIは未実装。実顧客/個人情報は使っていない。接続成功を施設分離や業務機能の検証済みとは扱わない。
