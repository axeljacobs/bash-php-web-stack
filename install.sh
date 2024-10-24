#!/bin/bash

print_green() {
  echo -e "\e[32m$1\e[0m"
}
print_red() {
  echo -e "\e[31m$1\e[0m"
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


# Install NGINX
#---------------
print_green "Installing Nginx..."

apt install nginx -y
systemctl start nginx && systemctl enable nginx
systemctl status nginx

# Install PUP
#-------------
print_green "Installing PHP..."

sudo add-apt-repository ppa:ondrej/php -y
sudo apt update

PS3='Which pup version do you want to install ?: '
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
#echo "You chose pup version: $php_version"

print_green "installing php$php_version"
apt install \
	php"$php_version" \
	php"$php_version"-cli \
	php"$php_version"-common \
	php"$php_version"-fpm \
	php"$php_version"-xml \
	php"$php_version"-zip \
	php"$php_version"-mbstring \
	php"$php_version"-curl \
	php"$php_version"-opcache \

# Install MariaDB
#-----------------

apt install mariadb-server -y
systemctl start mariadb && systemctl enable mariadb
systemctl status mariadb
mysql_secure_installation


# Setup user account & group
#----------------------------

# print_green "Setup user for running the wordpress"
# read -p 'Provide a username for the wordpress folder security (ie. prod, deploy, staging) [prod]: ' user
# user=${user:-prod}
# echo $user
# useradd -m -g "$user" -s /bin/bash "$username"

print_green "Add deploy user"
useradd -m -g "deploy" -s /bin/bash "deploy"
usermod -a -G www-data deploy

# Setup website folders
#-----------------------

print_green "Please entre the site name"
# shellcheck disable=SC2162
read -p "Website name (ie www.flexiways.be, intranet.nexx.be, nexxit.be) [website]:" sitename
sitename=${sitename:-website}

mkdir /var/www/"$sitename"
chown www-data:www-data /var/www/"$sitename"
chmod 770 www-data:www-data /var/www/"$sitename"

mkdir /var/www/"$sitename"/logs
chown www-data:www-data /var/www/"$sitename"/logs
chmod 2750 www-data:www-data /var/www/"$sitename"/logs

mkdir /var/www/"$sitename"/backups
chown root:deploy /var/www/"$sitename"/backups
chmod 2750 www-data:www-data /var/www/"$sitename"/backups

mkdir /var/www/"$sitename"/www
chown www-data:www-data /var/www/"$sitename"/www
chmod 2770 www-data:www-data /var/www/"$sitename"/www
