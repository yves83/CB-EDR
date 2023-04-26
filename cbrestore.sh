#!/bin/bash

/etc/init.d/cb-enterprise stop

rm -rf /etc/cb
rm -rf /var/cb

for f in *.tar; do tar -P -xvf "$f"; done

chcon -R system_u:object_r:rabbitmq_var_lib_t:s0 /var/cb/data/rabbitmq/
chcon -R system_u:object_r:var_log_t:s0 /var/log/cb/redis
chcon -R system_u:object_r:redis_log_t:s0 /var/log/cb/redis/*.log && chcon -R system_u:object_r:redis_log_t:s0 /var/log/cb/redis/*.log-*
chcon -R system_u:object_r:var_log_t:s0 /var/log/cb/redis/*  

#/etc/init.d/cb-enterprise start
