set no-exit-message
set quiet
set script-interpreter := ['bash', '-euo', 'pipefail']
set shell := ['bash', '-euo', 'pipefail', '-c']

# OCI instance public IP — used for initial talosctl apply-config
init_ip := env('FROSTLINK_INIT_IP', '')
# Node IP for phase2 ops — defaults to OCI public IP; override with Tailscale IP once confirmed
node_ip := env('FROSTLINK_NODE_IP', env('FROSTLINK_INIT_IP', ''))

[private]
default:
    just -l bootstrap

# Phase 1: generate config and apply to node via OCI public IP.
# After this, wait for the node to appear in the Tailscale admin console,
# then set FROSTLINK_NODE_IP to the Tailscale IP and run phase2.
[confirm('Bootstrap Frostlink — Phase 1 (Talos config + apply)? [y|N]')]
[doc('Render Talos config and apply to node via OCI public IP')]
phase1: config apply

# Phase 2: bootstrap Kubernetes, fetch kubeconfig, install base apps via Tailscale IP.
[confirm('Bootstrap Frostlink — Phase 2 (k8s + helmfile)? [y|N]')]
[doc('Bootstrap Kubernetes and install base apps (requires FROSTLINK_NODE_IP = Tailscale IP)')]
phase2: k8s kubeconfig base cni apps

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

    just log info "Appending Tailscale ExtensionServiceConfig..." "stage" "$(basename "$0")"
    export TS_AUTHKEY="$(op read 'op://kubernetes/tailscale-frostlink/TS_AUTH_KEY')"
    {
        echo '---'
        echo 'apiVersion: v1alpha1'
        echo 'kind: ExtensionServiceConfig'
        echo 'name: tailscale'
        echo 'environment:'
        printf '  - TS_AUTHKEY=%s\n' "${TS_AUTHKEY}"
        echo '  - TS_EXTRA_ARGS=--advertise-tags=tag:k8s'
        echo '  - TS_STATE_DIR=/var/lib/tailscale'
    } >> /tmp/frostlink-bootstrap/controlplane.yaml

[private]
[script]
apply:
    just log info "Applying Talos config via OCI IP ({{ init_ip }})..." "stage" "$(basename "$0")"
    talosctl apply-config \
        --insecure \
        --nodes "{{ init_ip }}" \
        --file /tmp/frostlink-bootstrap/controlplane.yaml
    just log info "Node is rebooting. Check the Tailscale admin console for the new device IP, then set FROSTLINK_NODE_IP and run: just bootstrap phase2" "stage" "$(basename "$0")"

[private]
[script]
k8s:
    just log info "Bootstrapping Kubernetes via Tailscale IP ({{ node_ip }})..." "stage" "$(basename "$0")"
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
apps:
    just log info "Syncing apps via helmfile..." "stage" "$(basename "$0")"
    if ! helmfile -f "{{ source_dir() }}/helmfile.d/01-apps.yaml" sync --hide-notes; then
        just log fatal "Failed to sync helmfile apps" "stage" "$(basename "$0")"
    fi
