# ローカル施設HTTPの認証・施設境界

Issue [#59](https://github.com/sauna-studio/sauna-api/issues/59) は親 [#9](https://github.com/sauna-studio/sauna-api/issues/9) のローカルHTTP slice。Atlasの本番受入やWorkspace社員確認が完了したという意味ではない。設計はsauna-docs ADR0021。

## 契約と利用範囲

`SAUNA_LOCAL_AUTH=1` のloopback APIでのみDB接続を有効にする。既定serverはDBを持たず固定503。`Origin: http://localhost:5174` とstaff profile session cookieを要求する。customer originは403、customer sessionをstaff cookie名へ移してもorigin照合で401。ログインだけではmembershipを作成せず、APIからmembership/roleを付与する経路はない。DB fixtureだけを用いるローカル開発境界であり、Workspace所属確認・実社員のprovisioning・本番管理者APIの代用ではない。

- `GET /staff/facilities/{facilityID}/products?limit=100`：現在のowner/manager/staffに最大100件のID/name投影。認可済み空施設は200と空配列。
- `GET /staff/facilities/{facilityID}/products/{productID}`：同じ閲覧roleで施設と商品の複合IDを照合。
- `PATCH /staff/facilities/{facilityID}/products/{productID}`：owner/managerだけが`{"name":"..."}`で名称を更新。session由来HMAC CSRFを必須にし、duplicate/escaped duplicate/未知JSON keyを拒否する。

施設IDは対象選択であり権限の証拠ではない。各SQLはactive membership/role/facilityを同時検査し、session hash/user/exact origin/DB時刻の有効期限/失効/credential ownerと失効も同statementで再照合する。セッションからだけVerifiedSubjectを生成し、外部入力userIDから生成しない。期限やroleをstore構築時の値へ固定しない。

未認証は401、施設・商品が欠落または閲覧/更新不可の場合は同一の固定404。構文・入力不正は400、固定Origin違反は403、DB利用不可は503。エラーにSQL、driver、cookie、tokenを含めず、成功・失敗ともno-store。名前はtrim後1〜200 Unicode scalar、NUL不可。販売区分/時間/定員/在庫/価格/予約の公開カタログは別Issue16以降。

## 並行処理の意味

SessionStoreのpackage限定callbackが10秒deadlineの中でpool leaseとtransactionを所有し、session照合と施設操作を実行し、cancel検査後にCOMMITする。autocommit UPDATEは切断後にrow lockが解放されると遅延commitし得るため、この経路には使わない。timeout/cancellationはこのleaseだけをcloseし、その完了を待ってpoolへ返す。共有poolを止めない。

READ COMMITTED statement snapshotが境界。失効が次のstatement開始前にcommitされれば拒否する。進行中statementと別transactionのsession/membership失効を大域的に直列化していない。特にUPDATEが商品row lockを待つ間に失効・期限到達した場合、既に評価した認可predicateをcommit直前に再検査する保証はない。COMMIT前に10秒deadlineを超えたblocked操作はleaseを破棄し、lock解放後の遅延commitを許さない。COMMITと同時のcancelや応答喪失は通常の結果不明の境界を持ち、503があらゆる場合の未変更を保証するわけではない。本番業務で強い直列化が必要なら、別Issueでlock順序/再検査を設計する。

## 検証とデータ保護

`FacilityHTTPTests`は二施設の同一商品ID、別施設だけの商品、空施設、owner/manager/staff、非member、降格/失効、customer origin/session、CSRF、入力制約、固定404、no-storeを実HTTP/PostgreSQLで検証する。内部issuerを使うsynthetic session fixtureであり、このtest単体を暗号署名ログインの証明としない。既存AuthenticationStore/PasskeyManagement testsが署名/UVログインを検証する。

直接構築したsession-bound storeへの後続失効で、list/detail/updateすべての同statement guardを検証する。10秒blocked updateのtimeout、遅延commitなし、pool再利用も検証する。fixtureは生成した正確なUUIDだけを依存順にsuccess/error cleanupし、DB/schema/volumeのresetを行わない。

実行結果はLOCAL_VALIDATION.mdへ記録する。新しい秘密鍵・外部API keyは不要。実Workspace所属確認、実Safari/iOS、BFFやnative clientの施設UI、production設定は未検証。
