#!/bin/bash
# ВОССТАНОВЛЕНИЕ СЕРВЕРА ОСТРОВКА ИЗ ПОЛНОГО РЕЗЕРВА
# Скрипт рассчитан на работу на слух: каждый шаг называет номер и говорит,
# что делает, ошибки объясняет словами и подсказывает, что делать дальше.
#
# Как запускать:
#     bash /root/ostrovok-nabor/ustanovit.sh
#       — скрипт спросит цифрой: 1 восстановить, 2 проверить, 0 отменить.
#
# Ключи:
#   --proverka   ничего не менять, только проверить набор и рассказать, что в нём
#   --otmenit    убрать всё, что было поставлено из набора, и вернуть прежние настройки
#   --poverh     разрешить восстановление поверх живого сервера
#   --modely     доставить тяжёлые библиотеки сайта (torch и прочее, ~5,5 ГБ)
#   --zdes       работать прямо в этом окне, не уходить в фон
#
# Журналы: восстановление — /root/vosstanovlenie.log, отмена — /root/otmena.log
# Снимок состояния до установки (нужен для отмены) — /root/ostrovok-do-ustanovki
set -u

NABOR=""
POVERH=0
MODELY=0
PROVERKA=0
ZDES=0
OTMENIT=0
VYBOR=""
FON="${VOSSTANOVLENIE_FON:-0}"
LOG=/root/vosstanovlenie.log
LOGO=/root/otmena.log
SNAP=/root/ostrovok-do-ustanovki
SKOLKO_ARGOV=$#

for arg in "$@"; do
  case "$arg" in
    --poverh)        POVERH=1 ;;
    --modely)        MODELY=1 ;;
    --proverka)      PROVERKA=1 ;;
    --zdes)          ZDES=1 ;;
    --otmenit|--otmena) OTMENIT=1 ;;
    -h|--pomosh)
      echo "Восстановление сервера Островка."
      echo "Запуск без ключей: bash ustanovit.sh"
      echo "  скрипт спросит цифру: 1 восстановить, 2 проверить, 0 отменить."
      echo ""
      echo "Можно и ключами:"
      echo "  1 — восстановить:        bash ustanovit.sh /root/ostrovok-nabor"
      echo "  2 — только проверить:    плюс --proverka"
      echo "  0 — отменить установку:  плюс --otmenit"
      echo "  поверх живого сервера:   плюс --poverh"
      echo "  тяжёлые библиотеки:      плюс --modely"
      exit 0 ;;
    -*) echo "Не понимаю ключ: $arg. Набери --pomosh, чтобы увидеть, какие есть."; exit 1 ;;
    *)  NABOR="$arg" ;;
  esac
done

govorit() { echo "$*"; }
probel()  { echo ""; }
shag()    { probel; echo "ШАГ $1 ИЗ $2. $3"; echo ""; }
umeret()  { probel; echo "ОШИБКА. $*"; echo "Работа остановлена."; echo "Журнал: $LOG"; exit 1; }
ladno()   { echo "  готово."; }

[ "$(id -u)" = 0 ] || umeret "Скрипт нужно запускать от root. Зайди под root и повтори."

# ---------- меню: запуск совсем без ключей ----------
if [ "$SKOLKO_ARGOV" = "0" ] && [ "$FON" = "0" ]; then
  NABOR="$(cd "$(dirname "$0")" && pwd)"
  probel
  govorit "ВОССТАНОВЛЕНИЕ СЕРВЕРА ОСТРОВКА"
  govorit "Папка набора: $NABOR"
  probel
  govorit "Что делаем?"
  govorit "  1 — восстановить сервер из набора"
  govorit "  2 — только проверить набор, ничего не меняя"
  govorit "  0 — отменить: убрать всё, что поставлено из набора, и вернуть прежние настройки"
  probel
  printf "Нажми цифру и Enter: "
  read -r VYBOR || VYBOR=""
  case "$VYBOR" in
    1) ;;
    2) PROVERKA=1 ;;
    0) OTMENIT=1 ;;
    *) probel; govorit "Не понял ответ «$VYBOR». Ничего не делаю."; exit 1 ;;
  esac
  probel
fi

# ---------- отмена установки ----------
otmena() {
  mkdir -p /root
  exec > >(tee -a "$LOGO") 2>&1

  probel
  govorit "ОТМЕНА УСТАНОВКИ. Начало $(date '+%d.%m.%Y %H:%M')"
  probel

  if [ ! -f "$SNAP/sostoyanie.txt" ]; then
    govorit "Снимка состояния до установки на этой машине нет."
    govorit "Значит набор сюда не ставили (или ставили прежней версией скрипта)."
    govorit "Убирать нечего, ничего не трогаю."
    exit 1
  fi

  govorit "Сейчас уберу всё, что поставил набор, и верну прежние настройки этой машины."
  govorit "Её учётки, пароли, вход по ssh и её службы вернутся такими, какими были до установки."
  probel
  govorit "Если передумал — нажми Ctrl+C прямо сейчас."
  govorit "Начинаю через десять секунд."
  sleep 10
  probel

  # --- 1. погасить службы, которых до установки не было ---
  govorit "1. Гашу службы, которые появились от набора."
  if [ -f "$SNAP/sluzhby-do.txt" ]; then
    for spisok in "$NABOR/sluzhby.txt" "$NABOR/rabotali.txt"; do
      [ -f "$spisok" ] || continue
      while read -r unit; do
        [ -n "$unit" ] || continue
        grep -qxF "$unit" "$SNAP/sluzhby-do.txt" 2>/dev/null && continue
        systemctl stop "$unit"    >/dev/null 2>&1 || true
        systemctl disable "$unit" >/dev/null 2>&1 || true
        govorit "   погашена: $unit"
      done < "$spisok"
    done
  else
    govorit "   списка прежних служб нет, пропускаю."
  fi
  systemctl daemon-reload >/dev/null 2>&1 || true
  ladno

  # --- 2. база ---
  probel
  govorit "2. База данных."
  if [ -f "$SNAP/baza-do.sql" ]; then
    if command -v mysql >/dev/null 2>&1; then
      systemctl start mariadb >/dev/null 2>&1 || systemctl start mysql >/dev/null 2>&1 || true
      for i in $(seq 1 40); do mysql -e 'select 1' >/dev/null 2>&1 && break; sleep 1; done
      if mysql -e 'select 1' >/dev/null 2>&1; then
        mysql < "$SNAP/baza-do.sql" && govorit "   прежняя база возвращена." || govorit "   база вернулась не целиком, проверь вручную."
      else
        govorit "   служба базы не поднялась, базу верни позже так:"
        govorit "   mysql < $SNAP/baza-do.sql"
      fi
    fi
  else
    govorit "   До установки базы на этой машине не было."
    govorit "   Базу, которую принёс набор, можно убрать так (если она больше не нужна):"
    govorit "   zstd -dc $NABOR/04-mariadb.sql.zst | grep -i '^CREATE DATABASE' | head"
    govorit "   Это только покажет имена, ничего не удалит."
  fi
  ladno

  # --- 3. вернуть папки ---
  probel
  govorit "3. Возвращаю папки, которые набор перезаписал или создал."
  while read -r p sost; do
    [ -n "${p:-}" ] || continue
    imya=$(echo "$p" | sed 's#^/##; s#/#_#g')
    fail="$SNAP/$imya.tar.zst"
    if [ "$sost" = "есть" ]; then
      if [ -f "$fail" ]; then
        tar -I zstd -xpf "$fail" --numeric-owner -C / && govorit "   возвращено: $p" || govorit "   не смог вернуть $p"
      else
        govorit "   $p был и раньше, снимка нет — не трогаю."
      fi
    else
      if [ -e "$p" ]; then
        rm -rf "$p" && govorit "   убрано (до установки этого не было): $p"
      fi
    fi
  done < "$SNAP/sostoyanie.txt"
  ladno

  # --- 4. пакеты ---
  probel
  govorit "4. Возвращаю список пакетов. Это самая долгая часть, до получаса."
  if [ -f "$SNAP/pakety-do.txt" ]; then
    export DEBIAN_FRONTEND=noninteractive
    dpkg --set-selections < "$SNAP/pakety-do.txt" || govorit "   часть строк пакетов пропущена"
    apt-get update -qq || true
    apt-get -y dselect-upgrade || govorit "   часть пакетов не снялась, продолжаю"
    ladno
  else
    govorit "   списка пакетов нет, пропускаю."
  fi

  # --- 5. итог ---
  probel
  systemctl daemon-reload >/dev/null 2>&1 || true
  govorit "ПРОВЕРЯЮ РЕЗУЛЬТАТ"
  sleep 2
  govorit "Портал Островка: $(systemctl is-active tt5@ostrovok 2>/dev/null) — так и должно быть, его здесь больше нет."
  govorit "Сайт Островка:   $(systemctl is-active ostrovok-web 2>/dev/null) — так и должно быть."
  probel
  govorit "ОТМЕНА ЗАВЕРШЕНА"
  probel
  govorit "Что осталось: отдельные файлы, которых у машины раньше не было, но их службы"
  govorit "уже выключены, и ни на что они не влияют. Ни один прежний файл не удалён."
  govorit "Снимок остаётся в $SNAP. Когда убедишься, что всё в порядке, его можно убрать:"
  govorit "    rm -rf $SNAP"
  exit 0
}

if [ "$OTMENIT" = "1" ]; then
  [ -z "$NABOR" ] && NABOR="$(cd "$(dirname "$0")" && pwd)"
  if [ ! -f "$NABOR/sluzhby.txt" ] && [ ! -d "$NABOR" ]; then
    probel
    govorit "Не могу найти папку набора: $NABOR"
    govorit "Запусти скрипт так: bash /root/ostrovok-nabor/ustanovit.sh --otmenit"
    exit 1
  fi
  otmena
fi

# ---------- папка набора по умолчанию ----------
[ -n "$NABOR" ] || NABOR="$(cd "$(dirname "$0")" && pwd)"
[ -d "$NABOR" ] || umeret "Папки $NABOR нет. Проверь, куда ты положил набор."

# ---------- проверка набора: работает и без восстановления ----------
proverit_nabor() {
  local oshibki=0 f
  govorit "Папка набора: $NABOR"
  probel
  govorit "Файлы набора:"
  for f in "$NABOR"/01-kostyak.tar.zst "$NABOR"/02-portal.tar.zst "$NABOR"/03-media.tar.zst "$NABOR"/04-mariadb.sql.zst; do
    if [ -f "$f" ]; then
      govorit "  есть: $(basename "$f"), $(du -h "$f" | cut -f1)"
    else
      govorit "  нет: $(basename "$f")"
      [ "$(basename "$f")" = "01-kostyak.tar.zst" ] && oshibki=$((oshibki+1))
    fi
  done
  probel
  if [ -f "$NABOR/SHA256SUMS" ]; then
    govorit "Проверяю целостность. Это долго и молча — так и должно быть."
    if ( cd "$NABOR" && sha256sum -c SHA256SUMS --quiet ); then
      govorit "  все архивы целы."
    else
      govorit "  ВНИМАНИЕ: часть архивов повреждена. Скачай набор заново."
      oshibki=$((oshibki+1))
    fi
  else
    govorit "Файла с контрольными суммами нет — целостность проверить не смогу."
  fi
  probel
  govorit "Хватит ли места на диске:"
  df -h / | tail -1 | awk '{print "  всего "$2", свободно "$4}'
  probel
  if [ "$oshibki" = 0 ]; then
    govorit "ИТОГ ПРОВЕРКИ: набор в порядке, можно восстанавливать."
    govorit "Убери ключ --proverka и запусти ту же команду снова."
  else
    govorit "ИТОГ ПРОВЕРКИ: набор неполный или повреждён. Восстанавливать нельзя."
  fi
}

if [ "$PROVERKA" = "1" ]; then
  proverit_nabor
  exit 0
fi

[ -f "$NABOR/01-kostyak.tar.zst" ] || umeret "В наборе нет главного файла 01-kostyak.tar.zst."

# --- защита от запуска поверх живого сервера ---
if [ "$POVERH" = "0" ] && systemctl is-active --quiet tt5@ostrovok 2>/dev/null; then
  probel
  govorit "ВНИМАНИЕ. На этой машине уже работает портал Островка."
  govorit "Восстановление перезапишет настройки, учётки и файлы каналов."
  govorit "Если это правда нужно, добавь ключ --poverh:"
  govorit "    bash $NABOR/ustanovit.sh $NABOR --poverh"
  exit 1
fi

# ---------- уход в фон, чтобы обрыв связи не убил восстановление ----------
if [ "$FON" != "1" ] && [ "$ZDES" = "0" ] && command -v systemd-run >/dev/null; then
  probel
  govorit "Запускаю восстановление в фоне, чтобы обрыв связи его не убил."
  systemd-run --unit=vosstanovlenie --collect --no-block \
      --property=Type=oneshot \
      --property=StandardOutput=append:$LOG \
      --property=StandardError=append:$LOG \
      --setenv=VOSSTANOVLENIE_FON=1 \
      /bin/bash "$0" "$@" >/dev/null 2>&1 \
    || { govorit "В фон уйти не получилось, работаю прямо здесь."; FON=1; }
  if [ "$FON" != "1" ]; then
    : > "$LOG" 2>/dev/null || true
    probel
    govorit "Работа пошла. Ждать от десяти минут до получаса."
    govorit "Ход восстановления можно слушать так:"
    govorit "    tail -n 20 $LOG"
    govorit "Когда закончится, последняя строка будет: ВОССТАНОВЛЕНИЕ ЗАВЕРШЕНО."
    govorit "Отменить всё это можно командой:"
    govorit "    bash $NABOR/ustanovit.sh --otmenit"
    exit 0
  fi
fi

# ниже — сама работа
exec >>"$LOG" 2>&1
ALLGO=10

shag 1 $ALLGO "Проверяю набор"
( cd "$NABOR" && sha256sum -c SHA256SUMS --quiet ) 2>/dev/null || umeret "Файлы набора повреждены. Скачай набор заново."
ladno

shag 2 $ALLGO "Ставлю инструмент распаковки"
export DEBIAN_FRONTEND=noninteractive
if command -v zstd >/dev/null; then ladno; else
  apt-get update -qq && apt-get install -y -qq zstd || umeret "Не смог поставить zstd. Проверь, есть ли выход в интернет."
  ladno
fi

# ---------- снимок того, что было до установки ----------
# Нужен для отмены: всё, что набор перезапишет или создаст, записывается сюда.
snimat_snimok() {
  local p imya svobodno
  svobodno=$(df --output=avail -m / 2>/dev/null | tail -1 | tr -d ' ')
  if [ -n "$svobodno" ] && [ "$svobodno" -lt 2000 ] 2>/dev/null; then
    govorit "  ВНИМАНИЕ: на диске меньше двух гигабайт свободных."
    govorit "  Снимок для отмены может не поместиться."
  fi

  rm -rf "$SNAP"
  mkdir -p "$SNAP"
  : > "$SNAP/sostoyanie.txt"

  cat > "$SNAP/.isklyuchit.txt" <<'KONEC'
/root/ostrovok-nabor
/root/ostrovok-do-ustanovki
/root/backups
/root/*.tar.zst
/root/*.tar.gz
/root/*.tgz
/root/*.log
/root/.cache
/root/.npm
/root/.debug
/home/tt
/usr/local/sbin/ostrovok-web/ml
/usr/local/sbin/ostrovok-web/golosa
/usr/local/sbin/ostrovok-web/voice
/usr/local/sbin/ostrovok-web/zvuki
/usr/local/sbin/ostrovok-diskoteka
/usr/local/lib/ollama
/usr/local/lib/radio-tts
KONEC

  for p in /etc /home /root /usr/local/bin /usr/local/sbin /usr/local/lib /usr/bin/tt5srv; do
    if [ -e "$p" ]; then
      echo "$p есть" >> "$SNAP/sostoyanie.txt"
      imya=$(echo "$p" | sed 's#^/##; s#/#_#g')
      govorit "  запоминаю: $p"
      tar -I zstd -cpf "$SNAP/$imya.tar.zst" --numeric-owner --one-file-system \
          -X "$SNAP/.isklyuchit.txt" "$p" 2>/dev/null || true
    else
      echo "$p нет" >> "$SNAP/sostoyanie.txt"
    fi
  done

  # портал ТимТолка запоминается отдельно: он большой, поэтому только факт
  if [ -e /home/tt ]; then
    echo "/home/tt есть" >> "$SNAP/sostoyanie.txt"
    govorit "  /home/tt был и раньше — при отмене я его не трону."
  else
    echo "/home/tt нет" >> "$SNAP/sostoyanie.txt"
  fi

  dpkg --get-selections > "$SNAP/pakety-do.txt" 2>/dev/null || true
  systemctl list-unit-files --state=enabled --no-legend 2>/dev/null \
      | awk '{print $1}' | sort -u > "$SNAP/sluzhby-do.txt" 2>/dev/null || true

  if command -v mysql >/dev/null 2>&1 && mysql -e 'select 1' >/dev/null 2>&1; then
    govorit "  запоминаю базу данных"
    mysqldump --all-databases --single-transaction > "$SNAP/baza-do.sql" 2>/dev/null || rm -f "$SNAP/baza-do.sql"
  fi

  date '+%d.%m.%Y %H:%M' > "$SNAP/vremya.txt" 2>/dev/null || true
}

shag 3 $ALLGO "Запоминаю, что было, чтобы можно было отменить"
tar -cpf /root/etc-do-vosstanovleniya.tar.zst /etc 2>/dev/null || true
snimat_snimok
govorit "  Снимок: $SNAP"
govorit "  Отмена потом — одной командой:"
govorit "      bash $NABOR/ustanovit.sh --otmenit"
ladno

shag 4 $ALLGO "Ставлю пакеты. Это самая долгая часть — до получаса. Это нормально, не завис."
if [ -f "$NABOR/pakety.txt" ]; then
  dpkg --set-selections < "$NABOR/pakety.txt" || govorit "  часть строк пакетов пропущена"
  apt-get update -qq || true
  apt-get -y dselect-upgrade || govorit "  часть пакетов не встала, продолжаю дальше"
  ladno
else
  govorit "  списка пакетов нет, пропускаю."
fi

shag 5 $ALLGO "Разворачиваю настройки, учётки, ботов и сайт"
tar -I zstd -xpf "$NABOR/01-kostyak.tar.zst" --numeric-owner -C / || umeret "Не смог развернуть 01-kostyak. Место на диске кончилось или файл повреждён."
ladno

shag 6 $ALLGO "Разворачиваю портал и файлы каналов"
if [ -f "$NABOR/02-portal.tar.zst" ]; then
  tar -I zstd -xpf "$NABOR/02-portal.tar.zst" --numeric-owner -C / || umeret "Не смог развернуть портал."
  ladno
else
  govorit "  файла портала нет, пропускаю."
fi

shag 7 $ALLGO "Разворачиваю музыку, голоса и звуки"
if [ -f "$NABOR/03-media.tar.zst" ]; then
  tar -I zstd -xpf "$NABOR/03-media.tar.zst" --numeric-owner -C / || umeret "Не смог развернуть музыку."
  ladno
else
  govorit "  файла с музыкой нет, пропускаю."
fi

shag 8 $ALLGO "Возвращаю базу сайта радио"
if [ -f "$NABOR/04-mariadb.sql.zst" ]; then
  systemctl start mariadb >/dev/null 2>&1 || true
  for i in $(seq 1 40); do mysql -e 'select 1' >/dev/null 2>&1 && break; sleep 1; done
  if mysql -e 'select 1' >/dev/null 2>&1; then
    zstd -dc "$NABOR/04-mariadb.sql.zst" | mysql || govorit "  база принялась не целиком, проверь вручную"
    ladno
  else
    govorit "  Служба базы не поднялась. Вернуть позже так:"
    govorit "  zstd -dc $NABOR/04-mariadb.sql.zst | mysql"
  fi
else
  govorit "  файла базы нет, пропускаю."
fi

shag 9 $ALLGO "Включаю и запускаю службы"
systemctl daemon-reload
if [ -f "$NABOR/sluzhby.txt" ]; then
  while read -r unit; do
    [ -n "$unit" ] || continue
    systemctl enable "$unit" >/dev/null 2>&1 || true
  done < "$NABOR/sluzhby.txt"
fi
PROPUSK='^(systemd-|dbus|ssh|cron|getty|serial-getty|user@|networkd|NetworkManager|systemd-resolved|systemd-journald|polkit|rsyslog|unattended|apparmor|multipathd|snapd|sudo|ufw|e2scrub|man-db|apt-daily|dpkg-db|fwupd|motd|update-notifier|cloud-init|chrony|ssh|nscd|logrotate|php|nginx|mariadb|mysql)'
if [ -f "$NABOR/rabotali.txt" ]; then
  while read -r unit; do
    [ -n "$unit" ] || continue
    if echo "$unit" | grep -Eq "$PROPUSK"; then
      systemctl restart "$unit" >/dev/null 2>&1 || systemctl start "$unit" >/dev/null 2>&1 || true
    else
      systemctl enable "$unit" >/dev/null 2>&1 || true
      systemctl restart "$unit" >/dev/null 2>&1 || systemctl start "$unit" >/dev/null 2>&1 || true
    fi
  done < "$NABOR/rabotali.txt"
fi
ladno

shag 10 $ALLGO "Тяжёлые библиотеки сайта"
if [ "$MODELY" = "1" ]; then
  REQ=/usr/local/sbin/ostrovok-web/requirements-ml.txt
  [ -f "$REQ" ] || REQ="$NABOR/requirements-ml.txt"
  if [ -f "$REQ" ]; then
    govorit "  качаю torch и прочее, около пяти гигабайт. Долго."
    python3 -m pip install --break-system-packages --target /usr/local/sbin/ostrovok-web/ml -r "$REQ" \
      || govorit "  часть не встала. Повтори с ключом --modely позже."
    ladno
  else
    govorit "  списка библиотек нет, придётся собирать вручную."
  fi
else
  govorit "  пропущено. Если сайт или озвучка ругаются на torch, запусти ту же команду с ключом --modely."
fi

# ---------- итог ----------
probel
govorit "ПРОВЕРЯЮ РЕЗУЛЬТАТ"
systemctl daemon-reload
sleep 3
PORTAL=$(systemctl is-active tt5@ostrovok 2>/dev/null)
SAYT=$(systemctl is-active ostrovok-web 2>/dev/null)
probel
govorit "Портал Островка: $PORTAL"
govorit "Сайт Островка:   $SAYT"
probel
SPISOK_FAILED=$(systemctl --failed --no-legend 2>/dev/null | awk '{print $1}' | head -20)
if [ -z "$SPISOK_FAILED" ]; then
  govorit "Провалившихся служб нет."
else
  govorit "Не поднялись такие службы:"
  echo "$SPISOK_FAILED" | while read -r u; do govorit "  $u"; done
  govorit "Это не всегда поломка: часть служб ждёт своего часа."
fi
probel
if [ "$PORTAL" = "active" ]; then
  govorit "ИТОГ: портал работает. Зайди в ТимТолк и проверь комнаты."
else
  govorit "ИТОГ: портал не поднялся. Посмотри журнал службы:"
  govorit "    journalctl -u tt5@ostrovok -n 40"
fi
probel
govorit "Если понадобится всё отменить и вернуть машину как было:"
govorit "    bash $NABOR/ustanovit.sh --otmenit"
probel
govorit "ВОССТАНОВЛЕНИЕ ЗАВЕРШЕНО"
