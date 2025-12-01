terraform {
  required_providers {
    proxmox = {
      source  = "Telmate/proxmox"
      version = "3.0.1-rc4"
    }
  }
}

variable "proxmox_api_token_id" {
  type = string
}

variable "proxmox_api_token_secret" {
  type      = string
  sensitive = true
}

provider "proxmox" {
  pm_api_url          = "https://proxmox.example.com:8006/api2/json"
  pm_api_token_id     = var.proxmox_api_token_id
  pm_api_token_secret = var.proxmox_api_token_secret
}

# User must have sudo permissions and NOPASSWD enabled.
variable "ssh_user" {
  type = string
}
variable "ssh_port" {
  type = string
}

variable "cipassword" {
  type      = string
  sensitive = true
}

variable "new_cluster_name" {
  type    = string
  default = "new-cluster-name"
}

locals {
  starting_vmid = 9100
}

# If new master clones are to be created for redundancy, AD on template should be reconfigured.
resource "proxmox_vm_qemu" "kubernetes-master" {
  name        = "server-k8s-m01"
  target_node = "server01"
  boot        = "order=virtio0;net0"
  clone       = "kubernetes-master"
  cores       = 3
  memory      = 8192
  agent       = 1                                 #qemu
  ipconfig0   = "ip=10.0.0.11/24,gw=10.0.0.1" # Fixed IP on template, can't be changed since it's not a cloud init image.
  tags        = "k8s,project"
  vmid        = local.starting_vmid + 1
  disks {
    virtio {
      virtio0 {
        disk {
          size    = "500G"
          storage = "storage" # Proxmox node lvm storage
        }
      }
    }
  }
  # Network configuration
  network {
    model  = "virtio"
    bridge = "vmbr1" # Replace with the actual bridge name
  }

  ssh_forward_ip = "10.0.0.11" # Fixed IP on template, can't be changed since it's not a cloud init image.

  provisioner "remote-exec" {
    inline = [
      "sudo ufw disable",                           # Necessary since kubernetes will manage ip tables
      "sudo hostnamectl set-hostname ${self.name}", # Change hostname for the VM name. K8s nodes can't have the same name.
      "echo '127.0.1.1 ${self.name}' | sudo tee -a /etc/hosts",
      "sudo swapoff -a", # Disable swap. K8s requirement.
      "sudo apt update",
      "sudo DEBIAN_FRONTEND=noninteractive apt upgrade -y",
      "sudo apt autoremove -y",
      "sudo apt clean",
      "sudo apt-get install cloud-guest-utils -y", # Resize disk for the possible new volume
      "sudo growpart /dev/vda 3",
      "sudo pvresize /dev/vda3",
      "sudo lvextend -l +100%FREE /dev/ubuntu-vg/ubuntu-lv",
      "sudo resize2fs /dev/ubuntu-vg/ubuntu-lv", # End disk resize
      "wget https://github.com/etcd-io/etcd/releases/download/v3.5.5/etcd-v3.5.5-linux-amd64.tar.gz",
      "tar -xvf etcd-v3.5.5-linux-amd64.tar.gz",
      "sudo mv etcd-v3.5.5-linux-amd64/etcd* /usr/local/bin/",
      "etcd --name k8s-etcd --data-dir /var/lib/etcd --listen-client-urls http://127.0.0.1:2379 --advertise-client-urls http://127.0.0.1:2379",
      "curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC=\"server --datastore-endpoint='etcd://127.0.0.1:2379'\" sh -", # Install k3s on the master
      "sudo kubectl taint nodes $(hostname) node-role.kubernetes.io/master=:NoSchedule",                              # Taint master to not schedule apps
      "sudo cp /var/lib/rancher/k3s/server/node-token /home/ORG/${var.ssh_user}/node-token",                        # Copy token to home directory
      "sudo chown ${var.ssh_user}:root /home/ORG/${var.ssh_user}/node-token",                                       # Change ownership to the SSH user
      "sudo cp /etc/rancher/k3s/k3s.yaml /home/ORG/${var.ssh_user}/k3s.yaml",                                       # Copy kubeconfig to home directory
      "sudo chown ${var.ssh_user}:root /home/ORG/${var.ssh_user}/k3s.yaml"                                          # Change ownership to the SSH user
    ]
    connection {
      type        = "ssh"
      user        = var.ssh_user
      host        = self.ssh_forward_ip
      private_key = file("~/.ssh/id_rsa") # This key should be previously added to the templates
      port        = var.ssh_port
    }
  }
}

resource "null_resource" "get_node_token" {
  provisioner "local-exec" {
    command = "scp -o StrictHostKeyChecking=no -i ~/.ssh/id_rsa -P ${var.ssh_port} ${var.ssh_user}@${proxmox_vm_qemu.kubernetes-master.ssh_forward_ip}:/home/ORG/${var.ssh_user}/node-token ./node-token"
  }
  depends_on = [proxmox_vm_qemu.kubernetes-master]
}

resource "null_resource" "get_kubeconfig" {
  provisioner "local-exec" {
    command = <<-EOT
      scp -o StrictHostKeyChecking=no -i ~/.ssh/id_rsa -P ${var.ssh_port} ${var.ssh_user}@${proxmox_vm_qemu.kubernetes-master.ssh_forward_ip}:/home/ORG/${var.ssh_user}/k3s.yaml ./k3s.yaml && \
      sed -i 's/127.0.0.1/${proxmox_vm_qemu.kubernetes-master.ssh_forward_ip}/' ./k3s.yaml && \
      sed -i 's/name: default/name: ${var.new_cluster_name}/' ./k3s.yaml && \
      sed -i 's/cluster: default/cluster: ${var.new_cluster_name}/' ./k3s.yaml && \
      sed -i 's/user: default/user: ${var.new_cluster_name}/' ./k3s.yaml && \
      sed -i 's/current-context: default/current-context: ${var.new_cluster_name}/' ./k3s.yaml \
      export KUBECONFIG=~/.kube/config:./k3s.yaml \
      kubectl config view --merge --flatten > ~/.kube/config
    EOT
  }

  depends_on = [proxmox_vm_qemu.kubernetes-master]
}

resource "proxmox_vm_qemu" "kubernetes-workers-02" {
  for_each = {
    "01" = "10.0.0.20"
  }
  name        = "server-k8s-w${each.key}"
  tags        = "k8s,project"
  target_node = "server01"
  clone       = "cloud-init-ubuntu-20.04-template"

  # Boot
  boot   = "order=virtio0;ide2"
  scsihw = "virtio-scsi-pci"
  bios   = "ovmf"
  vmid   = local.starting_vmid + 1 + tonumber(each.key)
  # Resources
  cores         = 15
  memory        = 16384
  balloon       = 8192
  agent         = 1 #qemu
  agent_timeout = 240

  #### Cloud init configs
  os_type   = "cloud-init"
  ciupgrade = "true"
  # SSH configs
  ssh_forward_ip = each.value
  # Your Terraform host public key(s)
  sshkeys = <<EOF
  ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj+NdBrCFBMv33OHEwLghK9dxFjMjgprT2M9ATMOL6bTX/lVNly8oFnRS3Hf8vj7UadXMKiBOkGbw4Q3wOBzlZUOS7XuLb3tEg4nPwl5/HWiRZXJrLUQMr+lITlmddK9/26363dNY+mD23dQ6jS2XUmzsUQX6KQH7+MsQCoz9NR0owUvppCxzTMefGT0RcBXyNKaTCTTh1KVOrOD0tx0cMVHSc2GTMdtUC8N4lOGLKC054PmqvvFz86M9paMQvNuORMDR90PSe+0aH42go+OtK/GuLZx+BgWSs2ZuBMQy1OAc12ozLEg3k/pgvV5wHgjgcUP29HAddHVhLyklw2ZCss+jCyBUAcqnfPz5edwlsmwoNB1t0sV205UIRZRrdjT+AjWBsc8nTpVrOPb8sCeKAH3E8tbbWI0zNJ6SAYG7Q6iAl6dTe+fux/5LT3R99Isv9bxlVtPsZ5WwqlfoeoyvgEWktUyGiGFVmdHBWvUZpF27I/l9o3JGpKFqyOzpfUp0= user@host
  EOF
  # Ip configs
  ipconfig0  = "ip=${each.value}/24,gw=10.0.0.254" # Fixed IP
  nameserver = "8.8.8.8,8.8.4.4"
  # User configs
  ciuser     = var.ssh_user
  cipassword = var.cipassword

  disks {
    # OS disk, will be logically auto resized by cloud-init (**happiness intensifies**)
    virtio {
      virtio0 {
        disk {
          size    = "2000G"
          storage = "storage" # Proxmox node lvm storage
        }
      }
    }
    #Cloud init driver
    ide {
      ide2 {
        cloudinit {
          storage = "storage" # Proxmox node lvm storage
        }
      }
    }
  }

  # Network configuration
  network {
    model  = "virtio"
    bridge = "vmbr1" # Replace with the actual bridge name
  }
  provisioner "file" {
    source      = "~/.ssh/id_rsa"
    destination = "/home/${var.ssh_user}/.ssh/id_rsa"

    connection {
      type        = "ssh"
      user        = var.ssh_user
      host        = self.ssh_forward_ip
      private_key = file("~/.ssh/id_rsa") # Use your local Terraform host key to connect to the VM
      port        = 22
    }
  }

  provisioner "file" {
    source      = "~/.ssh/id_rsa.pub"
    destination = "/home/${var.ssh_user}/.ssh/id_rsa.pub"

    connection {
      type        = "ssh"
      user        = var.ssh_user
      host        = self.ssh_forward_ip
      private_key = file("~/.ssh/id_rsa") # Use your local Terraform host key to connect to the VM
      port        = 22
    }
  }

  provisioner "file" {
    source      = "./node-token"
    destination = "/home/${var.ssh_user}/node-token"

    connection {
      type        = "ssh"
      user        = var.ssh_user
      host        = self.ssh_forward_ip
      private_key = file("~/.ssh/id_rsa") # Use your local Terraform host key to connect to the VM
      port        = 22
    }
  }

  provisioner "remote-exec" {
    inline = [
      "sudo ufw disable", # Necessary since kubernetes will manage ip tables
      "sudo swapoff -a",  # Disable swap. K8s requirement.
      "chmod 600 /home/${var.ssh_user}/.ssh/id_rsa",
      "export K3S_TOKEN=$(cat /home/${var.ssh_user}/node-token)",
      "export K3S_URL=https://${proxmox_vm_qemu.kubernetes-master.ssh_forward_ip}:6443",
      "curl -sfL https://get.k3s.io | K3S_URL=$K3S_URL K3S_TOKEN=$K3S_TOKEN sh -", # Install k3s and join the cluster
    ]
    connection {
      type        = "ssh"
      user        = var.ssh_user
      host        = self.ssh_forward_ip
      private_key = file("~/.ssh/id_rsa") # This key should be previously added to the templates
      port        = 22
    }
  }

  depends_on = [null_resource.get_node_token]
}

resource "proxmox_vm_qemu" "kubernetes-workers-01" {
  for_each = {
    "04" = "10.0.0.23"
  }
  name        = "server-k8s-w${each.key}"
  tags        = "k8s,project"
  target_node = "server01"
  clone       = "cloud-init-ubuntu-20.04-template"

  # Boot
  boot   = "order=virtio0;ide2"
  scsihw = "virtio-scsi-pci"
  bios   = "ovmf"
  vmid   = local.starting_vmid + 1 + tonumber(each.key)
  # Resources
  cores         = 4
  memory        = 49152
  balloon       = 8192
  agent         = 1 #qemu
  agent_timeout = 240

  #### Cloud init configs
  os_type   = "cloud-init"
  ciupgrade = "true"
  # SSH configs
  ssh_forward_ip = each.value
  # Your Terraform host public key(s)
  sshkeys = <<EOF
  ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj+NdBrCFBMv33OHEwLghK9dxFjMjgprT2M9ATMOL6bTX/lVNly8oFnRS3Hf8vj7UadXMKiBOkGbw4Q3wOBzlZUOS7XuLb3tEg4nPwl5/HWiRZXJrLUQMr+lITlmddK9/26363dNY+mD23dQ6jS2XUmzsUQX6KQH7+MsQCoz9NR0owUvppCxzTMefGT0RcBXyNKaTCTTh1KVOrOD0tx0cMVHSc2GTMdtUC8N4lOGLKC054PmqvvFz86M9paMQvNuORMDR90PSe+0aH42go+OtK/GuLZx+BgWSs2ZuBMQy1OAc12ozLEg3k/pgvV5wHgjgcUP29HAddHVhLyklw2ZCss+jCyBUAcqnfPz5edwlsmwoNB1t0sV205UIRZRrdjT+AjWBsc8nTpVrOPb8sCeKAH3E8tbbWI0zNJ6SAYG7Q6iAl6dTe+fux/5LT3R99Isv9bxlVtPsZ5WwqlfoeoyvgEWktUyGiGFVmdHBWvUZpF27I/l9o3JGpKFqyOzpfUp0= user@host
  EOF
  # Ip configs
  ipconfig0  = "ip=${each.value}/24,gw=10.0.0.254" # Fixed IP
  nameserver = "8.8.8.8,8.8.4.4"
  # User configs
  ciuser     = var.ssh_user
  cipassword = var.cipassword

  disks {
    # OS disk, will be logically auto resized by cloud-init (**happiness intensifies**)
    virtio {
      virtio0 {
        disk {
          size    = "2000G"
          storage = "local-zfs" # Proxmox node lvm storage
        }
      }
    }
    #Cloud init driver
    ide {
      ide2 {
        cloudinit {
          storage = "local-zfs" # Proxmox node lvm storage
        }
      }
    }
  }

  # Network configuration
  network {
    model  = "virtio"
    bridge = "vmbr1" # Replace with the actual bridge name
    tag    = 80      # Necessary in this case to connect to other VMs from proxmox-cpc
  }
  provisioner "file" {
    source      = "~/.ssh/id_rsa"
    destination = "/home/${var.ssh_user}/.ssh/id_rsa"

    connection {
      type        = "ssh"
      user        = var.ssh_user
      host        = self.ssh_forward_ip
      private_key = file("~/.ssh/id_rsa") # Use your local Terraform host key to connect to the VM
      port        = 22
    }
  }

  provisioner "file" {
    source      = "~/.ssh/id_rsa.pub"
    destination = "/home/${var.ssh_user}/.ssh/id_rsa.pub"

    connection {
      type        = "ssh"
      user        = var.ssh_user
      host        = self.ssh_forward_ip
      private_key = file("~/.ssh/id_rsa") # Use your local Terraform host key to connect to the VM
      port        = 22
    }
  }

  provisioner "file" {
    source      = "./node-token"
    destination = "/home/${var.ssh_user}/node-token"

    connection {
      type        = "ssh"
      user        = var.ssh_user
      host        = self.ssh_forward_ip
      private_key = file("~/.ssh/id_rsa") # Use your local Terraform host key to connect to the VM
      port        = 22
    }
  }

  provisioner "remote-exec" {
    inline = [
      "sudo apt update && sudo apt install -y nfs-common", # For longhorn ReadWriteMany
      "sudo ufw disable",                                  # Necessary since kubernetes will manage ip tables
      "sudo swapoff -a",                                   # Disable swap. K8s requirement.
      "chmod 600 /home/${var.ssh_user}/.ssh/id_rsa",
      "export K3S_TOKEN=$(cat /home/${var.ssh_user}/node-token)",
      "export K3S_URL=https://${proxmox_vm_qemu.kubernetes-master.ssh_forward_ip}:6443",
      "curl -sfL https://get.k3s.io | K3S_URL=$K3S_URL K3S_TOKEN=$K3S_TOKEN sh -", # Install k3s and join the cluster
    ]
    connection {
      type        = "ssh"
      user        = var.ssh_user
      host        = self.ssh_forward_ip
      private_key = file("~/.ssh/id_rsa") # This key should be previously added to the templates
      port        = 22
    }
  }

  depends_on = [null_resource.get_node_token]
}

resource "null_resource" "remote_exec_k8s_join" {
  for_each = {
    "01" = "10.0.0.20",
    "04" = "10.0.0.23"
  }
  provisioner "remote-exec" {

    inline = [
      "sudo apt update && sudo apt install -y nfs-common", # For longhorn ReadWriteMany
      "sudo ufw disable",
      "sudo swapoff -a", # Disable swap. K8s requirement.
      "chmod 600 /home/${var.ssh_user}/.ssh/id_rsa",
      "export K3S_TOKEN=$(cat /home/${var.ssh_user}/node-token)",
      "export K3S_URL=https://${proxmox_vm_qemu.kubernetes-master.ssh_forward_ip}:6443",
      "curl -sfL https://get.k3s.io | K3S_URL=$K3S_URL K3S_TOKEN=$K3S_TOKEN sh -",
    ]
    connection {
      type        = "ssh"
      user        = var.ssh_user
      host        = each.value
      private_key = file("~/.ssh/id_rsa")
      port        = 22
    }
  }

}
