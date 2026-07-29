variable "region" {
  description = "AWS region."
  type        = string
  default     = "eu-west-1"
}

variable "name_prefix" {
  description = "The project's naming prefix."
  type        = string
  default     = "sls-example"
}

variable "environment" {
  description = "The environment's name."
  type        = string
  default     = "dev"
}

variable "alarm_topic_arn" {
  description = "SNS topic to send the alarms to. Null leaves the alarms with no action."
  type        = string
  default     = null
}
