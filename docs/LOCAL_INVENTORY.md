# ローカル在庫・物理リソース基盤

Issue #17 / sauna-docs ADR0024。商品条件のparty capacityと物理在庫は別である。`inventory_resources`を施設内の実体とし、複数商品を同じresourceへ対応付ける。実施設の設備数・定員は未設定であり、テスト値は合成fixtureのみ。

## 保証と境界

- `inventory_product_resources`は施設・商品kind・resource kindを複合FK/CHECKで固定する。private/shared saunaはsauna実体、day/overnight tentはtent実体に対応する。
- 有効claimは有限の半開区間 `[starts_at,ends_at)` を使用する。shared saunaは0起点の単一seat `[i,i+1)`、private saunaとテントは全seatを表す非有界rangeを占有する。隣接時刻は競合しない。
- PostgreSQLのGiST exclusionが施設UUID・resource UUID・時間・seatの重複を拒否する。貸切商品と共用商品でも同じ実体なら競合する。resource capacityはcatalog capacityから推測しない。
- capacity/typeは複合FKにより参照中の変更を拒否する。解放済み履歴も参照を保持するため、過去claimがあるresourceのcapacity変更には将来の明示的な移行設計が必要となる。
- resourceは既定でdisabled。typed `InventoryService`はstaff RPの有効session・CSRF・施設owner/managerを変更時に検査する。staffは参照のみ。resource行をlock後、新しいSQL statementでsession・credential・membership・enabledを再検査して割り当てる。
- disabledへの変更は既存claimを取り消さない。解放はdisabledでも可能。serviceに解放済みclaimを復活させるAPIはなく、再解放も拒否する。直接DB更新全般を不変にするledger triggerは設けていない。

Swiftの時間入力はPostgreSQL 18 timestamp範囲と、利用中のPostgresNIOが符号付き64bitのmicrosecondへ変換する方式に合わせて検証する。非有限・範囲外・microsecond量子化後に空になる区間はDBへ送らない。

操作は既存の10秒上限のsession transactionで実行し、commit前のcancel確認により待機中deadlineの書き込みをrollbackする。COMMITと同時のキャンセルや応答喪失は通常の結果不明問題として残る。認可がCOMMITと直列化する保証ではない。

HTTP/UI、公開空き状況、利用者予約、hold期限、複数商品holdの原子性、予約確定、料金、運営上の枠設定は今回の範囲外。Workspace所属確認の完了も意味しない。

## PostgreSQL拡張の前提

`db/postgresql-prerequisites.json`は`btree_gist` version `1.8`、schema `extensions`、owner `postgres`だけを認める閉じたmanifestである。Atlas Communityのpublic schema管理と拡張の管理を分ける。固定bootstrap SQLと独立metadata/権限検査を両方の使い捨てDB harnessで実行し、qualified operator class `extensions.gist_uuid_ops`を使用する。

Atlas CEが拡張lifecycleを管理・修復するとは扱わない。実環境のインストール・更新・Cloud SQL対応は別途検証し、追跡Issue [#64](https://github.com/sauna-studio/sauna-api/issues/64)が解消するまではこの境界を維持する。今回、既存DBへの拡張導入や課金リソース作成は行わない。

名称CHECKの`BETWEEN`と外側のANDをAtlas CEが異なる表現として再検出するため、正本は生成SQLと等価な括弧付き比較の形を保持する。検出・削除条件は追跡Issue [#66](https://github.com/sauna-studio/sauna-api/issues/66)に記録し、schema diffを抑制したりmigration履歴を編集したりしない。

## 検証

通常のSwift PG検証は`python scripts/local_integration_db.py --filter Inventory`で新しいApple containerの使い捨てDBへ行う。既存55432/live replayへschema適用・reset・新fixture投入を行わない。migration検証は`python scripts/migration_ci.py --runtime apple --base <trusted-full-SHA>`を使用する。

実行結果は`docs/LOCAL_VALIDATION.md`に記録する。直接SQLの否定検証は`db/tests/006_inventory.sql`、Swiftの境界・service・競合検証は`InventoryIntervalTests`と`InventoryStoreTests`に配置する。
