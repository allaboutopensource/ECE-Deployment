variable "instance_name" {
  description = "Value of the Name tag for the ELK instance"
  type        = list(string)
  default     = ["ELK01", "ELK02", "ELK03", "ELK04", "ELK05", "ELK06"]
}
