# ローカル検証 — 2026-11-01 JST

以下は段階ごとの検証履歴である。「未実装」「未依頼」は各段階時点の記録。最新の認証実装と未検証範囲は末尾を参照する。基盤PR42はGitHub Codex最新HEADの指摘なし・CI成功を確認してmerge済み。後続もcodex/ブランチとPRを使用し、本番deploy・課金資源の作成は行わない。

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

## 施設アクセス・challenge追加段階

2施設のSwiftアクセス層とchallenge migrationを追加。host Swift38tests（Server10/Database23/Contract5）を実DBで検証。追加SQL8拒否と既存21拒否、Python26testsも成功。独立Review Agentも38件をskipなしで再実行し成功。外部moduleでのinitializer/Decodable生成拒否を、現行targetをbuildするscriptでも確認した。Security Reviewはdomain error型保持・secret非出力・実DB権限を確認しblocking指摘なし。最終sourceのApple container/Linux arm64 release build/testも成功。38定義のうちDB14件はsecret非渡しでskip、残り24件が成功。skipした14件はhostで実DB接続し成功している。署名/UV検証、session/Workspaceと公開業務HTTPは未実装。

swift-webauthnは隔離した公式beta1で上流38tests、修正済main固定commitで63tests成功。Sauna依存への追加は行わず、評価/未検証範囲はWEBAUTHN_EVALUATION.mdに記録した。

最終imageへのAPI再起動後にhealth/version、利用者/管理者Webからのapi:smoke、両WebのHTTP200を確認。Bunの最初の呼出は子process用PATH未設定で127終了し、workspace-local BunをPATHへ設定して両方を再実行し成功した（ソース変更なし）。

## blindlog-api固定参照の反映

user指定82a13ed73fff44984e8954781d669cf8320883eaのPackage/Sources/lockを確認し、共通の厳格swiftSettingsを自前production6targetsへ適用した。必要なpublic/direct importsを明示し、生成物は編集せず、認証subjectのconstructorはinternalのまま。host swift build/実DB込み38testsは警告なしで成功。独立Reviewも38testsと境界scriptを実行し成功、Security Reviewは厳格設定下の外部生成拒否を別moduleで確認した。Apple container上のLinux arm64 release build/testも成功（24実行成功、秘密を渡さないDB14件skip）。当該DB14件はhostで実接続し成功している。

Dependabotについては2026-11-01のユーザー指示により失敗・通知を対応対象/ブロッカーから除外した。#41はローカル運用記録へ反映し、GitHubのIssue状態や設定は今回変更していない。


## Passkey登録・署名/UV・session追加段階

実装は[LOCAL_IDENTITY.md](LOCAL_IDENTITY.md)を参照する。新規登録と署名付きログインを分け、session digest保存・origin分離・CSRF・失効・DB期限・credential row lockを追加した。OpenAPIの7認証操作をHummingbirdへ接続し、明示的なSAUNA_LOCAL_AUTH=1時だけDB poolをserver lifecycleで起動する。施設の業務HTTPやWorkspace認可の完了は主張しない。

この段階で追加した回帰は次のとおり。テストの存在と最終sourceでの実行結果は区別する。

- 一時P-256鍵による登録/署名成功、UV/UP/RP/origin/challenge/id/userHandle/signature/backup/counter拒否、重複JSON・CBOR framing拒否、callback障害・取消分類。
- 実DBの登録後ログイン必須、credential重複・不正署名・再利用拒否、競合counter更新、session期限・origin・CSRF・失効、有効credentialとの対応。認証schemaの追加SQL拒否12件。
- typed SQLのplaceholder/bind順、Data/UUID変換、攻撃文字列の非埋め込み、locking・認証predicate。
- 実HTTPのOrigin/重複cookie/body上限/fixed error/no-store/rate limitと、flow cookie・未知session拒否。
- operation deadlineによるleased connection取消とpool再接続。共有pool lifetimeを止める診断用timeoutとは別経路として検査する。

独立Reviewは初期WebAuthn実装の9testsをhostで再実行し成功した。この時点の依存は公式main固定版であり、後から指定されたWebAuthn fork・SQL dependencies・SwiftCBOR最終revisionを含むfull testsの代替にはしない。API全体の最終依存/取消修正を含む実DBfull testsは現在実行中で、結果が確定するまで成功件数を転記しない。

SwiftCBORの上流既知問題でWebAuthn CIに巨大allocation crashが再現した。既存[上流PR120](https://github.com/valpackett/SwiftCBOR/pull/120)の最小修正・回帰を原作者と出典を保持してforkへ適用した。coding側のfresh buildと78 XCTest成功に加え、独立Reviewが既存buildで78 XCTestを再実行し0 failures、narrow workflowのactionlintも成功した。この結果はSwiftCBOR package単体であり、API consumerの最終再検証とは別である。

両WebのBFFは固定loopback URL、同一origin、専用cookieだけの転送、共通10秒deadline、128KiB request/response制限、stream cancellation、no-storeを実装した。独立Reviewがcustomer unit51件・staff unit52件を再実行し成功。coding側で両Webのcheck/lint/buildとpublic shell Playwright各6件が成功した。public shell E2Eと実APIを使うPasskey ceremony E2Eは別であり、後者はまだこの記録の成功対象に含めない。

Web基盤PR [customer#10](https://github.com/sauna-studio/sauna-web/pull/10)・[staff#5](https://github.com/sauna-studio/sauna-admin-web/pull/5)、設計履歴[docs#7](https://github.com/sauna-studio/sauna-docs/pull/7)は最新HEADのCodex completed/no findings、全CI成功、未解決threadなしを独立確認してmergeした。これらのCIはAPI認証の実DB/E2E検証を意味しない。

最終API依存でのSwift full tests/identity境界script/生成契約、認証経路のLinux build/runtime、実API+仮想認証器の登録・ログイン・失効、GitHub Actionsと最新HEAD Codexレビューは、それぞれ結果確定後に追記する。現時点で未実行のものをmerge条件充足と見なさない。Safari/iOS・本番RP/origin・社員/施設権限・外部APIは未検証のままである。

### 2026-11-01 ローカル認証の追加検証

API source `0d762cc6d8f54142ea5bd27b5924e67f24bfd4ac`（最終fork依存切替前）で実PostgreSQL18接続のhost Swift65testsが成功した（Server14/Identity23/Database23/Contract5、skipなし）。Security Agentも同じbuildを独立実行し65件成功。query timeout・transaction timeout・Task cancelを伴わないCancellationErrorのいずれも接続を破棄し、DB行の未commitとpool再利用を検証した。初期のstandard transaction helperを使う取消テストは並行実行で停止したため、closed channelへのrollback再投入を避ける実装へ修正した。driver自体のclosed-channel enqueue raceは上流PR487/501を参照して別途最小修正を検証中。

実APIと両Bun production adapter、Chromium resident/UV virtual authenticatorでcustomerの登録→署名login→reload→logout→再login→revoke-all→401、staffのlogin準備・匿名登録404・Workspace未認可を各3回成功確認した。ChromeのCollectedClientDataに未知キーが追加されるroundも、W3C仕様に従う未知キー許容後に成功。元署名byte列・必須field/Origin検証を維持し、対応する署名成功/改ざん拒否のunit regressionを追加した。trace等のcredentialを含み得るartifactは生成しない。

Python28tests、OpenAPI構造/examples、migration3filesの過去改変guard、実DB/schema parityも成功。外部moduleからのidentity生成拒否scriptは依存増加後にcontrol compileで失敗したため原因を調査中であり、このscriptを成功扱いにしない。最新fork依存のresolve/build/test、Linux、GitHub CIと最新Codex合格は引き続き別の最終gateである。GitHub Codex利用上限によるfailed roundは指摘なしと扱わず、対象PRは開いたままにする。

ユーザー指定の全依存catalogue（129lockpins、WebAuthn fork `3825713877df160acfb64181f713f8ab0653cb91` / SwiftCBOR fork `eb8664c774024cfd0599757b3f7d75cdd09ca9cc`）へ切替後も、host Swift65testsは実DB接続・skipなしで成功した。未使用dependencyのSwiftPM警告はユーザーが将来用の宣言を明示要求したため保持しており、自前Swift sourceの警告を許可する設定には変更していない。追加したClang module探索で外部identity境界scriptも実行成功、Pythonは30件へ増えて独立再実行成功。PostgresNIOのdriver修正revisionを採用する場合はその後の検証を別途記録する。

### Consolidated PR128 and native Swift snapshot

最終WebAuthn fork `0d1a4e6408f0a611a98b408ab6a465e40303ac7c`、CBOR0.2.0、修正済NIO5722f49/130pinsでhost実DB67testsが成功した（Server14/Identity25/Database23/Contract5、skipなし）。公開Base64URL goldenとCBOR重複key拒否を追加し、文字変換はSwift標準APIへ統一した。独立Reviewもruntime sourceが同一の40b9b3b graphで67件・subject外部生成拒否scriptを再実行し成功。最終fork自身はminimumSwift6.4、Macとexact-SHA archiveをApple container内へcopyしたLinuxでwarnings-as-errors65tests成功、API breakage gateの限定allowlist positive/negative controlも成功。

最終0d1aを使うhost API+Bun production adapter+Chromium virtual authenticatorでcustomer/staff各3回が成功。登録、署名/UV login、cookie属性とJS不可視、reload、logout、再login、revoke-all完了後401を確認した。秘密鍵・token・credentialのexportやtrace/video/screenshot/HARは生成していない。Safari/実Apple Passkeyは未検証である。

PostgresNIO閉鎖query修正はfork PR1をCodex再レビュー/専用CI成功後にversion branchへmerge済み。source-only上流Draft PR698を提出した。上流mainの既存graceful-close unit flakeは原版でも再現し、全greenとは主張せず本文へ記録。自前forkの実DB367実行成功/上流既定9skipと、上流mainの結果を区別する。

APIのApple-container release検証は4GiB builderが応答しなくなったため中断した。手動で8GiBへ再起動した後もbuild helperが4GiBを指定してVMを再作成していたため、helperの指定を8GiBへ修正し、Containerfileのcompiler jobsを2へ制限した。所有builderだけを再作成した最終検証ではLinux arm64 release build/testとOCI image出力が成功した（67定義中44件実行成功、DB23件はsecret非渡しでskip）。これらのDB23件はhostで実接続し成功している。loopback公開・nonroot・read-only・capability全削除のruntimeでもhealth/version実HTTPとSIGTERM終了を確認した。このsnapshotにはPR43で後から追加したsmoke回帰6件は含まない。

SPMの上流/自前PostgresNIO同一identity警告と予約済み未使用dependenciesはdocs/DEPENDENCIES.md/依存PR43へ記録した。GitHub CI・最新Codex合格もローカル検証とは別gateである。PR43では子processが待受中でもhealth到達確認が15秒で失敗した。原因はSwift6.4.2 FoundationNetworkingがrequest timeoutの0.3秒を整数化してからミリ秒へ変換し、実質約1msのtimerになることだった。共通probeを1秒へ修正し、全体期限15秒と本番コードは維持した。50ms遅延する実HTTP回帰で、Linux上の旧request設定だけを戻す負例が失敗し、復元後に成功することを独立Reviewも確認した。PR43の最終1ec8848はLinux44件×6回成功、GitHub CI全9件成功、最新Codex指摘なしを確認してmerge済み。Passkey本体へこの修正を取り込んだ後の検証結果は別途記録する。

### Passkey rebase onto merged dependency foundation

PR43のmerge commit `b3aaec52aed3e4572f7e5e6b7333e657d9d8b670`へPasskey本体をrebaseした。独立Review/Securityが認証source・既存認証tests・固定lockfileのbyte不変と、共通AGENTS規則・8GiB helper・PR43回帰の保持を確認した。hostの`swift build --force-resolved-versions`と実PostgreSQL18を使う`swift test --force-resolved-versions`は成功（Server20/Identity25/Database23/Contract5、合計73件、skipなし）。Python30件、OpenAPI schema/examples、migration3filesの不変guardと実DB/schema parityも成功した。新HEADのGitHub CIとCodexレビューは別途確認し、旧HEADの合格で代用しない。

### Account-bound Passkey credential management

Issue53 / PR54で、本人の一覧とfresh署名・UVによる追加/失効を実装した。最終runtime source `44c4d1af28aef85b1a032baf652f22c832373b38`ではnative full tests88件（Server21/Identity39/Database23/Contract5）が実PostgreSQL18接続・skipなしで成功。fresh owned replayでAtlas4 migrationsの過去不変guard、初回/反復適用、schema parity、drift拒否とSQL58拒否（従来41+管理17）も成功した。既存local DB/volume/passwordは保持した。隔離worktreeでは既存workspaceのAtlas実binaryを明示してPython31件をskipなしで実行し、OpenAPI/examples検査も成功した。

独立Reviewは最新sourceのPG/crypto24選択testsと、VerifiedSubject生成・JSON decode・管理専用verification entryの外部module拒否を実行成功。public strict verificationの同一arguments positive controlもtypecheck成功し、拒否が別のimport/type不備でないことを確認した。Securityは17 SQL拒否、両DBのapp role権限、rowlock待機中に期限が切れる旧predicateの負例とlocked CTE後clockの正例を独立実行した。

実HTTP回帰で、新しい失効optionsのcredentialIDが旧empty-body validatorに拒否される接続不備を検出し、操作別の狭いbody shapeへ修正した。最新回帰は本人list、schema-valid bodyでのmissing-CSRF拒否、不正CSRF/Originの固定エラー、実署名UVの2段階追加・別key失効と204 cookie削除を通す。管理のPG回帰はcross-user/session/origin/action、認可前skip/2段階replay、認可key/session失効、上限/最後key、相互失効競合、row/unique待機後期限、取消後spend維持、並行loginを検証している。

GitHub CodexのP2指摘により、W3Cの識別済みaccountに対するuserHandle null/省略を管理専用internal entryだけで許容した。返却handleの一致と署名/UV等は維持し、discoverable loginの公開entryは引き続きhandle必須。DB経路で省略、HTTP経路でnull、crypto回帰でempty/wrong/type/base64不正/誤署名/UV無しと匿名loginの拒否を確認した。対応commit・検証結果をreview threadへ返信し、新しいreview roundを依頼している。

最新native API+Bun production BFF+Chromium/CDPの2authenticator検証もcustomer/staff各2caseが成功した。追加後の再login、別keyによる失効、最後key保護と跨profileの全session失効を確認し、鍵/tokenのexportやtrace/video/screenshot/HARは生成していない。Apple-container/Linux releaseと最新HEADのGitHub CI/Codexは[PR54](https://github.com/sauna-studio/sauna-api/pull/54)へsnapshot別の成否を記録し、旧snapshotやDB未設定skipで最新runtimeの合格を代用しない。Safari/実Apple Passkey・全credential喪失の本人回復・Apple保存契約・Workspace/本番設定は未検証/未実装のままであり、Issue13全体は閉じない。

## Recovery denial boundary (2026-11-01)

ユーザーは全喪失回復のfail-closedを維持し、設計・否定テストだけを選択した。RecoveryBoundaryTestsは、本人の有効session/CSRF/正しいnonceに別accountの正当な署名UVを提出しても追加認可できないことを実PGで確認する。foreign署名の暗号positiveと別freshintentのownerpositiveを入れ、単に壊れた入力を拒否しただけのfalsepassを避けた。拒否後もnonceはspend、認可/登録nonceは未設定、唯一key/sessionは不変である。既存helperが追跡するfixtureUUIDだけをcleanupし、DB/volume/サービスをresetしない。

明示swift buildと最新test名でのfull Swift89件（Server21/Identity40/Database23/Contract5、PG接続・skip0）、OpenAPI schema/examples、実Atlas binaryを明示したPython31件/skip0が成功した。Sources/Package/lock/db/schema/migrationsは既存main4eea6f0から変更せず、回復endpointや新secretを追加していない。今回localのLinux release image再buildや既存ブラウザーceremonyの再実行は行わず、production byte不変の確認と最新CIを別gateにする。否定境界は回復機能全体の実装完了を意味しない。ADR0016とIssue56へ設計・実測を関連付け、親Issue13は未提供の回復等を残して扱う。

独立Reviewも最新名のRecoveryBoundaryTestsを同じ実PG条件で1件再実行して成功（0.250秒、skip0）。foreign暗号positiveとfreshownerpositive、spend/未認可/本人key・session保全を確認し、production sourceの追加変更は無い。

## Issue59: ローカル施設HTTPのtenant境界（2026-11-01）

親Issue9のローカルsliceとして、staff origin/sessionと現在のDB membership/roleを用いる一覧・詳細・名称更新を追加した。OpenAPIが正本で生成物は未commit。Workspace社員確認や本番管理API、商品カタログIssue16全体の完成ではない。詳細は[LOCAL_FACILITY_HTTP.md](LOCAL_FACILITY_HTTP.md)、設計はsauna-docs ADR0021。

- `swift build --force-resolved-versions`：Xcode27.2/Swift6.4.2、厳格compiler policyで成功。既存のunused依存とPostgresNIO fork identityのSwiftPM warningは残る。
- `swift test --force-resolved-versions`：Apple containerの既存PostgreSQL18/replay DBへ接続して94件成功（server26、identity40、database23、contract5）。新規5件はlive HTTPで二施設越境・role/失効・CSRF・customer拒否・固定404・strict JSONと、直接session-bound SQLの再照合・blocked update deadlineを含む。
- 新規5件の先行実行で、autocommit UPDATEは10秒timeout後にleaseをcloseしてもrow lock解放後に遅延commitする問題を再現した。既存のscoped transaction helperへ変更し、cancel検査後にだけCOMMITする恒久修正を施した。対象は新規未mergeコードで、Issue59に修正と回帰を集約する。再実行とfull suiteの両方で10秒blocked update後に名称が変わらず、poolを再利用できた。
- OpenAPI3.1/schema/4既存response examples検証成功。Python31件は所有worktreeでは既存Atlas検査1件skip、rootの検証では公式Atlasのdigestを確認した明示pathを使い31件すべて成功。Atlas apply/test/resetは実行していない。
- 独立Review/Securityを実装と並行起動。fixture lifetimeの許容上限、raw driver errorの固定化、session lookupだけでなく各SQLの再検査を検証する回帰が必要という指摘を反映した。最終の独立実行結果、GitHub Actions/Codex最新HEADの結果はPRへ記録する。

テストは既存の所有password fileをアプリ内部で再利用し、秘密値を出力していない。synthetic session fixtureはmodule内部issuerを使うため、この5件単体をPasskey署名ログインの実証とは扱わない。署名/UVは既存identity/management testsで別途検証した。生成したfixture UUIDだけを成功・例外の両経路で依存順に削除し、DB/schema/volumeをresetしていない。既存サービスや不明な行は削除していない。

READ COMMITTEDのstatement snapshotは、失効と進行中更新の全順序化やcommit直前の時刻再検査を保証しない。COMMITと同時のcancel/応答喪失は結果不明となり得る。実Workspace・実Safari/iOS・施設UI・本番設定は未検証。新たな外部認証情報は不要だった。


## Issue8: 隔離したAtlas migration CI（2026-11-01）

既存ローカルDBをresetする手順から、Apple containerの新しいsocket-only PostgreSQL18 clusterを使う検証を分離した。`scripts/migration_ci.py --runtime apple --base 42cb47570f17feca3f1206a29b10b78a1989eb0b`で、公式Atlas1.3.0のhost/Linux arm64 digest照合、trusted Git guard、実Atlas hash/validate後の履歴改変拒否、破壊的DDL拒否、fresh apply/reapply journal同一/schema parity/実drift検出と保持/制限app roleのSQL4suiteが成功した。独立Reviewも別の新しいclusterで同じ実行が成功した。

新規7件の安全性テストを含むPython38件はskipなしで成功（既存Atlas checksum integrationには公式digest確認済みbinary pathを明示）。actionlint、bash構文、gh actions-lock --no-narrow生成と--verifyが成功した。workflow内で同じ完全SHAのcheckoutを追加したため、生成lockfileの依存集合は変化せずbyte同一だった。Swift source/schema/migration SQLは変更しておらず、このCI/helper変更だけのためのローカルSwift full test再実行はしていない。実GitHub Actions/Codex最新HEADの成否はPRへ記録する。

並行Review/Securityで、candidateのatlas.sum symlinkをcanaryへコピーしてhost Atlas hashを実行すると外部fileを書き換え得る問題を発見した。実装を入力の早期検証・O_NOFOLLOW/regular確認・whitelist byte snapshotへ変更し、外部sentinel不変かつAtlas未実行となる回帰を追加した。新規未mergeコード内の恒久修正であり、既存DBに対する回避策は導入していない。container cleanupはIDだけの一覧を読み、自分の正確なUUID名とlabelだけをinspect/deleteする。

既存のsauna_local/sauna_atlas_dev/sauna_atlas_replay、volume、稼働サービス、認証情報には接続・変更していない。新しいpassword/key/token、trust認証、host設定変更は不要。ローカルのDocker CLIは使用せず、CIはGitHub標準job containerを使う。CI job networkはnoneではなく、DBのsocket-only/peer/HBA制限を検証する。Linux amd64実jobとrequired check設定は遠隔CI成功後に確認する。


Issue8の最初の実CIでは、job rootとcheckout workspaceのowner差によりGitが`dubious ownership`で拒否し、Atlas実行前に失敗した。migration step限定の正確なworkspace `safe.directory`をGitの環境command scopeで設定する恒久的なjob設定へ修正した。実Gitの上流test fixtureで所有権拒否を再現し、対象workspaceだけ許可、別repoは拒否、Python `-I`の子Gitへ継承、step環境なしでは再拒否、global/local設定file不変を回帰検証した。hostのowner/global設定変更は行っていない。修正後のPython39件はskipなし、actionlint、公式lockfile再生成/verify、diff検査が成功した。独立Reviewは新しいApple container内の実際にownerが異なる二repoでも同じ許可/拒否を確認した。遠隔の修正後CI成功はPRで別途確認する。

## Issue16: 四区分の商品カタログと利用条件（2026-11-01）

公開catalogはproducts.published=trueと設定済みproduct_offeringsに限定し、staffは現在の施設membership/sessionで公開状態を絞る。条件と公開flagをmanager/ownerだけがCSRF付きで原子的に設定できる。定員・利用分数・泊数のkind-specific条件はSwiftとDBの両方で検証する。価格・実在庫・予約枠・施設営業/閉鎖の正本をこのmetadataから推定しない。詳細は[LOCAL_PRODUCT_CATALOG.md](LOCAL_PRODUCT_CATALOG.md)。

- Xcode27.2/Swift6.4.2で`swift build --force-resolved-versions`成功。新schemaの使い捨てPostgreSQL18/55433に対する最終full Swift101件成功（server31、identity40、database25、contract5）。PG testsはskipなし。private/shared sauna・day/overnight tentの四種類、二施設の同一商品UUID、draft/未設定/欠落、strict query/JSON、role/CSRF、同statementのsession/credential/membership失効、条件/公開の原子性、10秒blocked更新のrollback/pool再利用を含む。
- 独立Reviewは別cache/別の新しいVMで新規7＋既存施設HTTP5の計12定義を実行して成功した。四kindのparameter casesも成功。最終のwire境界テストとGitHubの最新HEAD結果はPRで記録する。
- 公式Atlas Community1.3.0で新しいpeer-only VMから`20261101063651_product_offerings.sql`を生成し、過去SQLを変更せずatlas.sumを更新した。別の新しいVMでtrusted history/破壊的DDL canary、fresh/reapply journal不変、schema一致、drift保持、restricted app接続のSQL5suiteが成功。既存dev/replay DBは使っていない。
- Python50件はskipなしで成功。既存Atlas checksum integrationには固定digest確認済みの公式host binaryを明示した。OpenAPI3.1と4既存response examples、actionlint、公式workflow lockfile provenance verify、diff検査が成功。新しいworkflow依存やpackage更新はない。
- 既存name CHECKがbtrim(name)だけを200文字に制限し、raw nameは201文字以上になり得る点を検出した。新catalog projectionはwire長とnonblankを検査し、無効な構成を固定503で拒否する。自分のsynthetic rowを200文字＋spaceにした実HTTP回帰で、一覧/詳細が不正なwireや内部値を返さないことを確認した。既存データや過去制約を変更していない。
- 新tableを既存forward apply helperの明示DML grantに追加し、正本schemaとのgrant対象一致とCREATE/TRUNCATEを付与しない回帰を追加した。helperを既存DBへ実行したという意味ではない。

新しいlocal_integration_db.pyは承認済みのlocal app password fileだけを同じlocal DB用途で再利用し、新しい秘密値を生成しない。rootが並行Review/Securityで、schema先頭のpsql meta-commandがOS命令になり得る問題を実行前に指摘し、credentialアクセス前のDDL AST allowlistと固定SQL prefixを追加した。秘密値なしの新VMでmeta-command拒否と外部marker不変を確認した。helperは既存55432/DB/volume/serviceへ接続せず、新しい所有UUID/labelのVMをfinally cleanupし、private copyはready後に削除する。fixtureも生成した正確なIDだけを依存順にcleanupする。

公開値は商品・条件の投影だけ。Workspace社員確認、実Safari/iOS、カタログUI、本番公開、価格、在庫、営業カレンダーは未検証。COMMIT時のcancel/応答喪失やREAD COMMITTEDの進行中statementの同時失効について、完全な直列化や絶対的未変更を主張しない。新規外部API key・鍵・課金resource・本番デプロイは不要だった。

## Issue17: 物理在庫と競合制約（2026-11-01）

施設内のphysical resource、四kindの商品対応、割り当て/解放ledgerとtyped staff serviceを追加した。private/shared saunaとday/overnight tentが同じ実体を共有でき、GiST exclusionが時間とseatの重複をDBで拒否する。HTTP/UI、公開空き状況、顧客予約/hold、料金、実設備の設定は含まない。詳細は[LOCAL_INVENTORY.md](LOCAL_INVENTORY.md)、sauna-docs ADR0024。

- Xcode27.2/Swift6.4.2で実build成功。最終の新しいApple container/PostgreSQL18によるfull Swift112定義がskipなしで成功した（server32/10.571秒、identity40/3.238秒、database35/21.071秒、contract5/0.001秒）。既存のunused dependency/fork identity警告は残る。
- Inventoryの新規10定義には有限timestamp/Int64変換前の境界とmicrosecond非空検査4件、resource設定/施設role/CSRF、四kindの同実体競合・隣接時刻・capacity・解放、12並行service要求、直接SQLの並行INSERT/exclusion待機を含む。SQL側の待機backendを実際に観測してから相手transactionをcommitし、待機側が正確なexclusion constraint/23P01で拒否されることを確認した。
- resource行lock待機中のbackendを観測した後、session失効・期限切れ・credential失効・membership失効・role降格・disabled変更の6条件で割り当てが拒否され、ledgerが増えないことを確認した。allocation/release両方の10秒deadlineでactive/total ledgerと既存claimが不変で、pool再利用に成功した。COMMITと同時のcancel/応答喪失まで未変更と保証するものではない。
- 公式Atlas Community1.3.0を用いる新しいpeer-only VMでforward migrationを生成した。最終の別VMでtrusted base `c968dbfe5105ebe2b79b593ded6c774390fb82ae`から過去SQL不変・rehash攻撃/破壊的DDL拒否・fresh/reapply journal不変・schema parity・drift保持・restricted-role SQL6suiteが成功した。exclusion constraintそのものを除去したdriftも検出し、検証による自動修復がないことを確認してから所有cluster内だけで復元した。
- 閉じた拡張manifestを秘密値アクセス前に検査し、固定SQLだけで新しいclusterへbtree_gist1.8を導入した。欠落/別version/namespace/owner/CREATE権限/危険なrole membershipを拒否する実DB canary、およびappによるschema/拡張CREATE・ALTER・DROPの拒否が成功した。Atlas CEが拡張lifecycleを管理するとは扱わず、Issue64を参照する。
- Python53件は公式Atlas checksum検査を含めskipなし。actionlint、bash構文、diff、公式workflow lockfile生成/verifyも成功し、workflow/lockfileはbyte不変。既存55432/live DB、volume、サービスにはschema適用/reset/拡張導入を行っていない。承認済みpassword fileを同じlocal DB用途で新VMへ限定して再利用し、新しい秘密値は生成していない。
- 独立Review/Securityを実装と並行起動した。Int64 bindのint4range overloadを明示castで固定し、実shared割り当てで検証した。lock到達前の失効だけで偽合格にならない待機観測、直接DB競合、deadline後のtotal ledgerとreleasedAtまで検査する回帰を追加した。Atlasのname CHECK表現のfalse-positive diffは等価なcanonical表現を保持し、Issue66で追跡する。過去migration編集やdiff抑制で隠していない。

実施設の運用値、Cloud SQLの拡張導入、本番権限、Workspace所属、Apple実端末、inventory HTTP/UIは未検証。GitHub Actions/Codexの最新HEADと独立再実行・最終SHAのreview結果はPRに記録する。
