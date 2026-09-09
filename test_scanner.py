#!/usr/bin/env python3
import os
import sys
import json
import tempfile
import shutil
from pathlib import Path
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'src'))
from scanner import SystemScanner

class TestSystemScanner(unittest.TestCase):
    def setUp(self):
        self.test_dir = tempfile.mkdtemp()
        self.etc_dir = os.path.join(self.test_dir, "etc")
        os.makedirs(self.etc_dir)
        
        # Nginx
        self.nginx_dir = os.path.join(self.etc_dir, "nginx")
        os.makedirs(self.nginx_dir)
        
        with open(os.path.join(self.nginx_dir, "nginx.conf"), 'w') as f:
            f.write("user www-data;\nworker_processes auto;\n")
        
        sites_dir = os.path.join(self.nginx_dir, "sites-available")
        os.makedirs(sites_dir, exist_ok=True)
        with open(os.path.join(sites_dir, "default"), 'w') as f:
            f.write("server { listen 80; }")
        
        # SSH
        self.ssh_dir = os.path.join(self.etc_dir, "ssh")
        os.makedirs(self.ssh_dir)
        with open(os.path.join(self.ssh_dir, "sshd_config"), 'w') as f:
            f.write("Port 22\nPermitRootLogin no")
    
    def tearDown(self):
        shutil.rmtree(self.test_dir)
    
    def test_scanner_creates_snapshot(self):
        scanner = SystemScanner()
        snapshot = scanner.scan()
        self.assertIsInstance(snapshot, dict)
        self.assertIn("timestamp", snapshot)
        self.assertIn("hostname", snapshot)
        self.assertIn("services", snapshot)
    
    def test_nginx_detected(self):
        scanner = SystemScanner()
        snapshot = scanner.scan()
        self.assertIn("nginx", snapshot["services"])
        self.assertTrue(snapshot["services"]["nginx"]["installed"])
        configs = snapshot["services"]["nginx"]["configs"]
        self.assertIn("/etc/nginx/nginx.conf", configs)
        self.assertIn("worker_processes", configs["/etc/nginx/nginx.conf"])
    
    def test_ssh_detected(self):
        scanner = SystemScanner()
        snapshot = scanner.scan()
        self.assertIn("ssh", snapshot["services"])
        self.assertTrue(snapshot["services"]["ssh"]["installed"])
    
    def test_docker_maybe_not_installed(self):
        scanner = SystemScanner()
        snapshot = scanner.scan()
        self.assertIn("docker", snapshot["services"])
        self.assertIn("installed", snapshot["services"]["docker"])
    
    def test_cron_detected(self):
        scanner = SystemScanner()
        snapshot = scanner.scan()
        self.assertIn("cron", snapshot["services"])
        self.assertIn("installed", snapshot["services"]["cron"])
    
    def test_snapshot_has_all_services(self):
        scanner = SystemScanner()
        snapshot = scanner.scan()
        expected = ["nginx", "ssh", "docker", "cron"]
        for service in expected:
            with self.subTest(service=service):
                self.assertIn(service, snapshot["services"])
    
    def test_config_content_preserved(self):
        scanner = SystemScanner()
        snapshot = scanner.scan()
        nginx_config = snapshot["services"]["nginx"]["configs"].get("/etc/nginx/nginx.conf", "")
        self.assertIn("user www-data", nginx_config)
        self.assertIn("worker_processes auto", nginx_config)

class TestScannerWithMock(unittest.TestCase):
    def setUp(self):
        self.test_dir = tempfile.mkdtemp()
        self.etc_dir = os.path.join(self.test_dir, "etc")
        os.makedirs(self.etc_dir)
        
        # Nginx
        nginx_dir = os.path.join(self.etc_dir, "nginx")
        os.makedirs(nginx_dir)
        with open(os.path.join(nginx_dir, "nginx.conf"), 'w') as f:
            f.write("user www-data;\nworker_processes 4;\n")
        
        sites_dir = os.path.join(nginx_dir, "sites-available")
        os.makedirs(sites_dir, exist_ok=True)
        with open(os.path.join(sites_dir, "default"), 'w') as f:
            f.write("server { listen 8080; }")
        
        # SSH
        ssh_dir = os.path.join(self.etc_dir, "ssh")
        os.makedirs(ssh_dir)
        with open(os.path.join(ssh_dir, "sshd_config"), 'w') as f:
            f.write("Port 2222\nPermitRootLogin yes")
    
    def tearDown(self):
        shutil.rmtree(self.test_dir)
    
    def test_custom_nginx_config(self):
        pass

if __name__ == "__main__":
    print("🧪 Запуск тестов для SystemScanner...\n")
    unittest.main(verbosity=2)
