# ローカルAtlas migration

## 現在の利用状態（2026-11-01）

`sauna_atlas_replay`は現在ローカルAPI/Webの利用中DBであり、使い捨てではない。`scripts/local_migrations.py test`はそのpublic schemaをresetするため、現在のDBでは実行しない。所有markerが一致しても利用中データを破棄する許可にはならない。fixtureの掃除は自分が作成した正確なIDを照合して個別に行い、schema/DB/volumeをresetしない。

以下のscratch準備・reset手順と実行結果は初期段階の履歴であり、現在の実行許可や最新CIの証明ではない。migrationの受入条件はIssue8で別途追跡する。新規の使い捨て検証環境が必要なら利用中の固定名へ流用せず、隔離と所有の設計を先に行う。

対象: [Issue8 / B04](https://github.com/sauna-studio/sauna-api/issues/8)と[Issue9 / B05](https://github.com/sauna-studio/sauna-api/issues/9)のDB部分。Issue6/7のローカルHTTP/接続pool実装に続く作業であり、未push・未mergeの積み重ねである。

## 現在の隔離検証・CI

通常の検証は新しい使い捨てclusterで行う。ローカルはApple `container`だけを使い、既存のPostgreSQLやcredential fileへ接続しない。

```sh
# origin/main等のレビュー済み履歴から、実在する完全SHAを明示する。
migration_base=$(git rev-parse refs/remotes/origin/main)
.venv/bin/python scripts/migration_ci.py --runtime apple --base "$migration_base"
```

入力はtrackedなschema.sql/migration SQL/atlas.sum/SQL tests/replay scriptだけを先に検証し、symlink・非regular・未追跡入力を拒否してbyte snapshotへ固定する。private fileや.gitはstageしない。candidateのatlas.sum symlinkがhost側のAtlas hashで外部fileを書き換えないよう、canary作成前にこの検査を行う。

trusted baseのguard moduleをGitから取り出して実行し、既存migration SQLのbyte不変性と限定したadditive DDLを検査する。実際にAtlas hash/validateし直した履歴改変も拒否し、破壊的DDL canaryも拒否する。過去policyを同じPRで緩めて新SQLを承認する方式は採らない。policy拡張は先行する独立PRでレビューする。workflow自体の改変へ耐える保証とは区別し、通常のレビュー・必須checkを維持する。

公式PostgreSQL18 imageをdigest固定し、OS postgresとして新しい一時clusterだけをinitdbする。local peer/kernel identityを使い、明示pg_identでpostgresから一時sauna_admin/app roleへ対応させる。両DB roleはNOSUPERUSER/NOCREATEDB/NOCREATEROLE/NOREPLICATION/NOBYPASSRLS。これはSQL権限分離の検証であり、同一OS userを別のOS境界に分ける方式ではない。Unix socketは0700、TCP listenは空、host HBAはreject、password/trust認証や新しい秘密値は使わない。

ローカルはnetwork none、host portなし、read-only rootfs、一時tmpfs、public inputのread-only mountだけを使う。UUID名/所有labelを確認して自分のcontainerだけをcleanupする。GitHub Actionsは標準のjob containerを使い、job network自体をnoneにしているとは主張しない。DBは同じsocket-only制限を使い、postgres実行環境からGitHub/PG/Atlasの継承環境を除外する。公式Atlas Community1.3.0はOS/arch別の固定SHA256を照合してから実行する。

検証内容は空DBへのapply、二度目のrevision journal byte同一、schema.sqlとの差分なし、実driftの検出とcolumn保持、明示したcanary除去後の差分なし、制限された実app接続による4つのSQL suite。fixtureはROLLBACKされる。正本・既存migrationは変更しない。ローカルでCIのLinux amd64 job全体を実行したとは扱わず、その結果はPRの実CIで確認する。

CIのtrusted baseはPR base SHA、push before SHA（新規branchのall-zeroだけfetched origin/main）、manual実行の必須base_shaから選ぶ。完全SHA・commit存在・HEADのancestor・過去migrationの存在を検証し、HEAD自身への暗黙fallbackは設けない。manual入力もレビュー済みmain履歴のSHAを指定する。

## 初期段階の正本と手順（履歴）

`db/schema.sql`を正本とし、Atlas Communityで`db/migrations`のforward-only SQLと`atlas.sum`を生成する。生成後の過去SQLを編集せず、修正はschema更新と新しいmigrationで行う。既存開発DBやvolumeをresetしない。

```sh
.venv/bin/python -m pip install -r scripts/requirements.txt
# schema.sql編集後のみ、新migrationを生成
.venv/bin/python scripts/local_migrations.py generate --name describe_change
# trusted baseは既存migrationが入ったcommit。CI導入時はPR base SHAを指定する
.venv/bin/python scripts/local_migrations.py guard --base HEAD
# 初期の使い捨て環境だけの破壊的検証。現在のreplay DBでは実行禁止。
# .venv/bin/python scripts/local_migrations.py test
# review後、ローカル開発DBだけへforward apply
.venv/bin/python scripts/local_migrations.py apply
.venv/bin/python scripts/local_migrations.py verify
```

Atlas Community1.3.0は公式versioned binaryと公開SHA256を照合し、ワークスペースの`.tools/atlas/atlas`へ配置した。シェルprofileやシステムPATHは変更していない。helperも実行前に同digestを検査する。別platformへの導入は公式binaryとchecksumを確認してhelperの固定値をレビューする。

- 配布: https://release.ariga.io/atlas/atlas-community-darwin-arm64-v1.3.0
- SHA256: `4e5ffdc10b2b4fd3a06074aba72848150907d5316cacad7b19bae6c6ae3db991`
- 公式導入・機能差: https://atlasgo.io/community-edition

## DB・秘密情報・保護範囲

承認済みadmin passwordをprivate一時HCL（directory0700/file0600）に読み込み、完了時に削除する。URL/secretをargv・environment・diagnosticsへ出さない。接続先は固定loopbackのみ。別のAPIキーや鍵は生成しない。

`sauna_local`は永続開発DB。`sauna_atlas_dev`と`sauna_atlas_replay`は専用scratch DBで、作成者ownerとDB commentを照合する。Atlas dev処理はdev DBを変更し、testはowned replayのpublic schemaだけをresetする。名前が一致しても所有marker不一致なら停止する。業務テストのsynthetic fixtureはreplay内でROLLBACKする。

migration ownerはadmin。appは業務6tablesおよびchallenge状態tableへのSELECT/INSERT/UPDATE/DELETEとschema USAGEのみ。schema CREATE、TRUNCATE、table ownership、admin membership、revision table権限は与えない。これはDDL権限分離であり、全行の施設別閲覧認可ではない。

## schemaの保証と未実装

施設、global user identity、施設membership、商品、予約、予約明細を定義。施設内entityは複合PK、明細参照はfacility_idを含む複合FKとし、越境参照を拒否する。金額は通貨とminor integer、予約明細は価格/商品名snapshotを保持する。数量・種別・status・有限の利用期間を制約で検証する。

認証済みsessionからのtenant context、RLS/API認可、Workspace社員確認、価格合計/通貨の業務整合、在庫hold・競合制御、決済状態遷移は未実装。商品と予約の通貨・価格一致は後続の見積もりtransactionで検証する。time_zoneのIANA実在検証も後続であり、現在は空白と長さの検査のみ。

## 検証とforward fix

- Atlas checksum/SQL replay、適用済DBとschema.sqlの`schema diff`で一致を確認する。Atlas自身のrevision tableだけ比較から除外する。
- Git trusted baseのSQL byte比較で過去改変/削除とbackdated新規fileを拒否する。atlas.sumの再生成だけではこの比較を迂回できない。
- pglast8.7のPostgreSQL ASTでDDLをparseし、CREATE TABLE/INDEXとALTER TABLE ADD CONSTRAINTだけを許可する保守的guardを実装した。他操作は個別の方針レビューまで停止する。全てのlock/データ移行の安全性を保証するlintではない。
- 実scratch DBへ余分columnを追加するとdrift検証が失敗し、columnが残ることを確認する。修復はtestが明示的に実施し、一致回復を確認する。
- 制約/越境/DDL権限のSQLテストは実app接続で業務21件とchallenge8件の拒否を検証する。

driftやmigration失敗時に自動down/resetは行わない。適用履歴とDB状態を確認し、backupと復旧方針を検討した上で新規forward fixを作成・review・再検証する。今回のhelperに本番操作やbackup自動化は含めない。

Atlas CEにProのmigrate lint/managed drift機能は含まれないため、利用したとは記録しない。上記はCEのschema diffと独立guard/testを組み合わせたローカル検証。GitHub workflowへの接続・リモートCIとrequired checkは未実施で、Issue8のCI受入およびIssue9全体は未完了である。

## 外部ライブラリ

Atlas CommunityはApache2.0。pglast8.7はGPL3以降の開発検証用Python依存としてpinし、API/Webの実行binaryへ組み込まない。PostgreSQL parserを使い、SQLを正規表現だけで判定しない。公式releaseをそのまま利用しており、forkは不要だった。

## 独立レビュー結果

独立Review Agentがfresh replay/reapply、schema一致、実drift拒否とcolumn残存、app接続の21拒否SQLを再実行し成功。guardのAST拒否ケースとPythonテストも再実行した。Security Review Agentはmain/replay両DBの6業務tableとrevision tableのadmin所有、appのDML許可/CREATE・TRUNCATE不可/revision閲覧不可/admin membershipなしをreadonly SQLで確認し、helperのtemp config・所有DB保護・secret非出力をレビューした。未解決blocking指摘なし。GitHub Codexレビュー・遠隔CIは今回未依頼であり、このローカルレビューで代替済みとは扱わない。
