#!/bin/bash
# ---------------------------------------------------------------------------
# Objectif : Mettre à jour les priorités des hosts et services dans Centreon à partir d'un fichier CSV
# 1. Input chemin CSV
# 2. Input login/password → token API Centreon
# 3. Mapping des priorités
# 4. Lecture ligne par ligne du CSV :
#    - Vérification priorité cible et mapping severity_id
#    - Vérification que le host existe (GET host)
#    - Récupération des services associés au host (GET services)
#    - Mise à jour de la severity du host (PATCH host)
#    - Mise à jour des severity des services (PATCH services)
#    - Collecte des erreurs pour le récap final
# 5. Affichage d'un récapitulatif des erreurs

# ---------------------------------------------------------------------------
# Input du CSV
# ---------------------------------------------------------------------------
echo; read -p "Emplacement CSV (chemin absolu) : " CSV_FILE

if [[ -z "$CSV_FILE" ]]; then
  echo "ERREUR : chemin CSV vide"
  exit 1
fi
if [[ ! -f "$CSV_FILE" || ! -r "$CSV_FILE" ]]; then
  echo "ERREUR : fichier CSV introuvable ou non lisible ($CSV_FILE)"
  exit 1
fi

# ---------------------------------------------------------------------------
# API URL
# ---------------------------------------------------------------------------
API="https://XXXXXXXXXX/centreon/api/latest"
ERROR_HOSTS=()

# ---------------------------------------------------------------------------
# Génération token API Centreon
# ---------------------------------------------------------------------------
echo;read -s -p "Login : " login; echo
read -s -p "Password : " password; echo

token=$(curl -s -X POST \
  -H "Content-Type: application/json" \
  -d "{\"security\":{\"credentials\":{\"login\":\"$login\",\"password\":\"$password\"}}}" \
  "$API/login" | jq -r '.security.token')

if [[ -z "$token" || "$token" == "null" ]]; then
  echo "ERREUR : impossible de récupérer le token Centreon"
  exit 1
fi

echo "Token généré avec succès"; echo

# ---------------------------------------------------------------------------
# Mapping priorités → severity_id
# ---------------------------------------------------------------------------
declare -A HOST_SEVERITY_MAP=([P1]=3 [P2]=4 [P3]=5 [P4]=6)
declare -A SERVICE_SEVERITY_MAP=([P1]=19 [P2]=20 [P3]=21 [P4]=22)

# ---------------------------------------------------------------------------
# Lecture CSV
# ---------------------------------------------------------------------------
exec 3< "$CSV_FILE"

while IFS=';' read -r HOST_ID HOST_NAME ALIAS PRIORITE_SOURCE PRIORITE_CIBLE <&3
do
  [[ -z "$HOST_ID" || "$HOST_ID" =~ ^# ]] && continue

  PRIORITE_SOURCE=$(echo "$PRIORITE_SOURCE" | tr -d '\r' | xargs)
  PRIORITE_CIBLE=$(echo "$PRIORITE_CIBLE" | tr -d '\r' | xargs)

  # Priorité cible obligatoire
  if [[ -z "$PRIORITE_CIBLE" ]]; then
    echo "============================================================"
    echo
    echo "Priorité cible vide — host ignoré : $HOST_NAME (ID $HOST_ID)"
    ERROR_HOSTS+=("$HOST_NAME (ID $HOST_ID) — priorité cible vide")
    continue
  fi

  TARGET_HOST_SEVERITY=${HOST_SEVERITY_MAP[$PRIORITE_CIBLE]}
  TARGET_SERVICE_SEVERITY=${SERVICE_SEVERITY_MAP[$PRIORITE_CIBLE]}

  if [[ -z "$TARGET_HOST_SEVERITY" || -z "$TARGET_SERVICE_SEVERITY" ]]; then
    echo "Priorité invalide ($PRIORITE_CIBLE) — host ignoré : $HOST_NAME (ID $HOST_ID)"
    ERROR_HOSTS+=("$HOST_NAME (ID $HOST_ID) — priorité invalide")
    continue
  fi

  TARGET_HP="HP${PRIORITE_CIBLE#P}"
  TARGET_SP="SP${PRIORITE_CIBLE#P}"

  echo "============================================================"
  echo "Host : $HOST_NAME (ID $HOST_ID) | Priorité source : $PRIORITE_SOURCE | Priorité cible : $PRIORITE_CIBLE"

  # -----------------------------------------------------------------------
  # Récupération configuration host (GET)
  # -----------------------------------------------------------------------
  SEARCH_CONF=$(jq -nc --arg id "$HOST_ID" '{ "id": { "$eq": ($id|tonumber) } }')
  SEARCH_CONF_URL=$(jq -rn --argjson s "$SEARCH_CONF" '$s|@uri')

  CONF_JSON=$(curl -s --connect-timeout 20 --max-time 30 \
    -H "Content-Type: application/json" \
    -H "X-AUTH-TOKEN: $token" \
    "$API/configuration/hosts?search=$SEARCH_CONF_URL&limit=900000")

  HOST_EXISTS=$(echo "$CONF_JSON" | jq -r '.result[0].id // empty')
  if [[ -z "$HOST_EXISTS" ]]; then
    echo "Host introuvable ou inaccessible : $HOST_NAME (ID $HOST_ID)"
    ERROR_HOSTS+=("$HOST_NAME (ID $HOST_ID) — GET host KO")
    continue
  fi

  HOST_SEVERITY_CURRENT=$(echo "$CONF_JSON" | jq -r '.result[0].severity.id // null')
  HOST_SEVERITY_NAME=$(echo "$CONF_JSON" | jq -r '.result[0].severity.name // null')

  # -----------------------------------------------------------------------
  # Récupération services
  # -----------------------------------------------------------------------
  MONITOR_JSON=$(curl -s --connect-timeout 10 --max-time 30 \
    -H "Content-Type: application/json" \
    -H "X-AUTH-TOKEN: $token" \
    "$API/monitoring/hosts/$HOST_ID")

  SERVICE_IDS=$(echo "$MONITOR_JSON" | jq -r '.services[].id')

  SERVICES=()
  echo "Services :"

  for SID in $SERVICE_IDS; do
    SERVICE_JSON=$(curl -s --connect-timeout 10 --max-time 30 \
      -H "Content-Type: application/json" \
      -H "X-AUTH-TOKEN: $token" \
      "$API/monitoring/hosts/$HOST_ID/services/$SID")
    SERVICES+=("$SERVICE_JSON")
    echo "Nom Service : $(echo "$SERVICE_JSON" | jq -r '.description') | ID : $SID | Severity cible : $TARGET_SERVICE_SEVERITY ($TARGET_SP)"
  done

  # -----------------------------------------------------------------------
  # PATCH HOST
  # -----------------------------------------------------------------------
  HTTP_CODE=$(curl -s -o /tmp/host_patch.json -w "%{http_code}" --connect-timeout 10 --max-time 30 \
    -X PATCH \
    -H "Content-Type: application/json" \
    -H "X-AUTH-TOKEN:$token" \
    -d "{\"severity_id\": $TARGET_HOST_SEVERITY}" \
    "$API/configuration/hosts/$HOST_ID")

  if [[ "$HTTP_CODE" != "200" && "$HTTP_CODE" != "204" ]]; then
    echo "ERREUR PATCH host $HOST_NAME (ID $HOST_ID)"
    cat /tmp/host_patch.json | jq .
    ERROR_HOSTS+=("$HOST_NAME (ID $HOST_ID) — erreur PATCH host")
    continue
  fi

  # -----------------------------------------------------------------------
  # PATCH SERVICES
  # -----------------------------------------------------------------------
  for SERVICE_JSON in "${SERVICES[@]}"; do
    SID=$(echo "$SERVICE_JSON" | jq -r '.id')
    SNAME=$(echo "$SERVICE_JSON" | jq -r '.description')

    HTTP_CODE=$(curl -s -o /tmp/service_patch.json -w "%{http_code}" --connect-timeout 10 --max-time 30 \
      -X PATCH \
      -H "Content-Type: application/json" \
      -H "X-AUTH-TOKEN:$token" \
      -d "{\"severity_id\": $TARGET_SERVICE_SEVERITY}" \
      "$API/configuration/services/$SID")

    if [[ "$HTTP_CODE" != "200" && "$HTTP_CODE" != "204" ]]; then
      echo "ERREUR PATCH service $SNAME (ID $SID)"
      cat /tmp/service_patch.json | jq .
      ERROR_HOSTS+=("$HOST_NAME (ID $HOST_ID) — erreur PATCH service $SID")
      break
    fi
  done

done
exec 3<&-
# ---------------------------------------------------------------------------
# Récap final
# ---------------------------------------------------------------------------
echo
echo "============================================================"
if [[ "${#ERROR_HOSTS[@]}" -eq 0 ]]; then
  echo "SCRIPT TERMINÉ — AUCUNE ERREUR DÉTECTÉE"
else
  echo "SCRIPT TERMINÉ — ${#ERROR_HOSTS[@]} ERREUR(S) DÉTECTÉE(S)"
  echo
  echo "Hosts concernés :"
  for ERR in "${ERROR_HOSTS[@]}"; do
    echo " - $ERR"
  done
fi
echo "============================================================"
