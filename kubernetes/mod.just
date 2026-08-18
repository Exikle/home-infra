set quiet
set script-interpreter := ['bash', '-euo', 'pipefail']
set shell := ['bash', '-euo', 'pipefail', '-c']

kubectl := "kubectl --context frostlink"

[private]
default:
    just -l kube

[doc('Apply local Flux Kustomization')]
apply-ks ns ks:
    just kube render-local-ks "{{ ns }}" "{{ ks }}" | {{ kubectl }} apply --server-side --force-conflicts --field-manager=kustomize-controller -f /dev/stdin

[doc('Browse a PVC')]
browse-pvc ns claim:
    {{ kubectl }} run -n {{ ns }} browse-pvc-{{ claim }} -it --rm --restart=Never \
        --image=mirror.gcr.io/alpine:latest \
        --overrides='{"spec":{"containers":[{"name":"browse-pvc-{{ claim }}","image":"mirror.gcr.io/alpine:latest","stdin":true,"tty":true,"command":["/bin/sh"],"workingDir":"/mnt","volumeMounts":[{"mountPath":"/mnt","name":"data"}]}],"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"{{ claim }}"}}]}}'

[doc('Debug a node')]
[script]
debug-node node:
    trap '{{ kubectl }} delete pod -n default -l app.kubernetes.io/managed-by=kubectl-debug --field-selector spec.nodeName={{ node }} --ignore-not-found --wait=false' EXIT
    {{ kubectl }} debug node/{{ node }} -n default -it --image=mirror.gcr.io/alpine:latest --profile=sysadmin

[doc('Delete local Flux Kustomization')]
delete-ks ns ks:
    just kube render-local-ks "{{ ns }}" "{{ ks }}" | {{ kubectl }} delete -f /dev/stdin

[doc('Prune pods in Failed, Pending, or Succeeded state')]
[script]
prune-pods:
    for phase in Failed Pending Succeeded; do
        {{ kubectl }} delete pods -A --field-selector status.phase="$phase" --ignore-not-found=true
    done

[arg('state', pattern='suspend|resume')]
[doc('Suspend or resume Kopiur')]
kopiur state:
    flux -n kopiur-system {{ state }} kustomization kopiur
    flux -n kopiur-system {{ state }} helmrelease kopiur
    {{ kubectl }} -n kopiur-system scale deployment kopiur-controller --replicas {{ if state != "suspend" { "1" } else { "0" } }}

[arg('resource', pattern='hr|ks|gitrepo|ocirepo|es')]
[doc('Sync a resource')]
[script]
sync resource:
    {{ kubectl }} get {{ resource }} --no-headers -A | while read -r ns name _; do
        {{ kubectl }} -n "$ns" annotate --field-manager flux-client-side-apply --overwrite {{ resource }} "$name" \
            "force-sync=$(date +%s)" \
            "reconcile.fluxcd.io/requestedAt=$(date +%s)" \
            "reconcile.fluxcd.io/forceAt=$(date +%s)"
    done

[doc('Restore a PVC from its latest Kopiur snapshot (DESTRUCTIVE - deletes the PVC)')]
[script]
restore ns ks claim offset='0':
    # Kopiur restore, as actually exercised on 2026-08-18. Order matters:
    #
    #  - The Restore CR pins its snapshot resolution at creation. A CR created
    #    before the app's first snapshot pins resolution=NoSnapshot forever and
    #    then silently populates an EMPTY volume while reporting Completed. So it
    #    is deleted and recreated here, and the resolution is asserted at the end.
    #  - openebs-zfs is WaitForFirstConsumer, so nothing is provisioned or
    #    populated until a pod claims the PVC. The workload must be scaled back
    #    UP to drive the restore - it cannot run with the app at zero.
    #  - The PV is flipped to Retain first so a bad restore is recoverable. That
    #    leaves an orphaned PV + ZFSVolume behind; the cleanup command is printed
    #    at the end. Do not skip it, or the space stays leaked.
    PVC="{{ claim }}"

    if ! {{ kubectl }} -n {{ ns }} get pvc "$PVC" >/dev/null 2>&1; then
        just log error "no such PVC" ns "{{ ns }}" claim "$PVC"
        exit 1
    fi

    # Workloads mounting this claim, with their current replica counts.
    WORKLOADS=$({{ kubectl }} -n {{ ns }} get deploy,sts -o json \
        | jq -r --arg c "$PVC" '.items[]
            | select([.spec.template.spec.volumes[]? | select(.persistentVolumeClaim.claimName == $c)] | length > 0)
            | "\(.kind | ascii_downcase)/\(.metadata.name)=\(.spec.replicas)"')

    if [[ -z "$WORKLOADS" ]]; then
        just log warn "no workload mounts this claim; one is required to drive the populator" claim "$PVC"
    fi

    PV=$({{ kubectl }} -n {{ ns }} get pvc "$PVC" -o jsonpath='{.spec.volumeName}')
    just log info "retaining old volume as a safety net" pv "$PV"
    {{ kubectl }} patch pv "$PV" -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'

    for w in $WORKLOADS; do
        just log info "scaling down" workload "${w%%=*}"
        {{ kubectl }} -n {{ ns }} scale "${w%%=*}" --replicas=0
    done
    {{ kubectl }} -n {{ ns }} wait pod --for=delete --all --timeout=10m \
        --field-selector=status.phase!=Succeeded || true

    just log info "deleting PVC and stale Restore CR" claim "$PVC"
    {{ kubectl }} -n {{ ns }} delete pvc "$PVC" --timeout=5m
    {{ kubectl }} -n {{ ns }} delete restore "$PVC" --ignore-not-found --timeout=5m

    # Both carry ssa: IfNotPresent, so Flux recreates them now that they are gone.
    flux -n {{ ns }} reconcile kustomization {{ ks }}
    {{ kubectl }} -n {{ ns }} wait restore "$PVC" --for=create --timeout=5m
    {{ kubectl }} -n {{ ns }} wait pvc "$PVC" --for=create --timeout=5m

    if [[ "{{ offset }}" != "0" ]]; then
        just log info "restoring an older snapshot" offset "{{ offset }}"
        {{ kubectl }} -n {{ ns }} patch restore "$PVC" --type=merge \
            -p '{"spec":{"source":{"fromPolicy":{"offset":{{ offset }}}}}}'
    fi

    # WaitForFirstConsumer: scaling back up is what actually starts the restore.
    for w in $WORKLOADS; do
        just log info "scaling up to drive the populator" workload "${w%%=*}" replicas "${w##*=}"
        {{ kubectl }} -n {{ ns }} scale "${w%%=*}" --replicas="${w##*=}"
    done

    {{ kubectl }} -n {{ ns }} wait pvc "$PVC" --for=jsonpath='{.status.phase}'=Bound --timeout=60m

    # The failure this whole recipe exists to catch: a "successful" empty restore.
    RESOLUTION=$({{ kubectl }} -n {{ ns }} get restore "$PVC" -o jsonpath='{.status.resolved.resolution}')
    if [[ "$RESOLUTION" != "Snapshot" ]]; then
        just log error "restore did NOT come from a snapshot - the volume is EMPTY" resolution "$RESOLUTION"
        just log error "old data is still on the retained PV" pv "$PV"
        exit 1
    fi

    {{ kubectl }} -n {{ ns }} wait pod --for=condition=ready --all --timeout=15m
    just log info "restore complete" claim "$PVC" resolution "$RESOLUTION"
    just log warn "verify the data, then reclaim the old volume" \
        run "kubectl --context frostlink delete pv $PV && kubectl --context frostlink -n openebs-system delete zfsvolume $PV"

[doc('Take an on-demand Kopiur snapshot and wait for it')]
[script]
backup ns claim:
    NAME="{{ claim }}-manual-$(date -u +%Y%m%d%H%M%S)"
    {{ kubectl }} apply --server-side -f - <<EOF
    apiVersion: kopiur.home-operations.com/v1alpha1
    kind: Snapshot
    metadata:
      name: $NAME
      namespace: {{ ns }}
    spec:
      description: on-demand snapshot via \`just kube backup\`
      policyRef:
        name: {{ claim }}
    EOF
    {{ kubectl }} -n {{ ns }} wait snapshot "$NAME" \
        --for=jsonpath='{.status.phase}'=Succeeded --timeout=120m
    {{ kubectl }} -n {{ ns }} get snapshot "$NAME" -o jsonpath='{.status.logTail}{"\n"}'

[doc('View a secret')]
view-secret namespace secret:
    {{ kubectl }} view-secret -n {{ namespace }} {{ secret }}

[private]
render-local-ks ns ks:
    flate build ks --namespace "{{ ns }}" --output yaml "{{ ks }}"
