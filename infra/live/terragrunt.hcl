# Remote state. Swap the bucket and table for your own before running.
remote_state {
  backend = "s3"
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
  config = {
    bucket         = get_env("TF_STATE_BUCKET", "change-me-tfstate")
    key            = "argo-rollouts-lab/${path_relative_to_include()}/terraform.tfstate"
    region         = get_env("AWS_REGION", "eu-west-1")
    encrypt        = true
    dynamodb_table = get_env("TF_LOCK_TABLE", "change-me-tfstate-locks")
  }
}

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOP
provider "aws" {
  region = "${get_env("AWS_REGION", "eu-west-1")}"
  default_tags {
    tags = {
      Project   = "cfg-lab"
      ManagedBy = "terragrunt"
      Article   = "argo-rollouts-canary-progressive-delivery"
    }
  }
}
EOP
}
