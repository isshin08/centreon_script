#!/bin/bash
# Add to the scripts that use this token
# token=$(cat /$HOME/.centreon/token.txt)
tmpfile="/$HOME/.centreon/token.txt"
# API endpoint
API="https://XXXXXXXXXXXXXX/centreon/api/latest"
# Login/password Input
read -s -p "login : " login;echo
read -s -p "password : " password;echo

# GET token API
token=$(curl -s -k -X POST \
  -H "Content-Type: application/json" \
  -d "{\"security\":{\"credentials\":{\"login\":\"$login\",\"password\":\"$password\"}}}" \
  "$API/login" | jq -r '.security.token')

# Check
if [ -n "$token" ] && [ "$token" != "null" ]; then
  echo "Token generated"
  echo "$token" > /$HOME/.centreon/token.txt
else
  echo "Error : Can't get token"
  exit 1
fi

