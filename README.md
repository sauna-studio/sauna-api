# sauna-api
Sauna Studio API — Swift / Hummingbird / PostgreSQL 18


## Scope

予約・決済・在庫・設備・シフト・チャットの業務API。Swift 6 / Hummingbird / PostgreSQL 18 / PostgresNIO / Atlas / OpenAPIを採用する。

## Architecture

施設IDによる境界をAPIとDBで検証する。予約・決済・シフトの正本はPostgreSQL。認証・決済・競合制御・個人情報・施設権限を実装する際はSecurity Review Agentを必須とする。

## Verification

現在は [MVP-001 / B01](https://github.com/sauna-studio/sauna-api/issues/5) のOpenAPI契約に加え、[MVP-002 / B02](https://github.com/sauna-studio/sauna-api/issues/6) のHummingbirdサーバをローカル開発しています。DBの接続pool・診断はローカル実装済みです。業務schema/Atlas migrationのローカル基盤も実装済みです。施設アクセス層とPasskey challenge管理を追加していますが、Passkey認証・業務HTTP・外部APIは未実装で、HTTPサーバ起動にAPI Keyや秘密鍵は必要ありません。今回の変更はローカルbranchのみで、push・PR・GitHub Actionsは実行しません。

契約の正本は [openapi.yaml](Sources/SaunaAPIContract/openapi.yaml) です。`GET /health` はDB readinessではなくAPIのlivenessを表す固定値、`GET /version` は公開API版とアプリrelease版のみです。両方とも認証不要で、成功は`application/json`、利用不能は固定メッセージの`application/problem+json`を定義します。ソースrevision・hostname・環境・依存サービスの状態・例外詳細は返しません。契約のexamplesは実装の稼働状態や実releaseを示すものではありません。

Swift OpenAPI Generator 1.14.3がtypes/server interfaceをbuild時に生成し、Runtime 1.13.3とともにコンパイルします。生成物はコミットしません。`Package.resolved`で推移依存も固定します。DTOのCodable処理だけでJSON Schemaの全制約が実行時に検証されるとは限らないため、HTTP実装時も出力制約と情報非公開を検証してください。

Swift 6.4.2 / Python 3.11以上で実行:

```sh
python3 -m venv .venv
.venv/bin/pip install -r scripts/requirements.txt
.venv/bin/python scripts/validate_openapi.py
.venv/bin/python -m unittest discover -s scripts -p 'test_*.py' -v
swift build --force-resolved-versions
swift test --force-resolved-versions
```

macOS標準の`python3`が古い場合は3.11以上のPythonを明示指定してください。CIはRepository policy、OpenAPI仕様と全成功・エラーexample、内部情報を拒否する契約テスト、Linux Swift生成・build・DTOテストを実行します。実PostgreSQL18の統合テストはPGPASSWORD_FILEを明示設定したときだけ実行します。未指定時のskipをDB検証成功とは扱いません。Atlas/schemaの手順と保証範囲は[ローカルmigration](docs/LOCAL_MIGRATIONS.md)を参照してください。

## Local HTTP server

Hummingbird 2.28.1 / OpenAPI Hummingbird 2.1.0をexactで指定しています。`SaunaAPIServer`が生成APIProtocolを実装し、実行可能な`SaunaAPI`が設定の検証とサービスの起動・終了を担当します。

```sh
swift build --force-resolved-versions
.build/debug/SaunaAPI
# 別のターミナルで実行
curl --fail http://127.0.0.1:8080/health
curl --fail http://127.0.0.1:8080/version
```

`PORT`は未設定なら8080、設定する場合はASCII数字のみの1〜65535です。空文字・空白・符号・範囲外値は起動エラーとし、入力値はログに出しません。`BIND_HOST`は未設定なら`127.0.0.1`。明示できる値は`127.0.0.1`・`::1`・`0.0.0.0`だけです。コンテナ内から接続を受ける場合は`BIND_HOST=0.0.0.0`を明示し、ホストへの公開はloopbackに限定します。

`SIGTERM`と`SIGINT`をServiceLifecycleで処理し、graceful shutdown後に終了します。通常のサービス終了はexit 0です。`/version`の値はソースにある公開release定数だけを使用し、環境・git SHA・hostname・内部例外は返しません。`Server`ヘッダーも付けません。503固定ProblemのHTTPテストはテスト用の依存注入を使用し、公開の障害切替URLや環境変数は追加していません。

`swift test --force-resolved-versions`には、実socket経由の200/503、Accept不一致・404の情報非公開、設定の境界値、実子processのHTTP応答とSIGTERM終了を含めます。Hummingbirdのliveテストと子processのテストは一時的なローカルportを使用します。失敗時のprocess cleanupはテスト自身が起動した子processだけを対象とします。

ローカルコンテナはApple `container`を使用し、Docker・Docker Composeは使いません。API Key・秘密鍵・DBパスワード等が必要になる作業では停止し、ユーザーへ確認します。無断の秘密値生成・既存credential探索・接続時のtrust回避は行いません。

参照: [Swift OpenAPI Generator](https://github.com/apple/swift-openapi-generator)、[OpenAPI validator](https://openapi-spec-validator.readthedocs.io/en/latest/)、[blindlog-api](https://github.com/zunda-pixel/blindlog-api)。

[AGENTS.md](AGENTS.md) と [CONTRIBUTING.md](CONTRIBUTING.md) に従い、Issueの依存関係を満たしてから独立Review Agentを並行起動して実装します。共通規則適用元: [sauna-studio/.github@075c6695309d](https://github.com/sauna-studio/.github/tree/075c6695309d28baad2dc1391d7d3821b81142cc)。

## Apple container / PostgreSQL のローカル環境

[ローカル環境の手順](docs/LOCAL_DEVELOPMENT.md)と[検証記録](docs/LOCAL_VALIDATION.md)を参照してください。Docker Engine/Desktop/CLI/Composeは使用しません。APIは127.0.0.1:8080、DBは127.0.0.1:55432だけに公開します。DBの承認済みローカル専用パスワードはGit除外の.local/secrets内、0700/0600で保持し、値を表示しません。

施設アクセスとchallengeの保証範囲・検証手順は[ローカル認証基盤](docs/LOCAL_IDENTITY.md)を参照してください。
