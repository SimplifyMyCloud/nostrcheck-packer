packer {
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = "~> 1.2"
    }
  }
}

# Variables for AWS configuration
variable "aws_region" {
  type    = string
  default = "us-west-2"
}

variable "instance_type" {
  type    = string
  default = "t3.medium"
}

# Source block for AWS
source "amazon-ebs" "ubuntu" {
  ami_name      = "nostrcheck-server-${formatdate("YYYYMMDDhhmmss", timestamp())}"
  instance_type = var.instance_type
  region        = var.aws_region
  
  source_ami_filter {
    filters = {
      name                = "ubuntu/images/*ubuntu-jammy-22.04-amd64-server-*"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    most_recent = true
    owners      = ["099720109477"] # Canonical
  }
  
  ssh_username = "ubuntu"

  # Add additional volume for media storage
  launch_block_device_mappings {
    device_name = "/dev/sdf"
    volume_size = 100
    volume_type = "gp3"
    delete_on_termination = true
  }
}

# Build configuration
build {
  name = "nostrcheck-server-aws"
  sources = ["source.amazon-ebs.ubuntu"]

  # Update and install required packages
  provisioner "shell" {
    inline = [
      "sudo apt-get update",
      "sudo apt-get upgrade -y",
      "sudo apt-get install -y nginx git redis-server mariadb-server mariadb-client ffmpeg jq certbot python3-certbot-nginx python3 python3-pip python3-dev python3-venv pkg-config libjpeg-dev zlib1g-dev libssl-dev awscli"
    ]
  }

  # Install Node.js
  provisioner "shell" {
    inline = [
      "curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -",
      "sudo apt-get install -y nodejs",
      "sudo npm install -g npm@latest"
    ]
  }

  # Install Rust
  provisioner "shell" {
    inline = [
      "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y",
      "source $HOME/.cargo/env",
      "echo 'source $HOME/.cargo/env' >> ~/.bashrc"
    ]
  }

  # Mount additional volume for media storage (AWS specific)
  provisioner "shell" {
    inline = [
      "sudo mkfs.ext4 /dev/nvme1n1 || sudo mkfs.ext4 /dev/sdf || true",
      "sudo mkdir -p /mnt/nostrcheck-media",
      "sudo mount /dev/nvme1n1 /mnt/nostrcheck-media || sudo mount /dev/sdf /mnt/nostrcheck-media || true",
      "echo '/dev/nvme1n1 /mnt/nostrcheck-media ext4 defaults 0 2' | sudo tee -a /etc/fstab",
      "sudo chown -R ubuntu:ubuntu /mnt/nostrcheck-media"
    ]
  }

  # Clone and set up nostrcheck-server
  provisioner "shell" {
    inline = [
      "git clone -b main https://github.com/quentintaranpino/nostrcheck-server.git",
      "cd nostrcheck-server",
      "python3 -m venv .venv",
      "source .venv/bin/activate",
      "pip install transformers==4.44.2 Flask==3.0.3 Pillow==10.4.0 torch torchvision torchaudio",
      "npm install --include=optional sharp",
      "npm run build"
    ]
  }

  # Configure services
  provisioner "shell" {
    inline = [
      "sudo systemctl enable redis-server",
      "sudo systemctl enable mariadb",
      "sudo systemctl start redis-server",
      "sudo systemctl start mariadb"
    ]
  }

  # Create systemd service
  provisioner "shell" {
    inline = [
      "sudo tee /etc/systemd/system/nostrcheck.service << EOF",
      "[Unit]",
      "Description=Nostrcheck server",
      "After=network.target mariadb.service redis-server.service",
      "",
      "[Service]",
      "Type=simple",
      "User=ubuntu",
      "WorkingDirectory=/home/ubuntu/nostrcheck-server",
      "Environment=NODE_ENV=production",
      "ExecStart=/usr/bin/npm run start",
      "Restart=always",
      "RestartSec=10",
      "",
      "[Install]",
      "WantedBy=multi-user.target",
      "EOF",
      "sudo systemctl enable nostrcheck"
    ]
  }

  # Configure Nginx
  provisioner "shell" {
    inline = [
      "sudo rm /etc/nginx/sites-enabled/default",
      "sudo systemctl restart nginx"
    ]
  }

  # Create backup script
  provisioner "shell" {
    inline = [
      "sudo tee /usr/local/bin/nostrcheck-backup << EOF",
      "#!/bin/bash",
      "BACKUP_DIR=/mnt/nostrcheck-media/backups/$(date +%Y%m%d)",
      "mkdir -p $BACKUP_DIR",
      "mysqldump -u root nostrcheck > $BACKUP_DIR/database.sql",
      "tar -czf $BACKUP_DIR/files.tar.gz /mnt/nostrcheck-media/files",
      "tar -czf $BACKUP_DIR/config.tar.gz /home/ubuntu/nostrcheck-server/config",
      "EOF",
      "sudo chmod +x /usr/local/bin/nostrcheck-backup",
      "echo '0 2 * * * /usr/local/bin/nostrcheck-backup' | sudo crontab -"
    ]
  }
}