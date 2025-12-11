#!/usr/bin/env python3
# Security tests: credential protection, gitignore, file permissions

import os
import re
from pathlib import Path
import subprocess
import pytest


class TestSecurityCompliance:
    # Verify security best practices
    
    @pytest.fixture(autouse=True)
    def setup(self):
        # Set repo paths
        self.repo_root = Path(__file__).parent.parent
        self.gitignore_path = self.repo_root / ".gitignore"
    
    def test_gitignore_exists(self):
        """Verify gitignore file exists."""
        assert self.gitignore_path.exists(), ".gitignore must exist"
        assert self.gitignore_path.is_file(), ".gitignore must be a file"
    
    def test_gitignore_excludes_credentials(self):
        """Verify gitignore excludes AWS credential files."""
        gitignore_content = self.gitignore_path.read_text()
        
        critical_patterns = [
            "credentials",  # AWS credentials file
            ".aws/",        # AWS config directory
            "*.pem",        # SSH private keys
            "*.ppk",        # PuTTY private keys
            ".env",         # Environment variables
        ]
        
        for pattern in critical_patterns:
            assert pattern in gitignore_content, \
                f".gitignore must exclude {pattern}"
    
    def test_gitignore_excludes_python_cache(self):
        """Verify gitignore excludes Python cache files."""
        gitignore_content = self.gitignore_path.read_text()
        
        python_patterns = [
            "__pycache__",
            "*.pyc",
            ".pytest_cache",
        ]
        
        for pattern in python_patterns:
            assert pattern in gitignore_content, \
                f".gitignore must exclude {pattern}"
    
    def test_no_credentials_in_tracked_files(self):
        """Verify no AWS credentials in git tracked files."""
        # Check git tracked files for potential credentials
        result = subprocess.run(
            ["git", "ls-files"],
            cwd=self.repo_root,
            capture_output=True,
            text=True
        )
        
        if result.returncode != 0:
            pytest.skip("Not a git repository or git not available")
        
        tracked_files = result.stdout.strip().split('\n')
        
        # Patterns that might indicate credentials
        credential_patterns = [
            r"AKIA[0-9A-Z]{16}",  # AWS Access Key ID
            r"aws_access_key_id\s*=\s*AKIA",
            r"aws_secret_access_key\s*=\s*[A-Za-z0-9/+=]{40}",
        ]
        
        violations = []
        for file_path in tracked_files:
            full_path = self.repo_root / file_path
            
            # Skip binary files and directories
            if not full_path.is_file():
                continue
            
            try:
                content = full_path.read_text(encoding='utf-8', errors='ignore')
                
                for pattern in credential_patterns:
                    matches = re.findall(pattern, content)
                    if len(matches) > 0:
                        violations.append(f"{file_path}: pattern {pattern}")
            except Exception as e:
                # Skip files that can't be read as text
                continue
        
        assert len(violations) == 0, \
            f"No credentials should be in tracked files: {violations}"
    def test_script_permissions(self):
        """Test 5: Verify script has executable permissions."""
        script_path = self.repo_root / "download_policy.sh"
        
        assert script_path.exists(), "download_policy.sh should exist"
        assert os.access(script_path, os.X_OK), \
            "download_policy.sh should be executable"
        
        stat_info = script_path.stat()
        mode = stat_info.st_mode
        
        world_writable = bool(mode & 0o002)
        if world_writable:
            oct_mode = oct(mode)[-3:]
            pytest.fail(
                f"Script should not be world-writable (current: {oct_mode}). "
                f"Run: chmod 755 download_policy.sh"
            )
    
    def test_no_hardcoded_secrets_in_script(self):
        """Verify script doesn't contain hardcoded secrets."""
        script_path = self.repo_root / "download_policy.sh"
        script_content = script_path.read_text()
        
        secret_patterns = [
            (r"AKIA[0-9A-Z]{16}", "AWS Access Key ID"),
            (r"aws_access_key_id\s*=\s*['\"]?AKIA", "Hardcoded Access Key"),
            (r"aws_secret_access_key\s*=\s*['\"]?[A-Za-z0-9/+=]{40}", "Hardcoded Secret Key"),
            (r"password\s*=\s*['\"][^'\"]+['\"]", "Hardcoded password"),
        ]
        
        for pattern, description in secret_patterns:
            matches = re.findall(pattern, script_content, re.IGNORECASE)
            assert len(matches) == 0, \
                f"Potential {description} found in script"
    
    def test_readme_security_section_exists(self):
        """Verify README contains security section."""
        readme_path = self.repo_root / "README.md"
        
        assert readme_path.exists(), "README.md should exist"
        
        readme_content = readme_path.read_text()
        
        assert "Security" in readme_content or "security" in readme_content, \
            "README should have security section"
        assert "credential" in readme_content.lower(), \
            "README should discuss credentials"
        assert "gitignore" in readme_content.lower(), \
            "README should mention .gitignore"
    
    def test_policies_directory_structure(self):
        """Test 8: Verify policies directory exists and is properly set up."""
        policies_dir = self.repo_root / "policies"
        
        # Directory should exist (created by script or already present)
        # But if it doesn't exist yet, that's ok (created on first run)
        if policies_dir.exists():
            assert policies_dir.is_dir(), "policies should be a directory"
            
            # Check that policies directory is not excluded by gitignore
            # (we want to track example policies)
            gitignore_content = self.gitignore_path.read_text()
            
            # Should NOT have "policies/" uncommented at the root level
            # (The commented line is ok)
            lines = gitignore_content.split('\n')
            for line in lines:
                if line.strip() and not line.strip().startswith('#'):
                    assert line.strip() != "policies/", \
                        "policies/ directory should not be fully excluded"


class TestScriptOutputSecurity:
    """Test that script output doesn't leak sensitive information."""
    
    def test_script_does_not_log_secret_keys(self):
        """Test 9: Verify script doesn't log AWS Secret Access Keys."""
        script_path = Path(__file__).parent.parent / "download_policy.sh"
        script_content = script_path.read_text()
        
        # Check that script doesn't echo or log variables that might contain secrets
        dangerous_patterns = [
            r'echo.*AWS_SECRET',
            r'printf.*AWS_SECRET',
            r'log.*SECRET',
        ]
        
        for pattern in dangerous_patterns:
            matches = re.findall(pattern, script_content, re.IGNORECASE)
            assert len(matches) == 0, \
                f"Script should not log secrets: found pattern {pattern}"
    
    def test_script_uses_safe_logging(self):
        """Test 10: Verify script uses safe logging practices."""
        script_path = Path(__file__).parent.parent / "download_policy.sh"
        script_content = script_path.read_text()
        
        # Script should log to stderr (>&2) for informational messages
        # This is a best practice to keep stdout clean for piping
        assert ">&2" in script_content or "stderr" in script_content.lower(), \
            "Script should use stderr for logging"
    def test_requirements_file_safe(self):
        """Test 11: Verify requirements.txt contains only package names."""
        requirements_path = Path(__file__).parent.parent / "requirements.txt"
        
        if not requirements_path.exists():
            pytest.skip("requirements.txt not found")
        
        requirements_content = requirements_path.read_text()
        lines = [l.strip() for l in requirements_content.split('\n') if l.strip()]
        
        # Should not contain URLs with credentials
        violations = []
        for line in lines:
            if "://" in line and "@" in line:
                violations.append(line)
        
        assert len(violations) == 0, \
            f"requirements.txt should not contain credentials in URLs: {violations}"
    
    def test_gitignore_protects_json_files(self):
        """Test 12: Verify .gitignore protects JSON policy files."""
        gitignore_path = Path(__file__).parent.parent / ".gitignore"
        
        if not gitignore_path.exists():
            pytest.fail(".gitignore file must exist for security")
        
        gitignore_content = gitignore_path.read_text()
        
        # Should contain pattern for JSON files
        assert "*.json" in gitignore_content or "policies/" in gitignore_content, \
            ".gitignore should protect JSON policy files from accidental commits"


if __name__ == "__main__":
    pytest.main([__file__, "-v", "--tb=short"])
