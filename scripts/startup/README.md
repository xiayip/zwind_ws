## can setup (on host, not in docker)

### 1. add systemd .link

```
sudo mkdir -p /etc/systemd/network
sudo tee /etc/systemd/network/10-mttcan.link > /dev/null <<'EOF'
[Match]
Driver=mttcan

[Link]
Name=can0
EOF

sudo tee /etc/systemd/network/20-gsusb.link > /dev/null <<'EOF'
[Match]
Driver=gs_usb

[Link]
Name=can1
EOF
```

### 2. copy rules file

```
sudo cp 80-can-names.rules /etc/udev/rules.d/
# enable
sudo udevadm control --reload-rules
sudo udevadm trigger --type=devices --action=add
```

### 3. copy service file 

```
sudo cp zwind_device_setup.sh /etc/systemd/
sudo cp zwind_device_setup.service /etc/systemd/system/
sudo systemctl enable zwind_device_setup
```