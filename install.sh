#!/bin/bash

print_green() {
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

service_exists() {
    systemctl list-units --full -all | grep -Fq "$1.service"
}

# Function to check if a service is running
service_is_running() {
    systemctl is-active --quiet "$1"
}

# Function to check if a service is enabled
service_is_enabled() {
    systemctl is-enabled --quiet "$1"
}

set_webserver_credentials() {
  if [ "$1" = "caddy" ]; then
    webserver_user="caddy"
    webserver_group="caddy"
  else
    webserver_user="www-data"
    webserver_group="www-data"
  fi
}

check_php_version_installed() {
  local version=$1
  if command -v php &> /dev/null; then
    installed_version=$(php -v | grep -oP 'PHP \K[0-9]+\.[0-9]+')
    if [ "$installed_version" = "$version" ]; then
      print_red "PHP version $version is already installed."
      return 0
    else
      print_red "PHP is installed, but version is $installed_version (expected $version)."
      # TODO mange migration php version
      return 0
    fi
  else
    print_green "PHP is not installed."
    return 1
  fi
}

check_folder_exists() {
  local dir=$1

  if [ -d "$dir" ]; then
    return 0  # true (folder exists)
  else
    return 1  # false (folder does not exist)
  fi
}

is_folder_empty() {
  local dir=$1

  if [ -z "$(ls -A "$dir")" ]; then
    return 0  # true (folder is empty)
  else
    return 1  # false (folder is not empty)
  fi
}

list_files_with_extension() {
  local dir=$1
  local ext=$2

  if [ -d "$dir" ]; then
    files=$(ls "$dir"/*."$ext" 2> /dev/null)
    if [ -z "$files" ]; then
      # echo "No .$ext files found in '$dir'."
      rerurn 1 # no files.ext found in folder
    else
      echo "Listing .$ext files in '$dir':"
      echo "$files"
      return 0
    fi
  else
    print_red "'$dir' is not a valid directory."
  fi
}


# Check root
#------------
if [[ $EUID -ne 0 ]]; then
  print_red "This script must be run as root."
  exit 1
fi

# Update & upgrade
#------------------

print_green "Updating package index and upgrading installed packages..."
apt update && apt upgrade -y


# Install required packages for PHP, MySQL, Nginx
#-------------------------------------------------
print_green "Installing prerequisites..."


# Install Webserver
#-------------------

# check for existing webserver
webserver_services=("caddy" "apache2" "nginx")
webserver_found=""
webserver=""
for service in "${webserver_services[@]}"; do
    if service_exists "$service"; then
        webserver_found="$service"
        webserver="$service"
        set_webserver_credentials "$service"
        print_red "Webserver $webserver_found is already installed"
        break
    fi
done

# No webserver found choose and install ($webserver_found is empty)
if [ -z "$webserver_found" ] ; then

  # Choose webserver in a list
  PS3='Which webserver do you want to install ?: '
  options=("caddy" "nginx" "apache2" "Quit")
  select opt in "${options[@]}"
  do
    case $opt in
      "caddy")
        webserver="caddy"
        break
        ;;
      "nginx")
        webserver="nginx"
        break
        ;;
      "apache2")
        webserver="apache2"
        break
        ;;
      "Quit")
        break
        ;;
      *) echo "invalid option $REPLY";;
    esac
  done

  # install webserver
  print_green "Installing $webserver..."
  if [ "$webserver" = "caddy" ]; then
    echo "caddy"
    sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https curl
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
    sudo apt update
    sudo apt install caddy
    systemctl start caddy && systemctl enable caddy
    set_webserver_credentials "caddy"

  elif [ "$webserver" = "nginx" ]; then
    echo "nginx"
    apt add ppa:ondrej/nginx-mainline
    apt install nginx -y
    systemctl start nginx && systemctl enable nginx
    systemctl status nginx
    set_webserver_credentials "www-data"

  elif [ "$webserver" = "apache2" ]; then
    echo "apache2"
    add ppa:ondrej/apache2
    set_webserver_credentials "www-data"
    echo "Not managed yet... quit"
    exit
  else
    echo "Error... quit"
    exit
  fi
fi

# Check if webserver is running and enable
if service_is_running "$webserver" && service_is_enabled "$webserver"; then
    print_green "Service '$webserver' is running and enabled."
else
    print_red "Service '$webserver' is either not running or not enabled."
fi

# Install PHP
#-------------
print_green "Installing PHP..."

# check if any php is installed
if command -v php >/dev/null 2>&1; then
  php_major_version_installed=$(php --version | awk -F'[ .]' '/^PHP/{print $2"."$3}')
  print_red "PHP $php_major_version_installed already installed"

  # ask to continue to install new version
  if yes_no_prompt "Do you want to install a new php?"; then
    install_php="yes"
  else
    install_php="no"
  fi

# no php installed
else
  install_php="yes"
fi

# Check continue php install
if [ "$install_php" = 'yes' ]; then
  sudo add-apt-repository ppa:ondrej/php -y
  sudo apt update

  # Ask for php version to install
  PS3='Which php version do you want to install ?: '
  options=("7.4" "8.2" "8.3" "Quit")
  select opt in "${options[@]}"
  do
      case $opt in
          "7.4")
              php_version="7.4"
              break
              ;;
          "8.2")
              php_version="8.2"
              break
              ;;
          "8.3")
              php_version="8.3"
              break
              ;;
          "Quit")
              break
              ;;
          *) echo "invalid option $REPLY";;
      esac
  done

  # Check if the requested php version is already installed
  if is_php_version_installed "$php_version"; then
    # installed
    print_red "PHP $php_version is already installed"
  else
    # not installed
    print_green "installing php$php_version"
    # TODO Check if there is a difference with 8.x and 7.4 cfr apt list --installed | grep php on wordpress server
    apt install -y \
    	php"$php_version" \
    	php"$php_version"-cli \
    	php"$php_version"-common \
    	php"$php_version"-curl \
    	php"$php_version"-fpm \
    	php"$php_version"-gd \
    	php"$php_version"-intl \
    	php"$php_version"-mbstring \
    	php"$php_version"-mcrypt \
    	php"$php_version"-mysql \
    	php"$php_version"-opcache \
    	php"$php_version"-readline \
    	php"$php_version"-xml \
    	php"$php_version"-xmlrpc \
    	php"$php_version"-zip \
    	php"$php_version"-imagick

  fi
fi

# Install MariaDB
#-----------------

# Check mariadb is installed
if service_exists "mariadb"; then
  print_red "MariaDB already installed"
else
  apt install mariadb-server -y
  systemctl start mariadb && systemctl enable mariadb
  mysql_secure_installation
fi

# Check if database is running and enable
if service_is_running mariadb && service_is_enabled mariadb; then
    print_green "Service mariadb is running and enabled."
else
    print_red "Service mariadb is either not running or not enabled."
fi

# Setup user account & group
#----------------------------

# print_green "Setup user for running the wordpress"
# read -p 'Provide a username for the wordpress folder security (ie. prod, deploy, staging) [prod]: ' user
# user=${user:-prod}
# echo $user
# useradd -m -g "$user" -s /bin/bash "$username"

print_green "Add deploy user"
useradd -m -g "deploy" -s /bin/bash "deploy"
usermod -a -G "$webserver_group" deploy

# Setup website folders
#-----------------------

if ! is_folder_empty "/var/www/"; then
  print_red "Warning /var/www/ contains already one or more folders"
fi

print_green "Please enter the site name"

# shellcheck disable=SC2162
read -p "Website name (ie www.flexiways.be, intranet.nexx.be, nexxit.be) [website]:" sitename
sitename=${sitename:-website}

if check_folder_exists "/var/www/$sitename"; then
  print_red "Warning /var/www/$sitename already exists"
else
  print_green "creating /var/www/$sitename folder and subfolders with permission for $webserver"
  mkdir -p /var/www/"$sitename"
  chown "$webserver_user":"$webserver_group" /var/www/"$sitename"
  chmod 770 /var/www/"$sitename"

  mkdir -p /var/www/"$sitename"/logs
  chown "$webserver_user":"$webserver_group" /var/www/"$sitename"/logs
  chmod 2750 /var/www/"$sitename"/logs

  mkdir -p /var/www/"$sitename"/backups
  chown root:deploy /var/www/"$sitename"/backups
  chmod 2750 /var/www/"$sitename"/backups

  mkdir -p /var/www/"$sitename"/www
  chown "$webserver_user":"$webserver_group" /var/www/"$sitename"/www
  chmod 2770 /var/www/"$sitename"/www
fi

# Setup php-fpm pool
#--------------------
print_red "Setup php-fpm pool configuration"

# detect existing files
php_pool_folder="/etc/php/$php_version/fpm/pool.d/"
php_pool_ext="conf"

if list_files_with_extension "$php_pool_folder" "$php_pool_ext"; then
  print_red "configuration files already exists"
  # OPTION disable existing files

# create new file with content
else
  php_pool_file="$php_pool_folder/$sitename.$php_pool_ext"

  # shellcheck disable=SC1073
  # shellcheck disable=SC1009
  # shellcheck disable=SC1010
  cat > "$php_pool_file" <<-EOF
  ["$sitename"]

    user = "$webserver_user"
    group = "$webserver_group"

    listen = /var/run/php7_4-fpm-"$sitename".sock
    listen.owner = "$webserver_user"
    listen.group = "$webserver_group"

    pm = dynamic
    pm.max_children = 5
    pm.start_servers = 2
    pm.min_spare_servers = 1
    pm.max_spare_servers = 3

    chdir = /
  EOF



fi



# restart php

# check process for php-fpm pool

# Setup webserver config for the site
#-------------------------------------
