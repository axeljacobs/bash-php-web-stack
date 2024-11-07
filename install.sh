#!/bin/bash
print_green() {
  echo -e "\e[32m$1\e[0m"
  printf "\n"
}
print_red() {
  echo -e "\e[31m$1\e[0m"
  printf "\n"
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

generate_site_base_folders() {
	local _sitename="$1"
	local _webserver="$2"

	# Get correct user and groups
	if [ "$_webserver" = "caddy" ]; then
		_webserver_user="caddy"
		_webserver_group="caddy"
	else
		_webserver_user="www-data"
		_webserver_group="www-data"
	fi

	print_green "Creating /var/www/$_sitename folder structure and permissions for $_webserver"

	mkdir -p /var/www/"$_sitename"
	chown deploy:"$_webserver_group" /var/www/"$_sitename"
	chmod 0750 /var/www/"$_sitename"

	mkdir -p /var/www/"$_sitename"/logs
	chown "$_webserver_group":deploy /var/www/"$_sitename"/logs
	chmod 0740 /var/www/"$_sitename"/logs

	mkdir -p /var/www/"$_sitename"/backups
	chown root:deploy /var/www/"$_sitename"/backups
	chmod 0740 /var/www/"$_sitename"/backups

	mkdir -p /var/www/"$_sitename"/restore/db
	mkdir -p /var/www/"$_sitename"/restore/files
	chown -R root:deploy /var/www/"$_sitename"/restore
	chmod -R 0760 /var/www/"$_sitename"/restore

	mkdir -p /var/www/"$_sitename"/public
	chown deploy:"$_webserver_group" /var/www/"$_sitename"/public
	chmod 2750 /var/www/"$_sitename"/public

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
      return 1 # no files.ext found in folder
    else
      echo "Listing .$ext files in '$dir':"
#      echo "$files"
      return 0
    fi
  else
    print_red "'$dir' is not a valid directory."
  fi
}

rename_extensions() {
  local directory="$1"
  local original_extension="$2"
  local new_extension="$3"
  _current_datetime=$(date +"%Y-%m-%d_%H-%M-%S")

  # Iterate over all files with the original extension in the directory
  for file in "$directory"/*."$original_extension"; do
    # Check if file exists (handles case where no file matches the pattern)
    [ -e "$file" ] || continue

    # Get the file name without the extension
    _base_name=$(basename "$file" ."$original_extension")

    # Generate the new file name with the new extension
    _new_file="$directory/${_base_name}.${new_extension}_${_current_datetime}"

    # Rename the file
    mv "$file" "$_new_file"

    # Output the renamed file
		# echo "Renamed $file to $_new_file"
  done
}

delete_symlinks() {
	local directory="$1"
	# find and delete symlinks in folder
	find "$directory" -type l -delete
}

generate_php_pool_config() {
	# need php_version
	# need sitename
	# need webserver
	local _php_version="$1"
	local _webserver="$2"
	local _sitename="$3"

	# Get correct user and groups
	if [ "$_webserver" = "caddy" ]; then
		_webserver_user="caddy"
		_webserver_group="caddy"
	else
		_webserver_user="www-data"
		_webserver_group="www-data"
	fi

	# Get all installed version and disable existing php_pool files
	print_green "Disabling all existing php-fpm pool config for all php versions"
	for dir in /etc/php/*/; do
		if [ -d "$dir" ]; then
			rename_extensions "${dir}/fpm/pool.d" "conf" "disabled"
		fi
	done

	# generate a new file
	_php_version_underscore="${_php_version//./_}"
	_php_pool_socket="/var/run/php${_php_version_underscore}-fpm-${_sitename}.sock"

  # !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
  # WARNING TAB INDENT must BE REAL TABS not SPACES otherwise
  # EOF and inside tabs will not work properly
  # !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
	cat > "/etc/php/${_php_version}/fpm/pool.d/${_sitename}.conf" <<-EOF
	[$_sitename]

	user = $_webserver_user
	group = $_webserver_group
	listen.owner = $_webserver_user
	listen.group = $_webserver_group

	listen = $_php_pool_socket

	pm = dynamic
	pm.max_children = 5
	pm.start_servers = 2
	pm.min_spare_servers = 1
	pm.max_spare_servers = 3

	chdir = /
	EOF
}

generate_caddy_base_config() {
	_current_datetime=$(date +"%Y-%m-%d_%H-%M-%S")
	# create /etc/caddy/conf.d folder
	mkdir -p "/etc/caddy/conf.d"
  mv "/etc/caddy/Caddyfile" "/etc/caddy/Caddyfile_backup_${_current_datetime}"
  # check if file exists if yes or no replace with existing content
  cat > "/etc/caddy/Caddyfile" <<-EOF
  #
  # Configuration file generated by install script on the $_current_datetime
  #
	# Caddy Health check on localhost:2016
	:2016 {
		respond "webserver is working !"
	}

 	# Import site configuration files *.caddy
	import /etc/caddy/conf.d/*.caddy
	EOF
	# Reformat caddy file
}


generate_caddy_website_file() {
	local _sitename="$1"
	local _php_version="$2"

	_php_pool_socket="/var/run/php${_php_version//./_}-fpm-${_sitename}.sock"

	cat > "/etc/caddy/conf.d/${sitename}.caddy" <<-EOF
	#
	# Configuration file generated by install script on the $_current_datetime
	#
	http://$_sitename:80 {
		# unauthorized paths
    @disallowed {
			path /xmlrpc.php
			path /wp-config.php
      path /readme.html
      path /wp-content/uploads/*.php
      path /wp-content/uploads/**/*.php
    }
    # root of site
    root * /var/www/$_sitename/public
    # PHP-FPM sock
    php_fastcgi unix/$_php_pool_socket
    # Static content
    file_server
    # Gzip compression
    encode gzip
    # access log
    log {
			output file /var/www/$_sitename/logs/$_sitename.log {
				roll_size 10mb
				roll_keep 20
				roll_keep_for 720h
			}
		}

    # Return 404 on unauthorized paths
    respond @disallowed 404
  }
	EOF
	caddy fmt "/etc/caddy/conf.d/${sitename}.caddy" --overwrite
}

generate_nginx_website_file() {
	local _sitename="$1"
	local _php_version="$2"

	_php_pool_socket="/var/run/php${_php_version//./_}-fpm-${_sitename}.sock"

	cat > "/etc/nginx/sites-available/${sitename}" <<-EOF
	#
	# Configuration file generated by install script on the $_current_datetime
	#
	server {
		# Port to listen
		listen 80;
		# listen [::].80;

		# Sitename to listen
		server_name $_sitename;

		# Path to document root
		root /var/www/$_sitename/public;

		# File to be used as index
		index index.php;

		# Overrides logs defined in nginx.conf.
		access_log /var/www/$_sitename/logs/access.log;
		error_log /var/www/$_sitename/logs/error.log;

		# Exclusions
		# Deny all attempts to access hidden files such as .htaccess, .htpasswd, .DS_Store (Mac).
		# Keep logging the requests to parse later (or to pass to firewall utilities such as fail2ban)
		location ~* /\.(?!well-known\/) {
			deny all;
		}

		# Prevent access to certain file extensions
		location ~\.(ini|log|conf)$ {
			deny all;
		}

		# Deny access to any files with a .php extension in the uploads directory
		# Works in sub-directory installs and also in multisite network
		# Keep logging the requests to parse later (or to pass to firewall utilities such as fail2ban)
		location ~* /(?:uploads|files)/.*\.php$ {
			deny all;
		}

		# Security
		# Generic security enhancements. Use https://securityheaders.io to test
		# and recommend further improvements.

		# Hide Nginx version in error messages and response headers.
		server_tokens off;

		# Don't allow pages to be rendered in an iframe on external domains.
		add_header X-Frame-Options "SAMEORIGIN" always;

		# MIME sniffing prevention
		add_header X-Content-Type-Options "nosniff" always;

		# Enable cross-site scripting filter in supported browsers.
		add_header X-Xss-Protection "1; mode=block" always;

		# Whitelist sources which are allowed to load assets (JS, CSS, etc). The following will block
		# only none HTTPS assets, but check out https://scotthelme.co.uk/content-security-policy-an-introduction/
		# for an in-depth guide on creating a more restrictive policy.
		# add_header Content-Security-Policy "default-src 'self' https: data: 'unsafe-inline' 'unsafe-eval';" always;

		# Static files
		# Don't cache appcache, document html and data.
		location ~* \.(?:manifest|appcache|html?|xml|json)$ {
			expires 0;
		}

		# Cache RSS and Atom feeds.
		location ~* \.(?:rss|atom)$ {
			expires 1h;
		}

		# Caches images, icons, video, audio, HTC, etc.
		location ~* \.(?:jpg|jpeg|gif|png|ico|cur|gz|svg|mp4|ogg|ogv|webm|htc)$ {
			expires 1y;
			access_log off;
		}

		# Cache svgz files, but don't compress them.
		location ~* \.svgz$ {
			expires 1y;
			access_log off;
			gzip off;
		}

		# Cache CSS and JavaScript.
		location ~* \.(?:css|js)$ {
			expires 1y;
			access_log off;
		}

		# Cache WebFonts.
		location ~* \.(?:ttf|ttc|otf|eot|woff|woff2)$ {
			expires 1y;
			access_log off;
			add_header Access-Control-Allow-Origin *;
		}

		# Don't record access/error logs for robots.txt.
		location = /robots.txt {
			try_files \$uri \$uri/ /index.php?\$args;
			access_log off;
			log_not_found off;
		}

		location / {
			try_files \$uri \$uri/ /index.php?\$args;
		}

		location ~ \.php$ {
			try_files \$uri =404;
			fastcgi_param  QUERY_STRING       \$query_string;
      fastcgi_param  REQUEST_METHOD     \$request_method;
      fastcgi_param  CONTENT_TYPE       \$content_type;
      fastcgi_param  CONTENT_LENGTH     \$content_length;

      fastcgi_param  SCRIPT_NAME        \$fastcgi_script_name;
      fastcgi_param  SCRIPT_FILENAME    \$document_root/\$fastcgi_script_name;
      fastcgi_param  REQUEST_URI        \$request_uri;
      fastcgi_param  DOCUMENT_URI       \$document_uri;
      fastcgi_param  DOCUMENT_ROOT      \$document_root;
      fastcgi_param  SERVER_PROTOCOL    \$server_protocol;
      fastcgi_param  REQUEST_SCHEME     \$scheme;
      fastcgi_param  HTTPS              \$https if_not_empty;

      fastcgi_param  GATEWAY_INTERFACE  CGI/1.1;
      fastcgi_param  SERVER_SOFTWARE    nginx/\$nginx_version;

      fastcgi_param  REMOTE_ADDR        \$remote_addr;
      fastcgi_param  REMOTE_PORT        \$remote_port;
      fastcgi_param  SERVER_ADDR        \$server_addr;
      fastcgi_param  SERVER_PORT        \$server_port;
      fastcgi_param  SERVER_NAME        \$server_name;

			# Use the php pool
			fastcgi_pass   unix:$_php_pool_socket;
		}
	}
	EOF
}


generate_webserver_conf_file() {
	local _webserver="$1"
	local _sitename="$2"
	local _php_version="$3"

	case "$_webserver" in
			"caddy")
				print_green "Disabling existing caddy site configs"
				rename_extensions "/etc/caddy/conf.d/" "caddy" "disabled"

				print_green "Generate a new config for ${_sitename}"
				generate_caddy_website_file "$_sitename" "$_php_version"
				;;
			"nginx")
				print_green "Disabling existing nginx site configs"

				# remove existing symlinks in sites-enabled
				delete_symlinks "/etc/nginx/sites-enabled"

				# create new file in site-available
				generate_nginx_website_file "$_sitename" "$_php_version"

				# create symlink in sites-enabled
				ln -s /etc/nginx/sites-available/"${_sitename}" /etc/nginx/sites-enabled/"${_sitename}"
				;;
			"apache2")
				echo "Apache is not managed yet... quit"
				exit
				;;
			*)
				echo "Error... quit"
				exit
				;;
	esac
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
#  options=("caddy" "nginx" "apache2" "Quit")
  options=("caddy" "nginx")
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
		generate_caddy_base_config
    sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https curl
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
    sudo apt update
    sudo apt install -y caddy
    # Reformat Caddyfile
    caddy fmt "/etc/caddy/Caddyfile" -- overwrite
    # Start & enable caddy service
    systemctl start caddy && systemctl enable caddy
  elif [ "$webserver" = "nginx" ]; then
    echo "nginx"
    add-apt-repository ppa:ondrej/nginx-mainline
    apt install -y nginx
  	systemctl start nginx && systemctl enable nginx
    systemctl status nginx

  elif [ "$webserver" = "apache2" ]; then
    echo "apache2"
    # TODO add apache2
    add ppa:ondrej/apache2
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
  php_version_installed=$(php --version | awk -F'[ .]' '/^PHP/{print $2"."$3}')
  print_red "PHP $php_version_installed already installed"

  # ask to continue to install new version
  if yes_no_prompt "Do you want to install a new php?"; then
  	# TODO Stop php-fpm existing services
    install_php="yes"
  else
    install_php="no"
    php_version="$php_version_installed"
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
    print_green "Installing php$php_version"
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

# Get correct user and groups
if [ "$webserver" = "caddy" ]; then
	webserver_group="caddy"
else
	webserver_group="www-data"
fi

print_green "Adding the deploy user"
useradd -m -g "deploy" -s /bin/bash "deploy"
usermod -a -G "$webserver_group" deploy

# Setup website folders
#-----------------------

if ! is_folder_empty "/var/www/"; then
  print_red "Warning /var/www/ contains already one or more folders"
fi

print_green "Configure website"

# shellcheck disable=SC2162
read -p "Enter website name (ie www.flexiways.be, intranet.nexx.be, nexxit.be) [website]:" sitename
sitename=${sitename:-website}

# Create base folder structure for website
# TODO check if problem if folder already exists
generate_site_base_folders "$sitename" "$webserver"

# generate simple phpinfo file to the website zone
echo "<?php phpinfo(); ?>" > /var/www/"${sitename}"/public/index.php

# Setup php-fpm pool
#--------------------
print_green "Setup php-fpm pool configuration"

# Set to always configure a new php_pool and disabling the existing ones
print_green "Generate new php-fpm ${php_version} pool config for ${sitename} for ${webserver}"
generate_php_pool_config "$php_version" "$webserver" "$sitename"


# Restart PHP-FPM
systemctl restart "php${php_version}-fpm"

# check process for php-fpm pool
print_green "Waiting 2 seconds and checking running php-pools for ${sitename}"
sleep 2
process_count=$(ps aux | grep "php-fpm: pool ${sitename}" | grep -v grep | wc -l)

if [ "$process_count" -eq 0 ]; then
  print_red "No php pool running for ${sitename}"
else
  echo "There are ${process_count} php-fpm processes running for the pool ${sitename}."
fi


# Setup webserver config for the site
#-------------------------------------
print_green "Setup ${webserver} configuration for ${sitename}"

# disable existing configs and generate new website config
generate_webserver_conf_file "$webserver" "$sitename" "$php_version"

# reload webserver
print_green "Reload ${webserver} webserver"
systemctl restart "$webserver"

