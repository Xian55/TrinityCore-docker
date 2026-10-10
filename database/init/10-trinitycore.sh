#!/bin/bash
# Runs once, when the MySQL container starts on an empty data volume.
#
# Creates the TrinityCore databases up front: the worldserver would otherwise stop at its
# "Database does not exist, do you want to create it?" prompt. Empty databases are fine, the
# worldserver fills them on its first start.
#
# The MySQL image sources this file (no `set` here: options would leak into its own entrypoint).

mysql --protocol=socket -uroot -p"${MYSQL_ROOT_PASSWORD}" <<SQL
CREATE USER IF NOT EXISTS '${TC_DB_USER}'@'%' IDENTIFIED BY '${TC_DB_PASSWORD}';
CREATE DATABASE IF NOT EXISTS \`auth\`       DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS \`characters\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS \`world\`      DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS \`hotfixes\`   DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
GRANT ALL PRIVILEGES ON \`auth\`.*       TO '${TC_DB_USER}'@'%';
GRANT ALL PRIVILEGES ON \`characters\`.* TO '${TC_DB_USER}'@'%';
GRANT ALL PRIVILEGES ON \`world\`.*      TO '${TC_DB_USER}'@'%';
GRANT ALL PRIVILEGES ON \`hotfixes\`.*   TO '${TC_DB_USER}'@'%';
SQL
