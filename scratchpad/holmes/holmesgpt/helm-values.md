You can use `helm get values` to extract the values from a deployed release:

```bash
# Get user-supplied values only (what was explicitly set during install/upgrade)
helm get values <release-name> -n <namespace>

# Get all values (including defaults from the chart)
helm get values <release-name> -n <namespace> --all

# Output to a file for editing
helm get values <release-name> -n <namespace> --all -o yaml > values.yaml
```

Then you can modify the `values.yaml` and redeploy:

```bash
helm upgrade <release-name> <chart> -n <namespace> -f values.yaml
```

A few useful variations:

```bash
# See what revision you're on
helm history <release-name> -n <namespace>

# Get values from a specific revision
helm get values <release-name> -n <namespace> --revision <number>

# Dry-run to preview changes before applying
helm upgrade <release-name> <chart> -n <namespace> -f values.yaml --dry-run
```

If you just want to see what would change without extracting everything, `helm diff` (if you have the plugin) is handy:

```bash
helm diff upgrade <release-name> <chart> -n <namespace> -f new-values.yaml
```