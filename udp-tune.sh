#!/usr/bin/env bash
set -u

CONF=/etc/sysctl.d/99-udp-tuning.conf
PAGE=$(getconf PAGESIZE)

[ "$(id -u)" -eq 0 ] || { echo "Запустите от root: sudo $0"; exit 1; }

ok()   { printf '\033[32mOK\033[0m'; }
fail() { printf '\033[31mНЕ СОВПАДАЕТ\033[0m'; }
norm() { echo $*; }

ask() {
  local prompt=$1 def=$2 min=$3 max=$4 ans
  while true; do
    read -r -p "$prompt [$def]: " ans
    ans=${ans:-$def}
    if [[ $ans =~ ^[0-9]+$ ]] && [ "$ans" -ge "$min" ] && [ "$ans" -le "$max" ]; then
      echo "$ans"
      return
    fi
    echo "  нужно число от $min до $max" >&2
  done
}

check_applied() {
  local bad=0 line key want got
  [ -f "$CONF" ] || { echo "Файла $CONF нет: после перезагрузки настройки пропадут"; return 1; }
  echo "1. Значения: файл и ядро"
  while IFS= read -r line; do
    case "$line" in ''|\#*) continue;; esac
    key=$(norm "${line%%=*}")
    want=$(norm "${line#*=}")
    got=$(norm "$(sysctl -n "$key" 2>/dev/null)")
    if [ "$got" = "$want" ]; then
      printf '   %-28s %s  %s\n' "$key" "$(ok)" "$got"
    else
      printf '   %-28s %s  файл=%s ядро=%s\n' "$key" "$(fail)" "$want" "$got"
      bad=1
    fi
  done < "$CONF"
  return $bad
}

check_sockets() {
  local want
  want=$(sysctl -n net.core.rmem_default)
  echo "2. UDP-сокеты (большим считается буфер от $((want / 1048576)) МБ)"
  ss -uamnp | tail -n +2 | paste - - | awk -v want="$want" '
    {
      if (!match($0, /,rb[0-9]+/)) next
      rb = substr($0, RSTART + 3, RLENGTH - 3) + 0
      proc = "(без процесса)"
      if (match($0, /\(\("[^"]+"/)) proc = substr($0, RSTART + 3, RLENGTH - 4)
      if (rb >= want) big[proc]++; else small[proc]++
    }
    END {
      for (p in big)   printf "   %-20s большой буфер: %d\n", p, big[p]
      for (p in small) printf "   %-20s старый/малый буфер: %d\n", p, small[p]
    }'
}

check_memory() {
  local mem lo pr hi
  mem=$(awk '/^UDP:/ { for (i = 1; i <= NF; i++) if ($i == "mem") print $(i + 1) }' /proc/net/sockstat)
  read -r lo pr hi < /proc/sys/net/ipv4/udp_mem
  mem=${mem:-0}
  printf '3. Память под UDP: %d МБ из лимита %d МБ (%d%%)\n' \
    $((mem * PAGE / 1048576)) $((hi * PAGE / 1048576)) $((mem * 100 / hi))
}

check_errors() {
  local a b
  command -v nstat >/dev/null || { echo "4. nstat не найден, пропускаю"; return; }
  a=$(nstat -az UdpRcvbufErrors | awk '/UdpRcvbufErrors/ {print $2}')
  sleep 10
  b=$(nstat -az UdpRcvbufErrors | awk '/UdpRcvbufErrors/ {print $2}')
  echo "4. Ошибки приёма UDP за 10 с: $((b - a))  (0-50 норма, тысячи плохо)"
}

run_checks() {
  local rc=0
  check_applied || rc=$?
  check_sockets
  check_memory
  check_errors
  return $rc
}

if [ "${1:-}" = "--check" ]; then
  run_checks
  exit $?
fi

total_kb=$(awk '/^MemTotal/ {print $2}' /proc/meminfo)
detected=$(( (total_kb + 1048575) / 1048576 ))
echo "Определено ОЗУ: ~${detected} ГБ"
ram_gb=$(ask "Сколько ОЗУ на сервере, ГБ" "$detected" 1 4096)

if   [ "$ram_gb" -lt 8 ];   then rec_buf=8;  rec_share=15
elif [ "$ram_gb" -lt 32 ];  then rec_buf=16; rec_share=20
elif [ "$ram_gb" -lt 128 ]; then rec_buf=32; rec_share=25
else                             rec_buf=64; rec_share=25
fi
echo "Рекомендация для ${ram_gb} ГБ: буфер ${rec_buf} МБ на сокет, ${rec_share}% ОЗУ под UDP"

buf_mb=$(ask "Буфер одного UDP-сокета, МБ" "$rec_buf" 1 1024)
share=$(ask "Сколько % ОЗУ разрешить под весь UDP" "$rec_share" 5 60)

buf_bytes=$(( buf_mb * 1048576 ))
high=$(( ram_gb * 1073741824 / 100 * share / PAGE ))
pressure=$(( high * 3 / 4 ))
low=$(( high / 2 ))

echo
echo "Будет записано в $CONF:"
echo "   rmem_max / wmem_max / rmem_default / wmem_default = ${buf_mb} МБ"
echo "   udp_mem = $low $pressure $high страниц (лимит $((high * PAGE / 1048576)) МБ)"
echo "   netdev_max_backlog = 250000"
read -r -p "Применить? [y/N]: " yn
[[ $yn =~ ^[yYдД]$ ]] || { echo "Отменено"; exit 0; }

[ -f "$CONF" ] && cp "$CONF" "$CONF.bak.$(date +%s)"

cat > "$CONF" <<EOF
net.core.rmem_max = $buf_bytes
net.core.wmem_max = $buf_bytes
net.core.rmem_default = $buf_bytes
net.core.wmem_default = $buf_bytes
net.core.netdev_max_backlog = 250000
net.ipv4.udp_mem = $low $pressure $high
EOF

sysctl -p "$CONF" >/dev/null || echo "sysctl вернул ошибку, смотрите вывод выше"

echo
run_checks
rc=$?
echo
if [ "$rc" -eq 0 ]; then
  echo "Всё применено и сохранено в $CONF."
else
  echo "Есть несовпадения, смотрите строки НЕ СОВПАДАЕТ."
fi
echo "Сокеты со старым буфером получат новый только после перезапуска их процесса."
echo "Повторная проверка в любой момент: sudo $0 --check"
exit $rc
