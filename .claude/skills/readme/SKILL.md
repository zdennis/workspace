---
name: readme
description: Create and update subcommand documentation in docs/ and the README.md subcommands table
argument-hint: [create|update] [subcommand-name]
---

# README Skill

Create and update subcommand documentation for the workspace CLI.

## Usage

```
/readme create [subcommand-name]
/readme update [subcommand-name]
```

If `subcommand-name` is omitted, operates on all subcommands.

## Commands

### create

Creates missing documentation:

1. **docs/README.\<subcommand\>.md** — For each subcommand missing a README, create one using the template below
2. **README.md subcommands table** — Add any new subcommands to the table

### update

Updates existing documentation:

1. **Check for changes** — Compare current CLI code against existing docs
2. **Update docs** — Re-analyze the subcommand and update its README
3. **Update README.md** — Sync the subcommands table (add/remove/update entries)

## Subcommand Discovery

Subcommands are defined in `lib/workspace/cli.rb`:

1. Read the `case subcommand` block in `CLI#run` to find all subcommands
2. Read each `cmd_<name>` method for its OptionParser to get usage, options, and description
3. Read the corresponding command object in `lib/workspace/commands/` if one exists

## Subcommand README Template (docs/README.\<subcommand\>.md)

```markdown
# workspace <subcommand>

<1-2 sentence description of what the subcommand does>

## Usage

\`\`\`sh
workspace <subcommand> [options] [args]
\`\`\`

## Options

<If the subcommand has options, list them in a table:>

| Option | Description |
|--------|-------------|
| `--flag` | What it does |

<If no options, omit this section>

## Details

<Explain behavior, what it does, edge cases, important notes>

## Examples

\`\`\`sh
<Practical usage examples>
\`\`\`
```

## README.md Subcommands Table

The subcommands table in `README.md` should look like:

```markdown
### Subcommands

| Subcommand | Docs | Description |
|------------|------|-------------|
| name | [README](docs/README.name.md) | Short description |
```

## Instructions for Claude

### When running `create`:

1. **Find all subcommands** from `CLI#run` case statement in `lib/workspace/cli.rb`
2. **Check which are missing** `docs/README.<subcommand>.md`
3. **For each missing subcommand:**
   - Read the `cmd_<name>` method for OptionParser details
   - Read the command object in `lib/workspace/commands/<name>.rb` if it exists
   - Create `docs/README.<subcommand>.md` using the template
4. **Update the README.md subcommands table** with any new entries

### When running `update`:

1. **For each subcommand to update:**
   - Read the current `docs/README.<subcommand>.md`
   - Read the current `cmd_<name>` method and command object
   - Compare and update the README if anything changed (new options, changed behavior, etc.)
2. **Sync the README.md subcommands table:**
   - Add entries for new subcommands
   - Remove entries for deleted subcommands
   - Update descriptions if they changed
3. **If a specific subcommand was requested**, only process that one

### Important notes:

- Use `docs/` directory for subcommand READMEs
- Filenames must match subcommand names exactly (e.g., `README.list-projects.md`)
- Keep descriptions concise
- Omit optional sections (Options, Details) if not applicable
- The `version` subcommand is handled inline in `CLI#run`, not via a command method — still document it
