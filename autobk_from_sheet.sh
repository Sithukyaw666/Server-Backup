#!/bin/bash

# Define backup function for directories and databases
backup_server() {
    local SERVER="$1"
    local IP="$2"
    local BACKUP_LIST="$3"
    local EXCLUDE_LIST="$4"
    local DATABASE="$5"

    DATETIME="$(date '+%Y-%m-%d')"
    BACKUP_DIR="/home/intern/backups/${DATETIME}"
    BACKUP_PATH="${BACKUP_DIR}/${SERVER}"

    mkdir -p "${BACKUP_DIR}"

    # Convert space-separated source paths into an array
    IFS=' ' read -r -a BACKUP_PATHS <<< "${BACKUP_LIST}"

    EXCLUDE_OPTIONS=()
    if [[ -n "${EXCLUDE_LIST}" ]]; then
        IFS=' ' read -r -a EXCLUDE_PATHS <<< "${EXCLUDE_LIST}"
        for EXCLUDE_PATH in "${EXCLUDE_PATHS[@]}"; do
            EXCLUDE_OPTIONS+=(--exclude="${EXCLUDE_PATH}")
        done
    fi

    # Iterate through the backup paths
    for SOURCE_PATH in "${BACKUP_PATHS[@]}"; do
        if ssh -n "${SERVER}" "[[ ! -e \"${SOURCE_PATH}\" ]]"; then
            echo "Source path ${SOURCE_PATH} does not exist on ${SERVER}. Skipping."
            continue
        fi

        if ssh -n "${SERVER}" "[[ -d \"${SOURCE_PATH}\" ]]"; then
            list_contents=$(ssh "${SERVER}" "ls -A \"${SOURCE_PATH}\"" | wc -l)
        else
            list_contents=1 # Treat files as having contents
        fi

        if [[ $list_contents -le 0 ]]; then
            echo "No files to backup under ${SOURCE_PATH} on ${SERVER}. Skipping."
            continue
        fi

        TEMP_ARCHIVE="/tmp/_$(basename "${SOURCE_PATH}").tar.gz"
        
        ssh -n "${SERVER}" "tar -czf ${TEMP_ARCHIVE} -C $(dirname "${SOURCE_PATH}") $(basename "${SOURCE_PATH}")"

        if [[ $? -ne 0 ]]; then
            echo "Compression failed for ${SOURCE_PATH} on ${SERVER}. Skipping."
            continue
        fi

        mkdir -p ${BACKUP_PATH}
        echo "Backing up to ${BACKUP_PATH}"

        # Use rsync to transfer the archive with exclusion options
        rsync -av --remove-source-files \
          -e "ssh" \
          "${SERVER}:${TEMP_ARCHIVE}" \
          "${BACKUP_PATH}/" \
          "${EXCLUDE_OPTIONS[@]}"

        if [[ $? -ne 0 ]]; then
            echo "Backup failed for ${SOURCE_PATH} on ${SERVER}. Cleaning up."
            continue
        fi

        ssh -n "${SERVER}" "rm -f ${TEMP_ARCHIVE}"
    done

    # Backup the database (if specified)
    if [[ -n "${DATABASE}" ]]; then
        echo "Backing up database ${DATABASE} on ${SERVER}..." 
        mysqldump -h ${SERVER} ${DATABASE} | gzip > ${BACKUP_PATH}/${DATABASE}.sql.gz
    fi
}
GOOGLE_SHEET_ID=$1

CSV_FILE="servers.csv"
wget -q --no-check-certificate --output-document=${CSV_FILE} "https://docs.google.com/spreadsheets/d/${GOOGLE_SHEET_ID}/export?format=csv"

if [[ $? -ne 0 ]]; then
    echo "Can't read the CSV file from Google Drive"
    exit 1
fi
echo "" >> ${CSV_FILE}
sed -i 's/\r//g' ${CSV_FILE}

while IFS=',' read -r SERVER IP BACKUP_LIST EXCLUDE_LIST DATABASE; do
    if [[ "${SERVER}" == "Server Name" ]]; then
        continue
    fi

    SERVER=$(echo "${SERVER}" | xargs)
    IP=$(echo "${IP}" | xargs)
    BACKUP_LIST=$(echo "${BACKUP_LIST}" | xargs)
    EXCLUDE_LIST=$(echo "${EXCLUDE_LIST}" | xargs)
    DATABASE=$(echo "${DATABASE}" | xargs)

    backup_server "${SERVER}" "${IP}" "${BACKUP_LIST}" "${EXCLUDE_LIST}" "${DATABASE}"
    echo ""
done < <(tail -n +2 "${CSV_FILE}")

