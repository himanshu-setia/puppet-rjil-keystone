#!/bin/bash -xe

if [ -z "${env}" ]
then
    echo '$env must be defined'
    exit 1
fi

# Load credentials (openrc style)
. ${env_file:-/var/lib/jenkins/cloud.${env}.env}

# Load map from generic image, flavor and network names to
# cloud specific ids
if [ -n "${mapping}" ]
then
	mappings_arg="--mappings=${mapping}"
elif [ -e "environment/${env}.map.yaml" ]
then
	mappings_arg="--mapping=senvironment/${env}.map.yaml"
else
	mappings_arg=""
fi

project_tag=${project_tag:-test${BUILD_NUMBER}}

if ! [ -e venv ]
then
    virtualenv venv
    . venv/bin/activate
    # This can go away with the next release of Pip (which will include a
    # version of python-requests newer than 2.4.0.)
    pip install -e git+http://github.com/pypa/pip#egg=pip

    # This speeds the whole process up *a lot*
    pip install pip-accel
    pip-accel install -e git+https://github.com/sorenh/python-jiocloud@mapping#egg=jiocloud
    deactivate
fi

. venv/bin/activate

# this is here to allow a user to override the command used for
# the timeout function just incase it happens to be gtimeout
timeout=${timeout_command:-timeout}

# If these aren't yet set (from credentials file, typically),
# create new ones.
if [ -z "${etcd_discovery_token}" ]
then
    etcd_discovery_token=$(python -m jiocloud.orchestrate new_discovery_token)
fi

if [ -z "${consul_discovery_token}" ]
then
    consul_discovery_token=$(curl http://consuldiscovery.linux2go.dk/new)
fi

cat <<EOF >userdata.txt
#!/bin/bash
release="\$(lsb_release -cs)"
export no_proxy="127.0.0.1,localhost,consul"
echo no_proxy="'127.0.0.1,localhost,consul'" >> /etc/environment
if [ -n "${env_http_proxy}" ]
then
	export http_proxy=${env_http_proxy}
	echo http_proxy="'${env_http_proxy}'" >> /etc/environment
fi
if [ -n "${env_https_proxy}" ]
then
	export https_proxy=${env_https_proxy}
	export ETCD_DISCOVERY_PROXY=${env_https_proxy}
	echo ETCD_DISCOVERY_PROXY="'${env_https_proxy}'" >> /etc/environment
	echo https_proxy="'${env_https_proxy}'" >> /etc/environment
fi
wget -O puppet.deb http://apt.puppetlabs.com/puppetlabs-release-\${release}.deb
wget -O jiocloud.deb http://jiocloud.rustedhalo.com/ubuntu/jiocloud-apt-\${release}.deb
dpkg -i puppet.deb jiocloud.deb
apt-get update
apt-get install -y puppet software-properties-common puppet-jiocloud
### XXX These two lines need to go away:
apt-get install -y python-glanceclient
sed -i -e s/eth0/eth2/g /etc/puppet/hiera/data/env/staging.yaml 
sed -i -e '2i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' /usr/local/bin/maybe-upgrade.sh
if [ -n "${puppet_modules_source_repo}" ]; then
  apt-get install -y git
  git clone ${puppet_modules_source_repo} /tmp/rjil
  if [ -n "${puppet_modules_source_branch}" ]; then
    pushd /tmp/rjil
    git checkout ${puppet_modules_source_branch}
    popd
  fi
  if [ -n "${pull_request_id}" ]; then
    pushd /tmp/rjil
    git fetch origin pull/${pull_request_id}/head:test_${pull_request_id}
    git config user.email "testuser@localhost.com"
    git config user.name "Test User"
    git merge -m 'Merging Pull Request' test_${pull_request_id}
    popd
  fi
  gem install librarian-puppet-simple --no-ri --no-rdoc;
  mkdir -p /etc/puppet/manifests.overrides
  cp /tmp/rjil/site.pp /etc/puppet/manifests.overrides/
  mkdir -p /etc/puppet/hiera
  cp /tmp/rjil/hiera/hiera.yaml /etc/puppet
  cp -Rvf /tmp/rjil/hiera/data /etc/puppet/hiera
  mkdir -p /etc/puppet/modules.overrides/rjil
  cp -Rvf /tmp/rjil/* /etc/puppet/modules.overrides/rjil/
  librarian-puppet install --puppetfile=/tmp/rjil/Puppetfile --path=/etc/puppet/modules.overrides
  puppet apply -e "ini_setting { modulepath: path => \"/etc/puppet/puppet.conf\", section => main, setting => modulepath, value => \"/etc/puppet/modules.overrides:/etc/puppet/modules\" }"
  puppet apply -e "ini_setting { manifestdir: path => \"/etc/puppet/puppet.conf\", section => main, setting => manifestdir, value => \"/etc/puppet/manifests.overrides\" }"
fi
sudo mkdir -p /etc/facter/facts.d
echo 'etcd_discovery_token='${etcd_discovery_token} > /etc/facter/facts.d/etcd.txt
echo 'consul_discovery_token='${consul_discovery_token} > /etc/facter/facts.d/consul.txt
echo 'env='${env} > /etc/facter/facts.d/env.txt
puppet apply --debug -e "include rjil::jiocloud"
EOF

time python -m jiocloud.apply_resources apply --key_name=${KEY_NAME:-soren} --project_tag=${project_tag} ${mappings_arg} environment/${layout:-full}.yaml userdata.txt

ip=$(python -m jiocloud.utils get_ip_of_node etcd1_${project_tag})

time $timeout 1200 bash -c "while ! python -m jiocloud.orchestrate --host ${ip} ping; do sleep 5; done"

time $timeout 600 bash -c "while ! ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no ${ssh_user:-jenkins}@${ip} python -m jiocloud.orchestrate trigger_update ${BUILD_NUMBER}; do sleep 5; done"

time $timeout 2400 bash -c "while ! python -m jiocloud.apply_resources list --project_tag=${project_tag} environment/${layout:-full}.yaml | sed -e 's/_/-/g' | python -m jiocloud.orchestrate --host ${ip} verify_hosts ${BUILD_NUMBER} ; do sleep 5; done"
time $timeout 2400 bash -c "while ! python -m jiocloud.orchestrate --host ${ip} check_single_version -v ${BUILD_NUMBER} ; do sleep 5; done"

# make sure that there are not any failures
if ! python -m jiocloud.orchestrate --host ${ip} get_failures; then
  echo "Failures occurred"
  exit 1
fi
