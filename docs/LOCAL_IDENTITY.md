# ローカル施設アクセス・Passkey challenge基盤

## 実装範囲

Issue9のDB境界に続き、`SaunaAPIIdentity.VerifiedSubject`と`FacilityStore`を追加した。VerifiedSubjectは外部moduleから生成/JSON decodeできず、testsだけが@testable fixtureを作る。認証を実装したproducerはまだないため、これらを使う業務HTTP endpointは公開していない。

FacilityStoreはproduct一覧・詳細・名称更新を扱い、要求facility_id、subject user_id、有効membership、許可roleを各SQL内で再検査する。staffは閲覧、manager/ownerは更新。権限不足と不存在は同じ固定エラーを返す。施設/roleをcontextへキャッシュせず、失効や降格は反映後の次のREAD COMMITTED statementで拒否する。実行中statementと失効処理の厳密な直列化は保証しない。

`LocalDatabase.withClient`はpool lifetimeの終了/取消を処理し、closed enumで固定文だけを持つFacilityStoreError/PasskeyChallengeErrorを保持する。任意driver/caller errorを公開せず、その他は固定DB unavailableへ写像する。

## Challenge lifecycle

Issue10の準備として、PostgreSQLの`webauthn_challenges`と`PasskeyChallengeStore`を実装した。これは署名検証やログインではない。

- CSPRNGで32-byte公開nonceと独立した32-byte browser-flow bindingを生成する。
- bindingはcanonical base64url。DBにはSwift Crypto5.0.3によるSHA-256 digestのみ保存する。表示はredactedとし、raw値をログへ渡さない。
- RPはlocalhost、originはcustomer=http://localhost:5173 / staff=http://localhost:5174の固定値。127.0.0.1のWeb閲覧とは区別し、将来のWebAuthn操作にはlocalhostを使う。production RP/originは別途設定・検証する。
- purpose、RP/origin、binding digest、未消費状態、DB時刻での期限を同一statementで検査してconsumeする。
- 消費時はrow lock取得後に依存CTEでclock_timestamp()を一度取得する。transaction開始時刻やlock前の時刻で期限切れを通さない。
- TTLは1msから5分まで。consume済みchallengeを署名検証失敗時に戻さない。

ユーザーはこの段階のローカル仮想認証器鍵とローカル専用token生成を許可した。Sauna本体で実際に生成したのはメモリ上の公開nonceとbrowser-flow bindingのみで、ログインsessionや本番用鍵は生成していない。DB credentialは承認済みファイルを再利用した。

## 再現と検証

```sh
# migration適用とscratch DB準備はLOCAL_MIGRATIONS.mdを参照
.venv/bin/python scripts/local_migrations.py test
PGPASSWORD_FILE="$PWD/.local/secrets/postgres-app-password" swift test --force-resolved-versions
.venv/bin/python scripts/validate_identity_boundary.py
```

LocalDatabaseConfigurationが受け付けるdatabase名はsauna_local/sauna_atlas_replayだけ。remote DBや任意databaseへ切り替える設定は受け付けない。Challenge integration testsは自動で専用replay DBを選ぶため、並行してmigration testのreplay resetを実行しない。

施設fixtureはtransaction内に固定しROLLBACK後0件を確認する。challengeの大半もROLLBACK。並行消費/lock待機testだけはreplay DBへ一時nonce行をcommitし、終了/エラー時に当該UUIDだけ削除する。プロセス強制終了で残ったsynthetic行は次回owned replayのresetで除去できる。

実DBで二施設同productID、越境read/write拒否、一般利用者/失効member/staff更新拒否、role降格、入力境界、SQL bound parameterを確認した。challengeは誤binding/purpose/origin/RP、期限切れ、再利用、16並行consumeで1成功、row lock待機で期限超過の拒否を検証した。DB shape/期限のSQL拒否は追加8件、既存業務schema21件と合わせ29件。

## 次の実装前提

Passkey登録/署名/UV検証、credential/userHandleとuserの一意な対応、追加credentialの再認証済user/session binding、ログインsession、CSRF/cookie、rate limit、期限切れ行cleanup、Workspace社員確認は未実装。challenge consumeだけでVerifiedSubjectを発行しない。raw SQL app roleは全施設行のDML権限を持つため、未認証userIDや任意facilityIDをtrusted subjectへ変換しない。

Issue8のremote CI接続、Issue9全体、Issue10のWebAuthn ceremony統合、Issue15のWorkspaceを含むstaff認可は未完了。GitHub Codexレビュー/Actionsは今回未依頼。手動ローカルレビューでそれらの条件を代替しない。

外部WebAuthn libraryは[隔離評価記録](WEBAUTHN_EVALUATION.md)を参照。betaで38、修正済main固定SHAで63の上流testsを実行し成功した。Saunaの依存にはまだ追加しておらず、Swift Crypto5対応は本家PR129に既存修正があるため重複forkは作らなかった。

TablePro/Safari MCPはこの環境で接続できていないため、実DBはPostgresNIO/psql/Atlas CLI、build/testはSwift CLIとApple containerを利用した。ブラウザー仮想認証器・Safari/iOSのPasskey ceremonyは未実行。隔離した上流testsの一時暗号materialと、Sauna本体の未実装credential/sessionを区別する。

validate_identity_boundary.pyは現在のidentity targetをbuildしてから外部moduleのpublic参照controlとinitializer/Decodable生成拒否を検査する。import失敗や古いmoduleだけの検証を成功扱いしない。compiler生診断は表示しない。

境界検証scriptも共有.buildを更新するため、他AgentのSwift build/testとは時間を調整し同時実行しない。Linux buildは別のApple container内scratchで実行する。
