# Sauna Studio — 共通エージェント規則

共通規則の正本: `sauna-studio/.github/AGENTS.md`。各リポジトリにはこの規則の実効的なコピーと固有の検証コマンドを配置する。リンクだけで規則が継承されると判断しない。

## 目的・アーキテクチャ

川沿いの小規模サウナ施設の予約・決済・運営を開発する。初期は1施設でも施設IDと施設単位の認可を設計する。予約・決済・シフトなどの業務データはSauna API / PostgreSQLを正本とし、外部サービスを正本にしない。

API: Swift 6 / Hummingbird / PostgreSQL 18 / PostgresNIO / Atlas / OpenAPI / Swift OpenAPI Generator。Apple: SwiftUI、iOS・iPadOS 27.2以上。Web: SvelteKit / TypeScript。基盤: Terraform / Cloud Run / Cloud SQL / Docker / OpenTelemetry。最新安定版OS・ブラウザを対象とし、不要な後方互換分岐を追加しない。

ログインはPasskey / WebAuthnのみ。社員のGoogle Workspace組織アカウントは所属・本人対応・API認可に使い、GoogleログインをSaunaセッション認証に代用しない。Stripeは決済処理を担当する。Google Cloud Swiftクライアントの対応範囲とWorkspace APIの対応範囲を個別に確認する。Google Chat Bot / sauna-mcpは`sauna-automation`で実装する。`zunda-pixel/GoogleChatApp`とそのProjectは対象外であり変更しない。

## 実装フローと役割

1. Issue、受け入れ条件、Sub-issues、Dependencies、既存PRとADRを読み、重複とブロッカーを確認する。
2. 実装計画を作る。Coding Agentが実装している間は、独立したReview Agentを必ず並行起動する。別コンテキストのレビューを用い、実装者自身の再読だけで代用しない。
3. 認証・決済・予約競合制御・個人情報・施設権限の変更はSecurity Review Agentも並行起動する。Bug Triage Agentは再現・重複確認、Tool Review AgentはMCP・Skills・CIの権限と実行安全性を確認する。
4. 指摘を修正し、実際にビルド・テスト・必要な動作検証を実行する。AIレビューのみで合格にしない。バグは重複を調べて必要ならIssueを作成し、回帰テストを追加する。
5. 再レビュー後、GitHub Actionsの成功を確認し、PRに実装内容・検証・レビュー結果・未解決事項を記録する。未実行チェックを成功と表現しない。

並行エージェントが利用できない場合はその制約を記録し、レビュー条件を満たすまでマージしない。レビューは自動でGitHubの承認票になるわけではない。

## コーディング・テスト

既存構成を尊重し、小さいIssue単位の変更にする。Swiftの並行性はSwift 6の検査を有効にし、無根拠な`@unchecked Sendable`やエラー握り潰しを避ける。TypeScriptはstrictを使用する。公開APIはOpenAPIで契約を先に明示し、生成物を手編集しない。DB変更はAtlasのバージョン管理されたmigrationと統合テストを伴う。

APIは`swift build` / `swift test`とPostgreSQL 18統合テスト、Webはlockfileによるinstall・型検査・単体テスト・production build・必要なPlaywright検証、Appleは対象Xcodeでbuild/testと必要なSimulator動作確認、Terraformはfmt / init -backend=false / validateを実行する。コード未配置の基盤PRは構造検査だけを実行し、アプリ検証済みと記録しない。

`.github`リポジトリで共通基盤を変更するときの検証は`python scripts/validate_repository.py`（Python 3.11以上、`scripts/validation-requirements.txt`を使用）と`actionlint`。他のリポジトリでは末尾の固有指針とREADMEにある実在する検証手順を使う。Reusable Workflowsは呼出先の実コード・lockfile・テストが存在してから有効化する。

## セキュリティ

Secrets、トークン、個人情報、実顧客データをコード・ログ・Issue・PRに残さない。認証情報の値を出力しない。施設IDは信頼できるセッションと権限から検証し、全読み書きで施設境界を守る。金額は通貨と最小単位の整数で扱い、クライアントの価格を信頼しない。予約はDBトランザクション・制約・競合テストで過剰予約を防ぐ。Stripe webhookは署名と冪等性を検証し、決済成功をブラウザの戻り値で確定しない。

Google APIは最小scopeを使い、Domain-wide delegation・組織全体の権限・課金リソース・本番デプロイは明示承認を得る。OpenTelemetryにPII・認証情報を含めない。Workflowは最小permissions、外部Actionsは完全なcommit SHA固定、checkoutの資格情報を永続化しない。PRの未信頼コードを`pull_request_target`で実行しない。

## MCP・Skills

開始時に実際に利用可能なMCP・Skills・CLIを確認する。GitHub MCP/CLI、TablePro/PostgreSQL/Atlas、XcodeMCPKit・NeoSimulator・SwiftUI Expert・Swift Build、Safari MCP・Playwright・SvelteKit関連Skillsを目的に応じて使う。公式導入方法と利用条件を検証してからローカル導入する。システム設定・認証・権限を無断で拡大しない。接続できないものは代替コマンドと未検証項目を記録する。インストール済みと利用済みを区別する。

## GitHub運用とドキュメント

`codex/`ブランチとPRを使い、`main`へ直接pushしない。既存変更・リポジトリ・ライセンスを上書きしない。必要なGitHub Issues/Projectsへの更新以外の他者宛メッセージは明示指示がない限り送信しない。Issueは横断Projectへ追加し、受け入れ条件と実際の依存関係を記録する。秘密の脆弱性は公開Issueで扱わずSECURITY.mdに従う。

PRには関連Issue、何が変わるか、実行したチェックと結果、独立Review/Security Reviewの結果、既知の制限を記録する。required checksをskipで満たしたように装わない。Releasesはテスト済みcommitと変更点を持ち、Environmentsは開発・検証・本番の承認境界を分ける。Packagesは配布の必要が生じたときだけ使う。

重要な設計変更は`sauna-docs`のADRに背景・決定・代替案・影響を残し、Wikiに索引を反映する。繰り返すバグや重要なレビュー指摘は必要に応じてこの規則と各repoのAGENTS.mdを更新する。共通規則の更新は他repoへの追従PRを作り、適用元のcommitを明示する。

## sauna-api 固有指針

共通規則適用元: `sauna-studio/.github@075c6695309d28baad2dc1391d7d3821b81142cc`。

予約・決済・在庫・設備・シフト・チャットの業務API。Swift 6 / Hummingbird / PostgreSQL 18 / PostgresNIO / Atlas / OpenAPIを採用する。

施設IDによる境界をAPIとDBで検証する。予約・決済・シフトの正本はPostgreSQL。認証・決済・競合制御・個人情報・施設権限を実装する際はSecurity Review Agentを必須とする。

実装後はswift build / swift test、PostgreSQL 18統合テスト、OpenAPI整合性とAtlas migrationを検証する。

初期CIは共通Repository policy検査のみ。アプリのビルド・テスト・実行を検証済みとは扱わない。実装Issueでmanifest・lockfile・テストを追加し、対応する実コードCIを有効化する。
