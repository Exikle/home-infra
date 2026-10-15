set no-exit-message
set quiet
set script-interpreter := ['bash', '-euo', 'pipefail']
set shell := ['bash', '-euo', 'pipefail', '-c']

# OCI instance public IP — every rebuild step talks to the node here; the tailnet does not exist yet
init_ip := env('FROSTLINK_INIT_IP', '')
# Node IP for phase2/tailnet — the public IP during a rebuild; day-2 is 10.0.0.203 over the site link
node_ip := env('FROSTLINK_NODE_IP', env('FROSTLINK_INIT_IP', ''))
seed_tag := 'exikle/frostlink:main'

[private]
default:
    just -l bootstrap

# Phase 1: generate config and apply to the node via the OCI public IP. No tailscale config —
# the node joins Headscale later with `just bootstrap tailnet`, once Headscale is back.
[confirm('Bootstrap Frostlink — Phase 1 (Talos config + apply)? [y|N]')]
[doc('Render Talos config and apply to node via OCI public IP')]
phase1: config apply

# Phase 2: needs 6443/tcp open on the OCI security list to your home /32 (bootstrap.md).
[confirm('Bootstrap Frostlink — Phase 2 (k8s + helmfile + seed)? [y|N]')]
[doc('Bootstrap Kubernetes over the public IP, install base apps, seed Flux from the Forgejo artifact')]
phase2: k8s kubeconfig talosconfig base cni seed apps

# Tailnet: join the rebuilt node to the restored Headscale with a fresh one-hour key.
[confirm('Join Frostlink to Headscale (mint key + patch Talos)? [y|N]')]
[doc('Mint a one-time tag:frostlink key and apply talos/patches/tailscale.yaml.j2 to the node')]
tailnet: tailnet-join

[private]
[script]
config:
    mkdir -p /tmp/frostlink-bootstrap

    just log info "Generating Talos config..." "stage" "$(basename "$0")"
    printf 'machine:\n  certSANs:\n    - %s\ncluster:\n  apiServer:\n    certSANs:\n      - %s\n' \
        "{{ init_ip }}" "{{ init_ip }}" > /tmp/frostlink-bootstrap/certsans.yaml
    talosctl gen config frostlink "https://{{ init_ip }}:6443" \
        --config-patch @"{{ source_dir() }}/../talos/patches/controlplane.yaml" \
        --config-patch @/tmp/frostlink-bootstrap/certsans.yaml \
        --output /tmp/frostlink-bootstrap \
        --force

    talosctl --talosconfig /tmp/frostlink-bootstrap/talosconfig config endpoint "{{ init_ip }}"

[private]
[script]
apply:
    just log info "Applying Talos config via OCI IP ({{ init_ip }})..." "stage" "$(basename "$0")"
    talosctl apply-config \
        --insecure \
        --nodes "{{ init_ip }}" \
        --file /tmp/frostlink-bootstrap/controlplane.yaml
    just log info "Node is rebooting. Next: open 6443/tcp on the OCI security list to your home /32, then run: just bootstrap phase2" "stage" "$(basename "$0")"

[private]
[script]
k8s:
    just log info "Bootstrapping Kubernetes via {{ node_ip }}..." "stage" "$(basename "$0")"
    until op=$(talosctl -n "{{ node_ip }}" \
        --talosconfig /tmp/frostlink-bootstrap/talosconfig \
        bootstrap 2>&1 || true) && [[ "$op" == *"AlreadyExists"* ]]; do
        just log info "Kubernetes bootstrap in progress. Retrying in 5 seconds..." "stage" "$(basename "$0")"
        sleep 5
    done

[private]
[script]
kubeconfig:
    just log info "Fetching kubeconfig..." "stage" "$(basename "$0")"
    talosctl kubeconfig \
        --talosconfig /tmp/frostlink-bootstrap/talosconfig \
        --nodes "{{ node_ip }}" \
        --force \
        --force-context-name frostlink \
        "{{ source_dir() }}/.."

[private]
[script]
talosconfig:
    just log info "Installing the rebuild talosconfig at the repo root (endpoint {{ init_ip }})..." "stage" "$(basename "$0")"
    install -m 600 /tmp/frostlink-bootstrap/talosconfig "{{ source_dir() }}/../talosconfig"

[private]
[script]
base:
    just log info "Applying namespaces..." "stage" "$(basename "$0")"
    find "{{ source_dir() }}/../kubernetes/apps" -mindepth 1 -maxdepth 1 -type d | while IFS= read -r dir; do
        if ! kustomize build "$dir" | yq ea -e 'select(.kind == "Namespace")' | \
            kubectl apply --server-side --field-manager bootstrap --force-conflicts -f -; then
            just log fatal "Failed to apply namespace" "stage" "$(basename "$0")" "namespace" "$(basename "$dir")"
        fi
    done
    just log info "Applying bootstrap secrets..." "stage" "$(basename "$0")"
    if ! just template "{{ source_dir() }}/resources.yaml.j2" | \
        kubectl apply --server-side --field-manager bootstrap --force-conflicts -f -; then
        just log fatal "Failed to apply bootstrap secrets" "stage" "$(basename "$0")"
    fi
    just log info "Applying CRDs..." "stage" "$(basename "$0")"
    if ! helmfile -f "{{ source_dir() }}/helmfile.d/00-crds.yaml" template -q | \
        yq ea -e 'select(.kind == "CustomResourceDefinition")' | \
        kubectl apply --server-side --field-manager bootstrap --force-conflicts -f -; then
        just log fatal "Failed to apply CRDs" "stage" "$(basename "$0")"
    fi

[private]
[script]
cni:
    just log info "Installing Cilium, CoreDNS, and cert-manager directly via helm (avoids SSA field-manager conflicts with helm-controller)..." "stage" "$(basename "$0")"

    for app in kube-system/cilium kube-system/coredns cert-manager/cert-manager; do
        ns="${app%%/*}"
        name="${app##*/}"
        ocirepo="{{ source_dir() }}/../kubernetes/apps/${app}/app/ocirepository.yaml"
        helmrelease="{{ source_dir() }}/../kubernetes/apps/${app}/app/helmrelease.yaml"

        chart="$(yq '.spec.url' "$ocirepo")"
        version="$(yq '.spec.ref.tag' "$ocirepo")"

        just log info "Installing ${name}..." "stage" "$(basename "$0")" "version" "$version"
        if ! yq '.spec.values' "$helmrelease" | \
            helm upgrade --install "$name" "$chart" \
                --version "$version" \
                --namespace "$ns" \
                --create-namespace \
                --values -; then
            just log fatal "Failed to install $name" "stage" "$(basename "$0")"
        fi
    done

[private]
[script]
seed:
    just log info "Starting the throwaway seed registry..." "stage" "$(basename "$0")"
    kubectl apply --server-side --field-manager bootstrap -f "{{ source_dir() }}/seed-registry.yaml"
    kubectl -n flux-system rollout status deploy/seed-registry --timeout=180s
    work="$(mktemp -d)"
    trap 'kill "${pf:-0}" 2>/dev/null || true; rm -rf "$work"' EXIT
    just log info "Pulling the CI artifact from Forgejo (git.dcunha.io) over the home network..." "stage" "$(basename "$0")"
    flux pull artifact "oci://git.dcunha.io/{{ seed_tag }}" --output "$work" \
        --creds "exikle:$(op read 'op://infrastructure/forgejo/EXIKLE_CLI_TOKEN')"
    kubectl -n flux-system port-forward svc/seed-registry 5000:5000 >/dev/null 2>&1 &
    pf=$!
    for _ in $(seq 1 20); do curl -fs http://127.0.0.1:5000/v2/ >/dev/null && break; sleep 1; done
    just log info "Pushing it into the seed registry..." "stage" "$(basename "$0")"
    flux push artifact "oci://127.0.0.1:5000/{{ seed_tag }}" --insecure-registry --path "$work" \
        --source "https://git.dcunha.io/Exikle/frostlink" \
        --revision "main@sha1:$(git -C "{{ source_dir() }}/.." rev-parse HEAD)"

[private]
[script]
tailnet-join:
    tmp="$(mktemp)"
    trap 'shred -u "$tmp" 2>/dev/null || rm -f "$tmp"' EXIT
    just log info "Minting a one-hour tag:frostlink pre-auth key on the restored Headscale..." "stage" "$(basename "$0")"
    key="$(kubectl -n network exec deploy/headscale -c app -- \
        headscale preauthkeys create --tags tag:frostlink --expiration 1h -o json | jq -r '.key')"
    [[ -n "$key" && "$key" != "null" ]] || just log fatal "Headscale returned no key" "stage" "$(basename "$0")"
    chmod 600 "$tmp"
    sed "s|op://infrastructure/headscale/TS_AUTH_KEY|${key}|" \
        "{{ source_dir() }}/../talos/patches/tailscale.yaml.j2" > "$tmp"
    just log info "Applying the tailscale ExtensionServiceConfig to {{ node_ip }} (no reboot)..." "stage" "$(basename "$0")"
    talosctl --talosconfig "{{ source_dir() }}/../talosconfig" -n "{{ node_ip }}" patch mc --patch @"$tmp"
    just log info "Done. Delete the old frostlink node and check routes (bootstrap.md § Rebuild order, step 5):" "stage" "$(basename "$0")"
    kubectl -n network exec deploy/headscale -c app -- headscale nodes list

[private]
[script]
apps:
    just log info "Syncing apps via helmfile..." "stage" "$(basename "$0")"
    if ! helmfile -f "{{ source_dir() }}/helmfile.d/01-apps.yaml" sync --hide-notes; then
        just log fatal "Failed to sync helmfile apps" "stage" "$(basename "$0")"
    fi
