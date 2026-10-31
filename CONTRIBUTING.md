# Contributing

最初に [AGENTS.md](AGENTS.md) を読みます。Issueと依存関係を確認し、`codex/<topic>`ブランチで実装してください。`main`へ直接pushしません。

- 重複Issueを検索し、受け入れ条件・依存関係・対象リポジトリを記録します。
- 実装中に独立Review Agentを並行起動します。認証・決済・予約競合・個人情報・施設権限はSecurity Review Agentも起動します。
- 動作するビルド・テストとGitHub Actionsの結果をPRに記録します。未実行・利用不能なMCPも明記します。
- バグ修正には再現と回帰テストを含め、指摘修正後に再レビューします。
- 設計判断はADR、索引はWiki、反復する教訓はAGENTS.mdに反映します。

Reusable Workflowsの更新はすべての呼出先に自動適用されません。呼出しはコミットSHAに固定し、検証後に追従PRを作成してください。

このリポジトリではREADMEのコマンドと`actionlint`を実行します。Issue Formのラベルを使う場合は対象リポジトリで先に作成してください。CODEOWNERS・AGENTS.md・workflowはOrganization共通設定だけでは継承されません。
