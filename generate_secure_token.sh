#!/bin/bash
# Add to the scripts that use this token
# token=$(openssl enc -aes-256-cbc -d -pbkdf2 -in /$HOME/.centreon/token.enc)
API="https://XXXXXXXXXXXXXX/centreon/api/latest"

# Input login password
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
  echo "$token" | openssl enc -aes-256-cbc -salt -pbkdf2  -out /$HOME/.centreon/token.enc
else
  echo "Error : Can't get token""
  exit 1
fi

