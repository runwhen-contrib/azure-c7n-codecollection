resource "azurerm_resource_group" "rg" {
  name     = "cloudcustodian"
  location = "East US"
}

resource "azurerm_virtual_network" "vnet" {
  name                = "spot-vnet"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"]
}

resource "azurerm_subnet" "subnet" {
  name                 = "spot-subnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_public_ip" "public_ip" {
  name                = "spot-vm-public-ip"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_network_interface" "nic" {
  name                = "spot-vm-nic"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.subnet.id
    public_ip_address_id          = azurerm_public_ip.public_ip.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "tls_private_key" "ssh_key" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "azurerm_linux_virtual_machine" "vm" {
  name                  = "spot-vm"
  resource_group_name   = azurerm_resource_group.rg.name
  location              = azurerm_resource_group.rg.location
  size                  = "Standard_DS1_v2"
  admin_username        = "azureuser"
  network_interface_ids = [azurerm_network_interface.nic.id]

  priority        = "Spot"
  eviction_policy = "Deallocate" # Change to "Delete" if you want auto-removal on eviction

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 30
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "UbuntuServer"
    sku       = "18.04-LTS"
    version   = "latest"
  }

  admin_ssh_key {
    username   = "azureuser"
    public_key = tls_private_key.ssh_key.public_key_openssh
  }

  # provisioner "remote-exec" {
  #   inline = [
  #     "sudo apt-get update",
  #     "sudo apt-get install -y stress-ng",
  #     "sudo stress-ng -c 1 l 80 -t 60m &" # Uses 50% of 1 CPU for 30 minutes
  #   ]

  #   connection {
  #     type        = "ssh"
  #     user        = "azureuser"
  #     private_key = tls_private_key.ssh_key.private_key_pem
  #     host        = azurerm_public_ip.public_ip.ip_address
  #   }
  # }
}

resource "azurerm_network_interface" "unused-nic" {
  name                = "unused-nic"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "example-ip-config"
    subnet_id                     = azurerm_subnet.subnet.id
    private_ip_address_allocation = "Dynamic"
  }
  tags = var.tags
}

resource "azurerm_public_ip" "example_unused" {
  name                = "unused-public-ip"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static" # You can also use "Dynamic" if preferred
  sku                 = "Standard" # "Basic" or "Standard"
  tags                = var.tags
}

# Save the private key locally (optional)
resource "local_file" "private_key" {
  content  = tls_private_key.ssh_key.private_key_pem
  filename = "spot-vm-key.pem"
}