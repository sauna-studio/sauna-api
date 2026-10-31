# sauna-api
Sauna Studio API — Swift / Hummingbird / PostgreSQL 18


## Scope

予約・決済・在庫・設備・シフト・チャットの業務API。Swift 6 / Hummingbird / PostgreSQL 18 / PostgresNIO / Atlas / OpenAPIを採用する。

## Architecture

施設IDによる境界をAPIとDBで検証する。予約・決済・シフトの正本はPostgreSQL。認証・決済・競合制御・個人情報・施設権限を実装する際はSecurity Review Agentを必須とする。

## Verification

実装後はswift build / swift test、PostgreSQL 18統合テスト、OpenAPI整合性とAtlas migrationを検証する。

初期PRは開発基盤のみを追加します。CIはRepository policy検査を実行し、業務機能の実装や動作検証はまだ含みません。

[AGENTS.md](AGENTS.md) と [CONTRIBUTING.md](CONTRIBUTING.md) に従い、Issueの依存関係を満たしてから独立Review Agentを並行起動して実装します。共通規則適用元: [sauna-studio/.github@075c6695309d](https://github.com/sauna-studio/.github/tree/075c6695309d28baad2dc1391d7d3821b81142cc)。
