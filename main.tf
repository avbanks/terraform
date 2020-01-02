terraform {
  required_version = ">= 0.12.0"
}

provider "aws" {
  version = ">= 2.28.1"
  region                  = var.region
  shared_credentials_file = "C:/Users/abanks/.aws/credentials"
  profile                 = "default"
}

provider "random" {
  version = "~> 2.1"
}

provider "local" {
  version = "~> 1.2"
}

provider "null" {
  version = "~> 2.1"
}

provider "template" {
  version = "~> 2.1"
}

data "aws_eks_cluster" "cluster" {
  name = module.eks.cluster_id
}

data "aws_eks_cluster_auth" "cluster" {
  name = module.eks.cluster_id
}

data "aws_vpc" "main_vpc" {
  tags = {
    Name = "alm VPC"
  }
}

data "aws_subnet" "private_subnet_1" {
  vpc_id = "${data.aws_vpc.main_vpc.id}"
  tags = {
    Name = "alm Private subnet 1A"
  }
}

data "aws_subnet" "private_subnet_2" {
  vpc_id = "${data.aws_vpc.main_vpc.id}"
  tags = {
    Name = "alm Private subnet 2A"
  }
}


data "aws_subnet" "public_subnet" {
  vpc_id = "${data.aws_vpc.main_vpc.id}"
  tags = {
    Name = "alm Public subnet 1"
  }
}



provider "kubernetes" {
  host                   = data.aws_eks_cluster.cluster.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority.0.data)
  token                  = data.aws_eks_cluster_auth.cluster.token
  load_config_file       = false
  version                = "~> 1.10"
}

data "aws_availability_zones" "available" {
}

locals {
  cluster_name = "andre-eks-${random_string.suffix.result}"
}

resource "random_string" "suffix" {
  length  = 8
  special = false
}

resource "aws_security_group" "worker_group_mgmt_one" {
  name_prefix = "worker_group_mgmt_one"
  vpc_id      = data.aws_vpc.main_vpc.id


  ingress {
    from_port = 22
    to_port   = 22
    protocol  = "tcp"

    cidr_blocks = [
      "10.0.0.0/8",
    ]
  }
}

resource "aws_security_group" "worker_group_mgmt_two" {
  name_prefix = "worker_group_mgmt_two"
  vpc_id      =  data.aws_vpc.main_vpc.id


  ingress {
    from_port = 22
    to_port   = 22
    protocol  = "tcp"

    cidr_blocks = [
      "192.168.0.0/16",
    ]
  }
}

resource "aws_security_group" "all_worker_mgmt" {
  name_prefix = "all_worker_management"
  vpc_id      = data.aws_vpc.main_vpc.id

  ingress {
    from_port = 22
    to_port   = 22
    protocol  = "tcp"

    cidr_blocks = [
      "10.0.0.0/8",
      "172.16.0.0/12",
      "192.168.0.0/16",
    ]
  }
}
resource "aws_iam_role" "node_group_role" {
  name = "eks-node-group-${local.cluster_name}"

  assume_role_policy = jsonencode({
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
    Version = "2012-10-17"
  })
}



module "eks" {
  source       = "terraform-aws-modules/eks/aws"
  cluster_name = local.cluster_name
  subnets      = [data.aws_subnet.private_subnet_1.id, data.aws_subnet.private_subnet_2.id]
  vpc_id       = data.aws_vpc.main_vpc.id

  tags = {
    Environment = "test"
    GithubRepo  = "terraform-aws-eks"
    GithubOrg   = "terraform-aws-modules"
  }


  worker_groups = [
    {
      name                          = "worker-group-1"
      instance_type                 = "t2.small"
      asg_desired_capacity          = 2
      additional_security_group_ids = [aws_security_group.worker_group_mgmt_one.id]
    },
    {
      name                          = "worker-group-2"
      instance_type                 = "t2.medium"
      additional_security_group_ids = [aws_security_group.worker_group_mgmt_two.id]
      asg_desired_capacity          = 1
    },
  ]

  worker_additional_security_group_ids = [aws_security_group.all_worker_mgmt.id]
  map_roles                            = var.map_roles
  map_users                            = var.map_users
}

resource "aws_eks_node_group" "andres_nodes" {
  cluster_name       = local.cluster_name
  node_group_name    = "andres_nodes_${local.cluster_name}"
  node_role_arn      = aws_iam_role.node_group_role.arn
  subnet_ids         = [data.aws_subnet.private_subnet_1.id, data.aws_subnet.private_subnet_2.id]

  scaling_config {
    desired_size = 2
    max_size     = 3
    min_size     = 2
  }

  depends_on = [
    aws_iam_role_policy_attachment.abanks-AmazonEKSWorkerNodePolicy,
    aws_iam_role_policy_attachment.abanks-AmazonEKS_CNI_Policy,
    aws_iam_role_policy_attachment.abanks-AmazonEC2ContainerRegistryReadOnly
  ]
}

resource "aws_iam_role_policy_attachment" "abanks-AmazonEKSWorkerNodePolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.node_group_role.name
}

resource "aws_iam_role_policy_attachment" "abanks-AmazonEKS_CNI_Policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.node_group_role.name
}

resource "aws_iam_role_policy_attachment" "abanks-AmazonEC2ContainerRegistryReadOnly" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.node_group_role.name
}

resource "null_resource" "tiller-setup" {
  depends_on = [
    data.aws_eks_cluster.cluster,
    aws_eks_node_group.andres_nodes
  ]

  provisioner "local-exec" {
    working_dir = "${path.root}"
    command = "kubectl --kubeconfig kubeconfig_${local.cluster_name} apply -f ./kube/tiller.yml && helm init --kubeconfig kubeconfig_${local.cluster_name} --service-account tiller --tiller-namespace tiller"
  }
}

