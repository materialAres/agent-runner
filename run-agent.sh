#!/usr/bin/env bash
# Orchestratore: un task per sessione (contesto fresco), verifiche e commit a cura dello script.
# Messaggio di commit: l'agente lo propone in un file (Conventional Commits), lo script lo valida
# e ci aggiunge il trailer "Task: <id>", su cui si basa il riconoscimento dei task già fatti.
set -uo pipefail

WORKDIR="${WORKDIR:-/workspace}"
LOG_DIR="${LOG_DIR:-/logs}"
ROADMAP="${ROADMAP:-docs/roadmap-en.md}"
CHANGELOG="${CHANGELOG:-docs/changelog.md}"
INSTRUCTIONS="${INSTRUCTIONS:-.github/copilot-instructions.md}"
START_TASK="${START_TASK:-M2.T9}"
SKIP_TASKS="${SKIP_TASKS:-}"
MODEL="${MODEL:-}"                       # es. openrouter/<id-modello>
INSTALL_CMD="${INSTALL_CMD:-bun install --frozen-lockfile}"
CHECK_CMD="${CHECK_CMD:-bun run compile && bun run lint && bun run test && bun run build:firefox && bun run build}"
REQUIRE_CHANGELOG_ID="${REQUIRE_CHANGELOG_ID:-1}"
COMMIT_TYPES="${COMMIT_TYPES:-feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert}"
COMMIT_SUBJECT_MAX="${COMMIT_SUBJECT_MAX:-72}"
REQUIRE_COMMIT_MSG="${REQUIRE_COMMIT_MSG:-0}"  # 1 = messaggio dell'agente obbligatorio, 0 = fallback dalla roadmap
COMMIT_MSG_FILE="${COMMIT_MSG_FILE:-$LOG_DIR/COMMIT_MSG.txt}"  # fuori dal repo: non finisce in stage/commit
MAX_TASKS="${MAX_TASKS:-50}"
MAX_RETRIES="${MAX_RETRIES:-2}"          # tentativi extra dopo il primo
MAX_CONSECUTIVE_FAILS="${MAX_CONSECUTIVE_FAILS:-2}"
TASK_TIMEOUT="${TASK_TIMEOUT:-45m}"
CHECK_TIMEOUT="${CHECK_TIMEOUT:-20m}"
PUSH="${PUSH:-0}"
NTFY_URL="${NTFY_URL:-}"

cd "$WORKDIR" || { echo "WORKDIR non trovato: $WORKDIR"; exit 1; }

log()    { echo "[$(date '+%F %T')] $*" | tee -a "$LOG_DIR/run.log"; }
notify() { [ -n "$NTFY_URL" ] && curl -fsS -m 10 -d "$1" "$NTFY_URL" >/dev/null 2>&1 || true; }
die()    { log "ERRORE: $*"; notify "agente: $*"; exit 1; }

list_tasks() {
  grep -E '^\|[[:space:]]*M[0-9]+\.T[0-9]+[a-z]?[[:space:]]*\|' "$ROADMAP" \
    | sed -E 's/^\|[[:space:]]*([^[:space:]|]+).*/\1/' | awk '!seen[$0]++'
}

# Un task è done se un commit lo dichiara nel trailer "Task: <id>" (formato nuovo)
# o nel vecchio subject "<id>: task completato dall'agente" (commit storici).
is_done() {
  git log --format='%s%n%b' | grep -qxF "Task: $1" && return 0
  git log --format=%s | grep -qxF "$1: task completato dall'agente"
}

pending_tasks() {
  local started=0 id
  for id in $(list_tasks); do
    if [ "$started" = 0 ]; then
      [ "$id" = "$START_TASK" ] && started=1 || continue
    fi
    case " $SKIP_TASKS " in *" $id "*) continue;; esac
    is_done "$id" || echo "$id"
  done
}

if [ "${1:-}" = "--list" ]; then pending_tasks; exit 0; fi

# File di messaggio visibile all'agente: se non esiste lo creo io (UID 1000), perché
# altrimenti docker lo creerebbe come root e l'agente non potrebbe scriverci.
COMMIT_MSG_FILE="${COMMIT_MSG_FILE:-$LOG_DIR/COMMIT_MSG.txt}"
[ -e "$COMMIT_MSG_FILE" ] || : > "$COMMIT_MSG_FILE" 2>/dev/null || true

# L'agente a volte non riesce a scrivere nel path indicato e ripiega su /tmp: se il file
# atteso è vuoto ma esiste /tmp/COMMIT_MSG.txt, lo uso.
commit_msg_candidate() {
  local f="$1"
  if [ -s "$f" ]; then printf '%s' "$f"; return 0; fi
  if [ "$f" != /tmp/COMMIT_MSG.txt ] && [ -s /tmp/COMMIT_MSG.txt ]; then
    printf '%s' /tmp/COMMIT_MSG.txt
  else
    printf '%s' "$f"
  fi
}

# Titolo del task dalla tabella della roadmap (per il messaggio di fallback).
task_title() {
  local id="$1" esc
  esc=$(printf '%s' "$id" | sed 's/\./\\./g')
  sed -nE "s/^\|[[:space:]]*${esc}[[:space:]]*\|([^|]*)\|.*/\1/p" "$ROADMAP" \
    | head -n1 | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]+/ /g' \
    | sed -E 's/`//g; s/—/-/g'
}

# Normalizza il messaggio proposto dall'agente: rimuove eventuali fence markdown,
# righe "Commit message:" e righe vuote. Stampa il messaggio (0 righe se il file non esiste).
clean_commit_msg() {
  local f="$1"
  [ -s "$f" ] || return 0
  sed -E 's/^[[:space:]]*```.*$//' "$f" \
    | sed -E '/^[Cc]ommit[[:space:]]+message[[:space:]]*:/d' \
    | sed -E 's/[[:space:]]+$//' \
    | awk 'NF || started { print; started = 1 }' \
    | awk '{ lines[NR] = $0 } END { last = NR; while (last > 0 && lines[last] == "") last--; for (i = 1; i <= last; i++) print lines[i] }'
}

# Taglia il testo alla lunghezza massima, preferendo un confine di parola.
truncate_text() {
  local s="$1" max="$2" cut
  [ "${#s}" -le "$max" ] && { printf '%s' "$s"; return 0; }
  cut="${s:0:max}"
  case "$cut" in *" "*) cut="${cut% *}";; esac
  printf '%s' "$cut"
}

# Valida (Conventional Commits) e imposta COMMIT_MSG, o ritorna 1 con FAIL_REASON.
# Imposta una variabile globale (non stampa su stdout) perché gira nella stessa shell del
# chiamante: così FAIL_REASON resta visibile al ciclo dei retry.
build_commit_msg() {
  local id="$1" file="$2" msg subject body fallback esc from_fallback=0 prefix desc
  file=$(commit_msg_candidate "$file")
  msg=$(clean_commit_msg "$file")
  subject=$(printf '%s\n' "$msg" | head -n1)
  body=$(printf '%s\n' "$msg" | tail -n +2)
  # Toglie le righe vuote in coda al corpo
  if [ -n "$body" ]; then
    body=$(printf '%s\n' "$body" | awk '{ l[NR] = $0 } END { last = NR; while (last > 0 && l[last] == "") last--; for (i = 1; i <= last; i++) print l[i] }')
  fi

  if [ -z "$subject" ]; then
    [ "$REQUIRE_COMMIT_MSG" = 1 ] && {
      FAIL_REASON="Non hai scritto il messaggio di commit in $COMMIT_MSG_FILE (formato Conventional Commits)."
      return 1
    }
    log "Nessun messaggio in $COMMIT_MSG_FILE: uso il titolo del task dalla roadmap"
    fallback=$(task_title "$id")
    subject="chore($id): ${fallback:-task completato}"
    from_fallback=1
  fi

  # Normalizza le varianti più comuni: tipo maiuscolo e spazio prima dello scope.
  subject=$(printf '%s' "$subject" | sed -E 's/^([A-Za-z]+)[[:space:]]+\(/\1(/; s/^([A-Za-z]+)/\L\1/')

  # L'ID può stare anche nello scope (es. "feat(M2.T13b): ..."), quindi lo cerco in tutto il
  # subject con un confine di parola per non confondere M2.T1 con M2.T10.
  esc=$(printf '%s' "$id" | sed 's/\./\\./g')
  if ! printf '%s' "$subject" | grep -qE "${esc}([^0-9A-Za-z]|\$)"; then
    log "Il subject non cita $id: lo antepongo"
    case "$subject" in
      *": "*|*":") subject="${subject%%: *}: $id ${subject#*: }" ;;
      *) subject="chore($id): $subject" ;;
    esac
  fi

  if ! printf '%s' "$subject" | grep -qE "^($COMMIT_TYPES)(\([^)]+\))?!?: .+"; then
    FAIL_REASON="Il messaggio di commit non segue Conventional Commits (tipo valido, ':', spazio, descrizione): '$subject'."
    return 1
  fi
  if [ "${#subject}" -gt "$COMMIT_SUBJECT_MAX" ]; then
    # Se la descrizione è troppo lunga la tronco (capita con i titoli della roadmap),
    # ma un messaggio scritto dall'agente troppo lungo resta un errore da correggere.
    if [ "$from_fallback" = 1 ]; then
      prefix="${subject%%: *}: "
      desc="${subject#*: }"
      subject="${prefix}$(truncate_text "$desc" $((COMMIT_SUBJECT_MAX - ${#prefix})))"
      log "Subject troncato a $COMMIT_SUBJECT_MAX caratteri: '$subject'"
    else
      FAIL_REASON="Il subject del commit supera $COMMIT_SUBJECT_MAX caratteri (${#subject})."
      return 1
    fi
  fi

  COMMIT_MSG="$(printf '%s\n' "$subject"; [ -n "$body" ] && printf '\n%s\n' "$body"; printf '\nTask: %s\n' "$id")"
}

# ---------- Controlli iniziali ----------
mkdir -p "$LOG_DIR" 2>/dev/null && [ -w "$LOG_DIR" ] || die "LOG_DIR non scrivibile ($LOG_DIR): monta un volume su /logs"
[ -n "$MODEL" ] || die "imposta MODEL (es. openrouter/<id-modello>)"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "$WORKDIR non è un repo git"
branch=$(git rev-parse --abbrev-ref HEAD)
case "$branch" in main|master|develop|release*) die "rifiuto di lavorare sul branch '$branch'";; esac
[ -z "$(git status --porcelain)" ] || die "working tree non pulito: committa o scarta le modifiche prima"
list_tasks | grep -qx "$START_TASK" || die "START_TASK $START_TASK non trovato in $ROADMAP"
[ -d node_modules ] || { log "Installo dipendenze: $INSTALL_CMD"; bash -c "$INSTALL_CMD" >"$LOG_DIR/install.log" 2>&1 || die "install fallita (vedi install.log)"; }
git status --porcelain | grep -q . && die "l'install ha modificato file tracciati (es. lockfile): committali e rilancia"

build_prompt() {
  local id="$1" note="$2"
  cat <<EOF
Stai lavorando su un progetto già avviato, in una sessione isolata: non hai memoria di lavori precedenti, tutto il contesto sta nei file del repository.

Task da completare in questa sessione: $id (e SOLO questo).

Prima di scrivere codice:
1. Leggi $INSTRUCTIONS: contiene le istruzioni di lavoro del progetto (principi di design, organizzazione del codice, manutenibilità, aggiornamento del changelog, strategie di testing, ecc.). Seguile alla lettera.
2. Leggi in $ROADMAP la specifica completa del task $id e le sue eventuali dipendenze.
3. Leggi $CHANGELOG per sapere cosa è già stato completato ed esplora il codice reale: non presumere che qualcosa esista o funzioni, verificalo.

Durante il lavoro:
- Implementa solo $id. Non anticipare né modificare altri task.
- Aggiungi o aggiorna i test come previsto dalle strategie di testing del progetto.
- Alla fine aggiorna $CHANGELOG come indicato in $INSTRUCTIONS, citando esplicitamente l'ID $id.
- Scrivi in $COMMIT_MSG_FILE (percorso assoluto, fuori dal repository) il messaggio di commit del lavoro svolto, seguendo Conventional Commits:
  * prima riga: \`<tipo>(<scope>): <descrizione sintetica in inglese, imperativo, minuscola, senza punto finale>\`;
  * tipi ammessi: $COMMIT_TYPES;
  * scope consigliato: $id;
  * massimo $COMMIT_SUBJECT_MAX caratteri e deve citare $id;
  * riga vuota e poi un breve corpo (1-3 righe) con il "cosa" e il "perché", non il "come";
  * il file deve contenere solo il messaggio, senza fence markdown, virgolette o commenti.
  * se non riesci a scrivere lì, usa /tmp/COMMIT_MSG.txt (l'orchestratore legge anche quello).
  * Esempio:
    feat($id): add malus on blocked site navigation

    Apply progressive character deletion when a blocked domain is visited
    during an active focus session.
- NON eseguire git commit, push, reset o clean: commit e verifiche li gestisce l'orchestratore.
- Se il task è bloccato o ambiguo, non inventare: descrivi il problema nel tuo ultimo messaggio e fermati.

Al termine esegui tu stesso le verifiche del progetto ($CHECK_CMD) e riassumi in poche righe cosa hai fatto.
$note
EOF
}

# Imposta FAIL_REASON e ritorna 1 se qualcosa non va
verify() {
  local id="$1" logf="$2"
  FAIL_REASON=""
  if git status --porcelain --untracked-files=all | awk '{print $NF}' \
       | grep -E '(^|/)\.env(\..*)?$' | grep -vqE '\.env\.example$'; then
    FAIL_REASON="Sono stati creati/modificati file .env: non devi toccarli."; return 1
  fi
  if ! timeout -k 30s "$CHECK_TIMEOUT" bash -c "$CHECK_CMD" >"$logf" 2>&1; then
    FAIL_REASON="Le verifiche automatiche ($CHECK_CMD) sono fallite. Ultimo output:
$(tail -n 60 "$logf")"; return 1
  fi
  if [ "$REQUIRE_CHANGELOG_ID" = 1 ]; then
    local esc; esc=$(printf '%s' "$id" | sed 's/\./\\./g')
    if ! git diff --cached -U0 -- "$CHANGELOG" | grep -E '^\+' | grep -vE '^\+\+\+' \
         | grep -qE "${esc}([^0-9A-Za-z]|\$)"; then
      FAIL_REASON="Non hai aggiunto a $CHANGELOG una voce che cita $id: aggiornalo come da istruzioni."; return 1
    fi
  fi
  return 0
}

run_task() {
  local id="$1" base attempt=0 note="" rc
  base=$(git rev-parse HEAD)
  while [ "$attempt" -le "$MAX_RETRIES" ]; do
    attempt=$((attempt+1))
    log "== $id: tentativo $attempt"
    rm -f "$COMMIT_MSG_FILE" /tmp/COMMIT_MSG.txt
    timeout -k 30s "$TASK_TIMEOUT" opencode run --standalone --auto -m "$MODEL" \
      "$(build_prompt "$id" "$note")" </dev/null >"$LOG_DIR/$id.try$attempt.agent.log" 2>&1
    rc=$?; log "agente terminato (exit $rc)"

    if git add -A && git diff --cached --quiet; then
      FAIL_REASON="Non hai prodotto alcuna modifica."
    elif verify "$id" "$LOG_DIR/$id.try$attempt.check.log"; then
      if build_commit_msg "$id" "$COMMIT_MSG_FILE"; then
        if git commit -q -F - <<<"$COMMIT_MSG"; then
          log "OK $id -> $(git rev-parse --short HEAD) — $(printf '%s' "$COMMIT_MSG" | head -n1)"
          [ "$PUSH" = 1 ] && { git push -q origin HEAD || log "ATTENZIONE: push fallito"; }
          return 0
        fi
        FAIL_REASON="Il commit è stato rifiutato (hook di pre-commit?)."
      fi
    fi
    log "KO $id: ${FAIL_REASON%%$'\n'*}"
    note="
ATTENZIONE: il tentativo precedente non è andato a buon fine. Le modifiche sono ancora nel working tree: correggi, non ripartire da zero.
$FAIL_REASON"
    git reset -q   # toglie dallo stage, tiene le modifiche per il retry
  done
  log "Ripristino a $base (task $id abbandonato)"
  rm -f "$COMMIT_MSG_FILE" /tmp/COMMIT_MSG.txt
  git reset -q --hard "$base" && git clean -fdq
  return 1
}

# ---------- Ciclo principale ----------
done_n=0; fails=0
for id in $(pending_tasks); do
  [ -e "$LOG_DIR/STOP" ] && { log "File STOP trovato: mi fermo"; notify "agente fermato da STOP"; exit 0; }
  [ "$done_n" -ge "$MAX_TASKS" ] && { log "MAX_TASKS raggiunto"; notify "agente: MAX_TASKS raggiunto"; exit 0; }
  if run_task "$id"; then done_n=$((done_n+1)); fails=0
  else
    fails=$((fails+1))
    [ "$fails" -ge "$MAX_CONSECUTIVE_FAILS" ] && die "$fails task consecutivi falliti (ultimo: $id)"
  fi
done
log "Nessun altro task: completati $done_n in questa esecuzione"
notify "agente: finito, $done_n task completati"
