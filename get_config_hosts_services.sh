#!/bin/bash
token=$(cat /$HOME/.centreon/token.txt)
API="https://XXXXXXXXXXXX/centreon/api/latest"
echo ;read -p "Hostname : " hostname;echo
#-----------------------------------------------------------------------------------------------
# 1 - Récupération ID  host (MONITORING)
search=$(jq -nc --arg h "$hostname" '{ "host.name": { "$eq": $h } }')
search_url=$(jq -rn --argjson s "$search" '$s|@uri')

HOST_ID=$(curl -s -X GET \
  -H "Content-Type: application/json" \
  -H "X-AUTH-TOKEN: $token" \
  "$API/monitoring/hosts?search=$search_url&limit=900000" \
  | jq -r '.result[0].id // empty')

if [[ -z "$HOST_ID" ]]; then
  echo "Host introuvable"
  exit 1
fi
echo "Host trouvé : $hostname (ID: $HOST_ID)";echo
#-----------------------------------------------------------------------------------------------
# 2 - Récupérer Configuration host
search_conf=$(jq -nc --arg h "$hostname" '{ "name": { "$eq": $h } }')
search_conf_url=$(jq -rn --argjson s "$search_conf" '$s|@uri')

echo "Configuration du host :"
curl -s -X GET \
  -H "Content-Type: application/json" \
  -H "X-AUTH-TOKEN: $token" \
  "$API/configuration/hosts?search=$search_conf_url&limit=900000" \
  | jq '.result[0] | {
      id,
      name,
      severity_id: .severity.id,
      severity_name: .severity.name
    }'
echo "================================================================="; echo
#-----------------------------------------------------------------------------------------------
# 3 - Services ID associés au host (MONITORING)
SERVICES_IDS=$(curl -s -X GET \
  -H "Content-Type: application/json" \
  -H "X-AUTH-TOKEN: $token" \
  "$API/monitoring/hosts/$HOST_ID" | jq -r '.services[].id')

if [[ -z "$SERVICES_IDS" ]]; then
  echo "Aucun service associé à ce host"
  exit 0
fi
#-----------------------------------------------------------------------------------------------
# 4 – GET Status des services associés
echo "Configuration des services :";echo

for SID in $SERVICES_IDS; do
  curl -s -X GET \
    -H "Content-Type: application/json" \
    -H "X-AUTH-TOKEN: $token" \
    "$API/monitoring/hosts/$HOST_ID/services/$SID" | jq '{
      ID: .id,
      description: .description,
      criticality: .criticality,
      severity_id: .status.severity_code
    }'
echo "------------------------------------------------------------"
done
