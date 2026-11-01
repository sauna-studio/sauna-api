# 商品カタログと利用条件

[Issue16](https://github.com/sauna-studio/sauna-api/issues/16)の対象は、貸切/共用サウナと日帰り/宿泊テントの販売区分・公開一覧/詳細・設定された利用条件。予約枠、実在庫、施設の営業・閉鎖、価格見積もり、決済は含まない。fixtureにある定員・時間・泊数はテスト用で、実施設の運用方針や既定値ではない。

## 正本と整合性

既存`products.published`だけを商品の公開状態の正本とする。`product_offerings`は施設/商品に一対一で、kind・定員・最小/最大利用分数・最小/最大泊数を保持する。既存商品の条件を推測してbackfillせず、新tableは空から始める。publishedがtrueでも条件未設定の商品は公開しない。

productsの(facility_id,id,kind)にunique constraintを追加し、offeringの同じ三要素から複合FKで参照する。kindを単にコピーすると宿泊条件と商品区分がずれるため、offeringがある商品のkind変更はDBが拒否する。kindの変更・商品の作成/価格設定は今回のAPIに含めない。

定員と利用分数は正のPostgreSQL integer、最大利用分数は最小以上。宿泊テントの泊数は正で最大が最小以上、他三種類は両方0。最大2147483647はDB表現の技術的上限であり、施設の販売上限ではない。定員は在庫台数・同時販売可能数ではない。利用分数と泊数は独立した設定範囲で、泊数×24時間、check-in/out、DSTや営業枠の判定を実装したとは扱わない。

## HTTP

OpenAPIが正本。公開projectionは施設/商品ID、名前、区分、published、定員・利用分数・泊数だけを返す。価格/通貨は将来の見積もり契約まで含めず、bigint金額をJavaScript numberに暗黙変換しない。

- `GET /facilities/{facilityID}/products?kind=private_sauna&limit=100`
- `GET /facilities/{facilityID}/products/{productID}`

公開readは認証不要で、各SQLにpublished=trueと条件tableのjoinを固定する。draft、条件未設定、別施設にしかない商品、欠落した商品のdetailは同じ固定404。対象施設に公開可能な商品がない場合、施設の存在に関わらず一覧は200と空配列。施設名/所属/セッション情報を公開しない。施設自体のactive/休業/閉鎖フラグは現在のschemaに存在せず、このAPIが施設の営業可否を保証することはない。

公開queryはkind/limitだけを許可し、publication/published/userID等の未知key、重複/escaped重複key、空値、範囲外limitを拒否する。公開bodyは空に限定し、cookieやOriginを権限根拠にしない。この二つのoperation IDだけが認証middlewareの明示的なpublic分岐を通り、staff/auth routeの条件を緩めない。success/errorともno-store、cookieを発行しない。rate limitはローカルprocess内であり、本番の分散制御ではない。

- `GET /staff/facilities/{facilityID}/offerings?publication=draft&kind=day_tent&limit=100`
- `GET /staff/facilities/{facilityID}/products/{productID}/offering`
- `PUT /staff/facilities/{facilityID}/products/{productID}/offering`

staff readは現在のowner/manager/staffだけにdraft/published filterを提供する。PUTは現在のowner/managerと有効staff session、厳密なOrigin、CSRFを要求する。bodyにはkind、capacity、minimum/maximumDurationMinutes、minimum/maximumNights、publishedをすべて指定する。kindは現在の商品rowと一致することを要求し、clientから変更できない。未知・重複JSON keyを拒否する。

PUTは認可済みproductをlockし、条件upsertと既存published flagの更新を一つのSQL/transactionで行う。不正条件・区分不一致・権限不足で公開状態だけを変更しない。各statementに施設membership/roleとsession/credentialの現在性を含める。10秒deadlineは所有leaseだけをcloseし、COMMIT前のcancelで条件・公開状態の両方をrollbackする。READ COMMITTEDの進行中statementと同時失効は大域的に直列化せず、COMMIT時のcancel/応答喪失は結果不明となり得る。

## ローカル検証

既存DBのschemaが古いままSwift PG testを実行しない。`scripts/local_integration_db.py`で新しい使い捨てVM/loopback55433へ正本schemaを適用し、既存の承認済みlocal app password fileだけを同じlocal DB用途で再利用する。helperが既存55432や既存DB/volumeを変更しないことを確認する。新しい秘密値は不要。

```sh
.venv/bin/python scripts/local_integration_db.py --filter 'ProductCatalogHTTPTests|ProductConditionsTests'
.venv/bin/python scripts/local_integration_db.py
migration_base=$(git rev-parse refs/remotes/origin/main)
.venv/bin/python scripts/migration_ci.py --runtime apple --base "$migration_base"
```

migrationは公式Atlas1.3.0で新しいpeer-only VMから生成した。過去SQLは不変。独立migration replayでは新migration、二度目のapply、schema一致、drift保持、kind/FK/条件拒否を確認する。Swift fixtureは生成した正確なUUIDだけをcleanupし、無関係な行を削除しない。実行結果はLOCAL_VALIDATION.md/PRに記録する。Workspace所属確認、本番公開、Web/nativeのカタログUIは未検証。
