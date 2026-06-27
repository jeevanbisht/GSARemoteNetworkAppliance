packer {
  required_plugins {
    azure = {
      version = ">= 2.0.0"
      source  = "github.com/hashicorp/azure"
    }
  }
}

variable "subscription_id" {
  type = string
}

variable "tenant_id" {
  type    = string
  default = ""
}

variable "location" {
  type    = string
  default = "westus3"
}

variable "resource_group_name" {
  type    = string
  default = "RNFleet"
}

variable "managed_image_name" {
  type    = string
  default = "rnfleet-appliance-ubuntu-2404"
}

variable "temp_resource_group_name" {
  type    = string
  default = "rnfleet-packer-temp"
}

locals {
  repo_root = "${path.root}/../../../../.."
}

source "azure-arm" "ubuntu_appliance" {
  use_azure_cli_auth                = true
  subscription_id                   = var.subscription_id
  tenant_id                         = var.tenant_id != "" ? var.tenant_id : null
  location                          = var.location
  managed_image_name                = var.managed_image_name
  managed_image_resource_group_name = var.resource_group_name
  os_type                           = "Linux"
  vm_size                           = "Standard_D2s_v5"
  temp_resource_group_name          = var.temp_resource_group_name

  image_publisher = "Canonical"
  image_offer     = "ubuntu-24_04-lts"
  image_sku       = "server"
  image_version   = "latest"

  # SSH configuration for easier debugging and troubleshooting
  ssh_username = "packer"
  ssh_timeout  = "5m"
  communicator = "ssh"

  azure_tags = {
    project     = "RNFleetManager"
    environment = "dev"
    workload    = "appliance-image"
    ssh_enabled = "true"
  }
}

build {
  name    = "rnfleet-appliance-image"
  sources = ["source.azure-arm.ubuntu_appliance"]

  provisioner "shell" {
    inline = [
      "sudo mkdir -p /tmp/rnfleet-src/apps /tmp/rnfleet-src/packages /tmp/rnfleet-packaging /tmp/rnfleet-firstboot",
      "sudo chown -R $USER:$USER /tmp/rnfleet-src /tmp/rnfleet-packaging /tmp/rnfleet-firstboot",
      "# Generate SSH host keys for first-time SSH access",
      "sudo ssh-keygen -A || echo 'SSH keys already present'",
      "# Create azureuser for VM access (required by Azure portal)",
      "sudo useradd -m -s /bin/bash azureuser 2>/dev/null || echo 'User already exists'",
      "# Configure sudo access for azureuser",
      "echo 'azureuser ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/azureuser > /dev/null",
      "sudo chmod 0440 /etc/sudoers.d/azureuser"
    ]
  }

  # Install IPSec (strongSwan, swanctl/vici) + BGP (FRR) for the tunnel agent.
  # The device-runtime tunnel agent drives the modern `swanctl` command
  # (/etc/swanctl/swanctl.conf) — NOT the legacy ipsec.conf starter — because
  # only swanctl/vici reliably honors if_id (route-based XFRM isolation).
  provisioner "shell" {
    inline = [
      "export DEBIAN_FRONTEND=noninteractive",
      "sudo apt-get update",
      "# strongSwan: charon daemon + swanctl/vici CLI (charon-systemd unit) used by the tunnel agent",
      "sudo apt-get install -y strongswan-swanctl charon-systemd strongswan-pki libcharon-extra-plugins libstrongswan-extra-plugins",
      "# FRR: BGP routing daemon + vtysh management shell",
      "sudo apt-get install -y frr frr-pythontools",
      "# Enable the BGP daemon (disabled by default in FRR)",
      "sudo sed -i 's/^bgpd=no/bgpd=yes/' /etc/frr/daemons",
      "# Allow IP forwarding so the appliance can route tunnelled traffic",
      "echo 'net.ipv4.ip_forward=1' | sudo tee /etc/sysctl.d/99-rnfleet-forwarding.conf > /dev/null",
      "# Use the swanctl-based charon-systemd service; disable the legacy starter",
      "sudo systemctl disable --now strongswan-starter 2>/dev/null || true",
      "sudo systemctl enable strongswan",
      "sudo systemctl enable frr"
    ]
  }

  provisioner "file" {
    source      = "${local.repo_root}/package.json"
    destination = "/tmp/rnfleet-src/package.json"
  }

  provisioner "file" {
    source      = "${local.repo_root}/package-lock.json"
    destination = "/tmp/rnfleet-src/package-lock.json"
  }

  provisioner "file" {
    source      = "${local.repo_root}/apps/device-runtime"
    destination = "/tmp/rnfleet-src/apps/"
  }

  provisioner "file" {
    source      = "${local.repo_root}/packages/contracts"
    destination = "/tmp/rnfleet-src/packages/"
  }

  provisioner "file" {
    source      = "${local.repo_root}/apps/device-runtime/packaging/install-device-runtime.sh"
    destination = "/tmp/rnfleet-packaging/install-device-runtime.sh"
  }

  provisioner "file" {
    source      = "${local.repo_root}/apps/device-runtime/packaging/device-runtime.env.example"
    destination = "/tmp/rnfleet-packaging/device-runtime.env.example"
  }

  provisioner "file" {
    source      = "${local.repo_root}/apps/device-runtime/packaging/systemd/rnfleet-device-runtime.service"
    destination = "/tmp/rnfleet-packaging/rnfleet-device-runtime.service"
  }

  provisioner "shell" {
    inline = [
      "sed -i 's/\\r$//' /tmp/rnfleet-packaging/install-device-runtime.sh",
      "chmod +x /tmp/rnfleet-packaging/install-device-runtime.sh",
      "sudo /tmp/rnfleet-packaging/install-device-runtime.sh"
    ]
  }

  # ---- First-boot enrollment (customer appliance experience) ----
  # Ship the interactive enrollment wizard + its systemd unit + a login status
  # banner + an unattended pre-seed example.
  provisioner "file" {
    source      = "${local.repo_root}/apps/device-runtime/packaging/firstboot/rnfleet-setup.sh"
    destination = "/tmp/rnfleet-firstboot/rnfleet-setup.sh"
  }
  provisioner "file" {
    source      = "${local.repo_root}/apps/device-runtime/packaging/systemd/rnfleet-firstboot.service"
    destination = "/tmp/rnfleet-firstboot/rnfleet-firstboot.service"
  }
  provisioner "file" {
    source      = "${local.repo_root}/apps/device-runtime/packaging/firstboot/30-rnfleet"
    destination = "/tmp/rnfleet-firstboot/30-rnfleet"
  }
  provisioner "file" {
    source      = "${local.repo_root}/apps/device-runtime/packaging/firstboot/enrollment.conf.example"
    destination = "/tmp/rnfleet-firstboot/enrollment.conf.example"
  }
  provisioner "file" {
    source      = "${local.repo_root}/apps/device-runtime/packaging/firstboot/rnfleet-logo.txt"
    destination = "/tmp/rnfleet-firstboot/rnfleet-logo.txt"
  }

  provisioner "shell" {
    inline = [
      "set -e",
      "for f in rnfleet-setup.sh 30-rnfleet rnfleet-firstboot.service enrollment.conf.example; do sed -i 's/\\r$//' /tmp/rnfleet-firstboot/$f; done",
      "# Install the enrollment wizard as a system command.",
      "sudo install -m 0755 /tmp/rnfleet-firstboot/rnfleet-setup.sh /usr/local/sbin/rnfleet-setup",
      "# Login status banner.",
      "sudo install -m 0755 /tmp/rnfleet-firstboot/30-rnfleet /etc/update-motd.d/30-rnfleet",
      "# Unattended pre-seed example (operators copy to /etc/rnfleet/enrollment.conf).",
      "sudo mkdir -p /etc/rnfleet",
      "sudo install -m 0644 /tmp/rnfleet-firstboot/enrollment.conf.example /etc/rnfleet/enrollment.conf.example",
      "# Appliance ASCII logo (shown in MOTD + first-boot wizard).",
      "sudo install -m 0644 /tmp/rnfleet-firstboot/rnfleet-logo.txt /etc/rnfleet/logo.txt",
      "# First-boot enrollment service.",
      "sudo install -m 0644 /tmp/rnfleet-firstboot/rnfleet-firstboot.service /etc/systemd/system/rnfleet-firstboot.service",
      "sudo systemctl daemon-reload",
      "# Appliance gating: the runtime must NOT auto-start as the default identity.",
      "# It stays disabled until rnfleet-setup enrolls the device, then enables it.",
      "sudo systemctl disable rnfleet-device-runtime.service || true",
      "sudo rm -f /etc/rnfleet/device-runtime.env",
      "sudo rm -f /var/lib/rnfleet/.configured",
      "# Run the enrollment wizard on first boot until the appliance is enrolled.",
      "sudo systemctl enable rnfleet-firstboot.service"
    ]
  }

  # Generalize so every VM cloned from this image gets a fresh machine-id (which
  # drives the auto-generated unique Device ID) and re-runs first-boot enrollment.
  provisioner "shell" {
    inline = [
      "sudo cloud-init clean --logs || true",
      "sudo truncate -s 0 /etc/machine-id || true",
      "sudo rm -f /var/lib/dbus/machine-id || true",
      "echo 'Provisioning complete. Deprovisioning agent for image capture...'",
      "sudo waagent -deprovision+user -force || true"
    ]
  }

  post-processor "manifest" {
    output = "manifest.json"
  }
}
