# Terraform deployment for Medusa backend and admin on AWS ECS Fargate

provider "aws" {
  region = "ap-south-1"
}

######################
# VPC & Networking   #
######################
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
  enable_dns_support = true
  enable_dns_hostnames = true
}

data "aws_availability_zones" "available" {}

resource "aws_subnet" "public" {
  count = 2
  vpc_id = aws_vpc.main.id
  cidr_block = cidrsubnet(aws_vpc.main.cidr_block, 4, count.index)
  availability_zone = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

resource "aws_route_table_association" "public" {
  count = 2
  subnet_id = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

######################
# Security Groups    #
######################
resource "aws_security_group" "ecs" {
  name   = "ecs-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

######################
# RDS PostgreSQL     #
######################
resource "aws_db_subnet_group" "medusa" {
  name       = "medusa-db-subnet-group"
  subnet_ids = aws_subnet.public[*].id
}

resource "aws_db_instance" "postgres" {
  identifier              = "medusa-postgres"
  engine                  = "postgres"
  instance_class          = "db.t3.micro"
  allocated_storage       = 20
  username                = "medusa"
  password                = "medusapassword"
  publicly_accessible     = true
  skip_final_snapshot     = true
  db_subnet_group_name    = aws_db_subnet_group.medusa.name
  vpc_security_group_ids  = [aws_security_group.ecs.id]
}

######################
# Redis (ElastiCache) #
######################
resource "aws_elasticache_subnet_group" "medusa" {
  name       = "medusa-redis-subnet-group"
  subnet_ids = aws_subnet.public[*].id
}

resource "aws_elasticache_cluster" "redis" {
  cluster_id           = "medusa-redis"
  engine               = "redis"
  node_type            = "cache.t3.micro"
  num_cache_nodes      = 1
  subnet_group_name    = aws_elasticache_subnet_group.medusa.name
  security_group_ids   = [aws_security_group.ecs.id]
}

######################
# S3 for file uploads#
######################
resource "aws_s3_bucket" "medusa_files" {
  bucket = "medusa-files-${random_id.suffix.hex}"
  force_destroy = true
}

resource "random_id" "suffix" {
  byte_length = 4
}

######################
# IAM Roles & Policies
######################
resource "aws_iam_role" "ecs_task_execution" {
  name = "ecsTaskExecutionRole"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_execution_policy" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

######################
# ECS Cluster        #
######################
resource "aws_ecs_cluster" "medusa" {
  name = "medusa-cluster"
}

############################
# Load Balancer for Access
############################
resource "aws_lb" "medusa" {
  name               = "medusa-lb"
  internal           = false
  load_balancer_type = "application"
  subnets            = aws_subnet.public[*].id
  security_groups    = [aws_security_group.ecs.id]
}

resource "aws_lb_target_group" "medusa_backend" {
  name     = "medusa-backend-tg"
  port     = 9000
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id
  target_type = "ip"
  health_check {
    path                = "/store/products"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
    matcher             = "200"
  }
}

resource "aws_lb_target_group" "medusa_admin" {
  name     = "medusa-admin-tg"
  port     = 7001
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id
  target_type = "ip"
  health_check {
    path                = "/"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
    matcher             = "200"
  }
}

resource "aws_lb_listener" "medusa_backend" {
  load_balancer_arn = aws_lb.medusa.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.medusa_backend.arn
  }
}

resource "aws_lb_listener" "medusa_admin" {
  load_balancer_arn = aws_lb.medusa.arn
  port              = 7001
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.medusa_admin.arn
  }
}

############################
# ECS Task Definitions     
############################
resource "aws_ecs_task_definition" "medusa_backend" {
  family                   = "medusa-backend"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  container_definitions    = jsonencode([
    {
      name      = "medusa-backend"
      image     = "medusajs/medusa"
      portMappings = [{ containerPort = 9000 }]
      environment = [
        { name = "DATABASE_URL", value = "postgres://medusa:medusapassword@${aws_db_instance.postgres.address}:5432/medusadb" },
        { name = "REDIS_URL", value = "redis://${aws_elasticache_cluster.redis.cache_nodes[0].address}:6379" },
        { name = "NODE_ENV", value = "production" },
        { name = "PORT", value = "9000" }
      ]
    }
  ])
}

resource "aws_ecs_task_definition" "medusa_admin" {
  family                   = "medusa-admin"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  container_definitions    = jsonencode([
    {
      name      = "medusa-admin"
      image     = "medusajs/admin"
      portMappings = [{ containerPort = 7001 }]
      environment = [
        { name = "PORT", value = "7001" }
      ]
    }
  ])
}

############################
# ECS Services             
############################
resource "aws_ecs_service" "backend" {
  name            = "medusa-backend"
  cluster         = aws_ecs_cluster.medusa.id
  task_definition = aws_ecs_task_definition.medusa_backend.arn
  launch_type     = "FARGATE"
  desired_count   = 1
  network_configuration {
    subnets          = aws_subnet.public[*].id
    assign_public_ip = true
    security_groups  = [aws_security_group.ecs.id]
  }
  load_balancer {
    target_group_arn = aws_lb_target_group.medusa_backend.arn
    container_name   = "medusa-backend"
    container_port   = 9000
  }
  depends_on = [aws_lb_listener.medusa_backend]
}

resource "aws_ecs_service" "admin" {
  name            = "medusa-admin"
  cluster         = aws_ecs_cluster.medusa.id
  task_definition = aws_ecs_task_definition.medusa_admin.arn
  launch_type     = "FARGATE"
  desired_count   = 1
  network_configuration {
    subnets          = aws_subnet.public[*].id
    assign_public_ip = true
    security_groups  = [aws_security_group.ecs.id]
  }
  load_balancer {
    target_group_arn = aws_lb_target_group.medusa_admin.arn
    container_name   = "medusa-admin"
    container_port   = 7001
  }
  depends_on = [aws_lb_listener.medusa_admin]
}
