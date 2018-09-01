#!/bin/sh

echo Preparing SonarQube container

mkdir -p /home/sonarqube/data
chown -R sonarqube:sonarqube /home/sonarqube

mv -n /opt/sonarqube/conf /home/sonarqube
mv -n /opt/sonarqube/logs /home/sonarqube
mv -n /opt/sonarqube/extensions /home/sonarqube

chown -R sonarqube:sonarqube /home/sonarqube/data
chown -R sonarqube:sonarqube /home/sonarqube/conf
chown -R sonarqube:sonarqube /home/sonarqube/logs
chown -R sonarqube:sonarqube /home/sonarqube/extensions

rm -rf /opt/sonarqube/conf
rm -rf /opt/sonarqube/logs
rm -rf /opt/sonarqube/extensions

ln -s /home/sonarqube/conf /opt/sonarqube/conf
ln -s /home/sonarqube/logs /opt/sonarqube/logs
ln -s /home/sonarqube/extensions /opt/sonarqube/extensions

chown -R sonarqube:sonarqube $SONARQUBE_HOME

set -e

if [ "${1:0:1}" != '-' ]; then
  exec "$@"
fi

echo Launching SonarQube instance

exec su-exec sonarqube \
  java -jar lib/sonar-application-$SONAR_VERSION.jar \
  -Dsonar.log.console=true \
  -Dsonar.jdbc.url="$SQLAZURECONNSTR_SONARQUBE_JDBC_URL" \
  -Dsonar.web.javaAdditionalOpts="$SONARQUBE_WEB_JVM_OPTS -Djava.security.egd=file:/dev/./urandom" \
  -Dsonar.path.data="/home/sonarqube/data" \
  "$@"
