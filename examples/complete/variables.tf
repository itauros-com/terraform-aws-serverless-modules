variable "region" {
  description = "AWS region."
  type        = string
  default     = "eu-west-1"
}

variable "name_prefix" {
  description = "The project's naming prefix."
  type        = string
  default     = "sls-complete"
}

variable "environment" {
  description = "The environment's name."
  type        = string
  default     = "dev"
}

variable "vpc_name" {
  description = "Name tag of the VPC to put the functions in. Null leaves the functions outside the VPC, and in that case they do not receive the ENI permissions."
  type        = string
  default     = null
}

variable "private_subnet_ids" {
  description = "Private subnets for the functions in the VPC. Used only if `vpc_name` is set."
  type        = list(string)
  default     = []
}
