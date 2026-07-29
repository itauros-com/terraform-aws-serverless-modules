variable "region" {
  description = "AWS region."
  type        = string
  default     = "eu-west-1"
}

variable "project" {
  description = "The project's name, first component of the prefix."
  type        = string
  default     = "sls-app"
}

variable "environment" {
  description = "The environment's name, second component of the prefix."
  type        = string
  default     = "dev"
}

variable "oncall_email" {
  description = "Address to deliver the alarms to. Null creates no subscription."
  type        = string
  default     = null
}
