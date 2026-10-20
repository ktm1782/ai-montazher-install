#!/bin/bash
# =============================================================================
# ИИ-монтажёр — мини-установщик (лежит в открытом репозитории, продукта внутри нет).
#
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/ktm1782/ai-montazher-install/main/install.sh)"
#
# Что делает:
#   1. Проверяет Mac и ставит git (через Homebrew или инструменты Apple).
#   2. Создаёт личный ключ доступа ~/.ssh/ai_montazher_ed25519 — он живёт только на этом Mac.
#   3. Записывает ключи серверов GitHub в свой файл ~/.ssh/ai_montazher_known_hosts.
#      ~/.ssh/config и ~/.ssh/known_hosts клиента не трогает: git ходит на GitHub отдельной
#      командой ssh (свой ключ, свой known_hosts, порт 443 — работает и там, где 22-й закрыт).
#   4. Показывает публичную половину ключа: её надо отправить Талгату в WhatsApp.
#   5. Ждёт, пока Талгат откроет доступ (только на скачивание), скачивает продукт
#      в ~/ai-montazher и запускает основной установщик ~/ai-montazher/install.sh.
#
# Совместим с системным bash 3.2. Повторный запуск безопасен: сделанное пропускается.
# Весь код — в функциях; выполняется только последняя строка (main), поэтому оборванная
# загрузка скрипта ничего не делает.
# =============================================================================
set -euo pipefail

if [ -z "${HOME:-}" ] || [ "${HOME:-}" = "/" ]; then
  printf '%s\n' "✗ Не задана домашняя папка (переменная HOME). Открой обычное окно программы «Терминал» и вставь команду там." >&2
  exit 1
fi

# --- Настройки ------------------------------------------------------------------
REPO_OWNER="ktm1782"
REPO_NAME="ai-montazher"
REPO_URL="git@ssh.github.com:$REPO_OWNER/$REPO_NAME.git"
SUPPORT_INTEL=0                 # держать в синхроне с install.sh продукта (под Intel нет onnxruntime 1.28.0)
MIN_MACOS_MAJOR=15              # держать в синхроне с install.sh: готовые пакеты Homebrew — только macOS 15+
MIN_FREE_GB=6
MAC_REQUIREMENT="Нужен Mac на чипе Apple (M1 и новее) с macOS 15 Sequoia или новее. Обновить бесплатно: меню  → Системные настройки → Основные → Обновление ПО."

KEY_FILE="$HOME/.ssh/ai_montazher_ed25519"
OWN_KNOWN_HOSTS="$HOME/.ssh/ai_montazher_known_hosts"
GITHUB_SSH_PORT=443
APP_DIR="$HOME/ai-montazher"
LOG_DIR="$HOME/Library/Logs/ai-montazher"
WAIT_TOTAL_SEC=1800             # ждать доступ до 30 минут
WAIT_STEP_SEC=10                # проверять каждые 10 секунд
NET_FAIL_LIMIT=3                # столько сетевых ошибок подряд — и стоп: дело не в доступе
CLT_WAIT_SEC=3600               # ждать инструменты Apple до 60 минут

# --- Состояние ----------------------------------------------------------------
STAMP="$(date +%Y-%m-%d_%H-%M-%S)"
LOG_FILE=""
LOG_FALLBACK=0
HAVE_TTY=0
BG_PID=""
TMP_FILE=""
STEP_NO=0
STEP_TOTAL=6
ACCESS_STATE=""

if [ -t 1 ]; then
  C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_RESET=$'\033[0m'
else
  C_BOLD=""; C_DIM=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_RESET=""
fi

log_line() {
  if [ -n "$LOG_FILE" ]; then
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" "$2" >>"$LOG_FILE" 2>/dev/null || true
  fi
}
say()  { printf '%s\n' "$*"; log_line INFO "$*"; }
ok()   { printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; log_line INFO "OK: $*"; }
skip() { printf '  %s✓ %s%s\n' "$C_DIM" "$*" "$C_RESET"; log_line INFO "ПРОПУСК: $*"; }
warn() { printf '  %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; log_line WARN "$*"; }
die() {
  printf '\n%s✗ %s%s\n' "$C_RED" "$*" "$C_RESET" >&2
  log_line ERROR "$*"
  if [ -n "$LOG_FILE" ]; then
    printf '  Журнал: %s\n  Если не получается — пришли этот файл Талгату.\n' "$LOG_FILE" >&2
  fi
  exit 1
}
step() {
  STEP_NO=$((STEP_NO + 1))
  printf '\n%s[%s/%s] %s%s\n' "$C_BOLD" "$STEP_NO" "$STEP_TOTAL" "$*" "$C_RESET"
  log_line INFO "=== Шаг $STEP_NO/$STEP_TOTAL: $*"
}

kill_tree() {
  # останавливает фоновую команду вместе с дочерними процессами (git → ssh и т. п.)
  local child
  for child in $(pgrep -P "$1" 2>/dev/null || true); do kill_tree "$child"; done
  kill "$1" 2>/dev/null || true
}

cleanup() {
  if [ -n "$BG_PID" ]; then kill_tree "$BG_PID"; fi
  if [ -n "$TMP_FILE" ] && [ -f "$TMP_FILE" ]; then rm -f "$TMP_FILE"; fi
}
on_interrupt() {
  printf '\n'
  warn "Остановлено. Запусти ту же команду ещё раз — сделанное повторно не делается."
  exit 130
}
trap cleanup EXIT
trap on_interrupt INT TERM HUP

fmt_elapsed() { printf '%d:%02d' $(($1 / 60)) $(($1 % 60)); }

run_logged() {
  # подпись, команда… → вывод в журнал, на экране индикатор с таймером
  local label="$1"; shift
  local start now pid rc=0
  log_line INFO "Запуск: $*"
  start=$(date +%s)
  "$@" >>"$LOG_FILE" 2>&1 </dev/null &
  pid=$!
  BG_PID=$pid
  if [ -t 1 ]; then
    while kill -0 "$pid" 2>/dev/null; do
      now=$(date +%s)
      printf '\r  … %s  %s ' "$label" "$(fmt_elapsed $((now - start)))"
      sleep 1
    done
    printf '\r\033[K'
  else
    printf '  … %s\n' "$label"
  fi
  wait "$pid" || rc=$?
  BG_PID=""
  log_line INFO "Код $rc: $label"
  return "$rc"
}

load_brew_env() {
  if [ -x /opt/homebrew/bin/brew ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [ -x /usr/local/bin/brew ]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi
}

ssh_command() {
  # изолированный ssh: без ~/.ssh/config клиента, только свой ключ и свой known_hosts
  printf 'ssh -F /dev/null -o IdentitiesOnly=yes -i "%s" -o "UserKnownHostsFile=%s" -o StrictHostKeyChecking=yes -o BatchMode=yes -o ConnectTimeout=20 -p %s' \
    "$KEY_FILE" "$OWN_KNOWN_HOSTS" "$GITHUB_SSH_PORT"
}

git_ssh() {
  # git без вопросов в Терминал: нет доступа — сразу ошибка, а не ожидание пароля
  GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="$(ssh_command)" git "$@"
}

# --- 0. Пользователь и журнал --------------------------------------------------------
check_not_root() {
  # до журнала: иначе папка журналов станет принадлежать root и сломает следующие запуски
  if [ "$(id -u)" = "0" ]; then die "Не запускай команду через sudo — вставь её как есть."; fi
}

init_log() {
  local tmp_base
  if mkdir -p "$LOG_DIR" 2>/dev/null && (umask 077; touch "$LOG_DIR/install-$STAMP.log") 2>/dev/null; then
    LOG_FILE="$LOG_DIR/install-$STAMP.log"
  else
    tmp_base="${TMPDIR:-/tmp}"
    LOG_FILE="${tmp_base%/}/ai-montazher-install-$STAMP.log"
    if ! (umask 077; touch "$LOG_FILE") 2>/dev/null; then
      LOG_FILE="/tmp/ai-montazher-install-$STAMP-$$.log"
      (umask 077; touch "$LOG_FILE")
    fi
    LOG_FALLBACK=1
  fi
  chmod 600 "$LOG_FILE" 2>/dev/null || true
  if { : </dev/tty; } 2>/dev/null; then HAVE_TTY=1; fi
}

warn_log_fallback() {
  if [ "$LOG_FALLBACK" = 1 ]; then
    warn "Папка журналов ~/Library/Logs/ai-montazher недоступна для записи (так бывает после запуска через sudo)."
    warn "Журнал пишу сюда: $LOG_FILE. Починить папку: sudo chown -R \"\$(whoami)\" ~/Library/Logs/ai-montazher"
  fi
}

# --- 1. Проверка Mac -------------------------------------------------------------
check_mac() {
  step "Проверка Mac"
  local ver major arch translated avail_kb avail_gb
  if [ "$(uname -s)" != "Darwin" ]; then die "Этот установщик только для Mac."; fi

  ver="$(sw_vers -productVersion 2>/dev/null || true)"
  major="${ver%%.*}"
  case "$major" in ''|*[!0-9]*) die "Не удалось узнать версию macOS. $MAC_REQUIREMENT" ;; esac
  if [ "$major" -lt "$MIN_MACOS_MAJOR" ]; then
    die "$MAC_REQUIREMENT
  Сейчас на этом Mac macOS $ver."
  fi
  ok "macOS $ver"

  arch="$(uname -m)"
  translated="$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)"
  if [ "$translated" = "1" ]; then
    die "Терминал запущен в режиме Rosetta (эмуляция Intel). Закрой его, в Finder → Программы → Утилиты → Терминал → «Свойства» сними галочку «Открыть в режиме Rosetta» и запусти команду снова."
  fi
  if [ "$arch" = "x86_64" ] && [ "$SUPPORT_INTEL" != 1 ]; then
    die "$MAC_REQUIREMENT
  Этот Mac — на процессоре Intel."
  fi
  ok "процессор: $arch"

  avail_kb="$(df -Pk "$HOME" | awk 'NR==2 {print $4}')"
  case "$avail_kb" in ''|*[!0-9]*) die "Не удалось узнать свободное место на диске." ;; esac
  avail_gb=$((avail_kb / 1024 / 1024))
  if [ "$avail_gb" -lt "$MIN_FREE_GB" ]; then
    die "Мало места на диске: свободно $avail_gb ГБ, нужно хотя бы $MIN_FREE_GB ГБ. Освободи место и запусти снова."
  fi
  ok "свободно на диске: $avail_gb ГБ"

  if ! curl -fsSI --max-time 20 --retry 2 -o /dev/null https://github.com >>"$LOG_FILE" 2>&1; then
    die "Нет интернета: не открывается github.com. Проверь подключение и запусти снова."
  fi
  ok "интернет есть"
}

# --- 2. git -----------------------------------------------------------------------
have_git() {
  local g
  g="$(command -v git 2>/dev/null || true)"
  if [ -z "$g" ]; then return 1; fi
  # без инструментов Apple /usr/bin/git — заглушка, которая только предлагает их поставить
  if [ "$g" = "/usr/bin/git" ] && ! xcode-select -p >/dev/null 2>&1; then return 1; fi
  "$g" --version >/dev/null 2>&1
}

install_homebrew() {
  local brew_script
  if [ "$HAVE_TTY" != 1 ]; then die "Нужен Терминал: Mac спросит пароль. Запусти команду в программе «Терминал»."; fi
  say ""
  say "  Ставлю Homebrew официальным установщиком (brew.sh) — вместе с ним Apple ставит git."
  warn "Mac попросит пароль от входа в систему. Символы при вводе не видны — это нормально: набери пароль и нажми Enter."
  warn "Потом Homebrew попросит нажать Enter (RETURN), чтобы начать."
  say ""
  brew_script="$(curl -fsSL --retry 3 https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
    || die "Не скачался официальный установщик Homebrew. Проверь интернет и запусти снова."
  log_line INFO "Запуск официального установщика Homebrew"
  if ! /bin/bash -c "$brew_script" 2>&1 | tee -a "$LOG_FILE"; then
    die "Homebrew не установился. Частая причина — у пользователя Mac нет прав администратора."
  fi
  load_brew_env
}

wait_for_clt() {
  local start now
  start=$(date +%s)
  while ! xcode-select -p >/dev/null 2>&1; do
    now=$(date +%s)
    if [ $((now - start)) -ge "$CLT_WAIT_SEC" ]; then
      printf '\n'
      die "Инструменты Apple так и не установились. Поставь их: в Терминале xcode-select --install, потом запусти команду снова."
    fi
    if [ -t 1 ]; then
      printf '\r  … жду установку инструментов Apple  %s ' "$(fmt_elapsed $((now - start)))"
    fi
    sleep 5
  done
  if [ -t 1 ]; then printf '\r\033[K'; fi
}

ensure_git() {
  step "git — программа, которой скачивается продукт"
  load_brew_env
  if have_git; then
    skip "git уже есть — пропускаю"
    return 0
  fi
  if ! command -v brew >/dev/null 2>&1; then
    install_homebrew
  else
    say "  Homebrew есть, а git нет — ставлю инструменты Apple (Command Line Tools)."
    xcode-select --install >>"$LOG_FILE" 2>&1 || true
    warn "Появится окно Apple — нажми «Установить» и согласись с условиями. Я подожду."
    wait_for_clt
  fi
  hash -r 2>/dev/null || true
  if ! have_git; then
    if ! xcode-select -p >/dev/null 2>&1; then
      xcode-select --install >>"$LOG_FILE" 2>&1 || true
      warn "Появится окно Apple — нажми «Установить» и согласись с условиями. Я подожду."
      wait_for_clt
    fi
  fi
  have_git || die "git так и не появился. Напиши Талгату."
  ok "git готов"
}

# --- 3. Ключ доступа -------------------------------------------------------------------
key_comment() {
  # комментарий ключа: ai-montazher-<имя Мака строчными, только a-z 0-9 и дефис>, всего не длиннее 40 символов.
  # Имени пользователя в нём нет; кириллица и пробелы в имени Мака заменяются дефисом.
  local name clean
  name="$(scutil --get LocalHostName 2>/dev/null || true)"
  if [ -z "$name" ]; then name="$(scutil --get ComputerName 2>/dev/null || true)"; fi
  clean="$(printf '%s' "$name" | LC_ALL=C tr 'A-Z' 'a-z' | LC_ALL=C tr -c 'a-z0-9-' '-' | LC_ALL=C tr -s '-' \
    | LC_ALL=C sed -e 's/^-*//' | cut -c1-27 | LC_ALL=C sed -e 's/-*$//')"
  if [ -z "$clean" ]; then clean="mac"; fi
  printf 'ai-montazher-%s' "$clean"
}

ensure_key() {
  step "Личный ключ доступа"
  local tmp
  if [ ! -d "$HOME/.ssh" ]; then
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
  fi
  if [ -f "$KEY_FILE" ]; then
    skip "ключ уже есть: $KEY_FILE — пропускаю"
  else
    ssh-keygen -t ed25519 -N "" -C "$(key_comment)" -f "$KEY_FILE" -q </dev/null >>"$LOG_FILE" 2>&1 \
      || die "Не удалось создать ключ доступа."
    ok "создал ключ $KEY_FILE (он остаётся только на этом Mac)"
  fi
  chmod 600 "$KEY_FILE"
  # публичную половину всегда пересобираю из приватной: старый .pub от другого ключа не покажется
  tmp="$KEY_FILE.pub.tmp.$$"
  if ! ssh-keygen -y -f "$KEY_FILE" >"$tmp" 2>>"$LOG_FILE"; then
    rm -f "$tmp"
    die "Ключ $KEY_FILE повреждён или защищён паролем. Переименуй его (например, в ai_montazher_ed25519.old) и запусти команду снова."
  fi
  mv -f "$tmp" "$KEY_FILE.pub"
  chmod 644 "$KEY_FILE.pub"
}

# --- 4. Ключи серверов GitHub -----------------------------------------------------------
known_hosts_intact() {
  # свой файл с прошлого запуска цел: ssh-keygen его читает, и в нём есть все три типа ключей
  local t
  [ -s "$OWN_KNOWN_HOSTS" ] || return 1
  ssh-keygen -l -f "$OWN_KNOWN_HOSTS" >>"$LOG_FILE" 2>&1 || return 1
  for t in ssh-ed25519 ecdsa-sha2-nistp256 ssh-rsa; do
    grep -q "^\[ssh\.github\.com\]:$GITHUB_SSH_PORT $t " "$OWN_KNOWN_HOSTS" || return 1
  done
}

known_hosts_fallback() {
  # причина → работать с файлом прошлого запуска, если он цел; иначе стоп
  if known_hosts_intact; then
    warn "$1 — беру ключи серверов GitHub, записанные в прошлый раз (~/.ssh/ai_montazher_known_hosts)"
    return 0
  fi
  die "$1. Проверь интернет и запусти команду снова."
}

ensure_known_hosts() {
  # свой файл ~/.ssh/ai_montazher_known_hosts — заново при каждом запуске из официального API
  # по HTTPS, с проверкой ssh-keygen -l. Общий ~/.ssh/known_hosts не трогаю.
  # API не ответил, а файл прошлого запуска цел — работаю с ним (с предупреждением).
  local meta keys k host_label="[ssh.github.com]:$GITHUB_SSH_PORT" tmp_base
  if ! meta="$(curl -fsSL --retry 3 --max-time 30 -H 'Accept: application/vnd.github+json' https://api.github.com/meta 2>>"$LOG_FILE")"; then
    known_hosts_fallback "Не удалось получить ключи серверов GitHub (api.github.com/meta)"
    return 0
  fi
  keys="$(printf '%s' "$meta" | grep -oE '"(ssh-ed25519|ecdsa-sha2-nistp256|ssh-rsa) [A-Za-z0-9+/=]+"' | tr -d '"' || true)"
  if [ -z "$keys" ]; then
    known_hosts_fallback "GitHub не прислал ключи своих серверов (api.github.com/meta)"
    return 0
  fi
  tmp_base="${TMPDIR:-/tmp}"
  TMP_FILE="$(mktemp "${tmp_base%/}/ai-montazher-hosts.XXXXXX")"
  while IFS= read -r k; do
    if [ -n "$k" ]; then printf '%s %s\n' "$host_label" "$k" >>"$TMP_FILE"; fi
  done <<EOF
$keys
EOF
  if ! ssh-keygen -l -f "$TMP_FILE" >>"$LOG_FILE" 2>&1; then
    rm -f "$TMP_FILE"
    TMP_FILE=""
    known_hosts_fallback "Ключи серверов GitHub пришли в непонятном виде"
    return 0
  fi
  if [ ! -d "$HOME/.ssh" ]; then mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"; fi
  chmod 644 "$TMP_FILE"
  mv -f "$TMP_FILE" "$OWN_KNOWN_HOSTS"
  TMP_FILE=""
  ok "ключи серверов GitHub записаны в ~/.ssh/ai_montazher_known_hosts"
}

setup_ssh() {
  step "Доступ к GitHub через порт 443"
  ensure_known_hosts
  skip "~/.ssh/config не трогаю: скачивание идёт отдельной командой ssh только с ключом ИИ-монтажёра"
}

# --- 5. Доступ от Талгата -------------------------------------------------------------------
access_check() {
  # → 0, если доступ есть; иначе ACCESS_STATE = denied | net | hostkey | other (по тексту ошибки)
  local out rc=0
  out="$(git_ssh ls-remote "$REPO_URL" HEAD 2>&1)" || rc=$?
  printf '%s\n' "$out" >>"$LOG_FILE"
  if [ "$rc" = 0 ]; then ACCESS_STATE="ok"; return 0; fi
  # Порядок важен. git после любой ошибки ssh дописывает «Could not read from remote repository» —
  # эта строка ничего не значит. Поэтому сначала подмена сервера и обрывы сети, потом отказ в доступе.
  case "$out" in
    *"Host key verification failed"*|*"REMOTE HOST IDENTIFICATION HAS CHANGED"*) ACCESS_STATE="hostkey" ;;
    *"Connection reset"*|*"Connection closed"*|*"kex_exchange_identification"*|\
    *"banner line contains invalid characters"*|*"Broken pipe"*|\
    *"Could not resolve hostname"*|*"timed out"*|*"Connection refused"*|\
    *"Network is unreachable"*|*"No route to host"*) ACCESS_STATE="net" ;;
    *"Permission denied (publickey"*|*"Repository not found"*) ACCESS_STATE="denied" ;;
    *) ACCESS_STATE="other" ;;
  esac
  return 1
}

stop_network_problem() {
  if [ "$ACCESS_STATE" = "hostkey" ]; then
    die "Не прошла проверка подлинности сервера GitHub (Host key verification failed). Ключ доступа здесь ни при чём: так бывает, когда сеть подменяет соединение (рабочий фильтр, общественный Wi-Fi). Подключись к другой сети — например, раздай интернет с телефона — и запусти команду снова."
  fi
  if [ "$ACCESS_STATE" = "other" ]; then
    die "GitHub отвечает непонятной ошибкой: это не «доступ не открыт» и не обрыв сети. Запусти команду ещё раз через пару минут; если повторится — пришли Талгату журнал."
  fi
  die "Не получается достучаться до GitHub через порт 443: сеть или фаервол режет соединение. Ключ доступа здесь ни при чём. Проверь интернет или подключись к другой сети — например, раздай интернет с телефона — и запусти команду снова."
}

wait_for_access() {
  step "Доступ к продукту"
  local pub copied=0 start now el i=0 net_fails=0 other_fails=0
  if access_check; then
    skip "доступ уже открыт — пропускаю"
    return 0
  fi
  case "$ACCESS_STATE" in net|hostkey) net_fails=1 ;; other) other_fails=1 ;; esac
  pub="$(cat "$KEY_FILE.pub")"
  if printf '%s' "$pub" | pbcopy 2>/dev/null; then copied=1; fi
  log_line INFO "Показан публичный ключ: $pub"
  printf '\n'
  if [ "$copied" = 1 ]; then
    printf '  %sОтправь эту строку Талгату в WhatsApp — она уже скопирована, просто вставь.%s\n' "$C_BOLD" "$C_RESET"
  else
    printf '  %sОтправь эту строку Талгату в WhatsApp — выдели её мышкой, скопируй (Cmd+C) и вставь в чат.%s\n' "$C_BOLD" "$C_RESET"
  fi
  printf '  Это не пароль: по ней Талгат откроет тебе доступ только на скачивание.\n\n'
  printf '%s\n\n' "$pub"
  start=$(date +%s)
  while :; do
    i=0
    while [ "$i" -lt "$WAIT_STEP_SEC" ]; do
      now=$(date +%s); el=$((now - start))
      if [ -t 1 ]; then
        printf '\r  ⏳ Жду, пока Талгат откроет доступ…  %s из %s (проверяю каждые %s с) ' \
          "$(fmt_elapsed "$el")" "$(fmt_elapsed "$WAIT_TOTAL_SEC")" "$WAIT_STEP_SEC"
      fi
      sleep 1
      i=$((i + 1))
    done
    if access_check; then
      if [ -t 1 ]; then printf '\r\033[K'; fi
      ok "доступ открыт"
      return 0
    fi
    # сеть и непонятные ошибки — стоп после трёх подряд; ждать имеет смысл только «доступ не открыт»
    case "$ACCESS_STATE" in
      net|hostkey) net_fails=$((net_fails + 1)); other_fails=0 ;;
      other) other_fails=$((other_fails + 1)); net_fails=0 ;;
      *) net_fails=0; other_fails=0 ;;
    esac
    if [ "$net_fails" -ge "$NET_FAIL_LIMIT" ] || [ "$other_fails" -ge "$NET_FAIL_LIMIT" ]; then
      printf '\n'
      stop_network_problem
    fi
    now=$(date +%s); el=$((now - start))
    if [ ! -t 1 ]; then say "  … всё ещё жду доступ ($(fmt_elapsed "$el"))"; fi
    if [ "$el" -ge "$WAIT_TOTAL_SEC" ]; then
      printf '\n'
      die "Доступ пока не открыт (ждал 30 минут). Когда Талгат напишет, что открыл доступ, запусти ту же команду ещё раз — ключ уже создан, отправлять его снова не нужно."
    fi
  done
}

# --- 6. Скачивание и запуск установщика ------------------------------------------------------------
origin_is_ours() {
  case "$1" in
    "git@ssh.github.com:$REPO_OWNER/$REPO_NAME.git"|"git@ssh.github.com:$REPO_OWNER/$REPO_NAME"|\
    "ssh://git@ssh.github.com:443/$REPO_OWNER/$REPO_NAME.git"|"ssh://git@ssh.github.com/$REPO_OWNER/$REPO_NAME.git"|\
    "git@github-ai-montazher:$REPO_OWNER/$REPO_NAME.git"|"git@github.com:$REPO_OWNER/$REPO_NAME.git"|\
    "https://github.com/$REPO_OWNER/$REPO_NAME.git"|"https://github.com/$REPO_OWNER/$REPO_NAME") return 0 ;;
  esac
  return 1
}

fetch_product() {
  step "Скачивание продукта в ~/ai-montazher"
  local url
  if [ -d "$APP_DIR/.git" ]; then
    url="$(git -C "$APP_DIR" remote get-url origin 2>/dev/null || true)"
    if ! origin_is_ours "$url"; then
      die "В папке $APP_DIR лежит другой репозиторий (${url:-адрес не задан}). Переименуй её (например, в ai-montazher-old) и запусти команду снова."
    fi
    if [ "$url" != "$REPO_URL" ]; then git -C "$APP_DIR" remote set-url origin "$REPO_URL"; fi
    git -C "$APP_DIR" config core.sshCommand "$(ssh_command)"
    if run_logged "обновляю продукт" git_ssh -C "$APP_DIR" pull --ff-only; then
      ok "продукт обновлён"
    else
      warn "не получилось скачать обновление — продолжаю с той версией, что уже есть (обновить потом: ~/ai-montazher/install.sh --update)"
    fi
  elif [ -e "$APP_DIR" ]; then
    die "Папка $APP_DIR уже есть, но это не копия репозитория. Переименуй её (например, в ai-montazher-old) и запусти команду снова."
  else
    run_logged "скачиваю продукт (git clone)" git_ssh clone "$REPO_URL" "$APP_DIR" \
      || die "Не получилось скачать продукт. Проверь интернет и запусти команду снова."
    # та же изолированная команда ssh — в настройки клона: на ней работает «обнови монтажёр»
    git -C "$APP_DIR" config core.sshCommand "$(ssh_command)"
    ok "продукт скачан"
  fi
  [ -f "$APP_DIR/install.sh" ] || die "В скачанном продукте нет install.sh. Напиши Талгату."
}

main() {
  check_not_root
  init_log
  log_line INFO "Мини-установщик ИИ-монтажёра, параметры: ${*:-нет}"
  printf '%sИИ-монтажёр — подготовка установки%s\n' "$C_BOLD" "$C_RESET"
  say "Журнал: $LOG_FILE"
  warn_log_fallback
  check_mac
  ensure_git
  ensure_key
  setup_ssh
  wait_for_access
  fetch_product
  printf '\n%sЗапускаю основной установщик…%s\n' "$C_BOLD" "$C_RESET"
  log_line INFO "exec $APP_DIR/install.sh ${*:-}"
  export AI_MONTAZHER_LOG_FILE="$LOG_FILE"   # один общий журнал на всю установку
  exec /bin/bash "$APP_DIR/install.sh" "$@"
}

main "$@"; exit $?
