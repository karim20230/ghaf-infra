# SPDX-FileCopyrightText: 2022-2024 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

locals {
  # Both var.allocate_public_ip and var.access_over_public_ip
  # will enable assigning public IP to the VM
  set_public_ip = var.allocate_public_ip || var.access_over_public_ip
}

resource "azurerm_virtual_machine" "main" {
  name                = var.virtual_machine_name
  resource_group_name = var.resource_group_name
  location            = var.location
  vm_size             = var.virtual_machine_size

  delete_os_disk_on_termination    = true
  delete_data_disks_on_termination = false

  network_interface_ids = [azurerm_network_interface.default.id]

  storage_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-arm64"
    version   = "latest"
  }

  identity {
    type = "SystemAssigned"
  }

  os_profile {
    computer_name = var.virtual_machine_name
    # Unused, but required by the API. May not be root either
    admin_username = "foo"
    admin_password = "S00persecret"

    # We only set custom_data here, not user_data.
    # user_data is more recent, and allows updates without recreating the machine,
    # but at least cloud-init 23.1.2 blocks boot if custom_data is not set.
    # (It logs about not being able to mount /dev/sr0 to /metadata).
    # This can be worked around by setting custom_data to a static placeholder,
    # but user_data is still ignored.
    # TODO: check this again with a more recent cloud-init version.
    custom_data = (var.virtual_machine_custom_data == "") ? null : base64encode(var.virtual_machine_custom_data)
  }

  os_profile_linux_config {
    # We *don't* support password auth, and this doesn't change anything.
    # However, if we don't set this to false we need to
    # specify additional pubkeys.
    disable_password_authentication = false
    # We can't use admin_ssh_key, as it only works for the admin_username.
  }

  boot_diagnostics {
    enabled = true
    # azurerm_virtual_machine doesn't support the managed storage account
    storage_uri = azurerm_storage_account.boot_diag.primary_blob_endpoint
  }

  storage_os_disk {
    name              = "${var.virtual_machine_name}-osdisk" # needs to be unique
    caching           = "ReadWrite"
    create_option     = "FromImage"
    managed_disk_type = "Standard_LRS"
    disk_size_gb      = var.virtual_machine_osdisk_size
  }

  dynamic "storage_data_disk" {
    for_each = var.data_disks

    content {
      # use lookup here, so keys can be set optionally
      name          = lookup(storage_data_disk.value, "name", null)
      caching       = lookup(storage_data_disk.value, "caching", null)
      create_option = "Attach"
      # This has to be passed, even for "Attach"
      disk_size_gb = lookup(storage_data_disk.value, "disk_size_gb", null)
      lun          = lookup(storage_data_disk.value, "lun", null)

      managed_disk_type = lookup(storage_data_disk.value, "managed_disk_type", null)
      managed_disk_id   = lookup(storage_data_disk.value, "managed_disk_id", null)
    }
  }
}

resource "azurerm_network_interface" "default" {
  name                = "${var.virtual_machine_name}-nic"
  resource_group_name = var.resource_group_name
  location            = var.location

  ip_configuration {
    name                          = "internal"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = (local.set_public_ip) ? azurerm_public_ip.default[0].id : null
  }
}

resource "azurerm_public_ip" "default" {
  count = (local.set_public_ip) ? 1 : 0

  name                = "${var.virtual_machine_name}-pub-ip"
  domain_name_label   = var.virtual_machine_name
  resource_group_name = var.resource_group_name
  location            = var.location
  allocation_method   = "Static"
}

# Create a random string, and a storage account using that random string.
resource "random_string" "boot_diag" {
  length  = "8"
  special = "false"
  upper   = false
}

resource "azurerm_storage_account" "boot_diag" {
  name                     = "${random_string.boot_diag.result}bootdiag"
  resource_group_name      = var.resource_group_name
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = "GRS"
}

resource "azurerm_virtual_machine_extension" "deploy_ubuntu_builder" {
  name                 = "${var.virtual_machine_name}-vmext"
  virtual_machine_id   = azurerm_virtual_machine.main.id
  publisher            = "Microsoft.Azure.Extensions"
  type                 = "CustomScript"
  type_handler_version = "2.1"
  settings             = <<EOF
    {
        "script": "${base64encode(templatefile("./modules/arm-builder-vm/ubuntu-builder.sh.tpl", { bincache_url = "${var.binary_cache_url}", bincache_pubkey = "${var.binary_cache_public_key}" }))}"
    }
    EOF
}

output "virtual_machine_id" {
  value = azurerm_virtual_machine.main.id
}

output "virtual_machine_identity_principal_id" {
  value = azurerm_virtual_machine.main.identity[0].principal_id
}

output "virtual_machine_network_interface_id" {
  value = azurerm_network_interface.default.id
}

output "virtual_machine_ip_address" {
  description = "IP address other VMs in the infra will use to access the VM."
  value       = var.access_over_public_ip ? azurerm_public_ip.default[0].ip_address : azurerm_network_interface.default.private_ip_address
}
