provider "aws" {
  region = "us-east-2"

}

variable "server_port" {
  description = "Puerto para la lista de seguridad y el purto por el cual va a estar escuchando el servidor web."
  type        = number
  default     = 8080
}

// Para encontrar el ID de la VPC que esta por default.
data "aws_vpc" "default" {
  default = true
}

// Una ves que encontramos el ID de la VPC podemos buscar los id de las subnet de dicha VPC.
data "aws_subnet_ids" "default" {
  vpc_id = data.aws_vpc.default.id
}


/*
Creación de una instancia en AWS.
User Data es usado para enviar un conjunto de comandos que serán ejecutados en el primer boot de la maquina. 
User Data Detalles: https://bloggingnectar.com/aws/automate-your-ec2-instance-setup-with-ec2-user-data-scripts/
*/
resource "aws_instance" "example" {
  ami                    = "ami-0c55b159cbfafe1f0"
  vpc_security_group_ids = [aws_security_group.instance.id]
  instance_type          = "t2.micro"

  // El <<-EOF y EOF son Terraform heredoc syntax, permiten ingresar bloques de codigo sin necesidad de usar caracteres para romper e ir a la nueva linea.
  user_data = <<-EOF
              #!/bin/bash
              echo "Hello, World" > index.html
              nohup busybox httpd -f -p ${var.server_port} &
              EOF

  tags = {
    Name = "terraform-example"
  }
}

// Este recurso le dice a la VM Example que va a ser accedida por el puerto 8080 desde cualquier maquina en el mundo.
// El nuevo recurso es una lista de seguridad que va a ser creada.
resource "aws_security_group" "instance" {
  name = "terraform-example-instance"
  ingress {
    from_port   = var.server_port
    to_port     = var.server_port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "example instance security group"
  }
}


resource "aws_launch_configuration" "example" {
  image_id        = "ami-0c55b159cbfafe1f0"
  instance_type   = "t2.micro"
  security_groups = [aws_security_group.instance.id]

  user_data = <<-EOF
              #!/bin/bash
              echo "Hello, World" > index.html
              nohup busybox httpd -f -p ${var.server_port} &
              EOF

  # Required when using a launch configuration with an auto scaling group.
  # https://www.terraform.io/docs/providers/aws/r/launch_configuration.html
  // Como no es posible eliminarlo primero dado que es usado en aws_autoscaling_group.example se debe invertir el comportamiento normal de Terraform, ahora lo crear, actualiza los recursos que dependen de este y luego elimina el recurso viejo.
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "example" {
  launch_configuration = aws_launch_configuration.example.name
  #   vpc_zone_identifier  = data.aws_subnet_ids.default.ids
  // Se usa de esta forma dado que la salida de las subnets son 6, las 3 adicionales son de andres cuando esta trabajando con functions de AWS. 
  vpc_zone_identifier = ["subnet-21d30b48",
    "subnet-6b050921",
  "subnet-804da3fb", ]
  target_group_arns = [aws_lb_target_group.asg.arn]
  health_check_type = "ELB"

  min_size = 2
  max_size = 10

  tag {
    key                 = "Name"
    value               = "terraform-asg-example"
    propagate_at_launch = true
  }
}

resource "aws_lb" "example" {
  name               = "terraform-asg-name"
  load_balancer_type = "application"
  // Se usa de esta forma dado que la salida de las subnets son 6, las 3 adicionales son de andres cuando esta trabajando con functions de AWS. 
  subnets = ["subnet-21d30b48",
    "subnet-6b050921",
  "subnet-804da3fb", ]
  # subnets            = data.aws_subnet_ids.default.ids
  security_groups = [aws_security_group.alb.id]
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.example.arn
  port              = 80
  protocol          = "HTTP"
  # By default, return a simple 404 page
  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "404: page not found"
      status_code  = 404
    }
  }
}

resource "aws_security_group" "alb" {
  name = "terraform-example-alb"

  # Allow inbound HTTP requests
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow all outbound requests
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

// Este es el recurso que me hizo doler la cabeza en cloud formation, aqui es mas sencillo de compprender y crear.
resource "aws_lb_target_group" "asg" {
  name     = "terraform-asg-example"
  port     = var.server_port
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id

  health_check {
    path                = "/"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 15
    timeout             = 3
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener_rule" "asg" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 100

  /*   
    Warning: "condition.0.values": [DEPRECATED] use 'host_header' or 'path_pattern'
   condition {
    field  = "path-pattern"
    values = ["*"]
  } */

  condition {
    path_pattern {
      values = ["*"]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.asg.arn
  }
}

output "alb_dns_name" {
  value       = aws_lb.example.dns_name
  description = "The domain name of the load balancer"
}

output "public_ip" {
  value       = aws_instance.example.public_ip
  description = "The public IP address of the web server"
}

output "subnets" {
  value       = data.aws_subnet_ids.default.ids
  description = "subnets"
}
