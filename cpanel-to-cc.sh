#!/bin/bash

################################################### DECLARATIONS #######################################################

JQ="/usr/bin/jq"
WHMAPI1="/usr/sbin/whmapi1"
UAPI="/usr/bin/uapi"
CURL="/usr/bin/curl"
TEMP_DIR="/tmp/cpanel_to_cc"
API_KEY=$(cat $(pwd)/api.key 2>/dev/null)

################################################ REQUIREMENTS CHECK ####################################################

if ! command -v $JQ &> /dev/null; then
    echo "$JQ could not be found: Please verify it's installed and what is the path to it"
    exit
fi

if ! command -v $WHMAPI1 &> /dev/null; then
  echo "$WHMAPI1 could not be found: Please verify it's installed and what is the path to it"
  exit
fi

#if ! command -v $UAPI &> /dev/null; then
#    echo "$UAPI could not be found: Please verify it's installed and what is the path to it"
#    exit
#fi

if ! command -v $CURL &> /dev/null; then
  echo "$CURL could not be found: Please verify it's installed and what is the path to it"
  exit
fi

################################################# HELPER FUNCTIONS #####################################################

function help_text {
	echo -e "This is how you use this:\n"
	echo -e "\t-c, --client-id \n\t\t Your SiteHost Client ID \n"
	echo -e "\t-k, --api-key \n\t\t Your SiteHost API key \n"
  echo -e "\t-d, --domain \n\t\t (Optional) The cPanel domain to migrate. If not specified we try migrate all \n"
}

function error_exit {
  echo "$(basename $0): ${1:-"Unknown Error"}" 1>&2
  exit 1
}

function timestamp {
  date +"%F %T"
}

function nice_wait {
  for i in {001..010}; do
    sleep 1
    printf "\r  waiting ... $i"
  done
}

function check_job_status () {
  local JOB_ID=$1
  echo "Checking status of Job ID: $JOB_ID"
  while :; do

    local JOB_CHECK_QUERY=$($CURL --silent "https://api.sitehost.nz/1.1/job/get.json?apikey=$API_KEY&job_id=$JOB_ID&type=scheduler");
    local QUERY_STATUS=$(echo $JOB_CHECK_QUERY | $JQ --raw-output '.status');
    if [ "$QUERY_STATUS" == "true" ]; then
      local JOB_STATE=$(echo $JOB_CHECK_QUERY | $JQ --raw-output '."return"."state"');
      if [ $JOB_STATE == "Completed" ]; then
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

################################################## START UP LOGIC ######################################################

# No parameters passed, print help and exit
[ -z "$1" ] && help_text && exit 0

# Argument Loop
while [ "$1" != "" ]; do
  case $1 in
    # USAGE!!!!
    "-h" | "--help" )
    	help_text
    	exit 0
    ;;

    # Client ID
    "-c" | "--client-id" )
    	shift
    	CLIENT_ID=$1
    ;;

    # API key
    "-k" | "--api-key" )
    	shift
    	API_KEY=$1
    ;;

    # cPanel user to migrate
    "-d" | "--domain" )
      shift
      MAIN_DOMAIN=$1
    ;;

	esac

  # Next Argument
  shift
done

################################################## BASE FUNCTIONS ######################################################
function migrate_user () {
  CPANEL_USER=$1

  if [ "$CPANEL_USER" == "root" ]; then
    error_exit "$LINENO: Cannot migrate root user"
  fi

  echo "Server name: $SERVER_NAME"
  echo "Server IP: $SERVER_IP"
  echo "--- $CPANEL_USER ---";

  cpanel_user_info_gathering
  STACK_NAME=$(get_random_name)
  #echo $STACK_NAME;
  IMAGE_CODE="sitehost-php$PHP_VERSION-apache";
  IMAGE_VERSION=$(get_last_image_version $IMAGE_CODE);
  DOCKERFILE=$(build_dockerfile $STACK_NAME $DOMAIN $IMAGE_CODE $IMAGE_VERSION)
  echo $DOCKERFILE
}

function migrate_domain () {
  local CPANEL_DOMAIN_DATA=$1

  DOMAIN=$(echo $CPANEL_DOMAIN_DATA | $JQ --raw-output '."domain"');
  echo "domain: $DOMAIN";

  CPANEL_USER=$(echo $CPANEL_DOMAIN_DATA | $JQ --raw-output '."user"');
  echo "cpanel user: $CPANEL_USER";

  local CPANEL_PHP_VERSION=$(echo $CPANEL_DOMAIN_DATA | $JQ --raw-output '."php_version"');
  PHP_VERSION="${CPANEL_PHP_VERSION//[!1-9]/}" # Note: we do not want 0s here. SiteHost convention
  echo "php_version for $DOMAIN: $PHP_VERSION";

  cpanel_get_userdata $DOMAIN;
  VHOSTS="${DOMAIN},${ALIAS_LIST}";

  STACK_NAME=$(get_random_name)
  IMAGE_CODE="sitehost-php$PHP_VERSION-apache";
  IMAGE_VERSION=$(get_last_image_version $IMAGE_CODE);
  DOCKERFILE=$(build_dockerfile $STACK_NAME $DOMAIN $IMAGE_CODE $IMAGE_VERSION $VHOSTS)
  #echo; echo $DOCKERFILE; echo;

  create_container_for_domain

  echo '---';
}

function create_container_for_domain {

  read -p "Would you like to create a Container for \"$DOMAIN\" [y/N]: " RESPONSE;
  case "$RESPONSE" in
    [yY][eE][sS]|[yY])
        echo "Yes, creating Container on $SERVER_NAME with IP $SERVER_IP";
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
    *)
        echo "No, won't create a Container";
        ;;
  esac
}

function cpanel_get_userdata () {
  local CPANEL_DOMAIN=$1
  local CPANEL_USER_DATA=$($WHMAPI1 --output=json domainuserdata domain=$CPANEL_DOMAIN);
  local CPANEL_SERVERALIAS=$(echo $CPANEL_USER_DATA | $JQ --raw-output '."data"."userdata"."serveralias"');
  local CPANEL_DOCUMENTROOT=$(echo $CPANEL_USER_DATA | $JQ --raw-output '."data"."userdata"."documentroot"');

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

function cpanel_user_info_gathering () {
  DOMAIN=$($UAPI --user=$CPANEL_USER DomainInfo list_domains --output=json | $JQ --raw-output  '.result.data.main_domain');
  echo "main_domain for $CPANEL_USER: $DOMAIN";

  local CPANEL_PARKED_DOMAINS=$($UAPI --user=$CPANEL_USER DomainInfo list_domains --output=json | $JQ --raw-output '.result.data.parked_domains');
  local PARKED_DOMAINS_COUNT=$(( $(echo $CPANEL_PARKED_DOMAINS | $JQ --raw-output 'length') - 1));
  ALIAS_LIST="";
  for (( i=0; i<=$PARKED_DOMAINS_COUNT; i++ )); do
    local ALIAS=$(echo $CPANEL_PARKED_DOMAINS | $JQ --raw-output ".[$i]");
    if [ $i -eq $PARKED_DOMAINS_COUNT ]; then
      # Last alias, do not add ,
      ALIAS_LIST="${ALIAS_LIST}${ALIAS}";
    else
      ALIAS_LIST="${ALIAS_LIST}${ALIAS},";
    fi
  done
  echo "parked_domains for $CPANEL_USER: $ALIAS_LIST";

  local CPANEL_PHP_VERSION=$($WHMAPI1 get_domain_info --output=json api.columns.enable=1 api.columns.a=user api.columns.b=php_version | $JQ --raw-output ".data.domains[] | select(.user==\"$CPANEL_USER\")" | $JQ --raw-output '.php_version');
  echo $CPANEL_PHP_VERSION;
  PHP_VERSION="${CPANEL_PHP_VERSION//[!1-9]/}" # Note: we do not want 0s here. SiteHost standard
  echo "php_version for $CPANEL_USER: $PHP_VERSION";

  local DB_INFO=$($WHMAPI1 list_mysql_databases_and_users --output=json  user=$CPANEL_USER);
  #TODO: possible point of failure. Check what are the results when cPanel server has MariaDB installed
  local CPANEL_MYSQL_VERSION=$(echo $DB_INFO | $JQ --raw-output ".data.mysql_config.\"mysql-version\"");
  MYSQL_VERSION="${CPANEL_MYSQL_VERSION//[!0-9]/}"
  echo "mysql_version for $CPANEL_USER: $MYSQL_VERSION";
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

function pick_destination_server {
  local SERVERS_QUERY=$($CURL --silent "https://api.sitehost.nz/1.1/server/list_all.json?apikey=$API_KEY&client_id=$CLIENT_ID");
  local QUERY_STATUS=$(echo $SERVERS_QUERY | $JQ --raw-output '.status');
  if [ "$QUERY_STATUS" == "true" ]; then
    local SERVERS_COUNT=$(( $(echo $SERVERS_QUERY | $JQ --raw-output '.return."total_items"') - 1));
    ## TODO: Error handling, when there's no Cloud Containers on the account
    echo -e "\nChoose a destionation server from the list:"
    for (( i=0; i<=$SERVERS_COUNT; i++ )); do
      local SRV_NAME=$(echo $SERVERS_QUERY | $JQ --raw-output ".return.\"data\"[$i].\"name\"");
      local SRV_LABEL=$(echo $SERVERS_QUERY | $JQ --raw-output ".return.\"data\"[$i].\"label\"");
      local SRV_IPS=$(echo $SERVERS_QUERY | $JQ --raw-output ".return.\"data\"[$i].\"primary_ips\"[]");
      local SRV_IP4=$(echo $SRV_IPS | $JQ --raw-output "select(.prefix==\"32\").ip_addr");
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
        SERVER_IP=$(echo $SRV_IPS | $JQ --raw-output "select(.prefix==\"32\").ip_addr");
        break
      fi
    done

  else
    error_exit "$LINENO: Cannot list Cloud Container servers on the account $CLIENT_ID"
  fi
}

#################################################### BASE LOGIC ########################################################

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

    sleep 3
  done

else
  # Domain specified, move it regardless of type
  CPANEL_DOMAIN_INFO=$(echo $CPANEL_DOMAINS_ARRAY | $JQ --raw-output ".[] | select(.domain==\"$MAIN_DOMAIN\")");
  migrate_domain "$CPANEL_DOMAIN_INFO"
fi

echo "All done!";
