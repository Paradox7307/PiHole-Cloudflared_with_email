#!/bin/bash

# Function to prompt the user for input and validate email
prompt_email() {
    while true; do
        read -p "$1" email
        if [[ "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            echo "$email"
            break
        else
            echo "Invalid email address, please try again."
        fi
    done
}

# Install cloudflared
install_cloudflared() {
    echo "Downloading and installing cloudflared..."
    wget https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64 -O /usr/local/bin/cloudflared
    sudo chmod +x /usr/local/bin/cloudflared
    cloudflared -v

    # Enable cloudflared to run at startup
    echo "Creating cloudflared systemd service..."
    sudo useradd -r -M -s /usr/sbin/nologin cloudflared
    sudo touch /etc/default/cloudflared
    echo "CLOUDFLARED_OPTS=--port 5053 --upstream https://cloudflare-dns.com/dns-query" | sudo tee /etc/default/cloudflared

    sudo chown cloudflared:cloudflared /etc/default/cloudflared
    sudo chown cloudflared:cloudflared /usr/local/bin/cloudflared

    # Create systemd service
    sudo bash -c 'cat > /etc/systemd/system/cloudflared.service <<EOF
[Unit]
Description=cloudflared DNS over HTTPS proxy
After=syslog.target network-online.target

[Service]
Type=simple
User=cloudflared
EnvironmentFile=/etc/default/cloudflared
ExecStart=/usr/local/bin/cloudflared proxy-dns \$CLOUDFLARED_OPTS
Restart=on-failure
RestartSec=10
KillMode=process

[Install]
WantedBy=multi-user.target
EOF'

    sudo systemctl enable cloudflared
    sudo systemctl start cloudflared
    sudo systemctl status cloudflared
}

# Install msmtp
install_msmtp() {
    echo "Installing msmtp..."
    sudo apt update
    sudo apt install -y msmtp msmtp-mta

    echo "Creating .msmtprc file for Gmail configuration..."

    # Prompt for Gmail details
    source_email=$(prompt_email "Enter your Gmail email address: ")
    echo "Warning: You must have 2FA enabled and generate an App Password for msmtp to work."

    read -sp "Enter your Gmail App Password (do not use your regular Gmail password): " source_password
    echo
    target_email=$(prompt_email "Enter the target email address to send the test email: ")

    # Create msmtp config
    sudo bash -c "cat > /home/pihole/.msmtprc <<EOF
account gmail
auth on
tls on
tls_certcheck off
user $source_email
password $source_password
host smtp.gmail.com
port 587
from $source_email
logfile /var/log/msmtp.log

account default : gmail
EOF"

    sudo chown pihole:pihole /home/pihole/.msmtprc
    sudo chmod 600 /home/pihole/.msmtprc

    # Fix log file permissions
    sudo touch /var/log/msmtp.log
    sudo chown pihole:pihole /var/log/msmtp.log
    sudo chmod 644 /var/log/msmtp.log

    echo "msmtp configuration complete!"
}

# Send a test email
send_test_email() {
    echo "Sending test email to $target_email..."
    echo "Test email from msmtp" | msmtp -a gmail "$target_email"
    if [ $? -eq 0 ]; then
        echo "Test email sent successfully to $target_email!"
    else
        echo "Failed to send test email. Please check the logs."
    fi
}

# Main script
install_cloudflared
install_msmtp
send_test_email