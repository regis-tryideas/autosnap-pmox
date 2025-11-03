Recursos principais
- Verificação automática do QEMU Guest Agent (QGA)
- Se o agente responder → snapshot com fsfreeze (consistente).
- Se não responder → snapshot “HOT” (sem pause/resume, sem freeze).
- Pula VMs com tag no_snapshot
- Pula VMs em backup ativo (lock=backup ou vzdump rodando)
- Desbloqueio automático caso a VM fique locked: snapshot ou suspended
- Retenção automática → mantém apenas os últimos N snapshots
- Compatível com VMs em cluster (qm listsnapshot funciona em qualquer nó)
- Logs detalhados de todas as checagens e ações
- Dry-run mode para testar sem criar ou apagar snapshots

Sintaxe
./autosnap-pmox.sh [opções] all [KEEP] 

./autosnap-pmox.sh [opções] <vmid> [<vmid> ...] [KEEP]


Cria snapshots para todas as VMs, mantendo 24 mais recentes:

/root/autosnap.sh all 24


Cria snapshot apenas para VM 101, mantendo os 2 últimos:

/root/autosnap.sh 101 2


Executa em modo de teste (dry-run):

/root/autosnap.sh --dry-run 101 2


Personaliza o prefixo e aumenta o timeout:

/root/autosnap.sh --prefix nightly --timeout 30 all 12
