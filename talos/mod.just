set quiet
set shell := ['bash', '-euo', 'pipefail', '-c']

[private]
default:
    just -l talos

[private]
[doc('Get schematic ID from factory.talos.dev for the current schematic')]
schematic-id:
    curl -sX POST --data-binary @"{{ source_dir() }}/schematic.yaml" "https://factory.talos.dev/schematics" | jq -r '.id'

[doc('Upgrade Talos on the Frostlink node to current schematic + version')]
upgrade version:
    talosctl --context frostlink \
        -n "$(talosctl --context frostlink config info -o yaml | yq -e '.endpoints[0]')" \
        upgrade \
        --image "factory.talos.dev/installer/$(just talos schematic-id):{{ version }}" \
        --reboot-mode powercycle \
        --timeout 10m
