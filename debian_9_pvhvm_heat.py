#!/usr/bin/env python3
# 6/27/2019
# Author: Kevin McJunkin
# Use away if this is somehow relevant to ya

import os
import subprocess
import shutil
import stat


# Install required packages via yum
def install_packages():
    package_list = ['python3-pip',
                    'gcc',
                    'git',
                    'python3-dev',
                    'libyaml-dev',
                    'libssl-dev',
                    'libffi-dev',
                    'libxml2-dev',
                    'libxslt-dev',
                    'puppet']
    print('Installing packages')
    did_package = False
    try:
        os.system('apt-get update')
        print('Installing packages')
        os.system('apt-get install -y {}'.format(" ".join(package_list)))
        print('Successful\n')
        did_package = True
    except Exception:
        print('Unsuccessful')
        exit(1)
    return did_package


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
        os.system('pip3 install -U decorator')
        print('Installing ansible')
        os.system('pip3 install ansible==2.4.3.0')
        print('Installing ansible success')
        os.system('pip3 install {}'.format(" ".join(os_list)))
        print('Successful')
        did_pip = True
    except Exception as e:
        print('Pip Install Unsuccessful {}'.format(e))
        exit(1)
    return did_pip


# Remove git repo if it exist (should never come up but might as well)
# Clone git repo that has all our configuration files
def git_configuration():
    did_git = False
    try:
        import git
        try:
            shutil.rmtree('hotstrap/')
        except OSError:
            pass
        print('\nCloning down configuration files')
        git.Git('./').clone('git://github.com/rockymccamey/hotstrap.git')
        did_git = True
    except Exception as e:
        print('Git configuration failure {}'.format(e))
        exit(1)
    return did_git


# Move configuration files to the proper location on the OS
# ...and use a really ghetto create directory for the move
# chmod files properly
def configurate():
    file_list = [
        'opt/stack/os-config-refresh/configure.d/20-os-apply-config',
        'opt/stack/os-config-refresh/configure.d/55-heat-config',
        'usr/bin/heat-config-notify',
        'var/lib/heat-config/hooks/ansible',
        'var/lib/heat-config/hooks/script',
        'var/lib/heat-config/hooks/puppet',
        'etc/os-collect-config.conf',
        'usr/libexec/os-apply-config/templates/var/run/heat-config/heat-config',  # noqa: E501
        'usr/libexec/os-apply-config/templates/etc/os-collect-config.conf'
    ]
    print('Moving configuration files to the proper locations\n\n')
    did_configure = False
    try:
        for file in file_list:
            directory = os.path.dirname('/' + file)
            if not os.path.exists(directory):
                os.makedirs(directory)
            print('hotstrap/' + file + '\t->\t' + '/' + file)
            shutil.move('hotstrap/' + file, '/' + file)
        for i in range(3):
            os.chmod(
                '/' + file_list[i],
                stat.S_IRUSR + stat.S_IWUSR + stat.S_IXUSR)
        for i in range(3, 6):
            os.chmod(
                '/' + file_list[i],
                stat.S_IRUSR + stat.S_IWUSR + stat.S_IXUSR + stat.S_IRGRP +
                stat.S_IXGRP + stat.S_IROTH + stat.S_IXOTH)
        did_configure = True
    except Exception:
        print('Configurate failure')
        exit(1)
    return did_configure


# Run os-collect to propagate the config & run it again
# Then run start_config to create/enable the os-collect service
# Also clean up the git repo cause it is dead to us
def jiggle_some_things():
    try:
        print('\nRunning os-collect-config & ensuring os-collect-config-exist')
        os.system('os-collect-config --one-time --debug')
        os.system('cat /etc/os-collect-config.conf')
        os.system('os-collect-config --one-time --debug')
        print('\nEnsuring everything is running & enabled on boot')
        subprocess.call('hotstrap/start_config_agent.sh')
        print('\nCleaning up git folder')
        shutil.rmtree('hotstrap/')
        did_jiggle = True
    except Exception:
        print('Jiggle failure')
        exit(1)
    return did_jiggle


# Ensure we don't get rekt by cloud-init next boot
def delete_some_other_things():
    try:
        print('Ensuring no cloud-init references exist')
        os.system('rm -rf /var/lib/cloud/instance')
        os.system('rm -rf /var/lib/cloud/instances/*')
        os.system('rm -rf /var/lib/cloud/data/*')
        os.system('rm -rf /var/lib/cloud/sem/config_scripts_per_once.once')
        os.system('rm -rf /var/log/cloud-init.log')
        os.system('rm -rf /var/log/cloud-init-output.log')
        print('\n\n\nDone!')
        did_delete = True
    except Exception:
        print('Delete failure')
        exit(1)
    return did_delete


did_package = install_packages()
did_pip = pip_down()
did_git = git_configuration()
did_configure = configurate()
did_jiggle = jiggle_some_things()
did_delete = delete_some_other_things()
