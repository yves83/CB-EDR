#!/bin/bash

tar -P --selinux -cvf cbhost.tar /etc/hosts
tar -P --selinux -cvf cbssh.tar /etc/ssh/
tar -P --selinux -cvf cbconfig.tar /etc/cb/
tar -P --selinux -cvf cbrootauthkeys.tar /root/.ssh/authorized_keys
tar -P --selinux -cvf cbinstallers.tar /usr/share/cb/coreservices/installers/
tar -P --selinux -cvf cbcrons.tar /etc/cron.d/cb
tar -P --selinux -cvf cbsyslog.tar /etc/rsyslog.conf /etc/rsyslog.d/ /usr/share/cb/syslog_templates

#Full Backup
#tar -P --selinux -cvf cbdata.tar /var/cb/

#Config Backup Only
tar --exclude=/var/cb/data/solr?/cbevents/* -P --selinux -cvf cbdata.tar /var/cb
