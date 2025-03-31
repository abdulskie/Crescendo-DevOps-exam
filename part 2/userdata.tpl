#!/bin/bash
NGINX_CONF="/etc/nginx/nginx.conf"
sudo dnf update -y
sudo dnf install -y nginx java-21-amazon-corretto unzip
sudo systemctl start nginx
sudo systemctl enable nginx
curl -O https://nexus.magnolia-cms.com/repository/public/info/magnolia/bundle/magnolia-community-demo-webapp/6.2.56/magnolia-community-demo-webapp-6.2.56-tomcat-bundle.zip?_gl=1*1cqq69b*_gcl_au*MTYwNDE5NTA5My4xNzQzMTM3NjEw*_ga*MTI2MjUzNjE2Mi4xNzQzMTM3NjEw*_ga_61HQH88LT4*MTc0MzI2NDYxOS4zLjEuMTc0MzI2NDc1Ni41Mi4wLjA.
unzip magnolia-community-demo-webapp-6.2.56-tomcat-bundle.zip
magnolia-6.2.56/apache-tomcat-9.0.102/bin/magnolia_control.sh start
rm -f /apache-tomcat-9.0.102.tar.gz /magnolia-community-demo-webapp-6.2.56-tomcat-bundle.zip
sudo tee /etc/nginx/nginx.conf > /dev/null <<EOF
# For more information on configuration, see:
#   * Official English Documentation: http://nginx.org/en/docs/
#   * Official Russian Documentation: http://nginx.org/ru/docs/

user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log notice;
pid /run/nginx.pid;

# Load dynamic modules. See /usr/share/doc/nginx/README.dynamic.
include /usr/share/nginx/modules/*.conf;

events {
    worker_connections 1024;
}

http {
    log_format  main  '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                      '\$status \$body_bytes_sent "\$http_referer" '
                      '"\$http_user_agent" "\$http_x_forwarded_for"';

    access_log  /var/log/nginx/access.log  main;

    sendfile            on;
    tcp_nopush          on;
    keepalive_timeout   65;
    types_hash_max_size 4096;

    include             /etc/nginx/mime.types;
    default_type        application/octet-stream;

    # Load modular configuration files from the /etc/nginx/conf.d directory.
    # See http://nginx.org/en/docs/ngx_core_module.html#include
    # for more information.
    include /etc/nginx/conf.d/*.conf;

    server {
        listen       80;
        listen       [::]:80;
        server_name  _;
        return 301 https://\$host\$request_uri;
        # Load configuration files for the default server block.
        include /etc/nginx/default.d/*.conf;

        error_page 404 /404.html;
        location = /404.html {
        }

        error_page 500 502 503 504 /50x.html;
        location = /50x.html {
        }
    }

    # Settings for a TLS enabled server.
    #
    server {
         listen       443 ssl;
         listen       [::]:443 ssl;
         http2        on;
         server_name  _;
         root         /usr/share/nginx/html;
#
         ssl_certificate "/home/ec2-user/test_ca_cert.pem";
         ssl_certificate_key "/home/ec2-user/test_ca_private_key.pem";
         ssl_session_cache shared:SSL:1m;
         ssl_session_timeout  10m;
         ssl_ciphers PROFILE=SYSTEM;
         ssl_prefer_server_ciphers on;
#
#        # Load configuration files for the default server block.
#        include /etc/nginx/default.d/*.conf;
         location / {
           proxy_pass http://127.0.0.1:8080;
         }
#        error_page 404 /404.html;
#        location = /404.html {
#        }
#
#        error_page 500 502 503 504 /50x.html;
#        location = /50x.html {
#        }
     }
}
EOF
sudo systemctl reload nginx