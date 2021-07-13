#!/bin/bash

# cPanel to SiteHost Containers Migration Tool - https://gitlab.com/andre.rodovalho/cpanel-to-cc
# Copyright (C) 2021-present Andre Campos Rodovalho.
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

# cPanel® is a trademark of cPanel, Inc.
# SiteHost Limited is a legal entity name owned by SiteTech Solutions Limited
#
# All trademarks, logos and brand names are the property of their respective owners.
# All company, product and service names used in this software are for
# identification purposes only. Use of these names, trademarks and brands
# does not imply endorsement.


################################################### CONFIGURATION ######################################################

# set shell to immediately exit if any command fails with status greater than zero
# TODO: consider pro and cons of using this
set -e;

################################################### DECLARATIONS #######################################################

JQ="/usr/bin/jq"
WHMAPI1="/usr/sbin/whmapi1"
RSYNC="/usr/bin/rsync"
CURL="/usr/bin/curl"
MYSQLDUMP="/usr/bin/mysqldump"
MYSQL="/usr/bin/mysql"
SSHPASS="/usr/bin/sshpass"
SSH="/usr/bin/ssh"
GZIP="/usr/bin/gzip"
TMP_DIR="/tmp/cpanel-to-cc"
LOG_FILE="${TMP_DIR}/run.log"
SFTP_CREDENTIALS_FILE="${TMP_DIR}/sftp.csv"
DB_CREDENTIALS_FILE="${TMP_DIR}/databases.csv"
VERBOSE=false
YES_TO_ALL=false

################################################# HELPER FUNCTIONS #####################################################

function help_text {
  echo;
  echo -e "Usage: ./cpanel-to-cc.sh [arguments] ..."
  echo -e "Examples: "
  echo -e "\t ./cpanel-to-cc.sh --client-id 123123 --api-key abc123def456 --domain example.com"
  echo -e "\t ./cpanel-to-cc.sh --client-id 123123 --tmp-dir /home/user/cpanel-to-cc"
  echo;
  echo -e "Arguments: \n"
  echo -e "Option \t\t\t Long option \t\t\t Function"
  echo -e " -c <id> \t\t --client-id <id> \t\t Specify the SiteHost Client ID"
  echo -e " -k <key> \t\t --api-key <key> \t\t Specify the SiteHost API key with access to Cloud, Job and Server modules"
  echo -e " -d <domain> \t\t --domain <domain> \t\t (Optional) The cPanel domain to migrate. If not specified we try migrate all"
  echo -e " -t <directory> \t --tmp-dir <directory> \t\t (Optional) Directory to store temporary files and logs. Default is: $TMP_DIR"
  echo -e " -v \t\t\t --verbose \t\t\t (Optional) Print debugging/verbose information"
  echo -e " -y \t\t\t --assume-yes \t\t\t (Optional) Automatic yes to prompts. Assume \"yes\" as answer to all prompts"
  echo;
}

function error_exit {
  echo "$(basename $0): ${1:-"Unknown Error"}" 1>&2
  # We want to print but also log this event
  echo "[$(timestamp)] $(basename $0): ${1:-"Unknown Error"}" >> $LOG_FILE
  exit 1
}

function timestamp {
  date +"%F %T"
}

function fulldate {
  date +"%F"
}

function nice_wait {
  for i in {001..010}; do
    sleep 1
    printf "\r  waiting ... $i"
  done
}

function get_random_password () {
  LENGTH=$1
  if [ -z "$LENGTH" ]; then
    # If length not specified
    LENGTH=16;
  fi
  echo "$(< /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c $LENGTH)";
}

function print_or_log () {
  local LINE=$1
  if [ "$VERBOSE" = true ]; then
    echo "+ $LINE";
  else
    echo "[$(timestamp)] $LINE" >> $LOG_FILE
  fi
}

function all_done {
  echo "All done!"
  echo;
  echo "=> Log file available at: $LOG_FILE"
  echo "=> SFTP/SSH credentials for users created at: $SFTP_CREDENTIALS_FILE"
  echo "=> sDatabase and Database user credentials created at: $DB_CREDENTIALS_FILE"
}

################################################ REQUIREMENTS CHECK ####################################################

function check_software () {
  while [ "$1" != "" ]; do
    if ! command -v $1 &> /dev/null; then
      error_exit "$1 could not be found: Please verify it's installed and what is the full path to it";
    fi
    # Next parameter passed
    shift
  done
}

################################################## START UP LOGIC ######################################################

# No parameters passed, print help and exit
[ -z "$1" ] && help_text && exit 0

# Argument Loop
while [ "$1" != "" ]; do
  case $1 in
    "-h" | "--help" )
    	help_text
    	exit 0
    ;;

    "-c" | "--client-id" )
    	shift
    	CLIENT_ID=$1
    ;;

    "-k" | "--api-key" )
    	shift
    	API_KEY=$1
    ;;

    # cPanel domain to migrate
    "-d" | "--domain" )
      shift
      MAIN_DOMAIN=$1
    ;;

    # Path to directory we store temporary files and logs
    "-t" | "--tmp-dir" )
      shift
      TMP_DIR=$1
    ;;

    "-v" | "--verbose" )
      VERBOSE=true
    ;;

    "-y" | "--assume-yes" )
      YES_TO_ALL=true
    ;;

	esac

  # Next Argument
  shift
done

# The script will try writting data to TMP_DIR, we must ensure this directory exists
mkdir --parents $TMP_DIR; # no error if existing, make parent directories as needed

# Sanity check: verify the basic software quirements are met
check_software $JQ $WHMAPI1 $RSYNC $CURL $MYSQLDUMP $MYSQL $SSHPASS $SSH $GZIP

################################################## BASE FUNCTIONS ######################################################

function migrate_domain () {
  local CPANEL_DOMAIN_DATA=$1
  print_or_log "--- Starting up ---"

  DOMAIN=$(echo $CPANEL_DOMAIN_DATA | $JQ --raw-output '."domain"');
  print_or_log "domain: $DOMAIN";

  CPANEL_USER=$(echo $CPANEL_DOMAIN_DATA | $JQ --raw-output '."user"');
  print_or_log "cpanel user: $CPANEL_USER";

  local CPANEL_PHP_VERSION=$(echo $CPANEL_DOMAIN_DATA | $JQ --raw-output '."php_version"');
  PHP_VERSION="${CPANEL_PHP_VERSION//[!1-9]/}" # Note: we do not want 0s here. SiteHost convention
  print_or_log "php_version for $DOMAIN: $PHP_VERSION";

  cpanel_get_userdata $DOMAIN;
  VHOSTS="${DOMAIN},${ALIAS_LIST}";

  STACK_NAME=$(get_random_name)
  IMAGE_CODE="sitehost-php$PHP_VERSION-apache";
  IMAGE_VERSION=$(get_last_image_version $IMAGE_CODE);
  DOCKERFILE=$(build_dockerfile $STACK_NAME $DOMAIN $IMAGE_CODE $IMAGE_VERSION $VHOSTS)
  #echo; echo $DOCKERFILE; echo;

  create_container_for_domain

  create_ssh_user_for_container

  copy_website_files

  cpanel_create_databases

  print_or_log "--- Done ---"
}

function create_container_for_domain {
  if [ "$YES_TO_ALL" = false ]; then
    read -p "Would you like to create a Container for \"$DOMAIN\" [y/N]: " RESPONSE;
  else
    RESPONSE="yes"
  fi

  case "$RESPONSE" in
    [yY][eE][sS]|[yY] )
        print_or_log "Yes, creating Container on $SERVER_NAME with IP $SERVER_IP";
        local CREATE_CONTAINER_QUERY=$($CURL --data "apikey=$API_KEY&client_id=$CLIENT_ID&server=$SERVER_NAME&name=$STACK_NAME&label=$DOMAIN&enable_ssl=0&docker_compose=$DOCKERFILE" --request POST --silent "https://api.sitehost.nz/1.1/cloud/stack/add.json");
        local QUERY_STATUS=$(echo $CREATE_CONTAINER_QUERY | $JQ --raw-output '.status');
        if [ "$QUERY_STATUS" == "true" ]; then
          #echo "Creation results $CREATE_CONTAINER_QUERY";
          local QUERY_JOB_ID=$(echo $CREATE_CONTAINER_QUERY | $JQ --raw-output '."return"."job_id"');
          check_job_status $QUERY_JOB_ID;
        else
          local QUERY_MSG=$(echo $CREATE_CONTAINER_QUERY | $JQ --raw-output '."msg"');
          error_exit "$LINENO: Failed creating a Container for \"$DOMAIN\". Message: $QUERY_MSG";
        fi
        ;;
    * )
        print_or_log "No, won't create a Container";
        ;;
  esac
}

function cpanel_get_userdata () {
  local CPANEL_DOMAIN=$1
  local CPANEL_USER_DATA=$($WHMAPI1 --output=json domainuserdata domain=$CPANEL_DOMAIN);
  local CPANEL_SERVERALIAS=$(echo $CPANEL_USER_DATA | $JQ --raw-output '."data"."userdata"."serveralias"');
  CPANEL_DOCUMENTROOT=$(echo $CPANEL_USER_DATA | $JQ --raw-output '."data"."userdata"."documentroot"');

  ALIAS_LIST="";
  for ALIAS in $CPANEL_SERVERALIAS; do
    if ! [[ $ALIAS == mail.* ]]; then
      # We do not want any cPanel webmail subdomains on this list
      ALIAS_LIST="${ALIAS_LIST}${ALIAS},";
    fi
  done
  # Remove last character ,
  ALIAS_LIST="${ALIAS_LIST%?}"
}

function cpanel_create_databases {
  DB_INFO=$($WHMAPI1 list_mysql_databases_and_users --output=json  user=$CPANEL_USER);
  #echo "DB INFO: $DB_INFO";
  #TODO: Investigate possible point of failure. Check what are the results when cPanel server has MariaDB installed
  local CPANEL_MYSQL_VERSION=$(echo $DB_INFO | $JQ --raw-output ".data.mysql_config.\"mysql-version\"");
  MYSQL_VERSION="${CPANEL_MYSQL_VERSION//[!0-9]/}"
  print_or_log "mysql_version for $CPANEL_USER: $MYSQL_VERSION";

  CPANEL_DATABASES_ARRAY=$(echo $DB_INFO | $JQ --raw-output '.data."mysql_databases" | keys');
  local NUMBER_OF_DATABASES=$(echo $CPANEL_DATABASES_ARRAY | $JQ --raw-output 'length');
  if [ "$NUMBER_OF_DATABASES" -gt "0" ]; then
    create_databases
  else
    print_or_log "No databases found for user: $CPANEL_USER"
  fi
}

function create_databases {
  local CPANEL_DATABASES=$(echo $CPANEL_DATABASES_ARRAY | $JQ --raw-output '.[]');
  for CPANEL_DATABASE in $CPANEL_DATABASES; do
    if [ "$YES_TO_ALL" = false ]; then
      read -p "Would you like to create a database to replace \"$CPANEL_DATABASE\" on the server? [y/N]: " RESPONSE;
    else
      RESPONSE="yes"
    fi

    case "$RESPONSE" in
      [yY][eE][sS]|[yY] )
          MYSQLHOST="mysql$MYSQL_VERSION";
          CONTAINER_DB_NAME=${CPANEL_DATABASE//_/}; # Underscore on DB name not supported
          local DB_CREATE_QUERY=$($CURL --data "apikey=$API_KEY&client_id=$CLIENT_ID&server_name=$SERVER_NAME&mysql_host=$MYSQLHOST&database=$CONTAINER_DB_NAME&container=$STACK_NAME" --request POST --silent "https://api.sitehost.nz/1.1/cloud/db/add.json");
          local QUERY_STATUS=$(echo $DB_CREATE_QUERY | $JQ --raw-output '.status');
          if [ "$QUERY_STATUS" == "true" ]; then
            local QUERY_JOB_ID=$(echo $DB_CREATE_QUERY | $JQ --raw-output '."return"."job_id"');
            print_or_log "Trying to create database name \"$CONTAINER_DB_NAME\"";
            check_job_status $QUERY_JOB_ID;
            create_database_users $CPANEL_DATABASE;
          else
            local QUERY_MSG=$(echo $DB_CREATE_QUERY | $JQ --raw-output '."msg"');
            error_exit "$LINENO: Failed creating database: $CONTAINER_DB_NAME. Message: $QUERY_MSG";
          fi
          ;;
      * )
          print_or_log "Ok, won't create a replacement for $CPANEL_DATABASE";
          ;;
    esac
  done
}

function create_database_users {
  local CPANEL_DATABASE=$1
  local CPANEL_DATABASE_USERS=$(echo $DB_INFO | $JQ --raw-output ".\"data\".\"mysql_databases\".\"$CPANEL_DATABASE\"[]");
  for CPANEL_DATABASE_USER in $CPANEL_DATABASE_USERS; do
    if [ "$YES_TO_ALL" = false ]; then
      read -p "Would you like to create a database user to replace \"$CPANEL_DATABASE_USER\" on the server? [y/N]: " RESPONSE;
    else
      RESPONSE="yes"
    fi

    case "$RESPONSE" in
      [yY][eE][sS]|[yY] )
          CONTAINER_DB_USER=${CPANEL_DATABASE_USER//_/}; # Underscore on DB users not supported
          CONTAINER_DB_USER_PWD=$(get_random_password); # Max length is 16
          # TODO: Check the data here, get user grants from cPanel
          local DB_USER_QUERY=$($CURL --data "apikey=$API_KEY&client_id=$CLIENT_ID&server_name=$SERVER_NAME&mysql_host=$MYSQLHOST&username=$CONTAINER_DB_USER&password=$CONTAINER_DB_USER_PWD&database=$CONTAINER_DB_NAME&grants[]=select&grants[]=insert&grants[]=update&grants[]=delete&grants[]=create&grants[]=drop&grants[]=alter&grants[]=index&grants[]=create view&grants[]=show view&grants[]=lock tables&grants[]=create temporary tables" --request POST --silent "https://api.sitehost.nz/1.1/cloud/db/user/add.json");
          local QUERY_STATUS=$(echo $DB_USER_QUERY | $JQ --raw-output '.status');
          if [ "$QUERY_STATUS" == "true" ]; then
            local QUERY_JOB_ID=$(echo $DB_USER_QUERY | $JQ --raw-output '."return"."job_id"');
            print_or_log "Trying to create database user \"$CPANEL_DATABASE_USER\" with password \"$CONTAINER_DB_USER_PWD\"";
            check_job_status $QUERY_JOB_ID;
            record_database_user_credentials
            copy_database_dump $CPANEL_DATABASE;
          else
            local QUERY_MSG=$(echo $DB_USER_QUERY | $JQ --raw-output '."msg"');
            error_exit "$LINENO: Failed creating database user: $CPANEL_DATABASE_USER. Message: $QUERY_MSG";
          fi
          ;;
      * )
          print_or_log "Ok, won't create a replacement database user for $CPANEL_DATABASE_USER";
          ;;
    esac
  done
}


function copy_database_dump {
  local CPANEL_DATABASE=$1
  # TODO: This depends on SSH credentials we only have if we created SFTP user on the runtime. Maybe do error handling or implement alternative methods.
  if [ "$YES_TO_ALL" = false ]; then
    read -p "Would you like to backup the database \"$CPANEL_DATABASE\" and restore it on the Container? [y/N]: " RESPONSE;
  else
    RESPONSE="yes"
  fi

  case "$RESPONSE" in
    [yY][eE][sS]|[yY] )
        local DATABASE_DUMP_FILENAME=$(echo ${CPANEL_DATABASE}_$(fulldate).sql.gz)
        local DATABASE_DUMP_PATH=$(echo ${TMP_DIR}/${DATABASE_DUMP_FILENAME});
        print_or_log "Trying to create dump at \"$DATABASE_DUMP_PATH\"";
        $MYSQLDUMP $CPANEL_DATABASE | $GZIP > $DATABASE_DUMP_PATH;
        print_or_log "Trying to copy dump to the Container's application directory";
        $RSYNC --rsh="$SSHPASS -p $SSH_PASSWORD $SSH -o StrictHostKeyChecking=no" --archive --stats --delete $DATABASE_DUMP_PATH ${SSH_USERNAME}@${SERVER_IP}:/container/application/
        # TODO: Error handling
        print_or_log "Removing dump at \"$DATABASE_DUMP_PATH\"";
        rm --force $DATABASE_DUMP_PATH;
        restore_database_from_dump $DATABASE_DUMP_FILENAME;
        ;;
    * )
        print_or_log "Ok, won't store a database backup of \"$CPANEL_DATABASE\" on the Container";
        ;;
  esac

}

function restore_database_from_dump () {
  local DATABASE_DUMP_FILENAME=$1
  if [ "$YES_TO_ALL" = false ]; then
    read -p "Would you like to restore the \"$CONTAINER_DB_NAME\" on the Container? [y/N]: " RESPONSE;
  else
    RESPONSE="yes"
  fi

  case "$RESPONSE" in
    [yY][eE][sS]|[yY] )
        $SSHPASS -p $SSH_PASSWORD $SSH -o StrictHostKeyChecking=no ${SSH_USERNAME}@${SERVER_IP} "gunzip < /container/application/$DATABASE_DUMP_FILENAME | mysql --host=$MYSQLHOST --user=${CONTAINER_DB_USER} --password=${CONTAINER_DB_USER_PWD} $CONTAINER_DB_NAME"
        # TODO: Error handling, check for CONTAINER_DB_USER_PWD and CONTAINER_DB_USER
        ;;
    * )
        print_or_log "Ok, won't try to restore the \"$CONTAINER_DB_NAME\" from the dump file";
        ;;
  esac
}

function build_dockerfile () {
  local STACK_NAME=$1
  local STACK_LABEL=$2
  local IMAGE_CODE=$3
  local IMAGE_VERSION=$4
  local VHOSTS=$5
  DOCKERFILE_TEMPLATE="
version: '2.1'
services:
    $STACK_NAME:
        container_name: $STACK_NAME
        environment:
            - 'VIRTUAL_HOST=$VHOSTS'
            - CERT_NAME=$STACK_LABEL
        expose:
            - 80/tcp
        image: 'registry.sitehost.co.nz/$IMAGE_CODE:$IMAGE_VERSION'
        labels:
            - 'nz.sitehost.container.website.vhosts=$VHOSTS'
            - nz.sitehost.container.image_update=True
            - nz.sitehost.container.label=$STACK_LABEL
            - nz.sitehost.container.type=www
            - nz.sitehost.container.monitored=True
            - nz.sitehost.container.backup_disable=False
        restart: unless-stopped
        volumes:
            - '/data/docker0/www/$STACK_NAME/crontabs:/cron:ro'
            - '/data/docker0/www/$STACK_NAME/application:/container/application:rw'
            - '/data/docker0/www/$STACK_NAME/config:/container/config:ro'
            - '/data/docker0/www/$STACK_NAME/logs:/container/logs:rw'
networks:
    default:
        external:
            name: infra_default"

    echo "$DOCKERFILE_TEMPLATE";
}

function get_random_name {
  local NAME_QUERY=$($CURL --silent "https://api.sitehost.nz/1.1/cloud/stack/generate_name.json?apikey=$API_KEY");
  local QUERY_STATUS=$(echo $NAME_QUERY | $JQ --raw-output '.status');
  if [ "$QUERY_STATUS" == "true" ]; then
    local NAME=$(echo $NAME_QUERY | $JQ --raw-output '.return.name');
    echo $NAME;
  else
    error_exit "$LINENO: Cannot get a random Container Name"
  fi
}

function get_last_image_version (){
  local IMAGE_CODE=$1
  local IMAGES_QUERY=$($CURL --silent "https://api.sitehost.nz/1.1/cloud/stack/image/list_all.json?apikey=$API_KEY");
  local QUERY_STATUS=$(echo $IMAGES_QUERY | $JQ --raw-output '.status');
  if [ "$QUERY_STATUS" == "true" ]; then
    local IMAGE_VERSIONS=$(echo $IMAGES_QUERY | $JQ --raw-output ".return[] | select(.code==\"$IMAGE_CODE\").\"versions\"[].\"version\"");
    local IMAGE_VERSION="${IMAGE_VERSIONS##*$'\n'}";
    echo $IMAGE_VERSION;
  else
    error_exit "$LINENO: Cannot list SiteHost Cloud Container images"
  fi
}

function check_job_status () {
  local JOB_ID=$1
  print_or_log "Verify Job ID: $JOB_ID"
  echo "Checking status of Job ID: $JOB_ID"

  while :; do

    local JOB_CHECK_QUERY=$($CURL --silent "https://api.sitehost.nz/1.1/job/get.json?apikey=$API_KEY&job_id=$JOB_ID&type=scheduler");
    local QUERY_STATUS=$(echo $JOB_CHECK_QUERY | $JQ --raw-output '.status');
    if [ "$QUERY_STATUS" == "true" ]; then
      local JOB_STATE=$(echo $JOB_CHECK_QUERY | $JQ --raw-output '."return"."state"');
      if [ $JOB_STATE == "Completed" ]; then
        print_or_log "Job ID $JOB_ID completed"
        printf "\rJob ID $JOB_ID completed! \n"
        return
      else
        printf "\r checking ... ---"
        nice_wait
      fi

    else
      local QUERY_MSG=$(echo $JOB_CHECK_QUERY | $JQ --raw-output '."msg"');
      error_exit "$LINENO: Failed checking status of Job ID: $JOB_ID. Message: $QUERY_MSG";
    fi

  done
}

function pick_destination_server {
  local SERVERS_QUERY=$($CURL --silent "https://api.sitehost.nz/1.1/server/list_all.json?apikey=$API_KEY&client_id=$CLIENT_ID");
  local QUERY_STATUS=$(echo $SERVERS_QUERY | $JQ --raw-output '.status');
  if [ "$QUERY_STATUS" == "true" ]; then
    local SERVERS_COUNT=$(( $(echo $SERVERS_QUERY | $JQ --raw-output '.return."total_items"') - 1));
    case $SERVERS_COUNT in
      -1 )
        # No Cloud Container server on the account
        error_exit "$LINENO: Cannot find a Cloud Container server on the account ID $CLIENT_ID"
        ;;

      0 )
        # Auto select the server if there's just one available
        SERVER_NAME=$(echo $SERVERS_QUERY | $JQ --raw-output '.return."data"[0]."name"');
        SRV_IPS=$(echo $SERVERS_QUERY | $JQ --raw-output '.return."data"[0]."primary_ips"[]');
        SERVER_IP=$(echo $SRV_IPS | $JQ --raw-output 'select(.prefix=="32").ip_addr');
        print_or_log "Only one server found on the account, auto selecting it.";
        ;;

      * )
        # Multiple Cloud Container servers on the account. Select one
        echo -e "\nChoose a destionation server from the list:"
        for (( i=0; i<=$SERVERS_COUNT; i++ )); do
          local SRV_NAME=$(echo $SERVERS_QUERY | $JQ --raw-output ".return.\"data\"[$i].\"name\"");
          local SRV_LABEL=$(echo $SERVERS_QUERY | $JQ --raw-output ".return.\"data\"[$i].\"label\"");
          local SRV_IPS=$(echo $SERVERS_QUERY | $JQ --raw-output ".return.\"data\"[$i].\"primary_ips\"[]");
          local SRV_IP4=$(echo $SRV_IPS | $JQ --raw-output 'select(.prefix=="32").ip_addr');
          echo "$i: Label=$SRV_LABEL, IPv4=$SRV_IP4";
        done

        while :; do
          read -p "Enter the server ID: " SRV_ID;
          [[ $SRV_ID =~ ^[0-9]+$ ]] || { echo -e "Error: \tInvalid ID, try again \n"; continue; }
          if (($SRV_ID < 0 || $SRV_ID > $SERVERS_COUNT)); then
            echo -e "Error: \tInvalid ID, try again \n";
          else
            SERVER_NAME=$(echo $SERVERS_QUERY | $JQ --raw-output ".return.\"data\"[$SRV_ID].\"name\"");
            SRV_IPS=$(echo $SERVERS_QUERY | $JQ --raw-output ".return.\"data\"[$SRV_ID].\"primary_ips\"[]");
            SERVER_IP=$(echo $SRV_IPS | $JQ --raw-output 'select(.prefix=="32").ip_addr');
            break
          fi
        done
        ;;
    esac

  else
    local QUERY_MSG=$(echo $SERVERS_QUERY | $JQ --raw-output '."msg"');
    error_exit "$LINENO: Cannot list Cloud Container servers on the account $CLIENT_ID. Message: $QUERY_MSG"
  fi

  print_or_log "Working with server name: $SERVER_NAME on IPv4: $SERVER_IP";
}

function create_ssh_user_for_container {
  if [ "$YES_TO_ALL" = false ]; then
    read -p "Would you like to create an SFTP/SSH user to access the \"$DOMAIN\" Container? [y/N]: " RESPONSE;
  else
    RESPONSE="yes"
  fi

  case "$RESPONSE" in
    [yY][eE][sS]|[yY] )
        SSH_USERNAME=$(echo ${DOMAIN//./} | head -c 16); # Remove . chars from Domain and limit length to 16 characters
        SSH_PASSWORD=$(get_random_password 20); # 20 characters should be enough
        print_or_log "Trying to create an SFTP/SSH user with name \"$SSH_USERNAME\" and password \"$SSH_PASSWORD\" on stack $STACK_NAME";
        local SFTP_USER_QUERY=$($CURL --data "apikey=$API_KEY&client_id=$CLIENT_ID&server_name=$SERVER_NAME&username=$SSH_USERNAME&password=$SSH_PASSWORD&containers[]=$STACK_NAME" --request POST --silent "https://api.sitehost.nz/1.1/cloud/ssh/user/add.json");
        local QUERY_STATUS=$(echo $SFTP_USER_QUERY | $JQ --raw-output '.status');
        if [ "$QUERY_STATUS" == "true" ]; then
          local QUERY_JOB_ID=$(echo $SFTP_USER_QUERY | $JQ --raw-output '."return"."job_id"');
          check_job_status $QUERY_JOB_ID;
          record_sftp_credentials
        else
          local QUERY_MSG=$(echo $SFTP_USER_QUERY | $JQ --raw-output '."msg"');
          error_exit "$LINENO: Cannot create SFTP/SSH user $SSH_USERNAME. Message: $QUERY_MSG"
        fi
        ;;
    * )
        print_or_log "Ok, won't create an SFTP/SSH user to access $DOMAIN";
        ;;
  esac
}

function copy_website_files {
  # TODO: This depends on SSH credentials we only have if we created SFTP user on the runtime. Maybe do error handling or implement alternative methods.
  if [ "$YES_TO_ALL" = false ]; then
    read -p "Would you like to copy website files to the \"$DOMAIN\" Container? [y/N]: " RESPONSE;
  else
    RESPONSE="yes"
  fi

  case "$RESPONSE" in
    [yY][eE][sS]|[yY] )
        print_or_log "Trying to copy files from \"$CPANEL_DOCUMENTROOT\" to the Container's public directory";
        $RSYNC --rsh="$SSHPASS -p $SSH_PASSWORD $SSH -o StrictHostKeyChecking=no" --archive --stats --delete ${CPANEL_DOCUMENTROOT}/ ${SSH_USERNAME}@${SERVER_IP}:/container/application/public/
        # TODO: Consider if we want to show stats allowing it to throw data into stdout
        # TODO: Maybe do some error handling and 2>/dev/null ?
        ;;
    * )
        print_or_log "Ok, won't copy \"$DOMAIN\" website files";
        ;;
  esac
}

function get_api_key {
  if [ -z "$API_KEY" ]; then
    local API_FILE="$(pwd)/api.key";
    if [ -f "$API_FILE" ]; then
      # If the API key is not specified, we search for a file named api.key on the current run path
      print_or_log "API key file found at $API_FILE, loading it";
      API_KEY=$(cat $API_FILE)
    else
      error_exit "$LINENO: API key not found, please specify";
    fi
  fi
}

function record_sftp_credentials () {
  touch $SFTP_CREDENTIALS_FILE;
  if [ $(wc -l <$SFTP_CREDENTIALS_FILE) -eq "0" ]; then
    # File is empty, let's put in the "headers"
    echo -e "SERVER_IP\t SFTP_USERNAME\t USER_PASSWORD" >> $SFTP_CREDENTIALS_FILE;
  fi
  echo -e "$SERVER_IP\t $SSH_USERNAME\t $SSH_PASSWORD" >> $SFTP_CREDENTIALS_FILE;
}

function record_database_user_credentials () {
  touch $DB_CREDENTIALS_FILE;
  if [ $(wc -l <$DB_CREDENTIALS_FILE) -eq "0" ]; then
    # File is empty, let's put in the "headers"
    echo -e "CPANEL_DB_USER\t CONTAINER_DB_USER\t CONTAINER_DB_USER_PWD" >> $DB_CREDENTIALS_FILE;
  fi
  echo -e "$CPANEL_DATABASE_USER\t $CONTAINER_DB_USER\t $CONTAINER_DB_USER_PWD" >> $DB_CREDENTIALS_FILE;
}

#################################################### BASE LOGIC ########################################################

get_api_key

pick_destination_server

# Let's get infomation about all domains on the server
CPANEL_DOMAINS_ARRAY=$($WHMAPI1 get_domain_info --output=json | $JQ --raw-output '.data.domains');

# Do we have a domain?
if [ -z "$MAIN_DOMAIN" ]; then

  # No domain specified, lets move all of them!
  CPANEL_DOMAINS_COUNT=$(( $(echo $CPANEL_DOMAINS_ARRAY | $JQ --raw-output 'length') - 1 ));
  for (( d=0; d<=$CPANEL_DOMAINS_COUNT; d++ )); do
    CPANEL_DOMAIN_INFO=$(echo $CPANEL_DOMAINS_ARRAY | $JQ --raw-output ".[$d]");
    DOMAIN_TYPE=$(echo $CPANEL_DOMAIN_INFO | $JQ --raw-output '."domain_type"');

    # We ignore any "domain_type" : "sub"
    # These are eduplicates of "domain_type" : "addon"
    # We ignore "domain_type" : "parked"
    # Unless it has specified it to be moved
    if [ $DOMAIN_TYPE == "main" -o $DOMAIN_TYPE == "addon" ]; then
      migrate_domain "$CPANEL_DOMAIN_INFO";
    fi

    #sleep 1
  done

else
  # Domain specified, move it regardless of type
  CPANEL_DOMAIN_INFO=$(echo $CPANEL_DOMAINS_ARRAY | $JQ --raw-output ".[] | select(.domain==\"$MAIN_DOMAIN\")");
  migrate_domain "$CPANEL_DOMAIN_INFO"
fi

all_done
