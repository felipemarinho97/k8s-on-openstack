# Kubernetes Cluster on Openstack with Terraform and Ansible

This repository contains the code to create a Kubernetes cluster on Openstack with Terraform and Ansible.

## Prerequisites

In order to use this code, you need to have the following tools installed on your machine:
 - [Terraform](https://www.terraform.io/downloads.html)
 - [Ansible](https://docs.ansible.com/ansible/latest/installation_guide/intro_installation.html)

## Usage

First, download the `clouds.yml` file from your Openstack instance and save in the root of this repository. Edit the file and replace the `username` and `password` fields with your credentials.

Then, create a file named `terraform.tfvars` in the root of this repository and add the following content:

```terraform
ssh_key_path = "/path/to/your/ssh/key"
ssh_public_key_path = "/path/to/your/ssh/key.pub"
node_count = 3
```

Now, execute the following commands:

```bash
terraform init
terraform apply
```

This will create a Kubernetes cluster with one master and two worker nodes by default. 

The master node will be accessible via SSH on port 22 via the floating IP address. The worker nodes will be accessible via SSH on port 22 via the private IP address. In order to access the worker nodes, you can use the proxy node (the master node).

Example for accessing the private IP address of a worker node:

```bash
ssh -i /path/to/your/ssh/key -o ProxyCommand="ssh -i /path/to/your/ssh/key -W %h:%p ubuntu@<public_floating_ip>" ubuntu@<private_ip>
```

## Accessing the Kubernetes cluster

To copy the kubeconfig file to your local machine, execute the following command:

```bash
scp -i /path/to/your/ssh/key ubuntu@<public_floating_ip>:/home/ubuntu/.kube/config ~/.kube/config
```

Create an entry in your `/etc/hosts` file for the master node:

```bash
<public_ip> k8s-node-0
```

Edit the `~/.kube/config` file and replace the `server` field with `k8s-node-0` (the hostname of the master node).

Now, you can use `kubectl` to interact with the Kubernetes cluster.