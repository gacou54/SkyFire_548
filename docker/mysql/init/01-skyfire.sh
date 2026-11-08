#!/usr/bin/env bash
#
# This file is part of Project SkyFire https://www.projectskyfire.org.
# See COPYRIGHT file for Copyright information
#
# Runs once, on first start of an empty MySQL data volume. The MySQL image has
# already created $MYSQL_USER; this creates the SkyFire databases and grants
# that user access. Schemas are imported by authserver/worldserver AutoSetup.
#
# The world database release creates its stored procedures with
# DEFINER=`skyfire`@`localhost`. That account is created so the procedures
# have a valid owner, and $MYSQL_USER gets SET_ANY_DEFINER so it can create
# them while connecting from another container.

MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql --protocol=socket -uroot <<-EOSQL
    CREATE DATABASE IF NOT EXISTS \`auth\` DEFAULT CHARACTER SET utf8mb4;
    CREATE DATABASE IF NOT EXISTS \`characters\` DEFAULT CHARACTER SET utf8mb4;
    CREATE DATABASE IF NOT EXISTS \`world\` DEFAULT CHARACTER SET utf8mb4;
    GRANT ALL PRIVILEGES ON \`auth\`.* TO '${MYSQL_USER}'@'%';
    GRANT ALL PRIVILEGES ON \`characters\`.* TO '${MYSQL_USER}'@'%';
    GRANT ALL PRIVILEGES ON \`world\`.* TO '${MYSQL_USER}'@'%';
    GRANT SET_ANY_DEFINER ON *.* TO '${MYSQL_USER}'@'%';

    CREATE USER IF NOT EXISTS 'skyfire'@'localhost' IDENTIFIED BY '${MYSQL_PASSWORD}';
    GRANT ALL PRIVILEGES ON \`world\`.* TO 'skyfire'@'localhost';
    FLUSH PRIVILEGES;
EOSQL
