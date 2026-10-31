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

APIのApple-container release検証は4GiB builderが応答しなくなったため中断し、所有build client1件を確認してbuilderだけを8GiBへ再起動した。Containerfileはcompiler jobs2へ制限し、最終sourceのrelease build/testを再実行中である。現時点でLinux API完了とは扱わない。SPMの上流/自前PostgresNIO同一identity警告と予約済み未使用dependenciesはdocs/DEPENDENCIES.md/依存PR43へ記録した。GitHub CI・最新Codex合格もローカル検証とは別gateである。
