# ローカル実行

Swift6.4.2 / Python3.11以上 / Apple container1.5.0を使用する。Docker Engine/Desktop/CLI/Composeは使わない。公開OCI imageはdigest固定。Containerfile.localのSwift imageはローカル用であり、本番最適化済みimageとは扱わない。

## API

```sh
container system start
python3 scripts/local_container.py build
python3 scripts/local_container.py start
python3 scripts/local_container.py smoke
python3 scripts/local_container.py status
# 必要時だけ、自分のlabelのcontainerを停止/削除 (volumeは対象外)
python3 scripts/local_container.py stop
python3 scripts/local_container.py remove
```

APIは127.0.0.1:8080に限定。別portはstart/smoke双方へ --port 18080 等を指定する。runtimeはnonroot10001、read-only rootfs、tmpfs、cap-drop ALL。既存の同名containerは勝手に置換しない。build contextはContainerfile/Package/lock/Sources/Testsだけを一時directoryへcopyし、.local/.env/.git/host credentialを渡さない。

## PostgreSQL18

このセッションではユーザーがlocal-only DB password生成を承認済み。別目的の鍵・API credential生成は含まない。値をチャットに送らず、既存ファイルを表示/上書きしない。

```sh
# 初回のみ。生成前にgitignoreとprivate permissionsを検査する
python3 scripts/local_postgres.py setup
python3 scripts/local_postgres.py start
python3 scripts/local_postgres.py configure-role
python3 scripts/local_postgres.py status
swift build --force-resolved-versions
PGPASSWORD_FILE="$PWD/.local/secrets/postgres-app-password" swift run --skip-build SaunaDBCheck
```

DBは127.0.0.1:55432、database sauna_local、app role sauna_app。admin/app credentialを別ファイルに分離し、directory0700/file0600、Git除外する。Postgres18のvolumeは/var/lib/postgresql、容量2G。host/localともSCRAM。再起動時はowned container/volumeを保持し、roleの権限を検証し、passwordはresetしない。停止はlocal_postgres.py stop、再開はstart→configure-role→診断の順に実行する。volume/secretの自動削除は実装しない。

DB pool/診断はlocal-loopback専用。remote接続・Cloud SQL TLS・認証/HTTP業務認可はまだ実装していない。schema/Atlasは[ローカルmigration](LOCAL_MIGRATIONS.md)を参照する。/healthはlivenessでありDB障害状態を返さない。

Linux APIとPostgreSQL 18の実接続は、検証用の同一Apple container VM内で確認できます。事前にこのリポジトリの `Containerfile.local` からAPIイメージをローカルでビルドし、Pythonの依存関係と承認済みのローカルDBパスワードを用意します。

```sh
.venv/bin/python scripts/local_linux_api_db.py --api-image sauna-api:local
```

この検証ではAPIからループバックで一時PostgreSQLへ接続し、登録オプションHTTPレスポンスに対応する行をDB側で確認します。

HTTPトレースは `SAUNA_LOCAL_OTLP_HOST` を指定した場合のみ、OTLP/HTTPの `4318/v1/traces` に送信します。APIは生成済みのOpenAPI operation IDとHTTPステータスを記録します。検証でCollectorを併用する場合は、専用の `container network create --internal` ネットワークに信頼できるCollectorを配置し、上の検証コマンドに `--network <名前> --collector-ip <CollectorのIPv4>` を追加します。このローカル経路は平文HTTPです。

Collectorの検証設定例を一時ディレクトリの `otel.yaml` に保存します。

```yaml
receivers:
  otlp:
    protocols:
      http:
        endpoint: 0.0.0.0:4318
exporters:
  debug:
    verbosity: detailed
service:
  pipelines:
    traces:
      receivers: [otlp]
      exporters: [debug]
```

```sh
collector_name="sauna-otel-test-$(uuidgen | tr '[:upper:]' '[:lower:]')"
container network create --internal "$collector_name"
container run -d --name "$collector_name" --network "$collector_name" --no-dns \
  --read-only --cap-drop ALL \
  --mount "type=bind,source=$OTEL_CONFIG_DIR,target=/probe,readonly" \
  docker.io/otel/opentelemetry-collector:0.165.0 --config=/probe/otel.yaml
container ls
# COLLECTOR_IP に上で表示された Collector の IPv4 を設定する。
.venv/bin/python scripts/local_linux_api_db.py --api-image sauna-api:local \
  --network "$collector_name" --collector-ip "$COLLECTOR_IP"
container logs "$collector_name"
container delete --force "$collector_name"
container network delete "$collector_name"
```

`OTEL_CONFIG_DIR` には `otel.yaml` のある一時ディレクトリの絶対パスを指定します。秘密情報を含まないこのディレクトリと設定ファイルには、CollectorのUID 10001がアクセスできるよう、それぞれ0755と0644を設定します。Collectorの出力で `service.name=sauna-api`、`getHealth`、`beginPasskeyRegistration` のスパンとHTTPステータスを確認します。

## 検証

```sh
swift build --force-resolved-versions
PGPASSWORD_FILE="$PWD/.local/secrets/postgres-app-password" swift test --force-resolved-versions
.venv/bin/python scripts/validate_openapi.py
.venv/bin/python -m unittest discover -s scripts -p 'test_*.py'
```

ContainerfileのLinuxテスト工程にはDBパスワードを渡さないため、実DBが必要なテストはホストで実行します。Linux APIの実行時の接続は、上記の同一VMスモークで別途検証します。

## 施設境界の次の設計

業務entityはfacility_idを明示し、施設内entity参照は(facility_id,id)の複合unique/FKで越境を防ぐ。user identityは施設membershipと分離する。UUIDは識別子であり認可の代替にしない。複合PK/FKのDB制約とappのDDL権限分離はローカル実装・検証済み。Swift施設アクセス層は[ローカル認証基盤](LOCAL_IDENTITY.md)を参照する。認証済sessionによるHTTP施設認可は後続Issueで実装する。

## 社員資格の定期再確認

社員確認の対象として登録された施設・ユーザーの組だけをDBキューで扱います。ワーカーは1件ずつ取得し、5秒間隔で次の照会を行います。照会不能なら5分後、適格なら1時間後に再確認します。非適格が確定した場合は、取得した紐付け・施設ロール・リースが現在も有効であることを確認し、施設ロールの失効と監査行を同じ更新で保存します。同時更新で行がロックされている場合はリースの期限後に再確認します。PostgreSQLの行バージョンは短いリース中の変更検知に使います。他施設のロールと利用者セッションは維持します。監査に保存するのはSauna側の施設・ユーザーID、照会ID、失効時刻です。監査表の閲覧・更新権限と保持方針は [Issue #36](https://github.com/sauna-studio/sauna-api/issues/36) で扱います。

現行の起動設定はワーカーを登録しません。合成検証器を渡すSwift統合テストで、ワーカーから実PostgreSQLを経由し、失効後に対象施設のHTTPアクセスが拒否されることを確認できます。

```sh
.venv/bin/python scripts/local_integration_db.py --filter WorkspaceEmployment
```

実Workspaceとの紐付け、対象登録、運用時の起動設定は [Issue #4](https://github.com/sauna-studio/sauna-api/issues/4) と [Issue #14](https://github.com/sauna-studio/sauna-api/issues/14) で扱います。
