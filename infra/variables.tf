variable "region" {
  description = "AWS region."
  type        = string
  default     = "ap-south-1"
}

variable "name" {
  description = "Name prefix for all resources."
  type        = string
  default     = "spr"
}

variable "kubernetes_version" {
  description = "EKS version. Must be in STANDARD_SUPPORT (extended support costs 6x). Check: aws eks describe-cluster-versions"
  type        = string
  default     = "1.36" # standard support until 2027-08-02; matches kubectl 1.36 client
}

variable "azs" {
  description = "Exactly two AZs, pinned explicitly so the subnet layout never changes when AWS adds a zone."
  type        = list(string)
  default     = ["ap-south-1a", "ap-south-1b"]

  validation {
    condition     = length(var.azs) == 2
    error_message = "This demo uses exactly two AZs (one public subnet each)."
  }
}

variable "vpc_cidr" {
  description = "VPC CIDR."
  type        = string
  default     = "10.30.0.0/16"
}

variable "my_ip_cidr" {
  description = "Your public IP as /32; the only source allowed to reach the public EKS API endpoint. up.sh fills this in."
  type        = string

  validation {
    condition     = can(cidrhost(var.my_ip_cidr, 0)) && endswith(var.my_ip_cidr, "/32") && var.my_ip_cidr != "0.0.0.0/32"
    error_message = "my_ip_cidr must be a single IPv4 address in /32 form (never 0.0.0.0/0)."
  }
}
