# Define required providers
terraform {
required_version = ">= 0.14.0"
  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
    }
  }
}

# Configure the OpenStack Provider
provider "openstack" {
  cloud = "openstack"
}

# add variables
variable "ssh_key_path" {
  type = string
  default = "~/.ssh/id_ed25519"
}

variable "ssh_public_key_path" {
  type = string
  default = "~/.ssh/id_ed25519.pub"
}

variable "node_count" {
  type = number
  default = 3
}

# create keypair
resource "openstack_compute_keypair_v2" "grupo11_pair" {
  name       = "grupo11"
  public_key = file(var.ssh_public_key_path)
}

# create security group
resource "openstack_compute_secgroup_v2" "grupo11sg" {
  name        = "grupo11"
  description = "Security group for grupo11"

  # ssh
  rule {
    from_port   = 22
    to_port     = 22
    ip_protocol = "tcp"
    cidr        = "0.0.0.0/0"
  }

  # api server
  rule {
    from_port   = 6443
    to_port     = 6443
    ip_protocol = "tcp"
    cidr        = "0.0.0.0/0"
  }

  # kubelet
  rule {
    from_port   = 10250
    to_port     = 10250
    ip_protocol = "tcp"
    cidr        = "10.5.0.0/16"
  }

  # kube-proxy
  rule {
    from_port   = 10249
    to_port     = 10259
    ip_protocol = "tcp"
    cidr        = "10.5.0.0/16"
  }

  # flannel vxlan
  rule {
    from_port   = 4789
    to_port     = 4789
    ip_protocol = "udp"
    cidr        = "10.5.0.0/16"
  }

  # flannel vtep
  rule {
    from_port   = 8472
    to_port     = 8472
    ip_protocol = "udp"
    cidr        = "10.5.0.0/16"
  }

  # node ports
  rule {
    from_port   = 30000
    to_port     = 32767
    ip_protocol = "tcp"
    cidr        = "0.0.0.0/0"
  }
}

# create 3 nodes within a loop
resource "openstack_compute_instance_v2" "k8s-node" {
  count           = 3
  name            = "k8s-node-${count.index}"
  image_id        = "62dee28f-987d-40f5-a308-051d59991da8" # Ubuntu 22.04
  flavor_id       = "69495bdc-cc5a-4596-9b0a-e2c30956df46" # general.medium
  key_pair        = openstack_compute_keypair_v2.grupo11_pair.name
  security_groups = [openstack_compute_secgroup_v2.grupo11sg.name]

  metadata = {
    grupo = "11"
    role = "k8s-node"
  }

  network {
    name = "provider"
  }
}

# create floating ip
resource "openstack_networking_floatingip_v2" "grupo11_floating_ip" {
  pool = "public"
}

# attach floating ip to bastion node (k8s-node-0)
resource "openstack_compute_floatingip_associate_v2" "grupo11_floating_ip" {
  floating_ip = openstack_networking_floatingip_v2.grupo11_floating_ip.address
  instance_id = openstack_compute_instance_v2.k8s-node[0].id
}

# generate inventory file
resource "local_file" "inventory" {
  content = <<EOF
[all]
${join("\n", openstack_compute_instance_v2.k8s-node.*.access_ip_v4)}

[master]
${openstack_compute_instance_v2.k8s-node[0].access_ip_v4}

[worker]
${join("\n", slice(openstack_compute_instance_v2.k8s-node.*.access_ip_v4, 1, length(openstack_compute_instance_v2.k8s-node.*.access_ip_v4)))}

[all:vars]
ansible_user=ubuntu
ansible_ssh_private_key_file=${var.ssh_key_path}
ansible_ssh_common_args='-o StrictHostKeyChecking=no -o ProxyCommand="ssh -W %h:%p -q ubuntu@${openstack_compute_floatingip_associate_v2.grupo11_floating_ip.floating_ip}"'
advertise_address=${openstack_compute_floatingip_associate_v2.grupo11_floating_ip.floating_ip}
EOF
  filename = "inventory"
  depends_on = [openstack_compute_floatingip_associate_v2.grupo11_floating_ip]
}

# execute ansible playbooks docker_install.yml and k8s_install.yml
resource "null_resource" "ansible_docker_install" {
  provisioner "remote-exec" {
    # test all nodes are up
    connection {
      type = "ssh"
      host = openstack_compute_floatingip_associate_v2.grupo11_floating_ip.floating_ip
      user = "ubuntu"
      private_key = file(var.ssh_key_path)
    }

    inline = ["echo 'connected!'"]
  }
  provisioner "local-exec" {
    command = "ansible-playbook -i inventory ansible/playbooks/docker_install.yml"
  }
  depends_on = [local_file.inventory]
}

resource "null_resource" "ansible_k8s_install" {
  provisioner "local-exec" {
    command = "ansible-playbook -i inventory ansible/playbooks/k8s_install.yml"
  }
  depends_on = [null_resource.ansible_docker_install]
}

# execute ansible playbooks k8s_init.yml
resource "null_resource" "ansible_k8s_init" {
  provisioner "local-exec" {
    command = "ansible-playbook -i inventory ansible/playbooks/k8s_init.yml"
  }
  depends_on = [null_resource.ansible_k8s_install, null_resource.ansible_docker_install]
}

# execute ansible playbooks k8s_cni.yml
resource "null_resource" "ansible_k8s_cni" {
  provisioner "local-exec" {
    command = "ansible-playbook -i inventory ansible/playbooks/k8s_cni.yml"
  }
  depends_on = [null_resource.ansible_k8s_init]
}

# execute ansible playbooks k8s_join.yml
resource "null_resource" "ansible_k8s_join" {
  provisioner "local-exec" {
    command = "ansible-playbook -i inventory ansible/playbooks/k8s_join.yml"
  }
  depends_on = [null_resource.ansible_k8s_init]
}

# output the command to copy the kubeconfig file
output "kubeconfig" {
  value = "ssh ubuntu@${openstack_compute_floatingip_associate_v2.grupo11_floating_ip.floating_ip} 'cat ~/.kube/config | sed \"s/${openstack_compute_instance_v2.k8s-node[0].access_ip_v4}/k8s-node-0/g\"' > ~/.kube/config"
}
output "ssh_control_plane" {
  value = "ssh ubuntu@${openstack_compute_instance_v2.k8s-node[0].access_ip_v4} -o StrictHostKeyChecking=no -o ProxyCommand=\"ssh -W %h:%p -q ubuntu@${openstack_compute_floatingip_associate_v2.grupo11_floating_ip.floating_ip}\""
}
output "public_ip" {
  value = openstack_compute_floatingip_associate_v2.grupo11_floating_ip.floating_ip
}