# openshift-cluster-benchmark-lab

Tool to provisioning OCP cluster and run pre-build benchmark tests.

The configuration will be created dinamicaly with a pre-set of cluster profiles (customized), once the cluster is provisioned, it will  start a set of pre-defined tests and collect the results locally.

The scripts run on top o openshift-installer using IPI method.

Use cases:
- benchmark specific components from a cloud provider. Eg:
  * benchamark AWS disks gp2 and gp3, then compare with Azure disks
  * test different instance types with a custom Installer binary
- help on daily tasks spining-up clusters configuration


## Usage

Edit the .env file with our credentials:

~~~
cp .env-sample .env
vim .env
~~~

The variables must be set:
- `SSH_PUB_KEYS` : ssh public keys to be added to cluster nodes
- `PULL_SECRET`  : your pull secret
- `OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE` : if desired, override installer image release

### `cluster create`

> similar `openshift-install create cluster`

This command creates the install-config.yaml and run `openshift-install create cluster`.

Create a cluster named `c2awsm5x2xgp2` with profile `aws_m5x2xgp2`

~~~
ocp-benchmark cluster create \
    --cluster-profile aws_m5x2xgp2 \
    --cluster-name c2awsm5x2xgp2 --force
~~~

### `cluster setup`

> similar `openshift-install create (manifests|ignition-configs)`

If you want to render the install-config and create manifests, run the `cluster setup`:

~~~
ocp-benchmark cluster setup \
    --cluster-profile aws_m5x2xgp2 \
    --cluster-name c2awsm5x2xgp2
~~~

Then, check-out the changes and run the `cluster install`.

### `cluster install`

> similar `openshift-install create cluster`

Install a cluster from a already created install dir:

~~~
ocp-benchmark cluster install \
    --cluster-profile aws_m5x2xgp2 \
    --cluster-name c2awsm5x2xgp2
~~~

### cluster destroy

- Remove a cluster:

~~~
ocp-benchmark cluster destroy --cluster-name c2awsm5x2xgp2
~~~

### cluster check / ping

- Check / ping current cluster

~~~
ocp-benchmark cluster ping --cluster-name c2awsm5x2xgp2
~~~


### run benchmark job

- Create a job [`b3_c2`] binding benchmark profile [`fio_libaio_rw`] to a cluster:

~~~
ocp-benchmark run \
    --job-name b3_c2 \
    --cluster-name c2awsm5x2xgp2 \
    --benchmark-profile fio_libaio_rw \
    --dump-prometheus
~~~

- group results with prefix dir (`b3`)
~~~
ocp-benchmark run \
    --cluster-name awsm5x2xgp2 \
    --job-name c2 \
    --job-group b3 \
    --benchmark-profile fio_etcd_one_cp
~~~

## Customization

You can edit any `config.yaml` parameter to create customized cluster installation.

> TODO add --config option to point to a custom config.

Please see bellow some examples to customize the project.

## Steps to create a new cluster profile

You may need to create a custom cluster profile when:
- change instance type
- change volume type
- run custom patchs
- run a custom installer

1. create a task function in `src/cluster_jobs`. Function should have name prefix `task_`
2. create a task profile in `config.yaml: task_profiles.${name}`
3. bind the new task to a benchmark profile: `benchmark_profiles.${name}.task_profiles[]`

## Steps to create new task

1. create a task function in `src/cluster_jobs`. Function should have name prefix `task_`
2. create a task profile in `config.yaml: task_profiles.${name}`
3. bind the new task to a benchmark profile: `benchmark_profiles.${name}.task_profiles[]`

## Step to create new manifest patch

> TODO


