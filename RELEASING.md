# Releasing json_rest_client

## One-time setup

1. Sign in to pub.dev as an uploader of `json_rest_client`.
2. Open the Admin tab: `https://pub.dev/packages/json_rest_client/admin`.
3. Automated publishing, Enable publishing from GitHub Actions:
   - Repository: `M1chlCZ/json_rest_client`
   - Tag pattern: `v{{version}}`
4. Optional hardening: require the GitHub environment `pub.dev` (the workflow
   already specifies it) and protect `v*` tags.

Automated publishing needs a package that already has a published version.

## Releasing a version

1. Bump `version` in `pubspec.yaml` and add a `CHANGELOG.md` entry.
2. Run `flutter analyze`, `flutter test` and `flutter pub publish --dry-run`
   locally (use the `dart` commands for pure Dart packages).
3. Commit and push to `main`.
4. Create and push an annotated tag:
   `git tag -a vX.Y.Z -m "vX.Y.Z" && git push origin vX.Y.Z`.
5. The publish workflow repeats the checks and uploads through OIDC. Only a
   tag push that matches `v{{version}}` can publish.

Versions published before this automation have no tags in the repository.

## Dependency updates

- Dependabot opens grouped weekly pull requests for pub and GitHub Actions
  updates. Merge them after CI passes.
- Cut a patch release when a runtime dependency changes.

## Notes

- pub.dev cannot unpublish a version; fix forward with a new patch version.
- Retract a bad version within seven days from the Admin tab when needed.
