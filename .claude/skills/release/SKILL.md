---
name: release
description: Release workspace by analyzing changes, bumping the version, tagging, and pushing
argument-hint: [patch|minor|major|<version>]
---

# Release Workspace

Analyze changes since the last release, suggest a version bump, and release.

## Usage

```
/release
/release patch
/release minor
/release major
/release <version>
```

## Instructions

When the user invokes this skill:

### Prerequisites

1. **Verify on main branch** - if not, inform the user and stop
2. **Verify no uncommitted changes** to tracked files - untracked files are fine

### If an argument is provided (patch, minor, major, or explicit version):

Skip change analysis and use the specified version directly:

1. **Get the current version** from `lib/workspace/version.rb`
2. **Calculate the new version** based on the bump type (or use the explicit version)
3. **Update documentation** — Run `/readme update` to sync subcommand docs and the README.md table with any changes since the last release. Commit doc changes separately if any: `Update subcommand documentation`
4. **Update the version** in `lib/workspace/version.rb`
5. **Commit** with message: `Bump version to <version>`
6. **Create tag** `v<version>`
7. **Check if tag exists** - if the tag already exists, inform the user and stop
8. **Push the commit and tag** to origin

### If NO argument is provided:

1. **Get the current version** from `lib/workspace/version.rb`
2. **Find the last tag** matching `v*`
3. **Analyze changes since last tag**:
   - Run `git log <last-tag>..HEAD --oneline` to see commits
   - Run `git diff <last-tag>..HEAD -- lib/ bin/` to see what changed
   - If no previous tag exists, this is the initial release
4. **Suggest version bump** based on changes:
   - **Patch** (x.y.Z): Internal changes only - refactoring, bug fixes, documentation, code cleanup
   - **Minor** (x.Y.0): New features added - new subcommands, new flags, new functionality
   - **Major** (X.0.0): Breaking changes - removed subcommands, changed default behavior, renamed flags, modified output format
5. **Show analysis to user**:
   - Display the current version
   - Summarize the changes since last tag
   - Show your recommended bump type with reasoning
   - Let the user confirm or choose a different version
6. **Update documentation** — Run `/readme update` to sync subcommand docs and the README.md table with any changes since the last release. Commit doc changes separately if any: `Update subcommand documentation`
7. **Update the version** in `lib/workspace/version.rb` to the chosen version
8. **Commit** with message: `Bump version to <version>`
9. **Create tag** `v<version>`
10. **Push the commit and tag** to origin

## Version File

The version is stored in `lib/workspace/version.rb`:

```ruby
module Workspace
  VERSION = "0.1.0"
end
```

Update only the version string when bumping.

## Example

```
/release
```

This will:
- Read `lib/workspace/version.rb` to get "0.1.0"
- Find the last tag `v0.1.0`
- Run `git log v0.1.0..HEAD --oneline` to see commits
- Run `git diff v0.1.0..HEAD -- lib/ bin/` to analyze changes
- Suggest a version bump:
  - "I see 3 commits with bug fixes and refactoring. No new subcommands or breaking changes. I recommend a **patch** bump to 0.1.1."
  - Or: "I see a new `start` subcommand was added. This is a new feature, so I recommend a **minor** bump to 0.2.0."
  - Or: "I see the state file format changed. This breaks backward compatibility, so I recommend a **major** bump to 1.0.0."
- Let the user confirm or choose differently
- Update `lib/workspace/version.rb`
- Commit, tag `v<new-version>`, push

### With explicit bump type

```
/release minor
```

This will skip analysis and directly bump 0.1.0 → 0.2.0, commit, tag, and push.

## Change Analysis Guidelines

When analyzing the diff, look for these patterns:

### Patch (bug fixes, internal changes)
- Fixed typos or documentation
- Refactored code without changing behavior
- Fixed bugs that made the tool not work as documented
- Performance improvements
- Code cleanup

### Minor (new features, backward compatible)
- New subcommands added
- New command-line flags or options
- New template placeholders
- New functionality that doesn't affect existing behavior

### Major (breaking changes)
- Removed subcommands or flags
- Changed default behavior
- Renamed subcommands or flags
- Changed state file format
- Changed config file naming conventions
- Changed exit codes
- Removed features

## Error Handling

- If not on main branch, inform the user and stop
- If the tag already exists, inform the user (this version has already been released)
- If there are uncommitted tracked changes, inform the user and stop

## No Previous Tag

If this is the first release (no previous tag exists):

1. Inform the user this is the initial release
2. Skip change analysis (nothing to compare against)
3. Use the current version as the release version
4. Proceed with tag creation and push
