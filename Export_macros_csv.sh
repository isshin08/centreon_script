#!/bin/bash
# Objectif: Exporter vers CSV les macros WARNING et CRITICAL de tous les services des hosts a partir d'un input trigramme
# Utilise CLAPI en local (binaire "centreon")

# 1. Saisie du motif de nom de host (ex: TEST-) + identifiants API
# 2. Récupération de la liste des hosts correspondant au motif (HOST show)
# 3. Pour chaque host : récupération de ses services (SERVICE show)
# 4. Pour chaque service : récupération des macros (SERVICE getmacro) et extraction de WARNING et CRITICAL
# 5. Écriture d'une ligne dans le CSV par service

CENTREON_BIN="centreon"   # adapter en /usr/share/centreon/bin/centreon si besoin

# ---------------------------------------------------------------------------
# Saisie du trigramme host + login API
# ---------------------------------------------------------------------------
echo; read -p "Hostname (ex:TEST-V-DEB12) : " HOST_PATTERN

if [[ -z "$HOST_PATTERN" ]]; then
  echo "ERREUR : motif vide"
  exit 1
fi

echo; read -s -p "Login : " login; echo
read -s -p "Password : " password; echo

# ---------------------------------------------------------------------------
# Fichier de sortie (dans le répertoire d'exécution du script)
# ---------------------------------------------------------------------------
CSV_FILE="$HOME/export_csv/macros_export_$(date +%Y%m%d_%H"h"%M).csv"
echo "id_host;hostname;service_id;service_name;warning_macro_name;warning_macro_value;critical_macro_name;critical_macro_value" > "$CSV_FILE"

# ---------------------------------------------------------------------------
# Récupération des hosts correspondant au motif
# ---------------------------------------------------------------------------
HOSTS_LIST=$("$CENTREON_BIN" -u "$login" -p "$password" -o HOST -a show \
  | awk -F';' -v pat="$HOST_PATTERN" 'NR>1 && index($2, pat)==1 {print $1";"$2}')

if [[ -z "$HOSTS_LIST" ]]; then
  echo "ERREUR : aucun host ne correspond au motif '$HOST_PATTERN'"
  exit 1
fi

NB_HOSTS=$(echo "$HOSTS_LIST" | wc -l)
NB_SERVICES=0
echo "$NB_HOSTS host(s) trouvé(s) pour le motif '$HOST_PATTERN'"
echo "============================================================"

# ---------------------------------------------------------------------------
# Boucle sur les hosts
# ---------------------------------------------------------------------------
while IFS=';' read -r HOST_ID HOST_NAME; do
  [[ -z "$HOST_ID" ]] && continue

  echo "Host : $HOST_NAME (ID $HOST_ID)"

  # -------------------------------------------------------------------------
  # Récupération des services du host
  # -------------------------------------------------------------------------
  SERVICES_LIST=$("$CENTREON_BIN" -u "$login" -p "$password" -o SERVICE -a show -v "$HOST_NAME;" \
    | awk -F';' 'NR>1 {print $3";"$4}')

  if [[ -z "$SERVICES_LIST" ]]; then
    echo "  Aucun service trouvé pour ce host"
    continue
  fi

  # -------------------------------------------------------------------------
  # Boucle sur les services du host
  # -------------------------------------------------------------------------
  while IFS=';' read -r SERVICE_ID SERVICE_NAME; do
    [[ -z "$SERVICE_ID" ]] && continue

    MACRO_OUTPUT=$("$CENTREON_BIN" -u "$login" -p "$password" -o SERVICE -a getmacro -v "$HOST_NAME;$SERVICE_NAME")

    # Toutes les macros dont le nom COMMENCE PAR "WARNING" ou "CRITICAL"
    # (couvre WARNING, WARNINGUSAGE, WARNINGINTRAFFIC, CRITICAL, CRITICALUSAGE, etc.)
    MACRO_LINES=$(echo "$MACRO_OUTPUT" | grep -E "^(WARNING|CRITICAL)")

    if [[ -z "$MACRO_LINES" ]]; then
      echo "  - $SERVICE_NAME (ID $SERVICE_ID) | aucune macro WARNING/CRITICAL"
      continue
    fi

    # Regroupement par "suffixe" (ce qu'il y a après WARNING/CRITICAL) pour
    # pouvoir associer WARNINGUSAGE avec CRITICALUSAGE sur la même ligne CSV.
    unset WARN_NAME WARN_VAL CRIT_NAME CRIT_VAL
    declare -A WARN_NAME=() WARN_VAL=() CRIT_NAME=() CRIT_VAL=()

    while IFS=';' read -r MACRO_NAME MACRO_VALUE _REST; do
      [[ -z "$MACRO_NAME" ]] && continue
      if [[ "$MACRO_NAME" == WARNING* ]]; then
        SUFFIX="${MACRO_NAME#WARNING}"
        [[ -z "$SUFFIX" ]] && SUFFIX="__BASE__"   # bash n'autorise pas les clés vides
        WARN_NAME[$SUFFIX]="$MACRO_NAME"
        WARN_VAL[$SUFFIX]="$MACRO_VALUE"
      elif [[ "$MACRO_NAME" == CRITICAL* ]]; then
        SUFFIX="${MACRO_NAME#CRITICAL}"
        [[ -z "$SUFFIX" ]] && SUFFIX="__BASE__"
        CRIT_NAME[$SUFFIX]="$MACRO_NAME"
        CRIT_VAL[$SUFFIX]="$MACRO_VALUE"
      fi
    done <<< "$MACRO_LINES"

    echo "  - $SERVICE_NAME (ID $SERVICE_ID) :"

    # Union des suffixes trouvés côté WARNING et côté CRITICAL
    ALL_SUFFIXES=$(printf '%s\n' "${!WARN_NAME[@]}" "${!CRIT_NAME[@]}" | sort -u)

    while IFS= read -r SUF; do
      WNAME="${WARN_NAME[$SUF]}"
      WVAL="${WARN_VAL[$SUF]}"
      CNAME="${CRIT_NAME[$SUF]}"
      CVAL="${CRIT_VAL[$SUF]}"
      echo "      WARNING=${WNAME:-—}(${WVAL}) | CRITICAL=${CNAME:-—}(${CVAL})"
      echo "$HOST_ID;$HOST_NAME;$SERVICE_ID;$SERVICE_NAME;$WNAME;$WVAL;$CNAME;$CVAL" >> "$CSV_FILE"
    done <<< "$ALL_SUFFIXES"

    NB_SERVICES=$((NB_SERVICES + 1))
  done <<< "$SERVICES_LIST"

done <<< "$HOSTS_LIST"

# ---------------------------------------------------------------------------
# Récap final
# ---------------------------------------------------------------------------
echo "============================================================"
echo "TERMINÉ — $NB_HOSTS host(s) traité(s), $NB_SERVICES service(s) exporté(s)"
echo "Fichier généré : $CSV_FILE"
echo "Localisation fichier : $HOME/export_csv/"
echo "============================================================"
