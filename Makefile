PROJECT_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
TERRAFORM_DIR := $(PROJECT_ROOT)/terraform

-include .env
export

TF_APPLY_VARS := \
  -var exoscale_api_key=$(EXOSCALE_API_KEY) \
  -var exoscale_secret_key=$(EXOSCALE_SECRET_KEY) \
  -var project_name=community-haqnow \
  -var ssh_key_name=community-haqnow-key \
  -var s3_access_key=$(EXOSCALE_S3_ACCESS_KEY) \
  -var s3_secret_key=$(EXOSCALE_S3_SECRET_KEY) \
  -var s3_endpoint=$(EXOSCALE_S3_ENDPOINT) \
  -var s3_region=$(EXOSCALE_S3_REGION) \
  -var s3_bucket_name=community-haqnow-docs \
  -var admin_email=$(admin_email) \
  -var admin_password=$(admin_password) \
  -var jwt_secret_key=$(or $(JWT_SECRET_KEY),$(shell openssl rand -hex 32)) \
  -var sendgrid_api_key=$(or $(SENDGRID_API_KEY),) \
  -var mysql_password=$(or $(MYSQL_PASSWORD),$(shell openssl rand -hex 16)) \
  -var mysql_root_password=$(or $(MYSQL_ROOT_PASSWORD),$(shell openssl rand -hex 16)) \
  -var postgres_password=$(or $(POSTGRES_PASSWORD),$(shell openssl rand -hex 16)) \
  -var seafile_domain=$(or $(SEAFILE_DOMAIN),community.haqnow.com) \
  -var onlyoffice_jwt_secret=$(or $(ONLYOFFICE_JWT_SECRET),$(shell openssl rand -hex 32))

.PHONY: init apply output ip destroy

init:
	cd $(TERRAFORM_DIR) && terraform init

apply:
	cd $(TERRAFORM_DIR) && terraform apply -auto-approve $(TF_APPLY_VARS)

output:
	cd $(TERRAFORM_DIR) && terraform output

ip:
	cd $(TERRAFORM_DIR) && terraform output -raw instance_ip

destroy:
	cd $(TERRAFORM_DIR) && terraform destroy -auto-approve $(TF_APPLY_VARS)
