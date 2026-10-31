# workspace version

Print the workspace version.

## Usage

```sh
workspace version
workspace --version
workspace -v
```

## Examples

```sh
# Which release is installed
$ workspace --version
workspace X.Y.Z

# Only the number, to compare in a script
$ workspace version | cut -d' ' -f2
X.Y.Z

# Add the version to a bug report
$ workspace version >> bug-report.txt
```
