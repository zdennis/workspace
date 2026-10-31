# workspace whereis

Print the workspace installation directory.

## Usage

```sh
workspace whereis
```

## Details

Outputs the directory where workspace is installed. Useful for debugging symlinked installs or finding template files.

## Examples

```sh
# Find out where a symlinked install really lives
$ workspace whereis
/Users/zdennis/source/opensource/workspace

# Look at the project templates it ships
$ workspace whereis | xargs -I{} ls {}/lib/templates

# Which commit this install runs
$ workspace whereis | xargs -I{} git -C {} log -1 --oneline
```
