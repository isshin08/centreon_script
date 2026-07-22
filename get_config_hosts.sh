#!/bin/bash
# API
API="https://XXXXXXXXXXXXXX/centreon/api/latest"
# Token
token=$(cat /$HOME/.centreon/token.txt)
#token=$(openssl enc -aes-256-cbc -d -pbkdf2 -in /$HOME/.centreon/token.enc)

# Input hostname
echo;read -p "hostname : " trigramme ;echo

# Encodage du paramètre search en JSON pour requête Centreon
search=$(jq -nc --arg tri "$trigramme" '{ "name": { "$lk": ($tri + "%") } }')
search_url=$(jq -rn --argjson s "$search" '$s|@uri')

# GET API config hosts + jq (id+name+severity_id+severity_name)
curl -s -X GET \
  -H "Content-Type: application/json" \
  -H "X-AUTH-TOKEN: $token" \  "$API/configuration/hosts?search=$search_url&limit=900000" \
 | jq '.result[] | {id: .id, name: .name, severity_id: .severity.id, severity_name: .severity.name}'
