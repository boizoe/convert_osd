#!/bin/sh 

#if [ $# != 3 ]; then
#    echo "you should provide this script 3 parameters:
#          OSDNUM as digit and DATADISK and JRNLDISK paths as /dev/sdX /dev/sdY
#          for example
#          ./convert_osd.sh 9 /dev/sdb /dev/sdc"
#    exit 255
#fi

echo "Please, look at mounted disks 
and enter OSDNUM as digit and DATADISK and JRNLDISK paths as /dev/sdX /dev/sdY

For example:
0 /dev/sdb /dev/sdc"

echo "
current mounts are:
$(mount | grep ceph)
Please provide you values:"
read OSDNUM DATADISK JRNLDISK

OLDOSDUUID=$(ceph osd dump 2>&1 | grep osd.${OSDNUM} | awk '{ print $19 }')

function delete_osd {
ceph osd reweight ${OSDNUM} 0.0
ceph osd crush reweight osd.${OSDNUM} 0.0

# Sleep before checking ceph status, otherwise
# $(ceph status) can show HEALTH_OK
sleep 10s 

while [ $(ceph status 2>&1 | grep health | awk '{ print $2 }') != HEALTH_OK ]; do
        echo "Cluster rebalancing, sleep for 1 minute. Time is $(date +%H:%M:%S)"
        sleep 60s
done
echo "Cluster rebalanced, HEALTH_OK now"

# Delete osd from cluster
ceph osd out ${OSDNUM}
ceph osd crush remove osd.${OSDNUM}
ceph auth del osd.${OSDNUM}
sudo systemctl stop ceph-osd@${OSDNUM}
ceph osd rm ${OSDNUM}
sudo umount /var/lib/ceph/osd/ceph-${OSDNUM}
sudo systemctl stop ceph-osd@${OSDNUM}
ceph osd rm ${OSDNUM}
sudo systemctl stop ceph-osd@${OSDNUM}
sudo umount /var/lib/ceph/osd/ceph-${OSDNUM}

# Backup and edit /etc/fstab
sudo cp /etc/fstab{,.$(date +%Y%m%d_%H%M%S)}
export LINENUM=$(grep -n ceph-${OSDNUM} /etc/fstab | awk -F : '{print $1}')
awk -v n=${LINENUM} 'NR == n {next} {print}' /etc/fstab > /tmp/fstab
sudo cp /tmp/fstab /etc/fstab

# Run parted
sudo parted -s ${DATADISK} mktable gpt
sudo parted -s ${JRNLDISK} mktable gpt

echo "Deleting done"
}

function prepare_osd {
uuidgen > /tmp/uuidgen
OSDUUID=$(cat /tmp/uuidgen)

# As I see, now ceph-disk ignores ${JRNLDISK}
# You can use additional disks/partitions for rocksdb.
# In that case you should copy partitions, created by ceph-disk to them.

sudo systemctl stop ceph-osd@${OSDNUM}
sudo umount /var/lib/ceph/osd/ceph-${OSDNUM}
sudo ceph-disk prepare --bluestore --osd-uuid ${OSDUUID} ${DATADISK} ${JRNLDISK}

sudo systemctl stop ceph-osd@${OSDNUM}
sudo umount /var/lib/ceph/osd/ceph-${OSDNUM}
sudo parted ${DATADISK} name 1 osd-device-${OSDNUM}-data
sudo parted ${DATADISK} name 2 osd-device-${OSDNUM}-block
sudo parted ${DATADISK} name 3 osd-device-${OSDNUM}-block.db
sudo parted ${DATADISK} name 4 osd-device-${OSDNUM}-block.wal

# Add mountpoint to /etc/fstab
sudo cp /etc/fstab{,.$(date +%Y%m%d_%H%M%S)}
echo -e "#!/bin/sh
OSDNUM=${OSDNUM}
DATADISK=${DATADISK}
JRNLDISK=${JRNLDISK}
echo "${DATADISK}1 /var/lib/ceph/osd/ceph-${OSDNUM} xfs rw,noatime,nodiratime,attr2,inode64,noquota 0 0" >> /etc/fstab" > /tmp/fstab.sh
sudo bash /tmp/fstab.sh

echo "Disk prepared, I will mount and create fs now"
}

function create_osd {
sudo mount /var/lib/ceph/osd/ceph-${OSDNUM}
ceph osd create ${OSDUUID}
sudo systemctl stop ceph-osd@${OSDNUM}
sudo umount /var/lib/ceph/osd/ceph-${OSDNUM}
sudo mount /var/lib/ceph/osd/ceph-${OSDNUM}
sudo ceph-osd -i ${OSDNUM} --mkfs --mkkey --osd-uuid ${OSDUUID}
sudo ceph auth add osd.${OSDNUM} osd 'allow *' mon 'allow profile osd' -i /var/lib/ceph/osd/ceph-${OSDNUM}/keyring
ceph osd crush add-bucket ${HOSTNAME} host
ceph osd crush move ${HOSTNAME} root=default
ceph osd crush add osd.${OSDNUM} 1.0 host=${HOSTNAME}
sudo chown -R ceph: /var/lib/ceph/osd/ceph-${OSDNUM}
sudo systemctl reset-failed ceph-osd@${OSDNUM}
sudo systemctl restart ceph-osd@${OSDNUM}

while [ $(ceph status 2>&1 | grep health | awk '{ print $2 }') != HEALTH_OK ]; do
        echo "Cluster rebalancing, sleep for 1 minute. Time is $(date +%H:%M:%S)"
        sleep 60s
done
echo "Cluster rebalanced, HEALTH_OK now"
echo "All done, you can start with another OSD now"
}

echo -e "WARNING!!!
This script can damage ALL you data on this server.
WARNING!!!

It will be ran with options below
OSDNUM=$(echo "${OSDNUM}")
DATADISK=$(echo "${DATADISK}")
JRNLDISK=$(echo "${JRNLDISK}")

Is it OK? Do you want to continue?"
OPTIONS="Yes Cancel"
select opt in ${OPTIONS}; do
    if [ "$opt" = "Cancel" ]; then
        echo "Ok, exiting then"
        exit 1
    elif [ "$opt" = "Yes" ]; then
        echo "Ok, starting converting OSD"
        delete_osd
        prepare_osd
        create_osd
        exit 0
    else
        echo "select 1 or 2"
    fi
done
