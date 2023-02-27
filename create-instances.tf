# Define required providers
terraform {
required_version = ">= 0.14.0"
  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 1.48.0"
    }
  }
}

# Configure the OpenStack Provider
provider "openstack" {
  user_name   = "devops"
  tenant_name = "devops-project"
  password    = "test@123"
  auth_url    = "https://cloudendpoint_vip:5000"
  region      = "region-one"
  domain_name = "domain-test"
}

resource "openstack_compute_instance_v2" "terraform_vm" {
  for_each        =  toset(var.instance_name)
  name            =  each.key
  image_id        = "image uuid for the centos image"
  flavor_id       = "large"
  key_pair        = "devops-key"
  network {
    name = "network1"
  }
  security_groups = ["default"]

  block_device {
    uuid                  = "uuid of the block volume"
    source_type           = "image"
    destination_type      = "local"
    boot_index            = 0
    delete_on_termination = true
  }

  block_device {
    source_type           = "blank"
    destination_type      = "volume"
    volume_size           = 100
    boot_index            = 1
    delete_on_termination = true
  }
}
resource "openstack_networking_floatingip_v2" "fip_1" {
  pool = "Floating Network"
  for_each   =  toset(var.instance_name)
}

resource "openstack_compute_floatingip_associate_v2" "fip_1" {
  for_each   =  toset(var.instance_name)
  floating_ip = "${openstack_networking_floatingip_v2.fip_1[each.key].address}"
  instance_id = "${openstack_compute_instance_v2.terraform_vm[each.key].id}"
}
