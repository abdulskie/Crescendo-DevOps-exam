#!/bin/bash
sudo dnf update -y
sudo dnf install -y nginx java-21-amazon-corretto unzip
sudo systemctl start nginx
sudo systemctl enable nginx
curl -O https://dlcdn.apache.org/tomcat/tomcat-9/v9.0.102/bin/apache-tomcat-9.0.102.tar.gz
tar -xvzf apache-tomcat-9.0.102.tar.gz
apache-tomcat-9.0.102/bin/startup.sh