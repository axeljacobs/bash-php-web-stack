#!/bin/bash
print_green() {
  printf "\n"
  echo -e "\e[32m$1\e[0m"
}
print_red() {
  echo -e "\e[31m$1\e[0m"
}

yes_no_prompt() {
  local prompt_message=$1
  local user_input

  while true; do
    read -p "$prompt_message (y/n): " user_input
    case $user_input in
      [Yy]* )
        return 0
        ;;
      [Nn]* )
        return 1
        ;;
      * )
        echo "Please answer yes or no (y/n)."
        ;;
    esac
  done
}



print_green "Restore a wordpress site with DB"

print_green "Checking requirements"
# Check root
#------------
if [[ $EUID -ne 0 ]]; then
  print_red "This script must be run as root."
  exit 1
fi


# Check services
# --------------

# Check if Mariadb commands for restoring the database are available
# ------------------------------------------------------------------
print_green "Check mysql command"
 if ! [ -x "$(command -v mysql)" ]; then
    print_red "ERROR: MySQL/MariaDB not installed (command mysql not found)."
    print_red "ERROR: No restore of database possible!"
    print_red "Cancel restore"
    exit 1
fi
print_green "mysql command OK"

# Check webserver
# ---------------
webserver=""

if which nginx > /dev/null 2>&1; then
  webserver="nginx"
	_webserver_user="www-data"
	_webserver_group="www-data"
fi

if which caddy > /dev/null 2>&1; then
  webserver="caddy"
	_webserver_user="caddy"
	_webserver_group="caddy"
fi

if [[ "$webserver" != "nginx" && "$webserver" != "caddy" ]]; then
  print_red "Error: nginx or caddy is not installed"
  exit 1
fi

print_green "WEBSERVER is ${webserver}"

# Check PHP
# ---------

if command -v php &> /dev/null; then
  php_version=$(php -v | grep -oP 'PHP \K[0-9]+\.[0-9]+')
else
  print_red "Error: no php found"
  exit 1
fi

print_green "PHP installed version: PHP-${php_version} "

# Stop services
# -------------
print_green "Stopping ${webserver} service"
systemctl stop $webserver
print_green "Stopping php-${php_version}-fpm service"
systemctl stop "php${php_version}-fpm"

# get the sitename from the php-fpm pool config

sitename=""
pool_dir="/etc/php/${php_version}/fpm/pool.d"

# Check if the php pool folder folder exists
if [[ -d "$pool_dir" ]]; then
  # Count the number of .conf files in the folder
  conf_count=$(find "$pool_dir"/*.conf 2>/dev/null | wc -l)

  # Provide feedback based on the count
  if [[ $conf_count -eq 0 ]]; then
    print_red "Error .conf files found in the folder '$pool_dir'."
    exit 1
  elif [[ $conf_count -gt 2 ]]; then
  	print_red "Error multiple .conf files found in the folder '$pool_dir'."
  	print_red "Fix the error and rerun this script."
    exit 1
  else
  	sitename=$(basename /etc/php/"${php_version}"/fpm/pool.d/*.conf .conf)
  fi
else
 print_red "The folder '$pool_dir' does not exist."
  exit 1
fi

# Stop if non sitename is defined
if [[ -z "$sitename" ]]; then
  echo "sitename is empty. Exiting with status code 1."
  exit 1
fi


# Set backup folders
print_green "Checking folders"
src_folder="/var/www/${sitename}/restore"
src_db_folder="${src_folder}/db"
src_files_folder="${src_folder}/files"
target_files_folder="/var/www/${sitename}/public"

echo "db source folder: ${src_db_folder}"
echo "files source folder: ${src_files_folder}"
echo "files target folder: ${target_files_folder}"

# SRC DB folder and file
# check folder
print_green "Checking if db file exists in  ${src_db_folder}"
if [ -z "$(ls -A "$src_db_folder")" ]; then
  print_red "The db folder $src_db_folder is empty."
  exit 1
else
	conf_count=$(find "$src_db_folder"/* 2>/dev/null | wc -l)
	if [[ $conf_count -gt 1 ]]; then
      print_red "Error multiple files in ${src_db_folder}."
      exit 1
  fi
fi
compressed_db_file=$(find "${src_db_folder}"/*.tar.gz)

# Check if the file is a compressed file
if [ -n "$compressed_db_file" ]; then
    echo "decompressing database file..."
    tar -I pigz -xvpf "$compressed_db_file" -C "$src_db_folder"
fi
db_file=$(find "${src_db_folder}"/*.sql)

echo "$db_file"
# TODO Check file extension

# SRC Files folder and files
# check folder
print_green "Checking files to restore ${src_files_folder}"
if [ -z "$(ls -A "$src_files_folder")" ]; then
  print_red "The files folder $src_files_folder is empty."
  exit 1
else
	conf_count=$(find "$src_files_folder"/* 2>/dev/null | wc -l)
	if [[ $conf_count -gt 1 ]]; then
      print_red "Error multiple files in ${src_files_folder}. We expect only one .tar.gz file !"
      exit 1
  fi
fi
targz_file=$(find "${src_files_folder}"/*.tar.gz)
echo "$targz_file"

# TARGET Files folder and files
# check folder
print_green "Checking files to restore ${target_files_folder}"
if [ -n "$(ls -A "$target_files_folder")" ]; then
  print_red "The target folder $target_files_folder is NOT empty. Please backup and empty before rerun this script"
  exit 1
  # TODO create a backup option to tar.gz the content of the public folder
fi
echo "$target_files_folder is empty."

# Decompress the tar.gz file in the public folder
print_green "Decompress archive in ${target_files_folder}"
tar -I pigz -xvpf "$targz_file" -C "$target_files_folder"

# Reset ownership and permission
# Ownership
print_green "Resetting ownership and permissions for ${target_files_folder}"
chown -R deploy:"$_webserver_group" /var/www/"$sitename"/public
# Permissions
# set all permission to 750
chmod -R 2750 "$target_files_folder"
# set the files (not the folder) permission correctly
find "$target_files_folder"/* -type f -exec chmod 640 {} \;

# Restore Database
# ----------------
print_green "Preparing database restore"
# Get db_name
db_name=$(grep DB_NAME "${target_files_folder}"/wp-config.php | tr "'" ':' | tr '"' ':' | cut -d: -f4)
# Get db_user
db_user=$(grep DB_USER "${target_files_folder}"/wp-config.php | tr "'" ':' | tr '"' ':' | cut -d: -f4)
# Get db_password
db_password=$(grep DB_PASSWORD "${target_files_folder}"/wp-config.php | tr "'" ':' | tr '"' ':' | cut -d: -f4)


# Check if database exists
print_green "Checking if database ${db_name} exists"
#   If yes STOP or rename/export existing database
db=$(mysql -e "SHOW DATABASES LIKE '${db_name}';")

if [ "$db" != "" ]; then
  bck_db_name="bck_$(date +'%Y%m%d_%H%M%S')_${db_name}"
  echo "Database ${db_name} exists, renaming to ${bck_db_name}"
  # mysqladmin -u username -p"password" create library
  # $ mysql -u dbUsername -p"dbPassword" oldDatabase -sNe 'show tables' | while read table; do mysql -u dbUsername -p"dbPassword" -sNe "RENAME TABLE oldDatabase.$table TO newDatabase.$table"; done
  mysql -e "CREATE DATABASE \`$bck_db_name\`;"
  mysql "$db_name" -sNe 'show tables' | while read table; do mysql -sNe "RENAME TABLE \`$db_name\`.$table TO \`$bck_db_name\`.$table"; done
	mysql -e "DROP DATABASE \`$db_name\`;"
else
	echo "Database ${db_name} does not exists"
fi
# Create/Recreate database
echo "Create or Recreate Database ${db_name}"
mysql -e "CREATE DATABASE \`$db_name\`;"

# Restore database from file
print_green "Importing database..."
mysql "${db_name}" < "${db_file}"

# Create user with password and grant access to database
print_green "Setup database user, password and permissions"
echo "checking if ${db_user} user exists"
user_count=$(mysql -e "SELECT COUNT(*) FROM mysql.user WHERE user = '$db_user'" | tail -n1)

if [ "$user_count" -gt 0 ]
then
  echo "User exists"
else
  echo "User doesn't exist, creating"
  mysql -e "CREATE USER '${db_user}'@'localhost' IDENTIFIED BY '${db_password}';"
fi
echo "applying privileges"
mysql -e "GRANT ALL PRIVILEGES ON \`$db_name\`.* TO '${db_user}'@'localhost';"
mysql -e "FLUSH PRIVILEGES;"

# Check Reverse proxy config

# Path to your wp-config.php file
wp_config_file="${target_files_folder}/wp-config.php"

# Use grep to search for each part of the PHP snippet
print_green "Check reverse proxy config in wp-config.php"
if grep -q "if(\$_SERVER\['HTTP_X_FORWARDED_PROTO'\] == 'https')" "$wp_config_file" && \
   grep -q "\$_SERVER\['HTTPS'\] = 'on';" "$wp_config_file" && \
   grep -q "\$_SERVER\['SERVER_PORT'\] = 443;" "$wp_config_file"; then
    echo "The HTTPS-forwarded proto snippet exists in wp-config.php"
else
    print_red "The HTTPS-forwarded proto snippet does not exist in wp-config.php"
    echo "Add this snippet at the top of wp-config.php"
    printf "\nif(\$_SERVER['HTTP_X_FORWARDED_PROTO'] == 'https'){\n\t\$_SERVER['HTTPS'] = 'on';\n\t\$_SERVER['SERVER_PORT'] = 443;\n}\n\n"
fi

# restart php & webserver
print_green "Restarting php${php_version}-fpm and $webserver"
systemctl restart $webserver php"${php_version}"-fpm