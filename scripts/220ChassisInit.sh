#!/bin/bash
ttyusbaddPowerPath="addPower.rules"
rpserialport="rpserialport.rules"
cd /etc/udev/rules.d/
if [ ! -f "$ttyusbaddPowerPath" ]
then    
    touch $ttyusbaddPowerPath
    echo 'KERNEL=="ttyUSB[0-9]*",MODE:="0777"' > $ttyusbaddPowerPath
    echo "" >> $ttyusbaddPowerPath
    echo "$ttyusbaddPowerPath created"
else
    echo "$ttyusbaddPowerPath existed"
fi

if [ ! -f "$rpserialport" ]
then    
    touch $rpserialport
    echo 'KERNEL=="ttyUSB[0-9]*",ATTRS{idVendor}=="10c4",ATTRS{idProduct}=="ea60",MODE:="0777",SYMLINK+="rpserialport"' > $rpserialport
    echo "" >> $rpserialport
    stty -F /dev/rpserialport 921600
    echo "$rpserialport created"
else
    stty -F /dev/rpserialport 921600
    echo "$rpserialport existed"
fi

sudo service udev reload
sudo service udev restart

function installutil(){
if [ $(whereis $1) == $1":" ]
then
    echo "$1 is not installed"
    apt install $1
    echo "$1 is installed"
else
    echo "$1 is installed"
fi
}

installutil busybox
installutil modprobe
installutil stty

sudo modprobe can
sudo modprobe can_raw
sudo modprobe mttcan
sudo ip link set down can0
sudo ip link set can0 type can bitrate 1000000
sudo ip link set up can0
sudo ip link set down can1
sudo ip link set can1 type can bitrate 1000000
sudo ip link set up can1
sudo busybox devmem 0x0c303000 32 0x0000C400
sudo busybox devmem 0x0c303008 32 0x0000C458
sudo busybox devmem 0x0c303010 32 0x0000C400
sudo busybox devmem 0x0c303018 32 0x0000C458
