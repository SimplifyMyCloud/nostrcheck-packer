packer {
  required_plugins {
    googlecompute = {
      source  = "github.com/hashicorp/googlecompute"
      version = "~> 1.1"
    }
  }
}

# Variables for GCP configuration
variable "gcp_project_id" {
  type = string
}

variable "gcp_zone" {
  type    = string
  default = "us-central1-a"
}

# Source block for GCP
source "googlecompute" "ubuntu" {
  project_id          = var.gcp_project_id
  source_image_family = "ubuntu-2204-lts"
  zone               = var.gcp_zone
  image_name         = "nostrcheck-server-${formatdate("YYYYMMDDhhmmss", timestamp())}"
  ssh_username       = "ubuntu"
  machine_type       = "n1-standard-2"
  
  # Add additional disk for media storage
  disk_size         = 100
  disk_type         = "pd-ssd"
}

# Build configuration
build {
  name = "nostrcheck-server-gcp"
  sources = ["source.googlecompute.ubuntu"]

  # Update and install required packages
  provisioner "shell" {
    inline = [
      "sudo apt-get update",
      "sudo apt-get upgrade -y",
      "sudo apt-get install -y nginx git redis-server mariadb-server mariadb-client ffmpeg jq certbot python3-certbot-nginx python3 python3-pip python3-dev python3-venv pkg-config libjpeg-dev zlib1g-dev libssl-dev google-cloud-sdk"
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

  # Mount additional volume for media storage (GCP specific)
  provisioner "shell" {
    inline = [
      "sudo mkfs.ext4 /dev/sdb",
      "sudo mkdir -p /mnt/nostrcheck-media",
      "sudo mount /dev/sdb /mnt/nostrcheck-media",
      "echo '/dev/sdb /mnt/nostrcheck-media ext4 defaults 0 2' | sudo tee -a /etc/fstab",
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