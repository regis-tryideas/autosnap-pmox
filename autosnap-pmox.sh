#!/usr/bin/env bash
# autosnap.sh — Snapshot seguro/automático para Proxmox (PVE <= 8.x)
# - QEMU + LXC
# - Pula VM/CT com tag "no_snapshot"
# - Pula se houver vzdump no host ou lock=backup
# - QEMU:
#   * Se QGA responder -> snapshot NORMAL (fsfreeze)
#   * Senão -> HOT (sem fsfreeze; sem pause/resume)
# - LXC:
#   * Sempre snapshot via `pct snapshot` (online se suportado)
# - Pós-snapshot:
#   * unlock somente para lock 'snapshot' ou 'suspended'
# - Retenção:
#   * Mantém N snapshots cujo nome COMEÇA com "<PREFIX>" (ex.: "auto" casa "auto-2025...")
#   * parsing robusto da árvore de `qm listsnapshot` / `pct listsnapshot`
#   * ordenação pelo timestamp no NOME (YYYYMMDD-HHMMSS); se não houver, vai pro fim
# - Logs verbosos de todas as checagens/ações

set -uo pipefail          # sem 'set -e' para não abortar após snapshot
shopt -s lastpipe         # permite while read após pipe no mesmo shell

PREFIX="auto"
PING_TIMEOUT=15
VMSTATE=0                 # 0 = não salva memória (apenas QEMU)
DRYRUN=0
KEEP_COUNT=0              # 0 = sem retenção

log(){ printf "[%s] %s\n" "$(date '+%F %T')" "$*" >&2; }

run(){
  local cmd="$*"
  if ((DRYRUN)); then
    log "DRY-RUN: $cmd"
    return 0
  fi
  eval "$cmd"
  local rc=$?
  log "EXEC: '$cmd' -> rc=${rc}"
  return $rc
}

on_err(){
  local rc=$?
  log "ERRO: comando anterior retornou rc=${rc}. Continuando (retenção ainda será tentada se possível)."
}
trap on_err ERR

usage(){
  cat <<EOF
Uso:
  $0 [OPÇÕES] all [KEEP] | <id> [<id> ...] [KEEP]

Onde:
  - "all"     = todas as VMs QEMU + todos os containers LXC
  - <id>      = ID numérico (será tentado como QEMU e como LXC)

Opções:
  --prefix NOME     Prefixo do snapshot (default: auto)
  --timeout N       Timeout QGA (s) (default: 15)
  --vmstate {0|1}   Incluir memória (apenas QEMU; default: 0)
  --dry-run         Simula (não executa)
  -h|--help         Ajuda

Exemplos:
  $0 all 24
  $0 101 203 12
  $0 --prefix nightly --timeout 60 all 10
EOF
  exit 1
}

# ---------- parse args ----------
ARGS=()
while (( $# )); do
  case "$1" in
    --prefix)   PREFIX="${2:-}"; shift 2;;
    --timeout)  PING_TIMEOUT="${2:-}"; shift 2;;
    --vmstate)  VMSTATE="${2:-}"; shift 2;;
    --dry-run)  DRYRUN=1; shift;;
    -h|--help)  usage;;
    *)          ARGS+=("$1"); shift;;
  esac
done
(( ${#ARGS[@]} )) || usage

# KEEP é o último token numérico
if [[ "${ARGS[-1]:-}" =~ ^[0-9]+$ ]]; then
  KEEP_COUNT="${ARGS[-1]}"
  unset "ARGS[${#ARGS[@]}-1]"
fi
VMIDS=("${ARGS[@]}"); (( ${#VMIDS[@]} )) || usage

# ---------- helpers ----------
now_stamp(){ date '+%Y%m%d-%H%M%S'; }
snapshot_name(){ echo "${PREFIX}-$(now_stamp)"; }

get_all_qemu_vmids(){ qm list 2>/dev/null | awk 'NR>1{print $1}' | sort -n; }
get_all_lxc_ctids(){ pct list 2>/dev/null | awk 'NR>1{print $1}' | sort -n; }

is_vm_running(){
  local s
  s="$(qm status "$1" 2>/dev/null | awk '{print $2}')"
  [[ "$s" == "running" ]]
}
is_ct_running(){
  local s
  s="$(pct status "$1" 2>/dev/null | awk '{print $2}')"
  [[ "$s" == "running" ]]
}

agent_enabled(){
  qm config "$1" 2>/dev/null | awk -F': ' '/^agent:/ {print $2}' | grep -q '1'
}

has_no_snapshot_tag_qemu(){
  local tags
  tags="$(qm config "$1" 2>/dev/null | awk -F': ' '/^tags:/{print $2}' | tr 'A-Z' 'a-z' || true)"
  [[ "$tags" == *"no_snapshot"* ]]
}
has_no_snapshot_tag_lxc(){
  local tags
  tags="$(pct config "$1" 2>/dev/null | awk -F': ' '/^tags:/{print $2}' | tr 'A-Z' 'a-z' || true)"
  [[ "$tags" == *"no_snapshot"* ]]
}

qga_ping_ok(){
  timeout "${PING_TIMEOUT}"s qm guest exec "$1" -- whoami >/dev/null 2>&1
}

get_qemu_lock(){
  qm config "$1" 2>/dev/null | awk -F': ' '/^lock:/ {print $2}'
}
get_lxc_lock(){
  pct config "$1" 2>/dev/null | awk -F': ' '/^lock:/ {print $2}'
}

backup_global_running(){ pgrep -x vzdump >/dev/null 2>&1; }

# ---------- retenção baseada em `qm listsnapshot` / `pct listsnapshot` ----------
_cleanup_old_snapshots_common(){
  local id="$1" keep="$2" kind="$3"   # kind = qm|pct
  (( keep > 0 )) || { log "$kind $id | Retenção: KEEP=0 → pulando."; return 0; }

  local matchprefix="${PREFIX}"
  log "$kind $id | Retenção: iniciando | prefixo='${matchprefix}' | keep=${keep}"

  local tree
  if [[ "$kind" == "qm" ]]; then
    if ! tree="$(qm listsnapshot "$id" 2>/dev/null)"; then
      log "$kind $id | Retenção: 'qm listsnapshot' falhou → pulando."
      return 0
    fi
  else
    if ! tree="$(pct listsnapshot "$id" 2>/dev/null)"; then
      log "$kind $id | Retenção: 'pct listsnapshot' falhou → pulando."
      return 0
    fi
  fi

  mapfile -t candidates < <(
    awk -v pfx="$matchprefix" '
      /^[[:space:]]/ {
        line=$0
        gsub(/^[[:space:]]+/, "", line)               # tira indent
        sub(/^([`"|+ -]*-> )[[:space:]]*/, "", line)  # tira galho (`, |, +, -, espaço) + "-> "
        name=line
        sub(/[[:space:]].*$/, "", name)               # só o primeiro campo
        if (index(name, pfx)==1) print name
      }
    ' <<< "$tree"
  )

  local total="${#candidates[@]}"
  log "$kind $id | Retenção: candidatos_encontrados=${total}"
  (( total > keep )) || { log "$kind $id | Retenção: nada a apagar (<= keep)."; return 0; }

  mapfile -t sorted < <(
    for n in "${candidates[@]}"; do
      rest="${n#*-}"                         # parte após o 1º '-'
      ymd="${rest%-*}"                       # YYYYMMDD
      hms="${rest##*-}"                      # HHMMSS
      ymd="${ymd//[^0-9]/}"
      hms="${hms//[^0-9]/}"
      if [[ "${#ymd}" -eq 8 && "${#hms}" -eq 6 ]]; then
        ts="${ymd}${hms}"
      else
        ts="000000000000"
      fi
      printf "%s %s\n" "${ts}" "$n"
    done | sort -r | awk '{ $1=""; sub(/^ /,""); print }'
  )

  log "$kind $id | Retenção: --- ORDEM (novo→antigo) ---"
  for n in "${sorted[@]}"; do log "  * ${n}"; done

  local keep_list=() del_list=()
  local idx=0
  for n in "${sorted[@]}"; do
    if (( idx < keep )); then keep_list+=("$n"); else del_list+=("$n"); fi
    ((idx++))
  done

  log "$kind $id | Retenção: --- MANTER (KEEP) ---"
  for n in "${keep_list[@]}";  do log "  KEEP: $n"; done

  if (( ${#del_list[@]} == 0 )); then
    log "$kind $id | Retenção: nada para apagar após ordenação."
    return 0
  fi

  log "$kind $id | Retenção: --- APAGAR (DEL) ---"
  for n in "${del_list[@]}"; do log "  DEL:  $n"; done

  for snap in "${del_list[@]}"; do
    if [[ "$kind" == "qm" ]]; then
      run "qm delsnapshot $id \"$snap\"" || true
    else
      run "pct delsnapshot $id \"$snap\"" || true
    fi
  done
  log "$kind $id | Retenção: limpeza concluída."
}

cleanup_old_snapshots_qemu(){ _cleanup_old_snapshots_common "$1" "$2" "qm"; }
cleanup_old_snapshots_lxc(){  _cleanup_old_snapshots_common "$1" "$2" "pct"; }

# ---------- pós-snapshot unlock ----------
post_snapshot_unlock_if_needed_qemu(){
  local vmid="$1" lock
  sleep 1
  lock="$(get_qemu_lock "$vmid" || true)"
  case "${lock:-}" in
    snapshot|suspended)
      log "VM $vmid | Pós-snapshot: lock='$lock' → qm unlock."
      run "qm unlock $vmid" || true
      lock="$(get_qemu_lock "$vmid" || true)"
      [[ -z "${lock:-}" ]] && log "VM $vmid | Unlock OK." || log "VM $vmid | Aviso: lock ainda '${lock}'."
      ;;
    backup|ha|'') [[ -n "${lock:-}" ]] && log "VM $vmid | Pós-snapshot: lock='$lock' — não destrava.";;
    *)            log "VM $vmid | Pós-snapshot: lock='$lock' — não destrava.";;
  esac
}

post_snapshot_unlock_if_needed_lxc(){
  local ctid="$1" lock
  sleep 1
  lock="$(get_lxc_lock "$ctid" || true)"
  case "${lock:-}" in
    snapshot|suspended)
      log "CT $ctid | Pós-snapshot: lock='$lock' → pct unlock."
      run "pct unlock $ctid" || true
      lock="$(get_lxc_lock "$ctid" || true)"
      [[ -z "${lock:-}" ]] && log "CT $ctid | Unlock OK." || log "CT $ctid | Aviso: lock ainda '${lock}'."
      ;;
    backup|ha|'') [[ -n "${lock:-}" ]] && log "CT $ctid | Pós-snapshot: lock='$lock' — não destrava.";;
    *)            log "CT $ctid | Pós-snapshot: lock='$lock' — não destrava.";;
  esac
}

# ---------- execução de snapshot QEMU ----------
do_snapshot_normal(){
  local vmid="$1" sname="$2" desc="$3" vmstate="$4"
  log "VM $vmid | Ação: snapshot NORMAL (fsfreeze), vmstate=$vmstate, nome=$sname"
  run "qm snapshot $vmid \"$sname\" --description \"$desc\" --vmstate $vmstate" || true
  log "VM $vmid | Snapshot finalizado (NORMAL): $sname"
}
do_snapshot_hot(){
  local vmid="$1" sname="$2" desc="$3" vmstate="$4"
  log "VM $vmid | Ação: snapshot HOT (sem fsfreeze), vmstate=$vmstate, nome=$sname"
  run "qm snapshot $vmid \"$sname\" --description \"$desc\" --vmstate $vmstate" || true
  log "VM $vmid | Snapshot finalizado (HOT): $sname"
}

process_vm(){
  local vmid="$1"

  if ! qm config "$vmid" >/dev/null 2>&1; then
    log "VM $vmid | Checagem: config inexistente → ignorando."
    return
  fi

  if has_no_snapshot_tag_qemu "$vmid"; then
    log "VM $vmid | Checagem: tag 'no_snapshot' → pulando."
    return
  fi
  if backup_global_running; then
    log "VM $vmid | Checagem: vzdump em execução no host → pulando."
    return
  fi

  local prelock; prelock="$(get_qemu_lock "$vmid" || true)"
  log "VM $vmid | Checagem: lock atual='${prelock:-none}'"
  if [[ "${prelock:-}" == "backup" ]]; then
    log "VM $vmid | Checagem: lock=backup → pulando."
    return
  fi

  local sname desc; sname="$(snapshot_name)"
  desc="autosnap: $(date '+%F %T') | vmstate=$VMSTATE | prefix=${PREFIX}"

  if ! is_vm_running "$vmid"; then
    log "VM $vmid | Checagem: status=STOPPED → snapshot HOT."
    do_snapshot_hot "$vmid" "$sname" "$desc" 0
  else
    if agent_enabled "$vmid"; then
      log "VM $vmid | Checagem: agent habilitado → testando QGA (timeout=${PING_TIMEOUT}s)."
      if qga_ping_ok "$vmid"; then
        log "VM $vmid | Checagem: QGA OK."
        do_snapshot_normal "$vmid" "$sname" "$desc" "$VMSTATE"
      else
        log "VM $vmid | Checagem: QGA NÃO respondeu → snapshot HOT."
        do_snapshot_hot "$vmid" "$sname" "$desc" "$VMSTATE"
      fi
    else
      log "VM $vmid | Checagem: agent desabilitado → snapshot HOT."
      do_snapshot_hot "$vmid" "$sname" "$desc" "$VMSTATE"
    fi
  fi

  post_snapshot_unlock_if_needed_qemu "$vmid"
  sleep 1
  cleanup_old_snapshots_qemu "$vmid" "$KEEP_COUNT"

  log "VM $vmid | Finalizado: $sname"
}

# ---------- execução de snapshot LXC ----------
do_ct_snapshot(){
  local ctid="$1" sname="$2" desc="$3"
  # pct snapshot suporta online snapshot; não temos QGA aqui
  log "CT $ctid | Ação: snapshot (pct snapshot), nome=$sname"
  run "pct snapshot $ctid \"$sname\" --description \"$desc\"" || true
  log "CT $ctid | Snapshot finalizado: $sname"
}

process_ct(){
  local ctid="$1"

  if ! pct config "$ctid" >/dev/null 2>&1; then
    log "CT $ctid | Checagem: config inexistente → ignorando."
    return
  fi

  if has_no_snapshot_tag_lxc "$ctid"; then
    log "CT $ctid | Checagem: tag 'no_snapshot' → pulando."
    return
  fi
  if backup_global_running; then
    log "CT $ctid | Checagem: vzdump em execução no host → pulando."
    return
  fi

  local prelock; prelock="$(get_lxc_lock "$ctid" || true)"
  log "CT $ctid | Checagem: lock atual='${prelock:-none}'"
  if [[ "${prelock:-}" == "backup" ]]; then
    log "CT $ctid | Checagem: lock=backup → pulando."
    return
  fi

  local sname desc; sname="$(snapshot_name)"
  desc="autosnap: $(date '+%F %T') | kind=LXC | prefix=${PREFIX}"

  # Snapshot LXC funciona tanto running quanto stopped, então só log informativo
  if is_ct_running "$ctid"; then
    log "CT $ctid | Checagem: status=RUNNING → snapshot online."
  else
    log "CT $ctid | Checagem: status=STOPPED → snapshot offline."
  fi

  do_ct_snapshot "$ctid" "$sname" "$desc"

  post_snapshot_unlock_if_needed_lxc "$ctid"
  sleep 1
  cleanup_old_snapshots_lxc "$ctid" "$KEEP_COUNT"

  log "CT $ctid | Finalizado: $sname"
}

# ---------- roteador de ID (QEMU ou LXC) ----------
process_any(){
  local id="$1"

  if qm config "$id" >/dev/null 2>&1; then
    process_vm "$id"
    return
  fi

  if pct config "$id" >/dev/null 2>&1; then
    process_ct "$id"
    return
  fi

  log "ID $id | Checagem: não é QEMU nem LXC conhecidos → ignorando."
}

main(){
  local targets=()

  if [[ "${VMIDS[0]}" == "all" ]]; then
    local qlist clist
    mapfile -t qlist < <(get_all_qemu_vmids)
    mapfile -t clist < <(get_all_lxc_ctids)
    # junta e deduplica
    mapfile -t targets < <(printf '%s\n' "${qlist[@]}" "${clist[@]}" | awk 'NF' | sort -n | uniq)
  else
    targets=("${VMIDS[@]}")
  fi

  log "Iniciando autosnap | prefix=${PREFIX} | timeout=${PING_TIMEOUT}s | vmstate=${VMSTATE} | keep=${KEEP_COUNT} | dryrun=${DRYRUN}"
  for id in "${targets[@]}"; do
    process_any "$id"
  done
  log "autosnap finalizado."
}

main
