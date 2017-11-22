#!/bin/bash

# Update repositories and install required packages for SoftwareConfig Agents and Ansible
yum install -y \
  python-pip \
  git \
  gcc \
  python-devel \
  libyaml-devel \
  openssl-devel \
  libffi-devel \
  libxml2-devel \
  libxslt-devel \
  salt-minion \
  puppet

# Install Chef
curl -L https://www.chef.io/chef/install.sh | sudo bash -

# Disable Salt-Minion daemon (to prevent polling)
systemctl disable salt-minion.service

# Disble Puppet daemon (to prevent polling)
systemctl disable puppet.service

# Write '/etc/os-collect-config.conf'
cat > /etc/os-collect-config.conf <<'EOF'
[DEFAULT]
command = os-refresh-config
EOF

# Write '/usr/libexec/os-apply-config/templates/etc/os-collect-config.conf'
mkdir -p /usr/libexec/os-apply-config/templates/etc/
cat > /usr/libexec/os-apply-config/templates/etc/os-collect-config.conf <<'EOF'
[DEFAULT]
{{^os-collect-config.command}}
command = os-refresh-config
{{/os-collect-config.command}}
{{#os-collect-config}}
{{#command}}
command = {{command}}
{{/command}}
polling_interval = 5
{{#cachedir}}
cachedir = {{cachedir}}
{{/cachedir}}
{{#collectors}}
collectors = {{.}}
{{/collectors}}

{{#cfn}}
[cfn]
{{#metadata_url}}
metadata_url = {{metadata_url}}
{{/metadata_url}}
stack_name = {{stack_name}}
secret_access_key = {{secret_access_key}}
access_key_id = {{access_key_id}}
path = {{path}}
{{/cfn}}

{{#heat}}
[heat]
auth_url = {{auth_url}}
user_id = {{user_id}}
password = {{password}}
project_id = {{project_id}}
stack_id = {{stack_id}}
resource_name = {{resource_name}}
{{/heat}}

{{#request}}
[request]
{{#metadata_url}}
metadata_url = {{metadata_url}}
{{/metadata_url}}
{{/request}}

{{#ec2}}
[ec2]
{{#metadata_url}}
metadata_url = {{metadata_url}}
{{/metadata_url}}
{{/ec2}}

{{/os-collect-config}}
EOF

# Write '/usr/libexec/os-apply-config/templates/var/run/heat-config/heat-config'
mkdir -p /usr/libexec/os-apply-config/templates/var/run/heat-config/
cat > /usr/libexec/os-apply-config/templates/var/run/heat-config/heat-config <<'EOF'
{{deployments}}
EOF

# Write '/opt/stack/os-config-refresh/configure.d/20-os-apply-config'
mkdir -p /opt/stack/os-config-refresh/configure.d/
cat > /opt/stack/os-config-refresh/configure.d/20-os-apply-config <<'EOF'
#!/bin/bash
set -ue
exec os-apply-config
EOF
chmod 0700 /opt/stack/os-config-refresh/configure.d/20-os-apply-config

# Write '/opt/stack/os-config-refresh/configure.d/55-heat-config'
mkdir -p /opt/stack/os-config-refresh/configure.d/
cat > /opt/stack/os-config-refresh/configure.d/55-heat-config <<'EOF'
#!/usr/bin/env python
#
#    Licensed under the Apache License, Version 2.0 (the "License"); you may
#    not use this file except in compliance with the License. You may obtain
#    a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
#    WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
#    License for the specific language governing permissions and limitations
#    under the License.

import json
import logging
import os
import subprocess
import sys

import requests

HOOKS_DIR = os.environ.get('HEAT_CONFIG_HOOKS',
                           '/var/lib/heat-config/hooks')
CONF_FILE = os.environ.get('HEAT_SHELL_CONFIG',
                           '/var/run/heat-config/heat-config')
DEPLOYED_DIR = os.environ.get('HEAT_CONFIG_DEPLOYED',
                              '/var/run/heat-config/deployed')
HEAT_CONFIG_NOTIFY = os.environ.get('HEAT_CONFIG_NOTIFY',
                                    'heat-config-notify')


def main(argv=sys.argv):
    log = logging.getLogger('heat-config')
    handler = logging.StreamHandler(sys.stderr)
    handler.setFormatter(
        logging.Formatter(
            '[%(asctime)s] (%(name)s) [%(levelname)s] %(message)s'))
    log.addHandler(handler)
    log.setLevel('DEBUG')

    if not os.path.exists(CONF_FILE):
        log.error('No config file %s' % CONF_FILE)
        return 1

    if not os.path.isdir(DEPLOYED_DIR):
        os.makedirs(DEPLOYED_DIR, 0o700)

    try:
        configs = json.load(open(CONF_FILE))
    except ValueError:
        pass
    else:
        for c in configs:
            try:
                invoke_hook(c, log)
            except Exception as e:
                log.exception(e)


def invoke_hook(c, log):
    # Sanitize input values (bug 1333992). Convert all String
    # inputs to strings if they're not already
    hot_inputs = c.get('inputs', [])
    for hot_input in hot_inputs:
        if hot_input.get('type', None) == 'String' and \
                not isinstance(hot_input['value'], basestring):
            hot_input['value'] = str(hot_input['value'])
    iv = dict((i['name'], i['value']) for i in c['inputs'])
    # The group property indicates whether it is softwarecomponent or
    # plain softwareconfig
    # If it is softwarecomponent, pick up a property config to invoke
    # according to deploy_action
    group = c.get('group')
    if group == 'component':
        found = False
        action = iv.get('deploy_action')
        config = c.get('config')
        configs = config.get('configs')
        if configs:
            for cfg in configs:
                if action in cfg['actions']:
                    c['config'] = cfg['config']
                    c['group'] = cfg['tool']
                    found = True
                    break
        if not found:
            log.warn('Skipping group %s, no valid script is defined'
                     ' for deploy action %s' % (group, action))
            return

    # check to see if this config is already deployed
    deployed_path = os.path.join(DEPLOYED_DIR, '%s.json' % c['id'])

    if os.path.exists(deployed_path):
        log.warn('Skipping config %s, already deployed' % c['id'])
        log.warn('To force-deploy, rm %s' % deployed_path)
        return

    # sanitise the group to get an alphanumeric hook file name
    hook = "".join(
        x for x in c['group'] if x == '-' or x == '_' or x.isalnum())
    hook_path = os.path.join(HOOKS_DIR, hook)

    signal_data = {}
    if not os.path.exists(hook_path):
        log.warn('Skipping group %s with no hook script %s' % (
            c['group'], hook_path))
        return

    # write out config, which indicates it is deployed regardless of
    # subsequent hook success
    with os.fdopen(os.open(
            deployed_path, os.O_CREAT | os.O_WRONLY, 0o600), 'w') as f:
        json.dump(c, f, indent=2)

    log.debug('Running %s < %s' % (hook_path, deployed_path))
    subproc = subprocess.Popen([hook_path],
                               stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE)
    stdout, stderr = subproc.communicate(input=json.dumps(c))

    log.info(stdout)
    log.debug(stderr)

    if subproc.returncode:
        log.error("Error running %s. [%s]\n" % (
            hook_path, subproc.returncode))
    else:
        log.info('Completed %s' % hook_path)

    try:
        if stdout:
            signal_data = json.loads(stdout)
    except ValueError:
        signal_data = {
            'deploy_stdout': stdout,
            'deploy_stderr': stderr,
            'deploy_status_code': subproc.returncode,
        }

    signal_data_path = os.path.join(DEPLOYED_DIR, '%s.notify.json' % c['id'])
    # write out notify data for debugging
    with os.fdopen(os.open(
            signal_data_path, os.O_CREAT | os.O_WRONLY, 0o600), 'w') as f:
        json.dump(signal_data, f, indent=2)

    log.debug('Running %s %s < %s' % (
        HEAT_CONFIG_NOTIFY, deployed_path, signal_data_path))
    subproc = subprocess.Popen([HEAT_CONFIG_NOTIFY, deployed_path],
                               stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE)
    stdout, stderr = subproc.communicate(input=json.dumps(signal_data))

    log.info(stdout)

    if subproc.returncode:
        log.error(
            "Error running heat-config-notify. [%s]\n" % subproc.returncode)
        log.error(stderr)
    else:
        log.debug(stderr)


if __name__ == '__main__':
    sys.exit(main(sys.argv))
EOF
chmod 0700 /opt/stack/os-config-refresh/configure.d/55-heat-config

# Write '/var/lib/heat-config/hooks/script'
mkdir -p /var/lib/heat-config/hooks/
cat > /var/lib/heat-config/hooks/script <<'EOF'
#!/usr/bin/env python
#
#    Licensed under the Apache License, Version 2.0 (the "License"); you may
#    not use this file except in compliance with the License. You may obtain
#    a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
#    WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
#    License for the specific language governing permissions and limitations
#    under the License.

import json
import logging
import os
import subprocess
import sys

WORKING_DIR = os.environ.get('HEAT_SCRIPT_WORKING',
                             '/var/lib/heat-config/heat-config-script')
OUTPUTS_DIR = os.environ.get('HEAT_SCRIPT_OUTPUTS',
                             '/var/run/heat-config/heat-config-script')


def prepare_dir(path):
    if not os.path.isdir(path):
        os.makedirs(path, 0o700)


def main(argv=sys.argv):
    log = logging.getLogger('heat-config')
    handler = logging.StreamHandler(sys.stderr)
    handler.setFormatter(
        logging.Formatter(
            '[%(asctime)s] (%(name)s) [%(levelname)s] %(message)s'))
    log.addHandler(handler)
    log.setLevel('DEBUG')

    prepare_dir(OUTPUTS_DIR)
    prepare_dir(WORKING_DIR)
    os.chdir(WORKING_DIR)

    c = json.load(sys.stdin)

    env = os.environ.copy()
    for input in c['inputs']:
        input_name = input['name']
        value = input.get('value', '')
        if isinstance(value, dict) or isinstance(value, list):
            env[input_name] = json.dumps(value)
        else:
            env[input_name] = value
        log.info('%s=%s' % (input_name, env[input_name]))

    fn = os.path.join(WORKING_DIR, c['id'])
    heat_outputs_path = os.path.join(OUTPUTS_DIR, c['id'])
    env['heat_outputs_path'] = heat_outputs_path

    with os.fdopen(os.open(fn, os.O_CREAT | os.O_WRONLY, 0o700), 'w') as f:
        f.write(c.get('config', '').encode('utf-8'))

    log.debug('Running %s' % fn)
    subproc = subprocess.Popen([fn], stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, env=env)
    stdout, stderr = subproc.communicate()

    log.info(stdout)
    log.debug(stderr)

    if subproc.returncode:
        log.error("Error running %s. [%s]\n" % (fn, subproc.returncode))
    else:
        log.info('Completed %s' % fn)

    response = {}

    for output in c.get('outputs') or []:
        output_name = output['name']
        try:
            with open('%s.%s' % (heat_outputs_path, output_name)) as out:
                response[output_name] = out.read()
        except IOError:
            pass

    response.update({
        'deploy_stdout': stdout,
        'deploy_stderr': stderr,
        'deploy_status_code': subproc.returncode,
    })

    json.dump(response, sys.stdout)

if __name__ == '__main__':
    sys.exit(main(sys.argv))
EOF
chmod 0755 /var/lib/heat-config/hooks/script

# Write '/var/lib/heat-config/hooks/ansible'
mkdir -p /var/lib/heat-config/hooks/
cat > /var/lib/heat-config/hooks/ansible <<'EOF'
#!/usr/bin/env python
#
#    Licensed under the Apache License, Version 2.0 (the "License"); you may
#    not use this file except in compliance with the License. You may obtain
#    a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
#    WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
#    License for the specific language governing permissions and limitations
#    under the License.

import json
import logging
import os
import subprocess
import sys

WORKING_DIR = os.environ.get('HEAT_ANSIBLE_WORKING',
                             '/var/lib/heat-config/heat-config-ansible')
OUTPUTS_DIR = os.environ.get('HEAT_ANSIBLE_OUTPUTS',
                             '/var/run/heat-config/heat-config-ansible')


def prepare_dir(path):
    if not os.path.isdir(path):
        os.makedirs(path, 0o700)


def main(argv=sys.argv):
    log = logging.getLogger('heat-config')
    handler = logging.StreamHandler(sys.stderr)
    handler.setFormatter(
        logging.Formatter(
            '[%(asctime)s] (%(name)s) [%(levelname)s] %(message)s'))
    log.addHandler(handler)
    log.setLevel('DEBUG')

    prepare_dir(OUTPUTS_DIR)
    prepare_dir(WORKING_DIR)
    os.chdir(WORKING_DIR)

    c = json.load(sys.stdin)

    variables = {}
    for input in c['inputs']:
        variables[input['name']] = input.get('value', '')

    fn = os.path.join(WORKING_DIR, '%s_playbook.yaml' % c['id'])
    vars_filename = os.path.join(WORKING_DIR, '%s_variables.json' % c['id'])
    heat_outputs_path = os.path.join(OUTPUTS_DIR, c['id'])
    variables['heat_outputs_path'] = heat_outputs_path

    config_text = c.get('config', '')
    if not config_text:
        log.warn("No 'config' input found, nothing to do.")
        return
    # Write 'variables' to file
    with os.fdopen(os.open(
            vars_filename, os.O_CREAT | os.O_WRONLY, 0o600), 'w') as var_file:
        json.dump(variables, var_file)
    # Write the executable, 'config', to file
    with os.fdopen(os.open(fn, os.O_CREAT | os.O_WRONLY, 0o600), 'w') as f:
        f.write(c.get('config', '').encode('utf-8'))

    cmd = [
        'ansible-playbook',
        '-i',
        'localhost,',
        fn,
        '--extra-vars',
        '@%s' % vars_filename
    ]
    log.debug('Running %s' % (' '.join(cmd),))
    try:
        subproc = subprocess.Popen(cmd, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE)
    except OSError:
        log.warn("ansible not installed yet")
        return
    stdout, stderr = subproc.communicate()

    log.info('Return code %s' % subproc.returncode)
    if stdout:
        log.info(stdout)
    if stderr:
        log.info(stderr)

    # TODO(stevebaker): Test if ansible returns any non-zero
    # return codes in success.
    if subproc.returncode:
        log.error("Error running %s. [%s]\n" % (fn, subproc.returncode))
    else:
        log.info('Completed %s' % fn)

    response = {}

    for output in c.get('outputs') or []:
        output_name = output['name']
        try:
            with open('%s.%s' % (heat_outputs_path, output_name)) as out:
                response[output_name] = out.read()
        except IOError:
            pass

    response.update({
        'deploy_stdout': stdout,
        'deploy_stderr': stderr,
        'deploy_status_code': subproc.returncode,
    })

    json.dump(response, sys.stdout)

if __name__ == '__main__':
    sys.exit(main(sys.argv))
EOF
chmod 0755 /var/lib/heat-config/hooks/ansible

# Write '/var/lib/heat-config/hooks/chef'
cat > /var/lib/heat-config/hooks/chef <<'EOF'
#!/usr/bin/env python
#
#    Licensed under the Apache License, Version 2.0 (the "License"); you may
#    not use this file except in compliance with the License. You may obtain
#    a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
#    WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
#    License for the specific language governing permissions and limitations
#    under the License.
import json
import logging
import os
import shutil
import six
import subprocess
import sys
DEPLOY_KEYS = ("deploy_server_id",
               "deploy_action",
               "deploy_stack_id",
               "deploy_resource_name",
               "deploy_signal_transport",
               "deploy_signal_id",
               "deploy_signal_verb")
WORKING_DIR = os.environ.get('HEAT_CHEF_WORKING',
                             '/var/lib/heat-config/heat-config-chef')
OUTPUTS_DIR = os.environ.get('HEAT_CHEF_OUTPUTS',
                             '/var/run/heat-config/heat-config-chef')
def prepare_dir(path):
    if not os.path.isdir(path):
        os.makedirs(path, 0o700)
def run_subproc(fn, **kwargs):
    env = os.environ.copy()
    for k, v in kwargs.items():
        env[six.text_type(k)] = v
    try:
        subproc = subprocess.Popen(fn, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE,
                                   env=env)
        stdout, stderr = subproc.communicate()
    except OSError as exc:
        ret = -1
        stderr = six.text_type(exc)
        stdout = ""
    else:
        ret = subproc.returncode
    if not ret:
        ret = 0
    return ret, stdout, stderr
def main(argv=sys.argv):
    log = logging.getLogger('heat-config')
    handler = logging.StreamHandler(sys.stderr)
    handler.setFormatter(
        logging.Formatter(
            '[%(asctime)s] (%(name)s) [%(levelname)s] %(message)s'))
    log.addHandler(handler)
    log.setLevel('DEBUG')
    prepare_dir(OUTPUTS_DIR)
    prepare_dir(WORKING_DIR)
    os.chdir(WORKING_DIR)
    c = json.load(sys.stdin)
    client_config = ("log_level :debug\n"
                     "log_location STDOUT\n"
                     "local_mode true\n"
                     "chef_zero.enabled true")
    # configure/set up the kitchen
    kitchen = c['options'].get('kitchen')
    kitchen_path = c['options'].get('kitchen_path', os.path.join(WORKING_DIR,
                                                                 "kitchen"))
    cookbook_path = os.path.join(kitchen_path, "cookbooks")
    role_path = os.path.join(kitchen_path, "roles")
    environment_path = os.path.join(kitchen_path, "environments")
    client_config += "\ncookbook_path '%s'" % cookbook_path
    client_config += "\nrole_path '%s'" % role_path
    client_config += "\nenvironment_path '%s'" % environment_path
    if kitchen:
        log.debug("Cloning kitchen from %s", kitchen)
        # remove the existing kitchen on update so we get a fresh clone
        dep_action = next((input['value'] for input in c['inputs']
                           if input['name'] == "deploy_action"), None)
        if dep_action == "UPDATE":
            shutil.rmtree(kitchen_path, ignore_errors=True)
        cmd = ["git", "clone", kitchen, kitchen_path]
        ret, out, err = run_subproc(cmd)
        if ret != 0:
            log.error("Error cloning kitchen from %s into %s: %s", kitchen,
                      kitchen_path, err)
            json.dump({'deploy_status_code': ret,
                       'deploy_stdout': out,
                       'deploy_stderr': err},
                      sys.stdout)
            return 0
    # write the json attributes
    ret, out, err = run_subproc(['hostname', '-f'])
    if ret == 0:
        fqdn = out.strip()
    else:
        err = "Could not determine hostname with hostname -f"
        json.dump({'deploy_status_code': ret,
                   'deploy_stdout': "",
                   'deploy_stderr': err}, sys.stdout)
        return 0
    node_config = {}
    for input in c['inputs']:
        if input['name'] == 'environment':
            client_config += "\nenvironment '%s'" % input['value']
        elif input['name'] not in DEPLOY_KEYS:
            node_config.update({input['name']: input['value']})
    node_config.update({"run_list": json.loads(c['config'])})
    node_path = os.path.join(WORKING_DIR, "node")
    prepare_dir(node_path)
    node_file = os.path.join(node_path, "%s.json" % fqdn)
    with os.fdopen(os.open(node_file, os.O_CREAT | os.O_WRONLY, 0o600),
                   'w') as f:
        f.write(json.dumps(node_config, indent=4))
    client_config += "\nnode_path '%s'" % node_path
    # write out the completed client config
    config_path = os.path.join(WORKING_DIR, "client.rb")
    with os.fdopen(os.open(config_path, os.O_CREAT | os.O_WRONLY, 0o600),
                   'w') as f:
        f.write(client_config)
    # run chef
    heat_outputs_path = os.path.join(OUTPUTS_DIR, c['id'])
    cmd = ['chef-client', '-z', '--config', config_path, "-j", node_file]
    ret, out, err = run_subproc(cmd, heat_outputs_path=heat_outputs_path)
    resp = {'deploy_status_code': ret,
            'deploy_stdout': out,
            'deploy_stderr': err}
    log.debug("Chef output: %s", out)
    if err:
        log.error("Chef return code %s:\n%s", ret, err)
    for output in c.get('outputs', []):
        output_name = output['name']
        try:
            with open('%s.%s' % (heat_outputs_path, output_name)) as out:
                resp[output_name] = out.read()
        except IOError:
            pass
    json.dump(resp, sys.stdout)
if __name__ == '__main__':
    sys.exit(main(sys.argv))
EOF
chmod 0755 /var/lib/heat-config/hooks/chef

# Write '/usr/bin/heat-config-notify'
cat > /usr/bin/heat-config-notify <<'EOF'
#!/usr/bin/env python
#
#    Licensed under the Apache License, Version 2.0 (the "License"); you may
#    not use this file except in compliance with the License. You may obtain
#    a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
#    WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
#    License for the specific language governing permissions and limitations
#    under the License.

import json
import logging
import os
import sys

import requests

try:
    from heatclient import client as heatclient
except ImportError:
    heatclient = None

try:
    from keystoneclient.v3 import client as ksclient
except ImportError:
    ksclient = None


def init_logging():
    log = logging.getLogger('heat-config-notify')
    handler = logging.StreamHandler(sys.stderr)
    handler.setFormatter(
        logging.Formatter(
            '[%(asctime)s] (%(name)s) [%(levelname)s] %(message)s'))
    log.addHandler(handler)
    log.setLevel('DEBUG')
    return log


def main(argv=sys.argv, stdin=sys.stdin):

    log = init_logging()
    usage = ('Usage:\n  heat-config-notify /path/to/config.json '
             '< /path/to/signal_data.json')

    if len(argv) < 2:
        log.error(usage)
        return 1

    try:
        signal_data = json.load(stdin)
    except ValueError:
        log.warn('No valid json found on stdin')
        signal_data = {}

    conf_file = argv[1]
    if not os.path.exists(conf_file):
        log.error('No config file %s' % conf_file)
        log.error(usage)
        return 1

    c = json.load(open(conf_file))

    iv = dict((i['name'], i['value']) for i in c['inputs'])

    if 'deploy_signal_id' in iv:
        sigurl = iv.get('deploy_signal_id')
        sigverb = iv.get('deploy_signal_verb', 'POST')
        signal_data = json.dumps(signal_data)
        log.debug('Signaling to %s via %s' % (sigurl, sigverb))
        if sigverb == 'PUT':
            r = requests.put(sigurl, data=signal_data,
                             headers={'content-type': None})
        else:
            r = requests.post(sigurl, data=signal_data,
                              headers={'content-type': None})
        log.debug('Response %s ' % r)

    if 'deploy_auth_url' in iv:
        ks = ksclient.Client(
            auth_url=iv['deploy_auth_url'],
            user_id=iv['deploy_user_id'],
            password=iv['deploy_password'],
            project_id=iv['deploy_project_id'])
        endpoint = ks.service_catalog.url_for(
            service_type='orchestration', endpoint_type='publicURL')
        log.debug('Signalling to %s' % endpoint)
        heat = heatclient.Client(
            '1', endpoint, token=ks.auth_token)
        r = heat.resources.signal(
            iv.get('deploy_stack_id'),
            iv.get('deploy_resource_name'),
            data=signal_data)
        log.debug('Response %s ' % r)

    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv, sys.stdin))
EOF
chmod 0700 /usr/bin/heat-config-notify

# Install SoftwareConfig and Ansible via PIP
pip install ansible os-collect-config os-apply-config os-refresh-config dib-utils


# Configure services (and symlinks) assuming CentOS is using systemd
# if there is no system unit file, install a local unit
cat <<EOF >/etc/systemd/system/os-collect-config.service
[Unit]
Description=Collect metadata and run hook commands.

[Service]
ExecStart=/usr/bin/os-collect-config
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

cat <<EOF >/etc/os-collect-config.conf
[DEFAULT]
command=os-refresh-config
EOF

# enable and start service to poll for deployment changes
systemctl enable os-collect-config
systemctl start --no-block os-collect-config
