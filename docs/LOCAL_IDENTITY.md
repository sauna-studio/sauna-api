# ローカル施設アクセス・Passkey認証

## 実装範囲と境界

`SaunaAPIIdentity`にPasskey登録、署名・User Verification検証、DB challengeとsession管理を実装している。`VerifiedSubject`は外部moduleから生成・JSON decodeできず、認証サービスだけが検証済み利用者を生成する。公開HTTPはローカル認証・credential管理の13操作のみで、施設の業務HTTP、予約・決済・Workspace認可は未実装である。

`FacilityStore`はproduct一覧・詳細・名称更新ごとに、要求facility_id、subject user_id、有効membership、許可roleを同じSQLで再検査する。staffは閲覧、manager/ownerは更新できる。権限不足と不存在は同じ固定エラーになる。施設/roleをcontextへキャッシュせず、失効や降格は反映後の次のREAD COMMITTED statementで拒否する。実行中statementと失効処理の厳密な直列化は保証しない。raw SQL app roleは全施設行のDML権限を持つため、任意userIDをtrusted subjectへ変換してはならない。

## 登録・ログイン

RPは`localhost`、originはcustomer=`http://localhost:5173` / staff=`http://localhost:5174`に固定する。Webはlocalhostで開き、APIの接続先だけをloopback `127.0.0.1:8080`にする。production RP/originは未対応である。

- 登録optionsはdiscoverable credentialとUVを必須とし、ES256/P-256、attestation noneのみを受け付ける。
- userIDと32-byte userHandleをserverで生成し、登録intentへ対応付ける。登録は新規accountのみを作り、sessionを発行しない。既存accountへのcredential追加は、後述する再認証付き管理経路だけで受け付ける。
- 登録ではcanonical id/rawId、attested credential ID、COSE key、RP hash、UP/UV、backup flags、clientData type/challenge/originを検査する。assertionは保存済み公開鍵による署名、userHandle、counter、backup eligibilityを検査する。
- crossOrigin=trueや型不正・null、topOriginの存在、重複JSON property、対応外extension、CBOR trailing bytesを拒否する。CBORはlibraryへ渡す前にbyte数・深さ・container種類を制限する。
- 認証ではcredential rowをlockし、counter更新とsession発行を同じtransactionで行う。sessionを作るには登録後に署名付きUV assertionが必要である。

clientDataの未知propertyは[WebAuthn Level 3 CollectedClientData](https://www.w3.org/TR/webauthn-3/#dictdef-collectedclientdata)に従って許容する。既知security fieldは厳格に検査し、署名検証には未知propertyも含む元のclientDataJSON byte列を使用する。再serializationや未知propertyの除去は行わない。

外部libraryは最新ユーザー指示に従い、[上流WebAuthn PR128](https://github.com/brokenhandsio/swift-webauthn/pull/128/)を基点とする自前forkとSQL packagesを採用する。直接のCBOR利用もbrokenhandsio/swift-cborのproduct `CBOR`、安定tag0.2.0へ統一する。入力全体を消費するdecoderへmaximumDepth16と重複map key拒否を明示し、既存の狭いframing制限も維持する。旧SwiftCBOR/上流PR120由来forkの検証は履歴として保持し、新グラフの検証に流用しない。PostgresNIOのclosed-channel query promise修正は[専用fork PR1](https://github.com/sauna-studio/postgres-nio/pull/1)で検証・merge済みで、[上流DRAFT PR698](https://github.com/vapor/postgres-nio/pull/698)へ最小差分を提出している。上流での採用済み修正とは表現しない。最終的な依存revisionの根拠はPackage.swift / Package.resolvedとADRに記録する。[以前の隔離評価](WEBAUTHN_EVALUATION.md)はその時点の履歴であり、最終依存による検証の代替にしない。

## Challenge・session lifecycle

CSPRNGで32-byte公開nonceと独立した32-byte browser-flow bindingを生成する。bindingはcanonical base64url、DBにはSHA-256 digestのみを保存する。purpose、RP/origin、binding digest、未消費状態、DB時刻の期限を同一statementで検査する。row lock取得後にclock_timestamp()を取得し、lock待機による期限超過も拒否する。TTLは1ms〜5分。challenge消費は署名検証・後続transactionの前にautocommitし、失敗時に再利用可能へ戻さない。

session tokenは独立した32-byte乱数で、DBにはdigestのみを保存する。sessionのorigin、期限、失効、対応credentialの有効性を照合し、CSRF tokenはsession tokenからHMACで導出する。既定期限は8時間、最大1日。logoutと全session失効はCSRF検証が必須である。cookieはcustomer/staffごとの`__Host-sauna-…`名、Secure / HttpOnly / SameSite=Strict / Path=/を使い、Domainを設定しない。生tokenや鍵を保存・表示しない。

HTTPはexact Origin、重複cookie、JSON形式、128KiB body上限を検査し、originごとに240要求/分のローカル制限を持つ。responseはno-store、固定エラーで内部情報を返さない。SvelteKitの同一origin BFFを通す構成で、直接cross-origin CORSは公開しない。

DB操作には10秒のoperation deadlineを設け、取消対象のleased connectionを閉じてからpoolへ返す。共有poolのrun taskをrequestごとに取り消さない。timeout・取消後のpool回復は実DB回帰で確認する。`LocalDatabase.withClient`の診断用lifetimeと、常駐HTTP serverのpool lifetimeは分けている。

## 複数Passkeyの管理

有効なsession本人のcredential一覧を返すが、COSE公開鍵や秘密鍵、他user情報は返さない。有効credential上限は10件。同期Passkeyのコピー数や物理端末数をcredential数から判断しない。

- 追加は`addition/authorization/options`→既存keyの新しい署名・UVを`authorization/finish`で検証→別nonceのcreation options→新keyを`addition/finish`で検証する。2段階のchallengeと消費状態は独立し、同じaccountの既存userHandleを維持する。
- 失効は`revocation/options`でtargetを固定し、`revocation/finish`でそのtargetとは異なる有効keyの署名・UVを要求する。最後の有効keyは失効できない。物理削除せずrevoked_atを保存する。
- すべての書込みは現在のsessionとCSRFを要求する。専用intentをuser/session digest/RP/origin/action/target/5分期限へ束縛し、匿名登録・login・別session・別操作へ転用できない。署名や新keyの検証前に独立transactionでnonceを消費・commitし、後続の失敗・取消でも復活させない。
- account rowを最初のserialization pointにし、管理・login session発行・全session失効を直列化する。管理ではsession/proof key/target等の必要なlockを取得後のDB時刻で期限・失効を再検証する。global credential IDのINSERT待機後も検査し、期限切れなら追加をrollbackする。取消は共有poolを止めず所有leaseだけを破棄する。
- 管理変更が成功するとaccountの全sessionを失効し、現在のcookieも削除する。新しい有効keyで再loginする。追加の認可成功だけではsessionを失効しないが、後段で元session・認可keyの有効性を再確認する。

allowCredentials/excludeCredentialsはbrowser hintでありserver認可の代替ではない。request optionsはlibraryのtyped allowCredentialsを使う。creation modelに無いexcludeCredentialsだけをtyped Encodable wrapperで補い、上流採用後の削除を[Issue49](https://github.com/sauna-studio/sauna-api/issues/49)で追跡する。独自transaction取消helperは[Issue50](https://github.com/sauna-studio/sauna-api/issues/50)、cookie transportは[Issue51](https://github.com/sauna-studio/sauna-api/issues/51)で再評価する。設計はsauna-docsのADR0014に記録している。

全credentialを失った本人の回復、Google/メールによる代替login、スタッフの権限だけでのkey追加は実装しない。同期Passkeyと別credentialの事前登録による備えを区別し、本人回復とApple保存契約を含むIssue13全体は未完了として残す。

## ローカル起動と検証

DBはApple containerを使う。既存の承認済みprivate credentialを表示・上書きせず再利用する。別のAPI keyや本番鍵が必要になればユーザー確認まで依存作業を止める。

```sh
python3 scripts/local_postgres.py start
python3 scripts/local_postgres.py configure-role
# 初期migrationとscratch DBの準備はLOCAL_MIGRATIONS.mdを参照
.venv/bin/python scripts/local_migrations.py test
swift build --force-resolved-versions
PGPASSWORD_FILE="$PWD/.local/secrets/postgres-app-password" swift test --force-resolved-versions
.venv/bin/python scripts/validate_identity_boundary.py
.venv/bin/python scripts/validate_openapi.py
.venv/bin/python -m unittest discover -s scripts -p 'test_*.py'

# Apple containerのDBへ、hostで認証APIを明示的に起動
SAUNA_LOCAL_AUTH=1 BIND_HOST=127.0.0.1 PORT=8080 \
  PGPASSWORD_FILE="$PWD/.local/secrets/postgres-app-password" \
  swift run --skip-build SaunaAPI
```

既存の8080サービスと同時起動しない。認証有効時はloopback bindのみ許可する。`SAUNA_LOCAL_AUTH`未指定の通常serverは認証DBを接続せず、認証操作に固定503を返す。上記host起動は新しい認証経路のための手順であり、旧Containerfileによる認証経路の検証済み宣言ではない。

Webは各repositoryのBun lockfileを使い、`bun run build`後`bun run start`でそれぞれ5173/5174へloopback bindする。`/auth`をlocalhostで開く。`bun run test:auth`は別設定のPlaywright仮想認証器テストで、実API/DBが必要であり、trace/video/screenshot/HAR/storageStateを保存しない。実行結果は[検証記録](LOCAL_VALIDATION.md)を確認する。

DB設定はsauna_local/sauna_atlas_replayだけを許可し、統合testはreplay DBを選ぶ。test中にmigrationのreplay resetを並行実行しない。追加認証testは一時user/challengeを追跡し、session・credential等を依存順に削除する。強制終了で残ったsynthetic行は次回owned replay resetで除去できる。共有.buildを使うbuild/test/identity境界scriptは並行実行しない。

## 残る制限

全credential喪失時の本人回復、Apple token保存契約、期限切れ行cleanup、Workspace社員確認、認証済sessionからの施設HTTP認可、本番設定、分散rate limitは未実装。staff originで認証できることは社員・施設管理者の認可を意味せず、管理操作は公開していない。Issue9/10/15全体の完了とは扱わない。

ユーザーはローカル仮想認証器の一時鍵とローカルsession token生成を承認済み。実アカウント・実顧客データは使用しない。TablePro/Safari MCPは接続できておらず、実DBはPostgresNIO/psql/Atlas、build/testはSwift CLI、DBはApple containerを用いる。実Safari/iOS Passkeyは未検証。最終依存でのfull tests、ブラウザー結合、Linux/CI、GitHub Codex最新HEADの成否は別々に記録し、未実行・skip・未着を成功扱いしない。
