# Swift WebAuthn local evaluation — 2026-11-01 JST

This is an isolated evaluation, not an added Sauna API dependency or a production security certification. No main Sauna source/dependency changes, remote writes, forks or upstream PRs were made.

## Provenance and reproducibility

- Repository: https://github.com/brokenhandsio/swift-webauthn
- License: Apache-2.0, verified LICENSE and source headers.
- Swift tools: manifest6.0, tested Apple Swift6.4.2 on arm64 macOS27.2.
- Beta: tag1.0.0-beta.1, commit909cf4193cde7d64196553c4245ab647a68aaaca.
- Current main: exact commit030acd1eedaa835958ae3fcc0e491bec03b2abf1, 2026-10-07, merged PR129.
- Clone/worktrees: sibling directories swift-webauthn-1.0.0-beta.1 and swift-webauthn-main-030acd1 under the workspace .tools/probes directory. Sauna .build was not used.
- Commands: beta `swift test --jobs 2`; main `swift package resolve` then `swift test --jobs 2 --force-resolved-versions`.
- Package.resolved is upstream-ignored but retained locally for each probe.

## Compatibility and result

Beta resolves swift-crypto4.5.2, SwiftCBOR0.6.0, swift-log1.16.2 and swift-asn1 1.7.3. Beta upstream test suite succeeded: 38 test definitions in6suites, including parameterized cases; build/test command exit0. No compiler warnings/errors were found in the captured log.

The beta manifest restricts Crypto to3.8.1..<5 and therefore excludes Sauna's current5.0.3. Main's merged PR129 already expands the range to..<6. This is an existing upstream fix, so a duplicate manifest fork/PR is unnecessary. Main resolution selects Crypto5.0.3. Exact-main upstream tests also succeeded:63 test definitions in7suites, including parameterized cases; build/test command exit0. No compiler warnings/errors were found in the captured main log. Main was tested unmodified, with its resolved dependency lock held fixed; no downgrade or local source patch was used.

Beta→main is not just a dependency change: main also adds AuthenticatorSelection/ResidentKeyRequirement and registration options APIs, mutable challenge integration, and FoundationEssentials imports. README still shows the earlier swift-server URL/alpha.2 example; integration should follow exact-revision source APIs rather than copying that version blindly.

## Security/application boundary

The library supplies WebAuthn registration/authentication options, CBOR/COSE parsing, origin/challenge/ceremony checks, RP hash, UP/optional UV, signature and signCount checks. It returns public credential material and authentication metadata.

The application must provide durable expiring one-use challenge storage/consumption, credential uniqueness and user ownership, userHandle mapping, atomic counter/backup-state policy and persistence, rate limiting, session issuance/revocation, additional-credential reauthentication and recovery. Default requireUserVerification is false, so Sauna must explicitly require UV and test it. Explicit modern algorithm policy is needed; the default supported enum includes legacyRS1. Attestation roots and formats are a separate deployment decision.

In the inspected beta/main source, CollectedClientData models type/challenge/origin; crossOrigin/topOrigin validation was not found. Cross-origin embedding policy requires a separate pre-integration check and tests. This is an observed evaluation gap, not a confirmed public vulnerability claim.

No user credential or real customer data was used. Upstream public test fixtures and ephemeral test-generated cryptographic material are not production credentials; private values were not displayed or copied into the report. The upstream Package/Sources/Tests safety review found no build plugin target execution or process/network/credential-access side effects in test source; a docc plugin package is declared as a dependency but not attached to build targets.

Browser virtual-authenticator integration, real Safari/iOS Passkeys, Linux/Apple-container build of this library, counter policy for synced credentials and a full integration security review remain unverified. A released version compatible with current dependencies is preferable; an unreleased exact SHA needs an ADR and explicit update/exit criteria before adoption.

## 2026-11-01 上流PR128とswift-cborの採用

最新ユーザー指示に従い、[swift-webauthn PR128](https://github.com/brokenhandsio/swift-webauthn/pull/128/)（head `3fe310ab82b4c7dc5429ca3dbcc1308b3ff8abbb`）を採用する。必要な独自修正はこのcommitを祖先に持つ自前fork branch `codex/pr128-compat`へ重ね、以前のadd-init/Crypto互換PRは採用しない。現行APIでは追加のpublic Credential initializerを使わないため、その変更は持ち込まない。

PR128は[brokenhandsio/swift-cbor](https://github.com/brokenhandsio/swift-cbor)へ移行済みで、APIの直接利用もproduct `CBOR`へ統一する。安定tag0.2.0（`52432a1118bcbabb9a973330c3af85d8ddf3f015`）を採用する。入力全体を消費する`CBOR.decode`に`maximumDepth:16`と`rejectDuplicateMapKeys:true`を明示する。既存の入力長・構造制限を維持し、以前のdecoder用custom input streamは削除する。

SwiftCBOR forkの既知PR120修正は以前のWebAuthn依存に対する検証履歴として保持するが、新APIの依存グラフには残さない。以前の65tests/実ブラウザー成功は旧依存段階の結果であり、PR128採用後にbuild・実DB・署名/UV・ブラウザーを再検証する。上流PRの採用を上流mainへのmerge済みと表現しない。

Final compatibility branch requires Swift6.4 (the Sauna compiler baseline). Runtime string transformations use native literal collection replacing/append, with no added Foundation import for those transformations. Test-only JSONSerialization imports its defining Foundation module explicitly. The strict main API comparison stays enabled with122exact diagnostics attributable to upstreamPR128; removing one allowed diagnostic makes the negative control fail. Old compiler compatibility shims are deliberately omitted.
