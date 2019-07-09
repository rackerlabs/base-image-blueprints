#!/usr/bin/env python
# 6/27/2019
# Author: Kevin McJunkin
# Use away if this is somehow relevant to ya

import os
import subprocess
import shutil


# Install required packages via yum
def install_packages():
    package_list = ['python-pip',
                    'gcc',
                    'git',
                    'python-devel',
                    'libyaml-devel',
                    'openssl-devel',
                    'libffi-devel',
                    'libxml2-devel',
                    'libxslt-devel',
                    'puppet']
    print('Installing packages')
    try:
        for package in package_list:
            print('Installing ' + package)
            os.system('yum install -y ' + package + '>/dev/null')
            print('Successful\n')
    except:
        print('Unsuccessful')


# Install required packages via pip
def pip_down():
    print('\nInstalling OpenStack HEAT requirements via pip')
    os_list = ['os-collect-config',
               'os-apply-config',
               'os-refresh-config',
               'dib-utils',
               'gitpython']
    try:
        print('Installing decorator')
        os.system('pip install -U decorator >/dev/null')
        for package in os_list:
            print('Installing ' + package)
            os.system('pip install ' + package + '>/dev/null')
            print('Successful')
        print('Installing ansible')
        os.system('pip install ansible==2.4.3.0 > /dev/null')
    except:
        print('Unsuccessful')


# Remove git repo if it exist (should never come up but might as well)
# Clone git repo that has all our configuration files
def git_configuration():
    import git
    try:
        shutil.rmtree('hotstrap/')
    except OSError:
        pass
    print('\nCloning down configuration files')
    git.Git('./').clone('git://github.com/kmcjunk/hotstrap.git')


# Move configuration files to the proper location on the OS
# ...and use a really ghetto create directory for the move
# chmod files properly
def configurate():
    file_list = ['opt/stack/os-config-refresh/configure.d/20-os-apply-config',
                 'opt/stack/os-config-refresh/configure.d/55-heat-config',
                 'usr/bin/heat-config-notify',
                 'var/lib/heat-config/hooks/ansible',
                 'var/lib/heat-config/hooks/script',
                 'var/lib/heat-config/hooks/puppet',
                 'etc/os-collect-config.conf',
                 'usr/libexec/os-apply-config/templates/var/run/heat-config/heat-config',
                 'usr/libexec/os-apply-config/templates/etc/os-collect-config.conf']
    print('Moving configuration files to the proper locations\n\n')
    for file in file_list:
        directory = os.path.dirname('/' + file)
        if not os.path.exists(directory):
            os.makedirs(directory)
        print('hotstrap/' + file + '\t->\t' + '/' + file)
        shutil.move('hotstrap/' + file, '/' + file)
    for i in range(3):
        os.chmod('/' + file_list[i], 0700)
    for i in range(3, 6):
        os.chmod('/' + file_list[i], 0755)
        # os.chmod('/' + file, 0700)


# Run os-collect to propagate the config & run it again
# Then run start_config to create/enable the os-collect service
# Also clean up the git repo cause it is dead to us
def jiggle_some_things():
    print('\nRunning os-collect-config & ensuring os-collect-config-exist')
    os.system('os-collect-config --one-time --debug')
    os.system('cat /etc/os-collect-config.conf')
    os.system('os-collect-config --one-time --debug')
    print('\nEnsuring everything is running & enabled on boot')
    subprocess.call('hotstrap/start_config_agent.sh')
    print('\nCleaning up git folder')
    shutil.rmtree('hotstrap/')


# Ensure we don't get rekt by cloud-init next boot
def delete_some_other_things():
    print('Ensuring no cloud-init references exist')
    os.system('rm -rf /var/lib/cloud/instance')
    os.system('rm -rf /var/lib/cloud/instances/*')
    os.system('rm -rf /var/lib/cloud/data/*')
    os.system('rm -rf /var/lib/cloud/sem/config_scripts_per_once.once')
    os.system('rm -rf /var/log/cloud-init.log')
    os.system('rm -rf /var/log/cloud-init-output.log')
    print('\n\n\nDone!')


install_packages()
pip_down()
git_configuration()
configurate()
jiggle_some_things()
delete_some_other_things()
