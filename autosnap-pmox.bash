#!/usr/bin/env bash
# autosnap.sh — Snapshot seguro/automático para Proxmox (PVE <= 8.x)
# - Pula VM com tag "no_snapshot"
# - Pula se houver vzdump no host ou lock=backup na VM
# - QGA: se responder -> snapshot NORMAL (fsfreeze); senão -> HOT (sem fsfreeze; sem pause/resume)
# - Pós-snapshot: unlock somente para lock 'snapshot' ou 'suspended'
# - Retenção: mantém N snapshots cujo nome COMEÇA com "<PREFIX>" (ex.: "auto" casa "auto-2025...")
#   * parsing robusto da árvore do `qm listsnapshot`
#   * ordenação pelo timestamp no NOME (YYYYMMDD-HHMMSS); se não houver, vai pro fim
# - Logs verbosos de todas as checagens/ações

set -uo pipefail          # sem 'set -e' para não abortar após snapshot
shopt -s lastpipe         # permite while read após pipe no mesmo shell

PREFIX="auto"
PING_TIMEOUT=15
VMSTATE=0                 # 0 = não salva memória
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
  $0 [OPÇÕES] all [KEEP] | <vmid> [<vmid> ...] [KEEP]

Opções:
  --prefix NOME     Prefixo do snapshot (default: auto)
  --timeout N       Timeout QGA (s) (default: 15)
  --vmstate {0|1}   Incluir memória (default: 0)
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
get_all_qemu_vmids(){ qm list | awk 'NR>1{print $1}' | sort -n; }
is_vm_running(){ local s; s="$(qm status "$1" 2>/dev/null | awk '{print $2}')"; [[ "$s" == "running" ]]; }
agent_enabled(){ qm config "$1" 2>/dev/null | awk -F': ' '/^agent:/ {print $2}' | grep -q '1'; }
has_no_snapshot_tag(){
  local tags; tags="$(qm config "$1" 2>/dev/null | awk -F': ' '/^tags:/{print $2}' | tr 'A-Z' 'a-z' || true)"
  [[ "$tags" == *"no_snapshot"* ]]
}
qga_ping_ok(){ timeout "${PING_TIMEOUT}"s qm guest exec "$1" -- whoami >/dev/null 2>&1; }
snapshot_name(){ echo "${PREFIX}-$(now_stamp)"; }
get_lock(){ qm config "$1" 2>/dev/null | awk -F': ' '/^lock:/ {print $2}'; }
backup_global_running(){ pgrep -x vzdump >/dev/null 2>&1; }

post_snapshot_unlock_if_needed(){
  local vmid="$1" lock
  sleep 1
  lock="$(get_lock "$vmid" || true)"
  case "${lock:-}" in
    snapshot|suspended)
      log "VM $vmid | Pós-snapshot: lock='$lock' → qm unlock."
      run "qm unlock $vmid" || true
      lock="$(get_lock "$vmid" || true)"
      [[ -z "${lock:-}" ]] && log "VM $vmid | Unlock OK." || log "VM $vmid | Aviso: lock ainda '${lock}'."
      ;;
    backup|ha|'') [[ -n "${lock:-}" ]] && log "VM $vmid | Pós-snapshot: lock='$lock' — não destrava."; ;;
    *)            log "VM $vmid | Pós-snapshot: lock='$lock' — não destrava."; ;;
  esac
}

# ---------- retenção baseada em `qm listsnapshot` ----------
cleanup_old_snapshots(){
  local vmid="$1" keep="$2"
  (( keep > 0 )) || { log "VM $vmid | Retenção: KEEP=0 → pulando."; return 0; }

  local matchprefix="${PREFIX}"
  log "VM $vmid | Retenção: iniciando | prefixo='${matchprefix}' | keep=${keep}"

  local tree
  if ! tree="$(qm listsnapshot "$vmid" 2>/dev/null)"; then
    log "VM $vmid | Retenção: 'qm listsnapshot' falhou → pulando."
    return 0
  fi

  # Extrai NOME correto removendo indent e o “galho” (`->`, '|->', '+->', '->'), depois pega o 1º campo
  # Ex.: "   `-> auto-20251103-104630  2025-11-03 10:46:34  desc"
  #      vira "auto-20251103-104630  2025-11-03 10:46:34  desc"
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
  log "VM $vmid | Retenção: candidatos_encontrados=${total}"
  (( total > keep )) || { log "VM $vmid | Retenção: nada a apagar (<= keep)."; return 0; }

  # Ordena por timestamp do nome (YYYYMMDD-HHMMSS) → novo→antigo; sem timestamp → vai pro fim
  mapfile -t sorted < <(
    for n in "${candidates[@]}"; do
      # formatos esperados: PREFIX-YYYYMMDD-HHMMSS
      rest="${n#*-}"                         # parte após o 1º '-'
      ymd="${rest%-*}"                       # YYYYMMDD
      hms="${rest##*-}"                      # HHMMSS
      ymd="${ymd//[^0-9]/}"
      hms="${hms//[^0-9]/}"
      if [[ "${#ymd}" -eq 8 && "${#hms}" -eq 6 ]]; then
        ts="${ymd}${hms}"
      else
        ts="000000000000"                    # sem timestamp → ordenar por último
      fi
      printf "%s %s\n" "${ts}" "$n"
    done | sort -r | awk '{ $1=""; sub(/^ /,""); print }'
  )

  log "VM $vmid | Retenção: --- ORDEM (novo→antigo) ---"
  for n in "${sorted[@]}"; do log "  * ${n}"; done

  # KEEP e DEL
  local keep_list=() del_list=()
  local idx=0
  for n in "${sorted[@]}"; do
    if (( idx < keep )); then keep_list+=("$n"); else del_list+=("$n"); fi
    ((idx++))
  done

  log "VM $vmid | Retenção: --- MANTER (KEEP) ---"
  for n in "${keep_list[@]}";  do log "  KEEP: $n"; done

  if (( ${#del_list[@]} == 0 )); then
    log "VM $vmid | Retenção: nada para apagar após ordenação."
    return 0
  fi

  log "VM $vmid | Retenção: --- APAGAR (DEL) ---"
  for n in "${del_list[@]}"; do log "  DEL:  $n"; done

  # Apaga um a um
  for snap in "${del_list[@]}"; do
    run "qm delsnapshot $vmid \"$snap\"" || true
  done
  log "VM $vmid | Retenção: limpeza concluída."
}

# ---------- execução de snapshot ----------
do_snapshot_normal(){  # QGA OK
  local vmid="$1" sname="$2" desc="$3" vmstate="$4"
  log "VM $vmid | Ação: snapshot NORMAL (fsfreeze), vmstate=$vmstate, nome=$sname"
  run "qm snapshot $vmid \"$sname\" --description \"$desc\" --vmstate $vmstate" || true
  log "VM $vmid | Snapshot finalizado (NORMAL): $sname"
}
do_snapshot_hot(){     # QGA NOK / agent off
  local vmid="$1" sname="$2" desc="$3" vmstate="$4"
  log "VM $vmid | Ação: snapshot HOT (sem fsfreeze), vmstate=$vmstate, nome=$sname"
  run "qm snapshot $vmid \"$sname\" --description \"$desc\" --vmstate $vmstate" || true
  log "VM $vmid | Snapshot finalizado (HOT): $sname"
}

process_vm(){
  local vmid="$1"

  if ! qm config "$vmid" >/dev/null 2>&1; then log "VM $vmid | Checagem: config inexistente → ignorando."; return; fi
  if has_no_snapshot_tag "$vmid"; then log "VM $vmid | Checagem: tag 'no_snapshot' → pulando."; return; fi
  if backup_global_running; then log "VM $vmid | Checagem: vzdump em execução no host → pulando."; return; fi

  local prelock; prelock="$(get_lock "$vmid" || true)"
  log "VM $vmid | Checagem: lock atual='${prelock:-none}'"
  if [[ "${prelock:-}" == "backup" ]]; then log "VM $vmid | Checagem: lock=backup → pulando."; return; fi

  local sname desc; sname="$(snapshot_name "$vmid")"
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

  post_snapshot_unlock_if_needed "$vmid"

  # dá 1s para a árvore de snapshots atualizar
  sleep 1

  # sempre roda a retenção e LOGA tudo
  cleanup_old_snapshots "$vmid" "$KEEP_COUNT"

  log "VM $vmid | Finalizado: $sname"
}

main(){
  local targets=()
  if [[ "${VMIDS[0]}" == "all" ]]; then mapfile -t targets < <(get_all_qemu_vmids)
  else targets=("${VMIDS[@]}"); fi

  log "Iniciando autosnap | prefix=${PREFIX} | timeout=${PING_TIMEOUT}s | vmstate=${VMSTATE} | keep=${KEEP_COUNT} | dryrun=${DRYRUN}"
  for vmid in "${targets[@]}"; do process_vm "$vmid"; done
  log "autosnap finalizado."
}
main
