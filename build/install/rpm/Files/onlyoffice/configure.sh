#!/bin/sh

DIR=/var/www/onlyoffice
SERVICES_DIR="${DIR}/Services"
CONF=$DIR/WebStudio/web.connections.config
DB_HOST=""
DB_NAME=""
DB_USER=""
DB_PWD=""
MYSQL=""

[ -e $CONF ] || { echo "Configuration file not found at path $CONF"; exit 1; }
[ $(id -u) -ne 0 ] && { echo "Root privileges required"; exit 1; }

restart_services() {
	[ -a /etc/nginx/conf.d/default.conf ] && mv /etc/nginx/conf.d/default.conf /etc/nginx/conf.d/default.conf.old
	echo -n "Restarting services... "
	for SVC in redis monoserve monoserve2 monoserveApiSystem nginx onlyofficeBackup onlyofficeFeed onlyofficeJabber onlyofficeIndex onlyofficeNotify onlyofficeMailAggregator onlyofficeMailWatchdog
	do
		systemctl stop $SVC.service 
		systemctl start $SVC.service

		echo -n " $SVC.service "
	done
	echo "OK"
}

read_db_params() {
	CONN_STR=$(grep -o "Server=.*;Database=.*;User ID=.*;Password=.*;" $CONF)

	OLD_IFS="$IFS"
	IFS=";="
	VALUES=( $CONN_STR )
	IFS="$OLD_IFS"

	DB_HOST="${VALUES[1]}"
	DB_NAME="${VALUES[3]}"
	DB_USER="${VALUES[5]}"

	echo "Configuring MySQL access... "
	read -e -p "Host: " -i "$DB_HOST" DB_HOST
	read -e -p "Database name: " -i "$DB_NAME" DB_NAME
	read -e -p "User: " -i "$DB_USER" DB_USER 
	read -e -p "Password: " -s DB_PWD
	echo
}

save_db_params() {
	CONN_STR="Server=$DB_HOST;Database=$DB_NAME;User ID=$DB_USER;Password=$DB_PWD;Pooling=true;Character Set=utf8;AutoEnlist=false"
	if [ -d "$DIR" ]; then
		find "$DIR/" -type f -name "*.[cC]onfig" -exec sed -i "s/connectionString=.*/connectionString=\"$CONN_STR\" providerName=\"MySql.Data.MySqlClient\"\/>/" {} \;
	fi
	
	sed 's!\(sql_host\s*=\s*\)\S*!\1'${DB_HOST}'!' -i ${SERVICES_DIR}/TeamLabSvc/sphinx-min.conf.in;
	sed 's!\(sql_pass\s*=\s*\)\S*!\1'${DB_PWD}'!' -i ${SERVICES_DIR}/TeamLabSvc/sphinx-min.conf.in;
	sed 's!\(sql_user\s*=\s*\)\S*!\1'${DB_USER}'!' -i ${SERVICES_DIR}/TeamLabSvc/sphinx-min.conf.in;
	sed 's!\(sql_db\s*=\s*\)\S*!\1'${DB_NAME}'!' -i ${SERVICES_DIR}/TeamLabSvc/sphinx-min.conf.in;
	
}

establish_db_conn() {
	echo -n "Trying to establish MySQL connection... "

	command -v mysql >/dev/null 2>&1 || { echo "MySQL client not found"; exit 1; }

	MYSQL="mysql -h$DB_HOST -u$DB_USER"
	if [ -n "$DB_PWD" ]; then
		MYSQL="$MYSQL -p$DB_PWD"
	fi

	$MYSQL -e ";" >/dev/null 2>&1
	ERRCODE=$?
	if [ $ERRCODE -ne 0 ]; then
		systemctl mysqld start >/dev/null 2>&1
		$MYSQL -e ";" >/dev/null 2>&1 || { echo "FAILURE"; exit 1; }
	fi

	echo "OK"
}

execute_db_scripts() {

    if [ -e  /etc/my.cnf ]; then 

		echo "max_connections = 1000" >> /etc/my.cnf # new config mysql 5.7 ignore errors
		
	    if grep -q "sql_mode" /etc/my.cnf; then
			sed "s/sql_mode.*/sql_mode = 'NO_ENGINE_SUBSTITUTION'/" -i /etc/my.cnf || true # disable new STRICT mode in mysql 5.7	 
		else
			echo "sql_mode = 'NO_ENGINE_SUBSTITUTION'" >> /etc/my.cnf # disable new STRICT mode in mysql 5.7
		fi
		
		systemctl stop mysqld
		systemctl start mysqld

	fi
	
	DB_TABLES_COUNT=$($MYSQL --silent --skip-column-names -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}'");
	
	if [ "${DB_TABLES_COUNT}" -eq "0" ]; then
		echo "Installing MySQL database... "
	
		$MYSQL -e "CREATE DATABASE IF NOT EXISTS $DB_NAME CHARACTER SET utf8 COLLATE 'utf8_general_ci';"
		$MYSQL "$DB_NAME" < $DIR/Sql/onlyoffice.sql
		$MYSQL "$DB_NAME" < $DIR/Sql/onlyoffice.data.sql
		$MYSQL "$DB_NAME" < $DIR/Sql/onlyoffice.resources.sql
	fi

	echo "Upgrading MySQL database... "
	
	for i in $(ls $DIR/Sql/onlyoffice.upgrade*); do
        $MYSQL "$DB_NAME" < ${i};
	done
	
	echo "OK"
}

install_sphinx() {

	if ! grep -q "name=\"textindex\"" $DIR/Services/TeamLabSvc/TeamLabSvc.exe.Config; then
			sed -i 's/.*<add\s*name="default"\s*connectionString=.*/&\n<add name="textindex" connectionString="Server=localhost;Port=9306;Pooling=True;Character Set=utf8;AutoEnlist=false" providerName="MySql.Data.MySqlClient"\/>/' $DIR/Services/TeamLabSvc/TeamLabSvc.exe.Config;
		else
			sed -i '/textindex/s/connectionString=.*/connectionString="Server=localhost;Port=9306;Pooling=True;Character Set=utf8;AutoEnlist=false" providerName="MySql.Data.MySqlClient"\/>/' $DIR/Services/TeamLabSvc/TeamLabSvc.exe.Config;
	fi

	if [ -x /usr/bin/searchd ]; then
		echo "Sphinx already installed."
	else
		echo -n "Installing sphinx... "
		yum -y install postgresql-libs unixODBC
		if [ ! -f /tmp/sphinx-2.2.11-1.rhel7.x86_64.rpm ]; then
			wget http://sphinxsearch.com/files/sphinx-2.2.11-1.rhel7.x86_64.rpm -O /tmp/sphinx-2.2.11-1.rhel7.x86_64.rpm
		fi
		rpm -Uhv /tmp/sphinx-2.2.11-1.rhel7.x86_64.rpm
		echo "OK"
	
		

	fi
}

upgrade_storage(){
	echo -n "Upgrade data storage... "
	if [ -d $DIR/WebStudio/Products/Community/Modules/Blogs/data ]; then
		mkdir -p $DIR/Data/Products/Community/Modules/Blogs/Data
		cp -R -u $DIR/WebStudio/Products/Community/Modules/Blogs/data/. $DIR/Data/Products/Community/Modules/Blogs/Data
	fi
	if [ -d $DIR/WebStudio/Products/Community/Modules/Forum/data ]; then
		mkdir -p $DIR/Data/Products/Community/Modules/Forum/Data
		cp -R -u $DIR/WebStudio/Products/Community/Modules/Forum/data/. $DIR/Data/Products/Community/Modules/Forum/Data
	fi
	if [ -d $DIR/WebStudio/Products/Community/Modules/News/data ]; then
		mkdir -p $DIR/Data/Products/Community/Modules/News/Data
		cp -R -u $DIR/WebStudio/Products/Community/Modules/News/data/. $DIR/Data/Products/Community/Modules/News/Data
	fi
	if [ -d $DIR/WebStudio/Products/Community/Modules/Bookmarking/data ]; then
		mkdir -p $DIR/Data/Products/Community/Modules/Bookmarking/Data
		cp -R -u $DIR/WebStudio/Products/Community/Modules/Bookmarking/data/. $DIR/Data/Products/Community/Modules/Bookmarking/Data
	fi
	if [ -d $DIR/WebStudio/Products/Community/Modules/Wiki/data ]; then
		mkdir -p $DIR/Data/Products/Community/Modules/Wiki/Data
		cp -R -u $DIR/WebStudio/Products/Community/Modules/Wiki/data/. $DIR/Data/Products/Community/Modules/Wiki/Data
	fi
	if [ -d $DIR/Data/Files ]; then
		mkdir -p $DIR/Data/Products
		cp -R -u $DIR/Data/Files $DIR/Data/Products
	fi
	if [ -d $DIR/WebStudio/Products/CRM/data ]; then
		mkdir -p $DIR/Data/Products/CRM/Data
		cp -R -u $DIR/WebStudio/Products/CRM/data/. $DIR/Data/Products/CRM/Data
	fi
	if [ -d $DIR/WebStudio/Products/Projects/data ]; then
		mkdir -p $DIR/Data/Products/Projects/Data
		cp -R -u $DIR/WebStudio/Products/Projects/data/. $DIR/Data/Products/Projects/Data
	fi
	if [ -d $DIR/WebStudio/data ]; then
		mkdir -p $DIR/Data/Studio
		cp -R -u $DIR/WebStudio/data/. $DIR/Data/Studio
	fi
	if [ -d $DIR/WebStudio/addons/mail/data ]; then
		mkdir -p $DIR/Data/addons/mail/Data
		cp -R -u $DIR/WebStudio/addons/mail/data/. $DIR/Data/addons/mail/Data
	fi
	if [ -d $DIR/WebStudio/addons/mail/Data ]; then
		mkdir -p $DIR/Data/addons/mail/Data
		cp -R -u $DIR/WebStudio/addons/mail/Data/. $DIR/Data/addons/mail/Data
	fi
	if [ -d $DIR/Data/Mail/Aggregator ]; then
		mkdir -p $DIR/Data/addons/mail/Data/aggregator
		cp -R -u $DIR/Data/Mail/Aggregator/. $DIR/Data/addons/mail/Data/aggregator
	fi
	if [ -d $DIR/WebStudio/addons/talk/Data/upload ]; then
		mkdir -p $DIR/Data/addons/talk/Data
		cp -R -u $DIR/WebStudio/addons/talk/Data/upload/. $DIR/Data/addons/talk/Data
	fi
	chown -R -f onlyoffice:onlyoffice -R $DIR/Data
	echo "OK"
}


read_db_params
establish_db_conn || exit $?
execute_db_scripts || exit $?
save_db_params
upgrade_storage
install_sphinx
restart_services
