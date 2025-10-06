#!/bin/sh
# DNS Speed Test (POSIX uyumlu, manuel TR ay adı çeviri, parametreli timeout, log + özet)

SERVERS="
1.1.1.1|Cloudflare (Primary)
1.0.0.1|Cloudflare (Secondary)
45.90.28.0|NextDNS (Primary)
45.90.30.0|NextDNS (Secondary)
9.9.9.9|Quad9 (Primary)
149.112.112.112|Quad9 (Secondary)
8.8.8.8|Google (Primary)
8.8.4.4|Google (Secondary)
76.76.2.0|ControlD (Primary)
76.76.10.0|ControlD (Secondary)
94.140.14.14|AdGuard (Primary)
94.140.15.15|AdGuard (Secondary)
208.67.222.222|OpenDNS (Primary)
208.67.220.220|OpenDNS (Secondary)
185.228.168.9|CleanBrowsing (Primary)
185.228.169.9|CleanBrowsing (Secondary)
156.154.70.1|Neustar (Primary)
156.154.71.1|Neustar (Secondary)
"

# ── Parametreler ────────────────────────────────────────────────────────────────
TIMEOUT=${1:-1}      # saniye (örn: ./dns-speed-test.sh 2)
QUERIES=15           # her sunucu için sorgu sayısı
SERVER_COUNT=$(echo "$SERVERS" | grep -c "|")

# ── Log ayarları ────────────────────────────────────────────────────────────────
LOG_DIR="./dns-results"
mkdir -p "$LOG_DIR"
STAMP=$(date +"%Y%m%d-%H%M%S")
RESULT_FILE="$LOG_DIR/dns-test-$STAMP.txt"
TMP_FILE=$(mktemp)

# ── Manuel TR ay adı çevirici (locale gerektirmez) ─────────────────────────────
format_tr_date() {
  # Girdi: "06 October 2025 19:31:26" gibi
  DATE_RAW="$1"
  MONTH_EN=$(echo "$DATE_RAW" | awk '{print $2}')
  case "$MONTH_EN" in
    January)   MONTH_TR="Ocak" ;;
    February)  MONTH_TR="Şubat" ;;
    March)     MONTH_TR="Mart" ;;
    April)     MONTH_TR="Nisan" ;;
    May)       MONTH_TR="Mayıs" ;;
    June)      MONTH_TR="Haziran" ;;
    July)      MONTH_TR="Temmuz" ;;
    August)    MONTH_TR="Ağustos" ;;
    September) MONTH_TR="Eylül" ;;
    October)   MONTH_TR="Ekim" ;;
    November)  MONTH_TR="Kasım" ;;
    December)  MONTH_TR="Aralık" ;;
    *)         MONTH_TR="$MONTH_EN" ;;
  esac
  # İlk bulunan İngilizce ayı Türkçe karşılığıyla değiştir
  echo "$DATE_RAW" | sed "s/$MONTH_EN/$MONTH_TR/"
}

echo "🔍 DNS hız testi başlıyor ($SERVER_COUNT sunucu, $QUERIES sorgu / sunucu, timeout=${TIMEOUT}s)..."
echo

# ── Test döngüsü ────────────────────────────────────────────────────────────────
echo "$SERVERS" | while IFS="|" read -r IP NAME; do
  [ -z "$IP" ] && continue
  TOTAL=0
  COUNT=0
  printf "⏳ Test ediliyor → %s [%s] ... " "$NAME" "$IP"
  i=1
  while [ $i -le "$QUERIES" ]; do
    TIME=$(timeout "$TIMEOUT" dig google.com @"$IP" +stats +time="$TIMEOUT" 2>/dev/null | grep "Query time" | awk '{print $4}')
    if [ -n "$TIME" ]; then
      TOTAL=$((TOTAL + TIME))
      COUNT=$((COUNT + 1))
    fi
    i=$((i + 1))
  done
  if [ "$COUNT" -gt 0 ]; then
    AVG=$((TOTAL / COUNT))
    printf "✅ Ortalama: %s ms (%s/%s yanıt)\n" "$AVG" "$COUNT" "$QUERIES"
  else
    AVG=9999
    printf "❌ Yanıt yok (timeout)\n"
  fi
  echo "$AVG|$IP|$NAME" >> "$TMP_FILE"
done

# ── Tablo ve log yazımı ────────────────────────────────────────────────────────
{
  echo "===== DNS Hız Sonuçları ($STAMP) ====="
  printf "%-18s %-15s %s\n" "Avg (ms)" "IP" "DNS Name"
  printf "%-18s %-15s %s\n" "--------" "--------------" "----------------"
  sort -t"|" -nrk1 "$TMP_FILE" | while IFS="|" read -r AVG IP NAME; do
    printf "%-18s %-15s %s\n" "$AVG" "$IP" "$NAME"
  done
} | tee "$RESULT_FILE"

# ── En iyi 2'liyi seç ──────────────────────────────────────────────────────────
BEST=$(sort -t"|" -nk1 "$TMP_FILE" | head -n 2)
BEST1_IP=$(echo "$BEST" | head -n1 | awk -F"|" '{print $2}')
BEST1_NAME=$(echo "$BEST" | head -n1 | awk -F"|" '{print $3}')
BEST1_AVG=$(echo "$BEST" | head -n1 | awk -F"|" '{print $1}')
BEST2_IP=$(echo "$BEST" | tail -n1 | awk -F"|" '{print $2}')
BEST2_NAME=$(echo "$BEST" | tail -n1 | awk -F"|" '{print $3}')
BEST2_AVG=$(echo "$BEST" | tail -n1 | awk -F"|" '{print $1}')

{
  echo
  echo "🏁 En İyi DNS Çifti:"
  echo "Primary DNS   → $BEST1_NAME [$BEST1_IP] (${BEST1_AVG} ms)"
  echo "Secondary DNS → $BEST2_NAME [$BEST2_IP] (${BEST2_AVG} ms)"
} | tee -a "$RESULT_FILE"

rm -f "$TMP_FILE"

echo
echo "📦 Sonuç kaydedildi: $RESULT_FILE"

# ── Son 5 testin özet karşılaştırması (locale'siz TR ay) ───────────────────────
echo
echo "📈 Son 5 testin özet karşılaştırması:"
echo "-----------------------------------"

ls -t "$LOG_DIR"/dns-test-*.txt 2>/dev/null | head -n 5 | while read -r FILE; do
  RAW_TS=$(basename "$FILE" .txt | cut -d"-" -f3-)
  DATE_PART=$(echo "$RAW_TS" | cut -c1-8)
  TIME_PART=$(echo "$RAW_TS" | cut -c10-15)
  YEAR=$(echo "$DATE_PART" | cut -c1-4)
  MONTH=$(echo "$DATE_PART" | cut -c5-6)
  DAY=$(echo "$DATE_PART" | cut -c7-8)
  HOUR=$(echo "$TIME_PART" | cut -c1-2)
  MIN=$(echo "$TIME_PART" | cut -c3-4)
  SEC=$(echo "$TIME_PART" | cut -c5-6)
  # ISO → İngilizce ay adlı tarih üret
  DATE_RAW=$(date -d "$YEAR-$MONTH-$DAY $HOUR:$MIN:$SEC" +"%d %B %Y %H:%M:%S" 2>/dev/null)
  [ -z "$DATE_RAW" ] && DATE_RAW="$RAW_TS"
  # İngilizce → Türkçe ay adı
  TR_DATE=$(format_tr_date "$DATE_RAW")
  PRIMARY=$(grep "Primary DNS" "$FILE" | sed 's/Primary DNS   → //')
  SECONDARY=$(grep "Secondary DNS" "$FILE" | sed 's/Secondary DNS → //')
  echo "📅 $TR_DATE"
  echo "   🥇 $PRIMARY"
  echo "   🥈 $SECONDARY"
  echo
done
