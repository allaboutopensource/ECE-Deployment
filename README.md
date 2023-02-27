# Elastic-Cloud-Enterprise-Deployment

This repo is to create a medium installation of the Elastic cloud enterprise using the ansible playbooks for the centos 8.x machine.

A medium installation with separate management services. 

3 hosts with at least 32 GB RAM each for directors and coordinators (ECE management services), and proxies
3 hosts with 256 GB RAM each for allocators
3 availability zones


We have created these 6 virtual machines on the cloud platform using terraform plan. 

ECE version: 3.5.1
Centos Version: CentOS Linux release 8.4.2105

Ansible Version: core 2.11.5

Terraform Version : Terraform v1.3.9

openstack Version: Wallaby



commands:

ansible-playbook -i inventory.yml site.yml
