# API dependency catalogue

ユーザー指定のblindlog-api参照と追加ライブラリを、将来用の未使用分も含めPackage.swiftへ宣言する。Swift6.4/compiler policy・既存実装のtarget構成は維持し、解決revisionをPackage.resolvedへ固定する。未使用dependencyのSwiftPM警告は宣言を削除して隠さない。

## 現在使用する基盤と将来用の宣言

Hummingbird / Swift OpenAPI Generator・Runtime・Hummingbird adapter / PostgresNIO / Crypto / Loggingを既存APIで使う。認証の積み重ねPRではWebAuthn、SwiftCBOR、swift-postgresqlのPostgresNIO trait、swift-sql/ISO、HTTPTypes/ServiceLifecycleを利用する。

blindlog参照のCurrency型も将来の通貨型利用に備えて宣言するが、現行のISO通貨文字列/minor整数契約は変更しない。

ArgumentParser、HummingbirdAuth、PostgresKit、JWTKit、Cloudflare、HummingbirdPostgres、Valkey、SwiftOTel、UUIDV7もユーザー指示で先に宣言する。宣言だけでclient・exporter・認証・外部送信を有効化しない。JWTやGoogleログインをPasskeyの代替認証として追加しない。API key・外部秘密鍵が必要になる処理は実装開始時にユーザーへ確認する。

## 積み重ねた依存PR

最新ユーザー指示に従い、[swift-webauthn PR128](https://github.com/brokenhandsio/swift-webauthn/pull/128/)（head `3fe310ab82b4c7dc5429ca3dbcc1308b3ff8abbb`）を基点とする自前fork `codex/pr128-compat`を使う。必要な独自変更はCrypto5互換とSwift6.4の冗長unsafe注釈修正だけに絞り、PR128の祖先を保持する。旧add-init互換PRは採用しない。上流PRは未mergeであることを明示し、解決revisionをlockする。

PR128の[brokenhandsio/swift-cbor](https://github.com/brokenhandsio/swift-cbor)依存に合わせ、APIの直接CBOR利用もproductCBOR/tag0.2.0へ統一する。旧SwiftCBOR forkは過去の検証・上流PR120由来修正の履歴として残すが、現行依存グラフには含めない。

[PostgresNIO fork PR1](https://github.com/sauna-studio/postgres-nio/pull/1)は1.33.2基準でclosed-channel queryのwrite失敗をquery promiseへ伝播する最小修正。上流PR487/501の経緯と再現を記録し、公開revisionをlockする。forkのdeploy/secret依存workflowは実行せず、専用read-only embedded unit CIとローカル実DB検証を区別する。

swift-postgresqlはユーザー指定`fix-postgresql-closure-lifetime`とPostgresNIO trait、swift-sqlは指定`main`を利用し、いずれもlockfileのrevisionを確認する。fork間で同じpackage identityを重複導入せず、最終graphをresolve/build/testで検証する。外部依存のPRと最新HEADのCodex/CIが完了するまでmainへ取り込まない。

## 検証

`swift package resolve`と`swift test --force-resolved-versions`を実行する。下流のPasskey実装ではこの初期129件のcatalogueを使い、実PostgreSQL18を含むhost Swift65testsが成功している。catalogue単体の新規checkout build/testと遠隔CIの結果はPRへ記録する。DB統合testは承認済みprivate password-fileを指定したときだけ実行し、未指定のskipを成功扱いしない。

新しい外部ライブラリは公式を優先し、必要なfork修正は再現・最小差分・独立レビューを伴う。ライブラリの全機能を検証済みとは扱わず、既存の権限・Secrets・本番deployを追加しない。

## Final local validation snapshot

WebAuthn PR128 compatibility revision `0d1a4e6408f0a611a98b408ab6a465e40303ac7c` requires Swift6.4 and uses native Swift literal replacement/padding. CBOR0.2.0 is pinned to `52432a1118bcbabb9a973330c3af85d8ddf3f015`; PostgresNIO fork revision `5722f49dad5eb951522afafa57320ad3f9ea69d2` is retained on merged sauna-1.33.2 history. The final lock has130 pins and contains no old SwiftCBOR.

The catalogue baseline passed38 real-PostgreSQL host tests. The downstream authentication implementation passed67 real-PostgreSQL tests on the consolidated revision; independent Review reran67 on the same runtime sources before the compiler-policy-only consolidation. The fork passed65 strict native and exact-snapshot Apple-container/Linux tests. These results do not replace latest-HEAD GitHub CI and Codex review.

SwiftPM6.4 currently warns that transitive upstream PostgresNIO URLs and the directly pinned fork share one identity. Package.resolved selects exactly one reviewed fork revision; no second PostgresNIO is linked. This is a known package-resolution warning, separate from intentional unused catalogue declarations. A future SwiftPM update may require public URL mirrors or upstream adoption of PR698; current own-source warning-as-error policy remains enabled.
