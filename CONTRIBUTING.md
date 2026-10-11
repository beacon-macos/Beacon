# Contributing to Beacon

Thank you for helping improve Beacon. Bug reports, feature suggestions, documentation updates, tests, and code changes are welcome.

## Before you start

- Search the [existing issues](https://github.com/dhkey/Beacon/issues) before opening a new one.
- For a bug, include your macOS version, Beacon version, steps to reproduce it, and the behavior you expected.
- For a substantial feature or behavior change, open an issue first so the approach can be discussed before implementation.

## Development requirements

- macOS 26.0 or later
- Xcode 26 or later
- Git

Beacon has no third-party dependencies. Clone the repository and open `Beacon.xcodeproj` in Xcode:

```sh
git clone https://github.com/dhkey/Beacon.git
cd Beacon
open Beacon.xcodeproj
```

Select the **Beacon** scheme and run the project, or build it from the command line:

```sh
xcodebuild -project Beacon.xcodeproj -scheme Beacon -configuration Debug build
```

## Making a change

1. Fork the repository and create a focused branch from `master`:

   ```sh
   git switch master
   git pull --ff-only origin master
   git switch -c fix/short-description
   ```

2. Make the smallest complete change that solves the problem.
3. Follow the existing Swift and SwiftUI style in the surrounding code.
4. Add or update tests when behavior changes.
5. Avoid committing build products, local Xcode user data, or unrelated formatting changes.

## Branch and commit naming

Use a short, lowercase, kebab-case branch name prefixed with the commit type the work belongs to:

- `feat/global-shortcut-presets`
- `fix/search-selection-reset`
- `docs/release-instructions`
- `refactor/application-indexing`
- `test/fuzzy-matching`
- `chore/update-workflow`

Write commit messages in the [Conventional Commits](https://www.conventionalcommits.org/) format:

```text
type(optional-scope): short imperative summary
```

Use one of these commit types:

- `feat`: a user-facing feature
- `fix`: a bug fix
- `docs`: documentation only
- `refactor`: an internal change without new behavior or a bug fix
- `test`: adding or correcting tests
- `perf`: a performance improvement
- `style`: formatting that does not change behavior
- `build`: build system or dependency changes
- `ci`: continuous-integration changes
- `chore`: repository maintenance not covered above

Use the scope to name the area of Beacon that changed. Prefer one of the established scopes:

- `launcher`: the floating panel, its presentation, and dismissal
- `search`: indexing, normalization, matching, and ranking
- `favorites`: favorite selection, ordering, and persistence
- `shortcuts`: the global shortcut and keyboard navigation
- `settings`: the settings window and stored preferences
- `theme`: appearance and styling
- `assets`: icons and asset catalog contents
- `extensions`: the extension runtime, installation, and the extensions page
- `release`: packaging and release workflow

Omit the scope when a change is genuinely repository-wide, and add a new scope only when no existing one fits.

Examples:

```text
feat(shortcuts): add preset key combinations
fix(search): reset selection after updating results
docs: explain how to create a release
ci: remove checksum artifacts
```

Keep the summary concise, start it with a lowercase imperative verb, and do not end it with a period. Keep commits focused on one logical change; avoid messages such as `update`, `changes`, `fix stuff`, or `WIP` in the final pull request history.

Use the commit body to explain why a non-obvious change is needed. Reference related issues with `Refs #123` or close them with `Closes #123`. Mark an incompatible change with a `BREAKING CHANGE:` footer.

## Testing

Run the test suite before opening a pull request:

```sh
xcodebuild test \
  -project Beacon.xcodeproj \
  -scheme Beacon \
  -destination 'platform=macOS'
```

For user-interface changes, also verify the relevant behavior manually, including keyboard navigation and the global shortcut when applicable.

## Pull requests

### Title

Title every pull request in the same Conventional Commits format used for commits, including the scope whenever the change belongs to one area:

```text
type(scope): short imperative summary
```

```text
feat(settings): add theme setting with light and dark appearances
fix(favorites): open the selected favorite instead of the first result
refactor(search): extract application discovery from LauncherModel
docs: document the pull request title convention
```

The title is the squash-merge commit message, so it must stand on its own in the `master` history. Its type also decides the next release when the pull request is merged: `feat` publishes a minor release, `fix` and `perf` publish a patch release, `type!:` publishes a major release, and other types do not publish a release. Keep it under roughly 72 characters, start the summary with a lowercase imperative verb, and do not end it with a period. Do not prefix the title with an issue number, a branch name, or `WIP`; mark work in progress by opening the pull request as a draft instead.

### Description

- Explain what changed and why.
- Link any related issue.
- Include screenshots or a short recording for visible interface changes.
- Keep each pull request focused on one concern.
- Confirm that the project builds and tests pass locally.

GitHub Actions builds and tests every pull request targeting `master`. Merging a pull request into `master` publishes a release automatically when its title calls for one; contributors do not need to create release tags.
