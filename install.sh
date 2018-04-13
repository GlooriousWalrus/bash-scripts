#!/bin/bash
#
# LibreNMS with nginx (https).
# Supported OS: Ubuntu 16.04
# Author: Okas

export DEBIAN_FRONTEND=noninteractive


random_password() {
    MATRIX='0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'
    LENGTH=10
    while [ ${n:=1} -le $LENGTH ]; do
        PASS="$PASS${MATRIX:$(($RANDOM%${#MATRIX})):1}"
        let n+=1
    done
    echo "$PASS"
}

function check_root {
    if [ "x$(id -u)" != 'x0' ]; then
        echo 'Error: this script can only be executed by root'
        exit 1
    fi
}

function check_os {
    if [ -e '/etc/redhat-release' ]; then
        echo 'Error: sorry, this installer works only on Debian or Ubuntu'
        exit 1
    fi
}

function check_for_package {
  if dpkg-query -s "${1}" 1>/dev/null 2>&1; then
    return 0   # package is installed
  else
    if apt-cache show "$1" 1>/dev/null 2>&1; then
      return 1 # package is not installed, it is available in package repository
    else
      return 2 # package is not installed, it is not available in package repository
    fi
  fi
}

function check_installed {

	packages="nginx-full mariadb-server"

	for package in $packages; do
	  if check_for_package "$package"; then
	    echo 'Error: This script runs only on a clean installation'
	    printf "%-20s - %s\n" "$package" "package is installed"
	    exit 1
	  else
	    if test "$?" -eq 1; then
	      printf "%-20s - %s\n" "$package" "package is not installed, it is available in package repository"
	    else
	      printf "%-20s - %s\n" "$package" "package is not installed, it is not available in package repository"
	    fi
	  fi
	done

}

function install_dependencies {
	echo "installing dependencies..."
	apt update > /dev/null
	apt upgrade -y > /dev/null
	apt install -y composer fping git graphviz imagemagick mtr-tiny nmap python-memcache python-mysqldb rrdtool snmp snmpd whois > /dev/null
}

function install_webserver {
	echo "installing nginx..."
	apt install -y nginx-full php7.0-cli php7.0-curl php7.0-fpm php7.0-gd php7.0-mcrypt php7.0-mysql php7.0-snmp php7.0-xml php7.0-zip > /dev/null

echo 'server {
	listen 443 ssl http2 default_server;
	root /opt/librenms/html;
	index index.php;

	ssl_certificate /etc/ssl/certs/nginx-selfsigned.crt;
	ssl_certificate_key /etc/ssl/private/nginx-selfsigned.key;

	charset utf-8;
	gzip on;
	gzip_types text/css application/javascript text/javascript application/x-javascript image/svg+xml text/plain text/xsl text/xml image/x-icon;
	location / {
		try_files $uri $uri/ /index.php?$query_string;
	}
	location /api/v0 {
		try_files $uri $uri/ /api_v0.php?$query_string;
	}
	location ~ \.php {
		include fastcgi.conf;
		fastcgi_split_path_info ^(.+\.php)(/.+)$;
		fastcgi_pass unix:/var/run/php/php7.0-fpm.sock;
	}
	location ~ /\.ht {
		deny all;
	}
}' > /etc/nginx/conf.d/librenms.conf

	echo "Creating SSL Certificates..."
	HOSTIPADDR=$(ifconfig | awk '/inet addr/{print substr($2,6)}'| head -n 1)
	sed -i '226s/.*/subjectAltName = IP: '"$HOSTIPADDR"'/' /etc/ssl/openssl.cnf
	openssl req -config /etc/ssl/openssl.cnf -x509 -days 3650 -batch -nodes -newkey rsa:2048 -keyout /etc/ssl/private/nginx-selfsigned.key -out /etc/ssl/certs/nginx-selfsigned.crt

	sed -i 's/^;date\.timezone[[:space:]]=.*$/date.timezone = "Europe\/Tallinn"/' /etc/php/7.0/fpm/php.ini
	sed -i 's/^;date\.timezone[[:space:]]=.*$/date.timezone = "Europe\/Tallinn"/' /etc/php/7.0/cli/php.ini


	#rm /etc/nginx/sites-enabled/default
	phpenmod mcrypt
	systemctl restart php7.0-fpm
}


function install_mysql {
	mysqlrootpassword=$(random_password)
	mysqllibrepassword=$(random_password)
	echo "installing mariadb..."
	apt install -y mariadb-server mariadb-client expect > /dev/null

	SECURE_MYSQL=$(expect -c "
	set timeout 10
	spawn mysql_secure_installation
	expect \"Enter current password for root (enter for none):\"
	send \"$MYSQL\r\"
	expect \"Change the root password?\"
	send \"n\r\"
	expect \"Remove anonymous users?\"
	send \"y\r\"
	expect \"Disallow root login remotely?\"
	send \"y\r\"
	expect \"Remove test database and access to it?\"
	send \"y\r\"
	expect \"Reload privilege tables now?\"
	send \"y\r\"
	expect eof
	")

	echo "$SECURE_MYSQL"

	mysql -u root -e "CREATE DATABASE librenms CHARACTER SET utf8 COLLATE utf8_unicode_ci;
	CREATE USER 'librenms'@'localhost' IDENTIFIED BY '$mysqllibrepassword';
	GRANT ALL PRIVILEGES ON librenms.* TO 'librenms'@'localhost'; FLUSH PRIVILEGES;"

	systemctl restart mysql
}


function install_snmp {

	echo "configuring snmpd..."

	community=
	while [[ $community = "" ]]; do
		read -p 'Enter SNMP community name:' community
	done

	sed -i "s/RANDOMSTRINGGOESHERE/$community/g" /etc/snmp/snmpd.conf
	curl -o /usr/bin/distro https://raw.githubusercontent.com/librenms/librenms-agent/master/snmp/distro
	chmod +x /usr/bin/distro
	service snmpd stop > /dev/null 2>&1
	service snmpd start
}

function cron_job {

	echo "setting up cron..."

	chown -R librenms:librenms /opt/librenms
	setfacl -d -m g::rwx /opt/librenms/rrd /opt/librenms/logs
	setfacl -R -m g::rwx /opt/librenms/rrd /opt/librenms/logs

}

function install_librenms {
	echo "installing librenms"
	useradd librenms -d /opt/librenms -M -r
	usermod -a -G librenms www-data
	cd /opt
	composer create-project --no-dev --keep-vcs librenms/librenms librenms dev-master
	cd /opt/librenms

	cp /opt/librenms/config.php.default /opt/librenms/config.php
	sed -i 's/USERNAME/librenms/g' /opt/librenms/config.php
	sed -i "s/PASSWORD/$mysqllibrepassword/g" /opt/librenms/config.php

	cp /opt/librenms/librenms.nonroot.cron /etc/cron.d/librenms

	chmod 775 /opt/librenms/rrd
	chown -R librenms:librenms /opt/librenms
	chmod ug+rw /opt/librenms/logs

	librepassword=$(random_password)

	/usr/bin/php7.0 build-base.php
	/usr/bin/php7.0 addhost.php localhost public v2c
	/usr/bin/php7.0 adduser.php admin $librepassword 10
	/usr/bin/php7.0 discovery.php -h all
	/usr/bin/php7.0 poller.php -h all

	systemctl restart nginx
}

function its_done {
	echo
	echo ' *** Done! ***'
	echo
	echo 'LibreNMS was successfully installed'
	echo
	echo "Username: admin"
	echo "Password: $librepassword"
	echo "Mysql root password: $mysqlrootpassword"
	echo ' *** Save them NOW before you fucking lose them!!! ***'
}

function install {
	check_root
	check_os
	check_installed
	install_dependencies
	install_webserver
	install_mysql
	install_snmp
	install_librenms
	its_done
}

echo
echo
echo ' *** LibreNMS Installer! ***'
echo
echo 'This script will install librenms in your environment for initial use and small tests'
echo
echo 'Note: this script only works on clean installation'
read -p 'Do you want to proceed? [y/n]: ' answer
if [ "$answer" != 'y' ] && [ "$answer" != 'Y'  ]; then
	echo 'Goodbye'
	exit 1
fi

install

