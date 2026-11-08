#!/bin/bash
# Setzt das Test-Backend auf einen festen Demozustand (nur Testkonten, nur erfundene Positionen in Berlin-Mitte).
# Zugänge kommen aus einer env-Datei (nie ins Repo):  FIND_ENV=~/.config/…/test-accounts.env tools/demo-state.sh [reset|all]
#   reset  Leo teilt, Ida teilt nicht, Mia teilt nicht, offene Anfragen abgelehnt
#   all    wie reset, zusätzlich teilen Ida und Mia (für Screenshots)
set -euo pipefail
set -a; source "${FIND_ENV:?FIND_ENV fehlt}"; set +a
S="$FIND_SERVER"
api() { local key=$1 m=$2 path=$3 body=${4:-}; curl -sf -X "$m" -H "Authorization: Bearer $key" -H 'Content-Type: application/json' ${body:+-d "$body"} "$S$path"; }
point() { local key=$1 lat=$2 lon=$3 batt=$4 tid=$5
  api "$key" POST /api/v1/owntracks/points "{\"_type\":\"location\",\"lat\":$lat,\"lon\":$lon,\"tst\":$(date +%s),\"acc\":12,\"batt\":$batt,\"bs\":1,\"tid\":\"$tid\",\"topic\":\"owntracks/homefind/$tid\"}" >/dev/null; }
mode=${1:-reset}
# offene Anfragen an alle ablehnen
for who in MIA LEO IDA; do
  k=$(eval echo \$FIND_${who}_KEY)
  for id in $(api "$k" GET /api/v1/families/mine | python3 -c 'import json,sys; [print(r["id"]) for r in json.load(sys.stdin)["location_requests"]["incoming"]]'); do
    api "$k" POST /api/v1/families/location_requests/$id/decline '{}' >/dev/null
  done
done
api "$FIND_MIA_KEY" PATCH /api/v1/families/sharing '{"enabled":false}' >/dev/null
api "$FIND_LEO_KEY" PATCH /api/v1/families/sharing '{"enabled":true,"duration":"permanent","share_history":false}' >/dev/null
point "$FIND_LEO_KEY" 52.51630 13.37770 64 leodemo01
point "$FIND_IDA_KEY" 52.50790 13.33760 88 idademo01
if [ "$mode" = all ]; then
  api "$FIND_MIA_KEY" PATCH /api/v1/families/sharing '{"enabled":true,"duration":"permanent","share_history":false}' >/dev/null
  api "$FIND_IDA_KEY" PATCH /api/v1/families/sharing '{"enabled":true,"duration":"permanent","share_history":false}' >/dev/null
else
  api "$FIND_IDA_KEY" PATCH /api/v1/families/sharing '{"enabled":false}' >/dev/null
fi
# zweites eigenes Gerät von Mia (Demo-iPad) als private Notiz
NOTE=$(api "$FIND_MIA_KEY" GET "/api/v1/notes?standalone=true" | python3 -c 'import json,sys; print(next((str(n["id"]) for n in json.load(sys.stdin) if n.get("title")=="homefind-device:demoipad0001"),""))')
BODY=$(python3 -c 'import json,datetime; print(json.dumps(json.dumps({"id":"demoipad0001","name":"iPad","emoji":"💻","model":"iPad (Demo)","system":"iPadOS 26.0","appVersion":"1.0.0","latitude":52.5219,"longitude":13.4132,"accuracy":20,"battery":41,"charging":False,"updatedAt":datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}, ensure_ascii=False), ensure_ascii=False))')
if [ -n "$NOTE" ]; then api "$FIND_MIA_KEY" PATCH /api/v1/notes/$NOTE "{\"note\":{\"body\":$BODY}}" >/dev/null
else api "$FIND_MIA_KEY" POST /api/v1/notes "{\"note\":{\"title\":\"homefind-device:demoipad0001\",\"body\":$BODY,\"noted_at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}}" >/dev/null; fi
echo "Demozustand: $mode"
