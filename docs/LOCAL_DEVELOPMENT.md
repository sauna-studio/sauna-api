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

## 検証

```sh
swift build --force-resolved-versions
PGPASSWORD_FILE="$PWD/.local/secrets/postgres-app-password" swift test --force-resolved-versions
.venv/bin/python scripts/validate_openapi.py
.venv/bin/python -m unittest discover -s scripts -p 'test_*.py'
```

未設定PGPASSWORD_FILEでintegrationがskipされた場合はDB検証済みと扱わない。ContainerfileのLinux testsにはprivate secretを渡さないため、DB実接続ケースはhostで別途検証する。

## 施設境界の次の設計

業務entityはfacility_idを明示し、施設内entity参照は(facility_id,id)の複合unique/FKで越境を防ぐ。user identityは施設membershipと分離する。UUIDは識別子であり認可の代替にしない。複合PK/FKのDB制約とappのDDL権限分離はローカル実装・検証済み。Swift施設アクセス層は[ローカル認証基盤](LOCAL_IDENTITY.md)を参照する。認証済sessionによるHTTP施設認可は後続Issueで実装する。
