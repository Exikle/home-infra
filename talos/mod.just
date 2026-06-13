set quiet
set shell := ['bash', '-euo', 'pipefail', '-c']

[private]
default:
    just -l talos
