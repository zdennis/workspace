# workspace dir

Print the root directory of a workspace project.

## Usage

```sh
workspace dir <project>
```

## Details

Outputs the full path to a workspace project's root directory as defined in its tmuxinator config file. Useful for scripting and integration with other tools that need to know where a project is located.

Paths are expanded (tilde `~` is resolved to the user's home directory).

## Examples

```sh
# Get the root directory of a project
$ workspace dir work-notes
/Users/zdennis/Documents/Obsidian-LocalOnly/Zendesk

$ workspace dir growth-engine
/Users/zdennis/Code/zendesk/growth-engine

# Use the output in a script
$ cd $(workspace dir myproject)

# Error when project doesn't exist
$ workspace dir unknown
Error: Project 'unknown' not found or has no root directory configured
```
