# OLIMPO IaC with Terraform

This repo is intended to be our Infrastructure-as-Code (IaC). Following sections will describe how to use it.

## Kubernetes Architecture

![k8s-architecture](./images/kubernetes-architecture.png)

## Terraform Setup and Execution Guide

This guide provides step-by-step instructions for installing Terraform, installing the required providers for this project, and executing the Terraform configuration with a `secret.tfvars` file.

## 1. Install Terraform

To install Terraform, follow these steps:

### On Ubuntu/Debian:

1. **Update the package list:**

    ```bash
    sudo apt-get update && sudo apt-get install -y gnupg software-properties-common curl
    ```

2. **Add HashiCorp’s official GPG key:**

    ```bash
    curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo gpg --batch --yes --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
    ```

3. **Add the HashiCorp Linux repository:**

    ```bash
        echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
    ```

4. **Update the package list again and install Terraform:**

    ```bash
    sudo apt-get update && sudo apt-get install terraform
    ```

5. **Verify the installation:**

    ```bash
    terraform -v
    ```

## Initialize the projet

This will download and install the required providers specified in your Terraform configuration.

```bash
terraform init
```

## Create the secret.tfvars File

The secret.tfvars file should contain sensitive information such as access keys, passwords, or tokens. Here’s an example of how to structure the secret.tfvars file:

```tfvars
proxmox_api_token_id     = "user@local"
proxmox_api_token_secret = "an-incredible-token"
ssh_user                 = "you"
ssh_port                 = 2245
cipassword               = "an-incredibly-secure-password"
new_cluster_name         = "new-cluster-name"
```

The ssh_user should be on VM templates sudoers.

Save this file as secret.tfvars in your project directory.

### Proxmox API Token

To generate API tokens and secrets for proxmox you should follow this steps via [CLI](https://pve.proxmox.com/wiki/Proxmox_VE_API#Ticket_Cookie) or via [UI](https://www.youtube.com/watch?v=wK8PUp7rjzs).

Your proxmox user should have full access for creating and configuring VMs on the datacenter as well as your API Token.

NOTE: Unchecking "Privilege Separation" was necessary for my case.

## Execute Terraform with the secret.tfvars File

Now that Terraform is installed, the providers are initialized, and the secret.tfvars file is created, you can execute your Terraform configuration.

1. **Run a Terraform plan to see the changes that will be made:**

    ```bash
    terraform plan -var-file="secret.tfvars"
    ```

2. **Apply the Terraform configuration:**

    ```bash
    terraform apply -var-file="secret.tfvars"
    ```

This will apply the changes defined in your Terraform configuration using the variables from secret.tfvars.

## Notes

* Always store the secret.tfvars file securely and add it to your .gitignore to prevent sensitive information from being committed to version control.

* When finished, you can use terraform destroy -var-file="secret.tfvars" to remove the infrastructure created by Terraform.

## Cloud-init template configuration

You should download a cloud-init ready image such as form https://cloud-images.ubuntu.com.

For this example focal-server-cloudimg-amd64.img was used (Ubuntu 20.04 LTS).

Access proxmox server via SSH and download the image.

```bash
# download the image
wget https://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-amd64.img

# Convert it to qcow2
qemu-img convert -f qcow2 -O qcow2 focal-server-cloudimg-amd64.img focal-server-cloudimg-amd64.qcow2

# create a new VM with VirtIO SCSI controller
qm create 9000 --memory 2048 --net0 virtio,bridge=vmbr0 --scsihw virtio-scsi-pci

# import the downloaded disk to the local-lvm storage, attaching it as a virtio drive
# Must use the full file path
qm set 9000 --virtio0 local-zfs:0,import-from=/root/focal-server-cloudimg-amd64.qcow2
```

**OBS: Ubuntu Cloud-Init images require the virtio-scsi-pci controller type for SCSI drives.**

The next step is to configure a CD-ROM drive, which will be used to pass the Cloud-Init data to the VM.

```bash
qm set 9000 --ide2 local-zfs:cloudinit
```

To be able to boot directly from the Cloud-Init image, set the boot parameter to order=virtio0 to restrict BIOS to boot from this disk only. This will speed up booting, because VM BIOS skips the testing for a bootable CD-ROM.

```bash
qm set 9000 --boot order=virtio0
```

Finally set BIOS to UEFI

```bash
qm set 9000 --bios ovmf
```

Then you can run the vm to test the boot. If it boots, then you can set an user and an ip-address using cloud-init. Redefine the image and then stop it, run it again.

You will want to install qemu-guest-agent using:

```bash
sudo apt-get install qemu-guest-agent
```

Now you can enable the VM qemu agent via proxmox. If you stop the VM and run it again, qemu agent will start and show IP address.

Now you will be able to shutdown the VM and execute other proxmox commands.

Finally you can exit the VM, reset the user and IP address, redefine the cloud image and then you can transform it on a template.

```bash
qm template 9000
```

### Undo template

If you want to modify the template you will need to undo it manually.

One way is to enter the proxmox server and find your template ID configuration file like /etc/pve/qemu-server/<\template-id>.conf

Then you can edit it with nano and delete the whole line with the key value pair "template: 1"

Save the file and you will soon see the template turn back into a VM.

Then you can start it and do the necessary modifications.