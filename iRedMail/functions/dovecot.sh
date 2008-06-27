# -------------------------------------------------------
# Dovecot & dovecot-sieve.
# -------------------------------------------------------

# For dovecot SSL support.
enable_dovecot_ssl()
{
    ECHO_INFO "Generate CA file for dovecot: /etc/pki/dovecot/*."
    rm -f /etc/pki/dovecot/{certs,private}/dovecot.pem
    cd /etc/pki/dovecot/
    gen_pem_key dovecot

    mv /etc/pki/dovecot/dovecotCert.pem /etc/pki/dovecot/certs/
    mv /etc/pki/dovecot/dovecotKey.pem /etc/pki/dovecot/private/

    chown root:root /etc/pki/dovecot/{certs,private}/*
    chmod 0400 /etc/pki/dovecot/{certs,private}/*

    [ X"${ENABLE_DOVECOT_SSL}" == X"YES" ] && cat >> ${DOVECOT_CONF} <<EOF
# SSL support.
# Refer to official documentation:
#   * http://wiki.dovecot.org/SSL/DovecotConfiguration
ssl_disable = no
verbose_ssl = no
ssl_key_file = /etc/pki/dovecot/private/dovecotKey.pem
ssl_cert_file = /etc/pki/dovecot/certs/dovecotCert.pem
EOF

    echo 'export status_enable_dovecot_ssl="DONE"' >> ${STATUS_FILE}
}

enable_dovecot()
{
    [ X"${ENABLE_DOVECOT}" == X"YES" ] && \
        backup_file ${DOVECOT_CONF} && \
        ECHO_INFO "Setup dovecot: ${DOVECOT_CONF}." && \
        cat > ${DOVECOT_CONF} <<EOF
${CONF_MSG}
# Provided services.
protocols = ${DOVECOT_PROTOCOLS}

#
# Debug options.
#
#mail_debug = yes
#auth_verbose = yes
#auth_debug = yes
#auth_debug_passwords = yes

#
# Log file.
#
#log_timestamp = "%Y-%m-%d %H:%M:%S "
log_path = ${DOVECOT_LOG_FILE}

max_mail_processes = 1024
umask = 0077
disable_plaintext_auth = no

# Default realm/domain to use if none was specified.
# This is used for both SASL realms and appending '@domain.ltd' to username in plaintext logins.
#auth_default_realm = ${FIRST_DOMAIN}

EOF

    # Enable SSL support.
    [ X"${ENABLE_DOVECOT_SSL}" == X"YES" ] && enable_dovecot_ssl

    # Mailbox format.
    if [ X"${HOME_MAILBOX}" == X"Maildir" ]; then
        cat >> ${DOVECOT_CONF} <<EOF
# Maildir format and location.
# Such as: /home/vmail/osspinc.com/www/
#          ----------- ================
#          homeDirectory  mailMessageStore
mail_location = maildir:/%Lh/%Ld/%Ln/:INDEX=/%Lh/%Ld/%Ln/
EOF
    elif [ X"${HOME_MAILBOX}" == X"mbox" ]; then
        cat >> ${DOVECOT_CONF} <<EOF
# Mailbox format and location.
# Such as: /home/vmail/osspinc.com/www
#          ----------- ====================
#          homeDirectory  mailMessageStore
mail_location = mbox:/%Lh/%Ld/%Ln:INBOX=/%Lh/%Ld/%Ln/inbox:INDEX=/%Lh/%Ld/%Ln/indexes

# mbox performance optimizations.
mbox_lazy_writes=yes
mbox_min_index_size=10240
mbox_very_dirty_syncs = yes
mbox_read_locks = fcntl
mbox_write_locks = dotlock fcntl
EOF
    else
        :
    fi

    cat >> ${DOVECOT_CONF} <<EOF
# LDA: Local Deliver Agent
protocol lda { 
    postmaster_address = root
    auth_socket_path = /var/run/dovecot/auth-master
    mail_plugins = cmusieve quota 
    sieve_global_path = ${SIEVE_FILTER_FILE}
    log_path = ${SIEVE_LOG_FILE}
}

# IMAP configuration
protocol imap {
    mail_plugins = quota imap_quota
}

# POP3 configuration
protocol pop3 {
    mail_plugins = quota
    pop3_uidl_format = %08Xu%08Xv
    pop3_client_workarounds = outlook-no-nuls oe-ns-eoh
}

auth default {
    mechanisms = plain login
    user = ${VMAIL_USER_NAME}
EOF

    if [ X"${BACKEND}" == X"OpenLDAP" ]; then
        cat >> ${DOVECOT_CONF} <<EOF
    passdb ldap {
        args = ${DOVECOT_LDAP_CONF}
    }
    userdb ldap {
        args = ${DOVECOT_LDAP_CONF}
    }
EOF

        cat > ${DOVECOT_LDAP_CONF} <<EOF
${CONF_MSG}
hosts           = ${LDAP_SERVER_HOST}:${LDAP_SERVER_PORT}
ldap_version    = 3
auth_bind       = yes
dn              = ${LDAP_BINDDN}
dnpass          = ${LDAP_BINDPW}
base            = ${LDAP_ATTR_DOMAIN_DN_NAME}=%d,${LDAP_BASEDN}
scope           = subtree
deref           = never
user_filter     = (&(mail=%u)(objectClass=${LDAP_OBJECTCLASS_USER})(${LDAP_ATTR_USER_STATUS}=active)(enable%Us=yes))
pass_filter     = (mail=%u)
pass_attrs      = ${LDAP_ATTR_USER_PASSWD}=password
user_global_uid = ${VMAIL_USER_UID}
user_global_gid = ${VMAIL_USER_GID}
default_pass_scheme = CRYPT
EOF
        # Maildir format.
        [ X"${HOME_MAILBOX}" == X"Maildir" ] && cat >> ${DOVECOT_LDAP_CONF} <<EOF
user_attrs      = homeDirectory=home,mailMessageStore=maildir:mail,${LDAP_ATTR_USER_QUOTA}=quota=maildir:storage
EOF
        [ X"${HOME_MAILBOX}" == X"mbox" ] && cat >> ${DOVECOT_LDAP_CONF} <<EOF
user_attrs      = homeDirectory=home,mailMessageStore=dirsize:mail,${LDAP_ATTR_USER_QUOTA}=quota=dirsize:storage
EOF
    else
        cat >> ${DOVECOT_CONF} <<EOF
    passdb sql {
        args = ${DOVECOT_MYSQL_CONF}
    }
    userdb sql {
        args = ${DOVECOT_MYSQL_CONF}
    }
EOF
        cat > ${DOVECOT_MYSQL_CONF} <<EOF
driver = mysql
default_pass_scheme = CRYPT
connect = host=${MYSQL_SERVER} dbname=${VMAIL_DB} user=${MYSQL_BIND_USER} password=${MYSQL_BIND_PW}
password_query = SELECT password FROM mailbox WHERE username='%u' AND active='1'
EOF
        # Maildir format.
        [ X"${HOME_MAILBOX}" == X"Maildir" ] && cat >> ${DOVECOT_MYSQL_CONF} <<EOF
user_query = SELECT ${VMAIL_USER_UID} AS uid, ${VMAIL_USER_GID} AS gid, "${VMAIL_USER_HOME_DIR}" AS home, maildir, CONCAT('maildir:storage=', quota) AS quota FROM mailbox WHERE username='%u' AND active='1' AND enable%Ls='1'
EOF
        [ X"${HOME_MAILBOX}" == X"mbox" ] && cat >> ${DOVECOT_MYSQL_CONF} <<EOF
user_query = SELECT ${VMAIL_USER_UID} AS uid, ${VMAIL_USER_GID} AS gid, "${VMAIL_USER_HOME_DIR}" AS home, maildir, CONCAT('dirsize:storage=', quota) AS quota FROM mailbox WHERE username='%u' AND active='1' AND enable%Ls='1'
EOF
    fi

    cat >> ${DOVECOT_CONF} <<EOF
    socket listen {
        master { 
            path = /var/run/dovecot/auth-master 
            mode = 0660 
            user = ${VMAIL_USER_NAME}
            group = ${VMAIL_GROUP_NAME}
        }
        client {
            path = /var/spool/postfix/private/auth
            mode = 0660
            user = postfix
            group = postfix
        }
    }
}

#plugin {
#    # NOTE: %variable expansion works only with Dovecot v1.0.2+.
#    # For maildir format.
#    sieve = /%Lh/%Ld/%Ln/.sieve.rule
#
#    # For mbox format.
#    sieve = /%Lh/%Ld/.%Ln.sieve.rule
#}
EOF

    ECHO_INFO "Generate dovecot sieve rule filter file: ${SIEVE_FILTER_FILE}."
    cp -f ${SAMPLE_DIR}/dovecot.sieve ${SIEVE_FILTER_FILE}
    chown ${VMAIL_USER_NAME}:${VMAIL_GROUP_NAME} ${SIEVE_FILTER_FILE}
    chmod 0500 ${SIEVE_FILTER_FILE}

    ECHO_INFO "Create dovecot log file: ${DOVECOT_LOG_FILE}, ${SIEVE_LOG_FILE}."
    touch ${DOVECOT_LOG_FILE} ${SIEVE_LOG_FILE}
    chown ${VMAIL_USER_NAME}:${VMAIL_GROUP_NAME} ${DOVECOT_LOG_FILE} ${SIEVE_LOG_FILE}
    chmod 0700 ${DOVECOT_LOG_FILE} ${SIEVE_LOG_FILE}

    ECHO_INFO "Enable dovecot in postfix: ${POSTFIX_FILE_MAIN_CF}."
    postconf -e mailbox_command="${DOVECOT_DELIVER}"
    postconf -e virtual_transport="${TRANSPORT}"
    postconf -e dovecot_destination_recipient_limit='1'

    postconf -e smtpd_sasl_type='dovecot'
    postconf -e smtpd_sasl_path='private/auth'

    cat >> ${POSTFIX_FILE_MASTER_CF} <<EOF
dovecot unix    -       n       n       -       -      pipe
  flags=DRhu user=${VMAIL_USER_NAME}:${VMAIL_GROUP_NAME} argv=${DOVECOT_DELIVER} -d \${recipient} -f \${sender}
EOF

    ECHO_INFO "Setting logrotate for dovecot log file."
    cat > ${DOVECOT_LOGROTATE_FILE} <<EOF
${CONF_MSG}
${DOVECOT_LOG_FILE} ${SIEVE_LOG_FILE} {
    compress
    weekly
    rotate 10
    create 0600 ${VMAIL_USER_NAME} ${VMAIL_GROUP_NAME}
    missingok
    postrotate
        /sbin/killall -HUP syslogd
    endscript
}
EOF

    cat >> ${TIP_FILE} <<EOF
Dovecot:
    * Configuration files:
        - ${DOVECOT_CONF}
    * LDAP:
        - ${DOVECOT_LDAP_CONF}
    * MySQL:
        - ${DOVECOT_MYSQL_CONF}
    * RC script:
        - /etc/init.d/dovecot
    * Log files:
        - ${DOVECOT_LOGROTATE_FILE}
        - ${DOVECOT_LOG_FILE}
        - ${SIEVE_LOG_FILE}
    * See also:
        - ${SIEVE_FILTER_FILE}

EOF

    echo 'export status_enable_dovecot="DONE"' >> ${STATUS_FILE}
}

dovecot_config()
{
    if [ X"${ENABLE_DOVECOT}" == X"YES" ]; then
        check_status_before_run enable_dovecot
    else
        check_status_before_run enable_procmail
    fi
    echo 'export status_dovecot_config="DONE"' >> ${STATUS_FILE}
}