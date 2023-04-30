provider "aws" {
  region     = var.region
}

# este es un cambio en la rama inventarioDinamico
# este es un segundo cambio en la rama inventarioDinamico
# otro cambio más

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "4.23.0"
    }
  }
  backend "s3" {
    bucket = "tf-aws-ansible-test"
    key    = "tf/terraform.tfstate"
    region = "eu-west-1"
  }
}

resource "aws_vpc" "main" { # Se exportan los atributos del recurso, pudiendose utilizar después
  cidr_block = var.vpc_cidr
  tags = {
    Name = "tf-vpc"
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_subnet" "public_subnet1" {
  vpc_id     = "${aws_vpc.main.id}"
  availability_zone = "${data.aws_availability_zones.available.names[0]}"
  cidr_block = var.public_subnet1_cidr
  map_public_ip_on_launch = true # auto-assing public ip
  tags = {
    Name = var.public_subnet1_name
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = "${aws_vpc.main.id}" # Id exportado en la creación de la vpc
  tags = {
    Name = var.igw_name
  }
}

resource "aws_route_table" "route_table_public_subnet1" {
  vpc_id = "${aws_vpc.main.id}"
  route {
    cidr_block = var.public_cidr_block
    gateway_id = "${aws_internet_gateway.igw.id}"
  }
  tags = {
    Name = var.route_table_public_subnet1_name
  }
}

resource "aws_route_table_association" "route_table_association_public_subnet1" {
  subnet_id      = "${aws_subnet.public_subnet1.id}"
  route_table_id = "${aws_route_table.route_table_public_subnet1.id}"
}

# Create a security group for the instance
resource "aws_security_group" "instance" {
  name_prefix = "tf-test-example-instance-"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.public_cidr_block]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.public_cidr_block]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.public_cidr_block]
  }
  tags = {
    Name = "tf-test-example-instance-security-group"
  }
}


resource "aws_key_pair" "my_key_pair" {
  key_name   = "my-key-pair"
  public_key = file("~/.ssh/id_rsa.pub")
}

resource "null_resource" "update_local_known_hosts" {
  provisioner "local-exec" {
    command = "sleep 15 && ssh-keyscan ${aws_instance.ec2_instance.public_ip} >> ~/.ssh/known_hosts"
    interpreter = ["/bin/bash", "-c"]
  }
  depends_on = [aws_instance.ec2_instance]
}

resource "null_resource" "ansible_provisioner" {
  depends_on = [aws_instance.ec2_instance,null_resource.update_local_known_hosts]

  connection {
    type        = "ssh"
    user        = "ubuntu"
    private_key = file("~/.ssh/id_rsa")
    host        = aws_instance.ec2_instance.public_ip
  }

  provisioner "local-exec" {
    command = "ansible-playbook -i ./ansible/inventories/inventory.ini ./ansible/playbooks/apache.yml"
    working_dir = "${path.module}"

    environment = {
      ANSIBLE_HOST_KEY_CHECKING = "False"
    }
  }
}

resource "local_file" "ansible_inventory" {
  content = templatefile("${path.module}/ansible/inventories/inventory.ini.tpl", {
    instance_ip = aws_instance.ec2_instance.public_ip
  })

  filename = "${path.module}/ansible/inventories/inventory.ini"
}

resource "aws_instance" "ec2_instance" {
  ami           = var.ami
  instance_type = var.instance_type
  key_name      = aws_key_pair.my_key_pair.key_name
  subnet_id     = aws_subnet.public_subnet1.id
  vpc_security_group_ids = [aws_security_group.instance.id]
  tenancy = "default"
  tags = {
    Name = "tf-test-example-instance"
  }
}