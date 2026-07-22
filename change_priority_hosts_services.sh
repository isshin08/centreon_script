#!/bin/bash
# Objectif : Modifier la priorité d'un host et de ses services dans Centreon a partir d'un hostname 

# Input hostname et priorité cible
echo
read -p "Hostname (exact dans Centreon) : " HOST_NAME
read -p "Priorité cible (P1, P2, P3 ou P4) : " PRIORITE_CIBLE

if [[ -z "$HOST_NAME" ]]; then
  echo "ERREUR : hostname vide"
  exit 1
fi

PRIORITE_CIBLE=$(echo "$PRIORITE_CIBLE" | tr -d '\r' | xargs)

# API URL
API="https://XXXXXXXXXXXXXXXXX/centreon/api/latest"
ERROR_HOSTS=()

# Génération du token API Centreon
echo
read -s -p "Login : " login; echo
read -s -p "Password : " password; echo

token=$(curl -s -X POST \
  -H "Content-Type: application/json" \
  -d "{\"security\":{\"credentials\":{\"login\":\"$login\",\"password\":\"$password\"}}}" \
  "$API/login" | jq -r '.security.token')

if [[ -z "$token" || "$token" == "null" ]]; then
  echo "ERREUR : impossible de récupérer le token"
  exit 1
fi

echo "Token généré avec succès"; echo

# Mapping priorités → severity_id
declare -A HOST_SEVERITY_MAP=([P1]=3 [P2]=4 [P3]=5 [P4]=6)
declare -A SERVICE_SEVERITY_MAP=([P1]=19 [P2]=20 [P3]=21 [P4]=22)

TARGET_HOST_SEVERITY=${HOST_SEVERITY_MAP[$PRIORITE_CIBLE]}
TARGET_SERVICE_SEVERITY=${SERVICE_SEVERITY_MAP[$PRIORITE_CIBLE]}

if [[ -z "$TARGET_HOST_SEVERITY" || -z "$TARGET_SERVICE_SEVERITY" ]]; then
  echo "ERREUR : priorité invalide ($PRIORITE_CIBLE). Valeurs acceptées : P1, P2, P3, P4"
  exit 1
fi

TARGET_HP="HP${PRIORITE_CIBLE#P}"
TARGET_SP="SP${PRIORITE_CIBLE#P}"

echo "============================================================"
echo "Host : $HOST_NAME | Priorité cible : $PRIORITE_CIBLE"

# Récupération du host par NOM (GET)
SEARCH_CONF=$(jq -nc --arg name "$HOST_NAME" '{ "name": { "$eq": $name } }')
SEARCH_CONF_URL=$(jq -rn --argjson s "$SEARCH_CONF" '$s|@uri')

CONF_JSON=$(curl -s --connect-timeout 20 --max-time 30 \
  -H "Content-Type: application/json" \
  -H "X-AUTH-TOKEN: $token" \
  "$API/configuration/hosts?search=$SEARCH_CONF_URL&limit=999999")

HOST_ID=$(echo "$CONF_JSON" | jq -r '.result[0].id // empty')
if [[ -z "$HOST_ID" ]]; then
  echo "ERREUR : host introuvable ou inaccessible : $HOST_NAME"
  ERROR_HOSTS+=("$HOST_NAME — host introuvable")
else
  HOST_SEVERITY_CURRENT=$(echo "$CONF_JSON" | jq -r '.result[0].severity.name // "aucune"')
  echo "Host trouvé (ID $HOST_ID) | Priorité actuelle : $HOST_SEVERITY_CURRENT"

  # Récupération services
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
    echo "  - $(echo "$SERVICE_JSON" | jq -r '.description') (ID $SID) → $TARGET_SP"
  done

  echo "-----------------------------------------------------------------------------"
  read -p "Confirmer la mise à jour vers $PRIORITE_CIBLE pour $HOST_NAME et ses services ? (y/n) : " CONFIRM
  if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Annulé par l'utilisateur."
    exit 1
  fi

  echo "-----------------------------------------------------------------------------";echo

  # -------------------------------------------------------------------------
  # PATCH HOST
  # -------------------------------------------------------------------------
  HTTP_CODE=$(curl -s -o /tmp/host_patch.json -w "%{http_code}" --connect-timeout 10 --max-time 30 \
    -X PATCH \
    -H "Content-Type: application/json" \
    -H "X-AUTH-TOKEN:$token" \
    -d "{\"severity_id\": $TARGET_HOST_SEVERITY}" \
    "$API/configuration/hosts/$HOST_ID")

  if [[ "$HTTP_CODE" != "200" && "$HTTP_CODE" != "204" ]]; then
    echo "ERREUR PATCH host $HOST_NAME"
    cat /tmp/host_patch.json | jq .
    ERROR_HOSTS+=("$HOST_NAME — erreur PATCH host")
  else
    echo "Host mis à jour → $TARGET_HP"

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
        ERROR_HOSTS+=("$HOST_NAME — erreur PATCH service $SID")
      else
        echo "  Service $SNAME mis à jour → $TARGET_SP"
      fi
    done
  fi
fi

# Récap final
echo
echo "============================================================"
if [[ "${#ERROR_HOSTS[@]}" -eq 0 ]]; then
  echo "SCRIPT TERMINÉ — AUCUNE ERREUR DÉTECTÉE"
else
  echo "SCRIPT TERMINÉ — ${#ERROR_HOSTS[@]} ERREUR(S) DÉTECTÉE(S)"
  echo
  for ERR in "${ERROR_HOSTS[@]}"; do
    echo " - $ERR"
  done
fi
echo "============================================================"

