#!/usr/bin/env bash
set -eux

# Download required packages
yum --enablerepo=extras install epel-release -y
yum install python-pip wget unzip gcc python-devel libyaml-devel \
openssl-devel libffi-devel libxml2-devel libxslt-devel puppet git -y

# Install required modules
pip install --upgrade pip
pip install --upgrade setuptools

for module in ansible==2.4.3.0 virtualenv dib-utils "-U decorator"; \
  do pip install $module ; \
done


# Create HEAT venv & activate it
virtualenv /etc/.rackspace_heat
. /etc/.rackspace_heat/bin/activate

# Download hotstrap repo
wget https://github.com/kmcjunk/hotstrapper/archive/staging.zip
unzip staging.zip

# Run hotstrap
python -u hotstrapper-staging/bootstrap/centos/7_new/hotstrap.py

# link venv binaries to global
ln -s /etc/.rackspace_heat/bin/os-refresh-config /usr/bin/os-refresh-config
ln -s /etc/.rackspace_heat/bin/os-apply-config /usr/bin/os-apply-config

# if there is no system unit file, install a local unit
if [ ! -f /usr/lib/systemd/system/os-collect-config.service ]; then

    cat <<EOF >/etc/systemd/system/os-collect-config.service
[Unit]
Description=Collect metadata and run hook commands.

[Service]
ExecStart=/etc/.rackspace_heat/bin/os-collect-config
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

cat <<EOF >/etc/os-collect-config.conf
[DEFAULT]
command=/etc/.rackspace_heat/bin/os-refresh-config
EOF
    fi

# start & enable required service
systemctl enable os-collect-config
systemctl start --no-block os-collect-config

deactivate
