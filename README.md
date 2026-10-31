# sauna-api
Sauna Studio API — Swift / Hummingbird / PostgreSQL 18


## Scope

予約・決済・在庫・設備・シフト・チャットの業務API。Swift 6 / Hummingbird / PostgreSQL 18 / PostgresNIO / Atlas / OpenAPIを採用する。

## Architecture

施設IDによる境界をAPIとDBで検証する。予約・決済・シフトの正本はPostgreSQL。認証・決済・競合制御・個人情報・施設権限を実装する際はSecurity Review Agentを必須とする。

## Verification

現在は [MVP-001 / B01](https://github.com/sauna-studio/sauna-api/issues/5) のOpenAPI契約とSwift生成コードのコンパイル検証までを実装しています。HTTPサーバ・DB・認証はまだ実装していません。HummingbirdのHTTP起動・port設定・graceful shutdownは [MVP-002 / B02](https://github.com/sauna-studio/sauna-api/issues/6) で扱います。

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

macOS標準の`python3`が古い場合は3.11以上のPythonを明示指定してください。CIはRepository policy、OpenAPI仕様と全成功・エラーexample、内部情報を拒否する契約テスト、Linux Swift生成・build・DTOテストを実行します。PostgreSQL/Atlasの検証はDB実装の追加時に有効化します。

参照: [Swift OpenAPI Generator](https://github.com/apple/swift-openapi-generator)、[OpenAPI validator](https://openapi-spec-validator.readthedocs.io/en/latest/)、[blindlog-api](https://github.com/zunda-pixel/blindlog-api)。

[AGENTS.md](AGENTS.md) と [CONTRIBUTING.md](CONTRIBUTING.md) に従い、Issueの依存関係を満たしてから独立Review Agentを並行起動して実装します。共通規則適用元: [sauna-studio/.github@075c6695309d](https://github.com/sauna-studio/.github/tree/075c6695309d28baad2dc1391d7d3821b81142cc)。
