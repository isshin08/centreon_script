#!/bin/bash
# Objectif : Extraire par requete API la priorité des Hosts Centreon  dans un fichier .csv
# API
API="https://XXXXXXXXXXXXX/centreon/api/latest"
# Input login/password API
echo;read -s -p "Login : " login;echo
read -s -p "Password : " password;echo

# Generate token API
token=$(curl -s -X POST \
  -H "Content-Type: application/json" \
  -d "{\"security\":{\"credentials\":{\"login\":\"$login\",\"password\":\"$password\"}}}" \
  "$API/login" | jq -r '.security.token')

if [[ -z "$token" || "$token" == "null" ]]; then
  echo "ERREUR : impossible de récupérer le token Centreon"
  exit 1
fi
echo "Token generé avec succès"

#----------------------------------------------------------------------------------------------------------
# Fonctionnement de la recherche par hostname : entrer le nom précis d'un host ou rechercher par Trigramme
# (si laisser vide ----> Extract de tous les hosts)
#----------------------------------------------------------------------------------------------------------

echo;read -p "Rechercher par Hostname : " trigramme;echo

# Encodage du paramètre search en JSON pour requête Centreon
search=$(jq -nc --arg tri "$trigramme" '{ "host.name": { "$lk": ($tri + "%") } }')
search_url=$(jq -rn --argjson s "$search" '$s|@uri')

# Requete GET hosts + jq + redirection vers .csv
curl -s -X GET \
  -H "Content-Type: application/json" \
  -H "X-AUTH-TOKEN: $token" \
  "$API/monitoring/hosts?search=$search_url&limit=900000" \
 | jq -r '.result[] | "\(.id);\(.name);\(.alias);'P'\(.criticality)"' > /$HOME/extract_centreon.csv

echo "Extract localisation : /$HOME/extract_centreon.csv"
