# blindlog-api を API 実装の参照にする

参照commit: [82a13ed73fff44984e8954781d669cf8320883ea](https://github.com/zunda-pixel/blindlog-api/tree/82a13ed73fff44984e8954781d669cf8320883ea)。ユーザーが指定した[Package.swift](https://github.com/zunda-pixel/blindlog-api/blob/82a13ed73fff44984e8954781d669cf8320883ea/Package.swift)と、そのcommitのSources/Package.resolvedを基準にする。将来のmainの内容をこの参照結果と混同しない。

## 構成の対応

The mapping starts from catalogue baseline PR43; authentication behavior is implemented in stacked PR44 as detailed below.

| blindlog | Saunaでの方針 |
| --- | --- |
| App.swift → BuildApplication.swift | SaunaAPIは起動/固定エラーだけ、SaunaAPIServer.makeApplicationをcomposition rootとする |
| APIProtocol実装と依存注入、操作別extension | 生成契約をSaunaAPIContractに隔離し、ServiceAPIへ依存を注入。操作増加時は機能別handlerへ分離 |
| Model/Middleware/WebAuthnProtocol | DB/identityは独立target、認証統合時は実verifierとtest doubleのprotocolを分離 |
| Hummingbird/Swift OpenAPI Generator | 現在も採用済み。生成物を編集しない |
| Swift6.4/macOS27/厳格swiftSettings | 自前production6targetsへ同じ厳格設定を適用。tests/第三者targetsへは強制しない |

ExistentialAny、InternalImportsByDefault、MemberImportVisibility、InferIsolatedConformances、ImmutableWeakCaptures、NonisolatedNonsendingByDefault、非隔離default、strictMemorySafety、warnings-as-errorsを有効化した。公開signatureで必要な型だけpublic importとし、その他のimportを公開しない。生成OpenAPI targetにも同設定でbuildし、生成物は手編集しない。

MemberImportVisibilityで見つかった欠落は定義moduleの直接importで直す。起動処理は固定Hummingbird版のrunService既定値（SIGTERM/SIGINT）を使い、transitive importのUnixSignal静的memberへ依存しない。strictMemorySafetyはコンパイラの検査であり、第三者libraryも含む完全なmemory safetyの証明とは記録しない。

## Current adoption decisions

The fixed blindlog commit remains the historical architecture reference. Later explicit user instructions require declaring its dependency catalogue, including packages not yet used. The earlier assessment that WebAuthn and UUIDV7 were not added is superseded: both are declared and locked in Package.swift/Package.resolved. Declaration, linked runtime use, source review and license evidence are separate decisions.

[DEPENDENCIES.md](DEPENDENCIES.md#locked-direct-dependency-evidence) records all 25 direct declarations at their actual locked revisions, including license/NOTICE files read from cached Git objects. The catalogue PR #43 preserves the existing runtime; stacked [authentication PR #44](https://github.com/sauna-studio/sauna-api/pull/44) selects additional products. An unused declaration does not enable its clients, exporters, login methods or external calls.

| Package or group | Current decision |
| --- | --- |
| Hummingbird / OpenAPI Generator, Runtime and adapter / PostgresNIO / Crypto / Logging | Already selected by baseline API targets. Generator is a build plugin. |
| NIO / HTTPTypes / ServiceLifecycle | Already transitively used by the existing server/database; PR #44 also selects products explicitly. |
| WebAuthn / new CBOR / swift-postgresql / swift-sql / ISO9075 | Declared and locked here; PR #44 uses them for actual Passkey verification and typed SQL on the existing async borrowed PostgresNIO connection. No nested synchronous database lease is added. |
| ArgumentParser / Currency / HummingbirdAuth / PostgresKit / JWTKit / Cloudflare / HummingbirdPostgres / Valkey / SwiftOTel | Declared for future work by user instruction; no Sauna target in this catalogue selects their products. Currency contracts remain ISO strings plus integer minor units. JWT and Google login do not replace Passkey. |
| UUIDV7 | Declared at f9340a6f666e794a035d15df5be36bc091b60028, not selected by Sauna targets. No LICENSE/COPYING or README license grant was found at that revision; source headers state All rights reserved. License permission is unresolved, rather than falsely recorded as cleared or as an absent dependency. |

Business records and challenges remain authoritative in PostgreSQL; Google Cloud and Workspace retain their specified roles. The reference project's email OTP login, Valkey challenge store, Cloudflare deployment and secret configuration are not inherited.

## Current forks and source evaluation

- WebAuthn now follows the user-selected [upstream PR #128](https://github.com/brokenhandsio/swift-webauthn/pull/128), head `3fe310ab82b4c7dc5429ca3dbcc1308b3ff8abbb`. [Consumer fork PR #2](https://github.com/zunda-pixel/swift-webauthn/pull/2) merged into fork main at `4687a265f5dc733d5cd105db9de8b2531fb44ee0`; locked `0d1a4e6408f0a611a98b408ab6a465e40303ac7c` is retained in that history. Source changes cover Crypto 5, Swift 6.4 safety annotations, literal stdlib Base64 transformations and test-only hex/JSON import fixes. The fork declares Swift 6.4 minimum and explicitly allowlists only the 122 intentional PR #128 API changes; an omitted-entry negative control confirms other breaks still fail. No public initializer is added to manufacture a verified result. The locked LICENSE is Apache-2.0 and NOTICE.txt is present.
- New [swift-cbor 0.2.0](https://github.com/brokenhandsio/swift-cbor/tree/52432a1118bcbabb9a973330c3af85d8ddf3f015), product CBOR, is the selected parser. Its locked LICENSE is MIT. Old SwiftCBOR is absent from this lock. The separately merged legacy SwiftCBOR fork remains a historical consumer compatibility fix, not a current parser dependency.
- swift-postgresql uses the requested `fix-postgresql-closure-lifetime` at `e5dca9dca136f5dd646bc98e2f3cdf1090430e26` with PostgresNIO trait. Source review identified the synchronous borrowed-closure lifetime change. Sauna uses its query rendering bridge on the existing async connection rather than copying unsafe lifetime code. LICENSE.md is Apache-2.0.
- swift-sql is declared on requested main and locked to `76b61c7adfa3159dba5353a8f8b05110112d0050`; its table macros/builders feed parameterized queries in PR #44. LICENSE.md is MIT. Direct ISO9075 is locked to `a8e0f3223cd0046adbd8545e7a290f61c12f6048`; its Apache-2.0 license includes a Runtime Library Exception.
- PostgresNIO is locked to reviewed fork `5722f49dad5eb951522afafa57320ad3f9ea69d2`, retained on merged sauna-1.33.2 history. Its closed-channel promise fix has dedicated CI and actual database/cancellation tests. LICENSE is MIT and NOTICE.txt is present.

## Historical reference pins

These describe blindlog at the supplied commit, not current Sauna adoption: WebAuthn add-init `1781923545d83304905473944f95262bb5225c56`, swift-postgresql `e5dca9dca136f5dd646bc98e2f3cdf1090430e26`, swift-sql `a09763bdc3b81683e5bca5f913875c6304dc2f9b`, and UUIDV7 `f9340a6f666e794a035d15df5be36bc091b60028`. Old add-init compatibility PR #1 was closed without merging after the PR #128 instruction. Its public-initializer experiment is not the current authentication boundary.

[WEBAUTHN_EVALUATION.md](WEBAUTHN_EVALUATION.md) is an earlier isolated evaluation. Current evidence is the locked source/license table and the specific fork, catalogue and authentication PR checks; an earlier probe does not verify a different revision.
