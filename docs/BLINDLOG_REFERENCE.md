# blindlog-api を API 実装の参照にする

参照commit: [82a13ed73fff44984e8954781d669cf8320883ea](https://github.com/zunda-pixel/blindlog-api/tree/82a13ed73fff44984e8954781d669cf8320883ea)。ユーザーが指定した[Package.swift](https://github.com/zunda-pixel/blindlog-api/blob/82a13ed73fff44984e8954781d669cf8320883ea/Package.swift)と、そのcommitのSources/Package.resolvedを基準にする。将来のmainの内容をこの参照結果と混同しない。

## 構成の対応

| blindlog | Saunaでの方針 |
| --- | --- |
| App.swift → BuildApplication.swift | SaunaAPIは起動/固定エラーだけ、SaunaAPIServer.makeApplicationをcomposition rootとする |
| APIProtocol実装と依存注入、操作別extension | 生成契約をSaunaAPIContractに隔離し、ServiceAPIへ依存を注入。操作増加時は機能別handlerへ分離 |
| Model/Middleware/WebAuthnProtocol | DB/identityは独立target、認証統合時は実verifierとtest doubleのprotocolを分離 |
| Hummingbird/Swift OpenAPI Generator | 現在も採用済み。生成物を編集しない |
| Swift6.4/macOS27/厳格swiftSettings | 自前production6targetsへ同じ厳格設定を適用。tests/第三者targetsへは強制しない |

ExistentialAny、InternalImportsByDefault、MemberImportVisibility、InferIsolatedConformances、ImmutableWeakCaptures、NonisolatedNonsendingByDefault、非隔離default、strictMemorySafety、warnings-as-errorsを有効化した。公開signatureで必要な型だけpublic importとし、その他のimportを公開しない。生成OpenAPI targetにも同設定でbuildし、生成物は手編集しない。

MemberImportVisibilityで見つかった欠落は定義moduleの直接importで直す。起動処理は固定Hummingbird版のrunService既定値（SIGTERM/SIGINT）を使い、transitive importのUnixSignal静的memberへ依存しない。strictMemorySafetyはコンパイラの検査であり、第三者libraryも含む完全なmemory safetyの証明とは記録しない。

## 依存ライブラリの評価方針

blindlogの依存を選定の起点とし、Saunaの受け入れ条件に必要なものを採用する。branchをそのまま追従せず、その参照commitのPackage.resolvedが示すrevisionと上流差分を確認し、採用時にrelease/exact revisionとlockfileを固定する。

| 候補 | 現在の判断 |
| --- | --- |
| ArgumentParser | command/subcommandが増える時に評価 |
| HummingbirdAuth/WebAuthn | Passkey verifier/sessionのprotocol注入に評価。Sauna subjectの無検証factoryは作らない |
| PostgresKit/HummingbirdPostgres/swift-postgresql/swift-sql | schema/async pool lifetime/型付きqueryへ適用できるか評価。現PostgresNIOを根拠なく置換しない |
| swift-otel | OTel実装時の第一候補。PII/secretを含めない属性とlocal exporterを先に検証 |
| swift-currency | minor-unit/対応通貨の検証で評価。金額は整数で扱う |
| UUIDV7 | 必要性とlicense/上流状態を確認後に評価。今回未採用 |
| JWT/Valkey/Cloudflare | 必要性が生じた時に個別判断。メールOTPログインやValkey challenge正本はSaunaへ継承しない |

JWTはPasskey検証の代わりにしない。予約・決済・シフト/challengeの正本はPostgreSQL、基盤はGoogle Cloud、社員連携はWorkspaceとする。参照先のメール認証・Cloudflare設定・secret設定をコピーしない。

## 指定commitで使われているforkとbranch依存

- WebAuthn `add-init`: [1781923545d83304905473944f95262bb5225c56](https://github.com/zunda-pixel/swift-webauthn/tree/1781923545d83304905473944f95262bb5225c56)。公開のCredential/VerifiedAuthentication initializerはtest doubleで返却値を作る用途として評価できるが、認証証明を外部入力から作る入口にしない。Crypto4系制約とSauna5.0.3の差、Linux test修正も調査対象。今回静的確認のみで、Sauna依存へ未追加。
- PostgreSQL `fix-postgresql-closure-lifetime`: [e5dca9dca136f5dd646bc98e2f3cdf1090430e26](https://github.com/zunda-pixel/swift-postgresql/tree/e5dca9dca136f5dd646bc98e2f3cdf1090430e26)。同期借用closureのthread-pool lifetime修正であり、現async PostgresNIO poolへ同じunsafe処理をコピーしない。導入時はcancel/throw/lifetime回帰が必要。
- swift-sql: [a09763bdc3b81683e5bca5f913875c6304dc2f9b](https://github.com/swift-compositions/swift-sql/tree/a09763bdc3b81683e5bca5f913875c6304dc2f9b)。SQL Macros/Foundation Integrationを型付きquery候補として評価する。
- UUIDV7: [f9340a6f666e794a035d15df5be36bc091b60028](https://github.com/zunda-pixel/UUIDV7/tree/f9340a6f666e794a035d15df5be36bc091b60028)。現調査でlicense確認を完了しておらず未採用。

既存の[上流WebAuthn隔離評価](WEBAUTHN_EVALUATION.md)はこのforkの実行検証ではない。forkが必要なら再現/最小差分/固定revision/上流PRを追跡し、上流にある修正と重複させない。
