#!/usr/bin/env bash

execname=$0

log() {
  echo "$(date): [${execname}] $@" >> /tmp/initialize-cloudera-server.log
}

#fail on any error
set -e

ClusterName=$1
key=$2
mip=$3
worker_ip=$4
HA=$5
User=$6
Password=$7

cmUser=$8
cmPassword=$9

EMAILADDRESS=${10}
BUSINESSPHONE=${11}
FIRSTNAME=${12}
LASTNAME=${13}
JOBROLE=${14}
JOBFUNCTION=${15}
COMPANY=${16}
VMSIZE=${17}

log "BEGIN: master node deployments"

log "Beginning process of disabling SELinux"

log "Running as $(whoami) on $(hostname)"

# Use the Cloudera-documentation-suggested workaround
log "about to set setenforce to 0"
set +e
setenforce 0 >> /tmp/setenforce.out

exitcode=$?
log "Done with settiing enforce. Its exit code was $exitcode"

log "Running setenforce inline as $(setenforce 0)"

getenforce
log "Running getenforce inline as $(getenforce)"
getenforce >> /tmp/getenforce.out

log "should be done logging things"


cat /etc/selinux/config > /tmp/beforeSelinux.out
log "ABOUT to replace enforcing with disabled"
sed -i 's^SELINUX=enforcing^SELINUX=disabled^g' /etc/selinux/config || true

cat /etc/selinux/config > /tmp/afterSeLinux.out
log "Done disabling selinux"

set +e

log "Set cloudera-manager.repo to CM v5"
yum clean all >> /tmp/initialize-cloudera-server.log
rpm --import http://archive.cloudera.com/cdh5/redhat/6/x86_64/cdh/RPM-GPG-KEY-cloudera >> /tmp/initialize-cloudera-server.log

wget http://archive.cloudera.com/cm5/redhat/6/x86_64/cm/cloudera-manager.repo -O /etc/yum.repos.d/cloudera-manager.repo >> /tmp/initialize-cloudera-server.log

# this often fails so adding retry logic
n=0
until [ $n -ge 5 ]
do
    yum install -y oracle-j2sdk* cloudera-manager-daemons cloudera-manager-server >> /tmp/initialize-cloudera-server.log 2>> /tmp/initialize-cloudera-server.err && break
    n=$[$n+1]
    sleep 15s
done
if [ $n -ge 5 ]; then log "scp error $remote, exiting..." & exit 1; fi

#######################################################################################################################
log "installing external DB"
yum install postgresql-server -y >> /tmp/initialize-cloudera-server.log 2>> /tmp/initialize-cloudera-server.err
bash install-postgresql.sh >> /tmp/initialize-cloudera-server.log 2>> /tmp/initialize-cloudera-server.err
#restart to make sure all configuration take effects
service postgresql restart

log "finished installing external DB"
#######################################################################################################################

log "start cloudera-scm-server services"
#service cloudera-scm-server-db start >> /tmp/initialize-cloudera-server.log
service cloudera-scm-server start >> /tmp/initialize-cloudera-server.log

#log "Create HIVE metastore DB Cloudera embedded PostgreSQL"
#export PGPASSWORD=$(head -1 /var/lib/cloudera-scm-server-db/data/generated_password.txt)
#SQLCMD=( """CREATE ROLE hive LOGIN PASSWORD 'hive';""" """CREATE DATABASE hive OWNER hive ENCODING 'UTF8';""" """ALTER DATABASE hive SET standard_conforming_strings = off;""" )
#for SQL in "${SQLCMD[@]}"; do
#	psql -A -t -d scm -U cloudera-scm -h localhost -p 5432 -c "${SQL}" >> /tmp/initialize-cloudera-server.log
#done
while ! (exec 6<>/dev/tcp/$(hostname)/7180) ; do log 'Waiting for cloudera-scm-server to start...'; sleep 15; done
log "END: master node deployments"



# Set up python,  epel and pyhton are part of image
# rpm -ivh http://dl.fedoraproject.org/pub/epel/6/i386/epel-release-6-8.noarch.rpm >> /tmp/initialize-cloudera-server.log 2>> /tmp/initialize-cloudera-server.err
yum -y install python-pip >> /tmp/initialize-cloudera-server.log
pip install cm_api >> /tmp/initialize-cloudera-server.log

# trap file to indicate done
log "creating file to indicate finished"
touch /tmp/readyFile

# Execute script to deploy Cloudera cluster
log "BEGIN: CM deployment - starting"
log "Parameters: $ClusterName $mip $worker_ip $EMAILADDRESS $BUSINESSPHONE $FIRSTNAME $LASTNAME $JOBROLE $JOBFUNCTION $COMPANY $VMSIZE"
if $HA; then
    python cmxDeployOnIbiza.py -n "$ClusterName" -u $User -p $Password  -m "$mip" -w "$worker_ip" -a -c $cmUser -s $cmPassword -e -r "$EMAILADDRESS" -b "$BUSINESSPHONE" -f "$FIRSTNAME" -t "$LASTNAME" -o "$JOBROLE" -i "$JOBFUNCTION" -y "$COMPANY" -v "$VMSIZE">> /tmp/initialize-cloudera-server.log 2>> /tmp/initialize-cloudera-server.err
else
    python cmxDeployOnIbiza.py -n "$ClusterName" -u $User -p $Password  -m "$mip" -w "$worker_ip" -c $cmUser -s $cmPassword -e -r "$EMAILADDRESS" -b "$BUSINESSPHONE" -f "$FIRSTNAME" -t "$LASTNAME" -o "$JOBROLE" -i "$JOBFUNCTION" -y "$COMPANY" -v "$VMSIZE">> /tmp/initialize-cloudera-server.log 2>> /tmp/initialize-cloudera-server.err
fi
log "END: CM deployment ended"

#Adding post depoly customizations
log "BEGIN: Customizations - starting"
clusterServer='localhost:7180';
hdfsJavaHeapValue='8589934592';

for i in $(curl -s  -u $cmUser:$cmPassword "http://$clusterServer/api/v1/hosts" |grep hostId |grep -o -E [0-9a-f]{8}\(-[0-9a-f]{4}\){3}-[0-9a-f]{12}); do
    echo "suppress fqdn alert on $i" >> /tmp/initialize-cloudera-server.log 2>> /tmp/initialize-cloudera-server.err; 
    curl -s -X PUT  -H "Content-Type:application/json"  -u $cmUser:$cmPassword   "http://$clusterServer/api/v1/hosts/$i/config"    --data   '{"items": [{                                  "name" : "host_health_suppression_host_dns_resolution",
    "value" : "true"  }]}' >> /tmp/initialize-cloudera-server.log 2>> /tmp/initialize-cloudera-server.err; 
done;  

echo "Setting java heap for NAMENODE and SECONDARYNAMENODE to $hdfsJavaHeapValue" >> /tmp/initialize-cloudera-server.log 2>> /tmp/initialize-cloudera-server.err; 
curl -s -X PUT -H "Content-Type:application/json" -u $cmUser:$cmPassword "http://$clusterServer/api/v1/clusters/$ClusterName/services/hdfs/config" --data "{\"roleTypeConfigs\": [
    {\"roleType\" : \"NAMENODE\",
     \"items\" : [ {
      \"name\" : \"namenode_java_heapsize\",
      \"value\" : \"$hdfsJavaHeapValue\"
    }]},
    {\"roleType\" : \"SECONDARYNAMENODE\",
     \"items\" : [ {
      \"name\" : \"secondary_namenode_java_heapsize\",
      \"value\" : \"$hdfsJavaHeapValue\"
    }]}
]}" >> /tmp/initialize-cloudera-server.log 2>> /tmp/initialize-cloudera-server.err

echo "Restarting hdfs service to make updated configurations effective" >> /tmp/initialize-cloudera-server.log 2>> /tmp/initialize-cloudera-server.err; 
curl -s -X POST -u $cmUser:$cmPassword http://$clusterServer/api/v1/clusters/$ClusterName/services/hdfs/commands/restart >> /tmp/initialize-cloudera-server.log 2>> /tmp/initialize-cloudera-server.err
log "END: Customizations ended"