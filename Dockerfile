FROM yyxjcc/java:8u202
LABEL Maintainer="yyxjcc <yyxjcc@gmail.com>"

ENV CATALINA_HOME /opt/tomcat
ENV PATH $CATALINA_HOME/bin:$PATH
RUN mkdir -p "$CATALINA_HOME"
WORKDIR $CATALINA_HOME

# let "Tomcat Native" live somewhere isolated
ENV TOMCAT_NATIVE_LIBDIR $CATALINA_HOME/native-jni-lib
ENV LD_LIBRARY_PATH ${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}$TOMCAT_NATIVE_LIBDIR

RUN apk update
#RUN apk add --no-cache  curl

# see https://www.apache.org/dist/tomcat/tomcat-$TOMCAT_MAJOR/KEYS
# see also "update.sh" (https://github.com/docker-library/tomcat/blob/master/update.sh)
#ENV GPG_KEYS 05AB33110949707C93A279E3D3EFE6B686867BA6 07E48665A34DCAFAE522E5E6266191C37C037D42 47309207D818FFD8DCD3F83F1931D684307A10A5 541FBE7D8F78B25E055DDEE13C370389288584E7 61B832AC2F1C5A90F0F9B00A1C506407564C17A3 79F7026C690BAA50B92CD8B66A3AD3F4F22C4FED 9BA44C2621385CB966EBA586F72C284D731FABEE A27677289986DB50844682F8ACB77FC2E86E29AC A9C5DF4D22E99998D9875A5110C01C5A2F6059E7 DCFD35E0BF8CA7344752DE8B6FB21E8933C60243 F3A04C595DB5B6A5F1ECA43E3B7BBB100D811BBE F7DA48BB64BCB84ECBA7EE6935CD23C10D498E23
#RUN set -ex; \
#	for key in $GPG_KEYS; do \
#		gpg --keyserver pgpkeys.mit.edu --recv-keys "$key"; \
#	done

ENV TOMCAT_MAJOR 9
ENV TOMCAT_VERSION 9.0.17

# https://issues.apache.org/jira/browse/INFRA-8753?focusedCommentId=14735394#comment-14735394
ENV TOMCAT_TGZ_URL https://www.apache.org/dyn/closer.cgi?action=download&filename=tomcat/tomcat-$TOMCAT_MAJOR/v$TOMCAT_VERSION/bin/apache-tomcat-$TOMCAT_VERSION.tar.gz
# not all the mirrors actually carry the .asc files :'(
ENV TOMCAT_ASC_URL https://www.apache.org/dist/tomcat/tomcat-$TOMCAT_MAJOR/v$TOMCAT_VERSION/bin/apache-tomcat-$TOMCAT_VERSION.tar.gz.asc

RUN set -x \
	\
	&& apk add --no-cache --virtual .fetch-deps \
		ca-certificates \
		tar \
		openssl \
	&& wget -O tomcat.tar.gz "$TOMCAT_TGZ_URL" \
	&& wget -O tomcat.tar.gz.asc "$TOMCAT_ASC_URL" \
	&& tar -xvf tomcat.tar.gz --strip-components=1 \
	&& rm bin/*.bat \
	&& rm tomcat.tar.gz* \
	\
	&& nativeBuildDir="$(mktemp -d)" \
	&& tar -xvf bin/tomcat-native.tar.gz -C "$nativeBuildDir" --strip-components=1 \
	&& apk add --no-cache --virtual .native-build-deps \
		apr-dev \
		gcc \
		libc-dev \
		make \
		openssl-dev \
	&& ( \
		export CATALINA_HOME="$PWD" \
		&& cd "$nativeBuildDir/native" \
		&& ./configure \
			--libdir="$TOMCAT_NATIVE_LIBDIR" \
			--prefix="$CATALINA_HOME" \
			--with-apr="$(which apr-1-config)" \
			--with-java-home="$JAVA_HOME" \
			--with-ssl=yes \
		&& make -j$(getconf _NPROCESSORS_ONLN) \
		&& make install \
	) \
	&& runDeps="$( \
		scanelf --needed --nobanner --recursive "$TOMCAT_NATIVE_LIBDIR" \
			| awk '{ gsub(/,/, "\nso:", $2); print "so:" $2 }' \
			| sort -u \
			| xargs -r apk info --installed \
			| sort -u \
	)" \
	&& apk add --virtual .tomcat-native-rundeps $runDeps \
	&& apk del .fetch-deps .native-build-deps \
	&& rm -rf "$nativeBuildDir" \
	&& rm bin/tomcat-native.tar.gz

# verify Tomcat Native is working properly
RUN set -e \
	&& nativeLines="$(catalina.sh configtest 2>&1)" \
	&& nativeLines="$(echo "$nativeLines" | grep 'Apache Tomcat Native')" \
	&& nativeLines="$(echo "$nativeLines" | sort -u)" \
	&& if ! echo "$nativeLines" | grep 'INFO: Loaded APR based Apache Tomcat Native library' >&2; then \
		echo >&2 "$nativeLines"; \
		exit 1; \
	fi

# delete log and webapps dir
RUN set -e \
	&& rm -rf ${CATALINA_HOME}/logs \ 
	&& rm -rf ${CATALINA_HOME}/webapps

# fix 403 ERROR when upload file through nginx to tomcat
RUN sed -ie 's/UMASK="0027"/UMASK="0022"/g' bin/catalina.sh \ 
	# add tomcat startup parameters
	&& sed -i '111i JAVA_OPTS="-server -Xms512m -Xmx512m -Xmn64m -XX:MetaspaceSize=256M -XX:MaxMetaspaceSize=256M -XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=$CATALINA_HOME/logs/heap.dump -XX:+UseConcMarkSweepGC -XX:+CMSClassUnloadingEnabled -XX:+PrintGC -XX:+PrintGCDetails -XX:+PrintGCTimeStamps -XX:+PrintGCDateStamps -Xloggc:$CATALINA_HOME/logs/gc.log -XX:CMSInitiatingOccupancyFraction=75 -XX:+UseCMSInitiatingOccupancyOnly"' bin/catalina.sh \ 
	# add tomcat executor thread pool
	&& sed -i '60i <Executor name="tomcatThreadPool" namePrefix="catalina-exec-" maxThreads="1000" minSpareThreads="100" maxIdleTime="60000"/>' conf/server.xml \ 
	# change tomcat startup mode 'nio' to 'apr'
	&& sed -ie 's/<Connector port="8080"/<!--<Connector port="8080"/g' conf/server.xml \ 
	&& sed -ie 's/redirectPort="8443" \/>/redirectPort="8443" \/>-->/g' conf/server.xml \ 
	&& sed -i '73i <Connector port="8080" executor="tomcatThreadPool" protocol="org.apache.coyote.http11.Http11AprProtocol" connectionTimeout="20000" redirectPort="8443" acceptCount="1000" URIEncoding="UTF-8" maxHttpHeaderSize="8192" disableUploadTimeout="true" enableLookups="false"/>' conf/server.xml	

VOLUME ["${CATALINA_HOME}/logs", "${CATALINA_HOME}/webapps"]

EXPOSE 8080
CMD ["bin/catalina.sh","run"]
