# Personal Sure maintenance

This branch preserves the installed personal features on top of an official stable Sure release. Docker remains the runtime. Source setup does not deploy, migrate, reset financial records, read live configuration, change credentials or reconnect providers.

## Branches and commits

- `origin` is the owner's existing fork. Its existing `main` and older fix branch are preserved.
- `codex/upstream-stable` is an untouched mirror of the selected stable release; it contains no custom commits.
- `codex/personal` carries separate commits for desktop Plaid consent/partial-sync handling, budget inclusion preferences, and personal Reviewed controls.
- `codex/upgrade-<version>` is a temporary upgrade branch for a selected stable tag. Review and test it before merging into `codex/personal`.
- `upstream` points to `we-promise/sure`. Local pushes to this remote are disabled; publishing goes to `origin` only.

`upstream.json` records the exact upstream commit, immutable multi-platform image digest and hashes of all runtime overrides. The first baseline is `v0.7.6-hotfix.1`, commit `4b549c6e72c98d76352cd0645bca585e012ce424`. Existing migrations retain their original identifiers so current installations do not rerun them.

Keep feature changes small. Drop a local workaround when a stable upstream release supplies an equivalent fix, after checking its behavior against the regression tests. Proposing upstream contributions is separate from maintaining this fork.

## Verify and build

```sh
python3 personal/fetch_base.py
python3 personal/build.py --check
python3 personal/upgrade.py --check v0.7.6-hotfix.1
python3 personal/verify.py
python3 personal/verify.py --full
python3 personal/build.py --image sure-personal:0.7.6-hotfix.1-custom.1
```

The custom suite covers review permissions, invalidation through bulk rules/import SQL, unchanged-sync preservation, budget/split/default treatment, provider partial failures and consent payloads. It uses fictional credentials and uniquely named disposable PostgreSQL/Redis containers. Test execution has networking disabled, no production config and no live volume mounts. The full command additionally builds locked developer dependencies and runs `bin/rails test` against a separate fictional database. Dependency downloads happen during the build only. Ordinary unit/integration tests replay upstream cassettes; no provider access is required.

The test runner cleans up only its own disposable containers and socket volume, leaving logs under ignored `personal/local/`. Full test images may remain as a local build cache. The focused runtime suite uses PostgreSQL 16, matching the current deployment; the full suite uses PostgreSQL 17 to match its developer image's dump/restore client. Four full-suite workers use a disposable SQL schema snapshot so the PostgreSQL review triggers survive test-database cloning; this changes no live application configuration or source schema. The full suite can include upstream skips; record them rather than counting them as passed. Run both commands before pushing, and all upstream pre-PR checks in `docs/llm-guides/development.md` before opening any upstream PR.

The personal GitHub workflow runs custom/full regressions on personal-branch pushes and pull requests. It has read-only repository permissions, no secrets, no schedule and no publishing/deployment step. The inherited release pipeline is gated to the official upstream repository; its dependent publishing/deployment jobs cannot run in this fork. Do not push `main` or `v*` tags or invoke other upstream publishing workflows as part of ordinary personal maintenance. Personal release labels should use a `personal-` prefix.

The image build exports only the manifest's Ruby/ERB runtime files into a temporary build context. It never copies the checkout's `.env`, credentials, uploads, dumps or logs. Asset/dependency/library changes are deliberately rejected until the build approach is reviewed; do not silently reuse precompiled assets after changing JavaScript/CSS/dependencies. For those changes, use the upstream full-source Docker build and validate it separately.

## Stable-release upgrade procedure

1. Start with a clean `codex/personal` checkout. Fetch upstream metadata without pushing to upstream. Choose an official published stable release; avoid `main`, `latest`, alpha and beta tags.
2. Run `python3 personal/upgrade.py vX.Y.Z` (or a `vX.Y.Z-hotfix.N` tag). It verifies published stable status, newer version and shared upstream history, creates an upgrade branch and merges the exact tag. Hotfix backports need not be direct ancestors of the next minor release. It will leave conflicts visible for resolution. It never deploys or pushes.
3. Review upstream changes against each personal feature, especially provider consent, pending/posted handling, authorization, categories, budget calculations, review invalidation and migration identifiers. Resolve conflicts without dropping protections or saved-data compatibility.
4. Update `personal/upstream.json` with the tag/commit, the official immutable multi-platform image digest, and SHA-256 hashes of the remaining runtime changes relative to that tag. Verify the image revision label matches the selected commit. Commit the reviewed changes before the full test export.
5. Run custom and full Rails tests, the applicable upstream checks, and fictional browser checks. Restore a fresh private backup into an isolated environment to rehearse any pending migrations and compare existing records before/after.
6. Merge the tested upgrade into `codex/personal`; advance `codex/upstream-stable` to the exact upstream tag with a normal fast-forward. Keep the deployment decision explicit. Build a versioned custom image and record its digest; never replace it with an unmodified `stable`/`latest` image.
7. For an authorized deployment, back up the complete database, uploads and private runtime config; preserve encryption/session keys, provider Items/tokens, mapping and cursors. Replace web/worker images only. Verify health and preservation before resuming ordinary worker scheduling. Do not force a provider refresh just to validate a code deployment.

Keep the previous image and backup. Prefer a code-only rollback when schema compatibility permits; never overwrite newer financial activity with an old database dump as routine rollback. A clean financial restart is a separate operation with its own reviewed scope.

## Source and private runtime separation

The source fork contains application code, public upstream history, fictional tests and maintenance instructions only. Keep `.env*` secrets, encryption keys, tokens, personal connection payloads, database dumps, statements/receipts and deployment backups outside Git. Do not add secrets to Actions or copy live volumes into a test environment. Tests do not establish that a bank is currently healthy or reconciled; they establish the bounded code behavior.
