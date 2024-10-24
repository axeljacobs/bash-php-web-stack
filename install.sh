#!/bin/bash

print_green() {
  echo -e "\e[32m$1\e[0m"
}
print_red() {
  echo -e "\e[31m$1\e[0m"
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
    webserver_user="caddy"
    webserver_group="caddy"

  elif [ "$webserver" = "nginx" ]; then
    echo "nginx"
    apt add ppa:ondrej/nginx-mainline
    apt install nginx -y
    systemctl start nginx && systemctl enable nginx
    systemctl status nginx
    webserver_user="www-data"
    webserver_group="www-data"

  elif [ "$webserver" = "apache2" ]; then
    echo "apache2"
    add ppa:ondrej/apache2
    webserver_user="www-data"
    webserver_group="www-data"
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

sudo add-apt-repository ppa:ondrej/php -y
sudo apt update

# Choose PHP version
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

print_green "installing php$php_version"
#
# Check if there is a difference with 8.x and 7.4 cfr apt list --installed | grep php on wordpress server
#
apt install \
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
	php"$php_version"-imagick \

# Install MariaDB
#-----------------
if service_exists "mysql"; then
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

print_green "Please entre the site name"
# shellcheck disable=SC2162
read -p "Website name (ie www.flexiways.be, intranet.nexx.be, nexxit.be) [website]:" sitename
sitename=${sitename:-website}

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
