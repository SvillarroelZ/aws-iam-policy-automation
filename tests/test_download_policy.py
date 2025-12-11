#!/usr/bin/env python3
# Integration tests for download_policy.sh
# Verifies AWS CLI, credentials, policy operations, and file handling

import subprocess
import os
import json
import tempfile
import shutil
from pathlib import Path
import pytest


class TestDownloadPolicyScript:
    def test_interactive_selection_by_number(self):
        """Test: Select policy by number in interactive menu (robust)."""
        # Primero obtenemos la lista de políticas disponibles
        policies_result = subprocess.run([
            "aws", "iam", "list-policies", "--scope", "Local", "--query", "Policies[].PolicyName", "--output", "text"
        ], capture_output=True, text=True)
        policy_names = policies_result.stdout.strip().split()
        if len(policy_names) >= 2:
            # Si hay al menos dos políticas, selecciona la segunda por número
            result = self.run_script(input_text="2\n")
            assert result.returncode == 0 or result.returncode == 4, "Script should handle selection by number"
            assert "Selected policy" in result.stderr or "No customer-managed policies found" in result.stderr or "Policy document saved successfully" in result.stderr
        elif len(policy_names) == 1:
            # Si solo hay una, selecciona la primera por número
            result = self.run_script(input_text="1\n")
            assert result.returncode == 0 or result.returncode == 4, "Script should handle selection by number"
            assert "Selected policy" in result.stderr or "No customer-managed policies found" in result.stderr or "Policy document saved successfully" in result.stderr
        else:
            # Si no hay políticas, el test valida el mensaje de error
            result = self.run_script(input_text="1\n")
            assert result.returncode != 0, "Script should fail if no policies exist"
            assert "No customer-managed policies found" in result.stderr or "Invalid selection" in result.stderr

    def test_interactive_selection_by_name(self):
        """Test: Select policy by name in interactive menu."""
        # Simula que el usuario escribe el nombre de la política
        result = self.run_script(input_text="lab_policy\n")
        assert result.returncode == 0 or result.returncode == 4, "Script should handle selection by name"
        assert "Selected policy" in result.stderr or "No customer-managed policies found" in result.stderr

    def test_invalid_selection(self):
        """Test: Invalid selection in interactive menu."""
        # Simula entrada inválida
        result = self.run_script(input_text="9999\n")
        assert result.returncode != 0, "Script should exit with error for invalid selection"
        assert "Invalid selection" in result.stderr or "No customer-managed policies found" in result.stderr
    # Test script functionality with real AWS environment
    
    @pytest.fixture(autouse=True)
    def setup(self):
        # Create temp directory for test outputs
        self.script_path = Path(__file__).parent.parent / "download_policy.sh"
        self.test_output_dir = tempfile.mkdtemp(prefix="test_policies_")
        yield
        if os.path.exists(self.test_output_dir):
            shutil.rmtree(self.test_output_dir)
    
    def run_script(self, args=None, env=None, input_text=None):
        """Execute script and return result."""
        cmd = [str(self.script_path)]
        if args:
            cmd.extend(args)
        
        run_env = os.environ.copy()
        if env:
            run_env.update(env)
        
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            env=run_env,
            input=input_text
        )
        return result
    
    def test_aws_cli_installed(self):
        """Verify AWS CLI is installed."""
        result = subprocess.run(
            ["aws", "--version"],
            capture_output=True,
            text=True
        )
        assert result.returncode == 0, "AWS CLI should be installed"
        assert "aws-cli" in result.stdout, "Should return AWS CLI version"
    
    def test_script_exists_and_executable(self):
        """Verify script exists and has execute permission."""
        assert self.script_path.exists(), f"Script should exist at {self.script_path}"
        assert os.access(self.script_path, os.X_OK), "Script should be executable"
    
    def test_aws_credentials_configured(self):
        """Verify AWS credentials are configured."""
        result = subprocess.run(
            ["aws", "sts", "get-caller-identity"],
            capture_output=True,
            text=True
        )
        assert result.returncode == 0, "AWS credentials should be configured"
        
        # Parse and validate the identity response
        try:
            identity = json.loads(result.stdout)
            assert "UserId" in identity, "Response should contain UserId"
            assert "Account" in identity, "Response should contain Account"
            assert "Arn" in identity, "Response should contain Arn"
            assert len(identity["Account"]) == 12, "Account ID should be 12 digits"
        except json.JSONDecodeError:
            pytest.fail("get-caller-identity should return valid JSON")
        except Exception as e:
            pytest.fail(f"Unexpected error checking caller identity: {e}")
    
    def test_script_requires_aws_cli(self):
        """Test 4: Script should fail gracefully if AWS CLI is not in PATH."""
        # Run script with AWS_CMD pointing to non-existent binary
        result = self.run_script(env={"AWS_CMD": "/nonexistent/aws"})
        
        assert result.returncode == 1, "Script should exit with code 1 for missing AWS CLI"
        assert "AWS CLI not found" in result.stderr, "Should show AWS CLI not found message"
    
    def test_script_validates_credentials(self):
        """Test 5: Script should validate credentials before proceeding."""
        # This test runs the script and checks if credential validation occurs
        # We provide a policy name to avoid interactive prompts
        result = self.run_script(args=["nonexistent_policy", self.test_output_dir])
        
        assert "Validating AWS credentials" in result.stderr or \
               "Credentials are valid" in result.stderr, \
               "Script should validate credentials"
    
    def test_script_creates_output_directory(self):
        """Verify script creates output directory if missing."""
        new_output_dir = os.path.join(self.test_output_dir, "new_subdir")
        assert not os.path.exists(new_output_dir), "Directory shouldn't exist yet"
        
        result = self.run_script(args=["nonexistent_policy", new_output_dir])
        
        assert os.path.exists(new_output_dir), "Script should create output directory"
        assert os.path.isdir(new_output_dir), "Output path should be a directory"
    
    def test_script_handles_nonexistent_policy(self):
        """Verify script handles non-existent policies gracefully."""
        fake_policy_name = "this_policy_definitely_does_not_exist_12345"
        result = self.run_script(args=[fake_policy_name, self.test_output_dir])
        
        assert result.returncode != 0, "Script should exit with error for non-existent policy"
        assert "was not found" in result.stderr, "Should indicate policy was not found"
    
    def test_script_shows_user_policies(self):
        """Verify script lists policies attached to current user."""
        result = self.run_script(input_text="\n")
        
        output = result.stderr + result.stdout
        assert "Fetching policies" in output or \
               "attached to user" in output, \
               "Script should attempt to fetch user policies"
    
    def test_list_customer_managed_policies(self):
        """Verify AWS CLI can list customer-managed policies."""
        result = subprocess.run(
            ["aws", "iam", "list-policies", "--scope", "Local", "--max-items", "5"],
            capture_output=True,
            text=True
        )
        
        assert result.returncode == 0, "Should be able to list policies"
        
        try:
            policies = json.loads(result.stdout)
            assert "Policies" in policies, "Response should contain Policies key"
            assert isinstance(policies["Policies"], list), "Policies should be a list"
            
            # Additional validation if policies exist
            if len(policies["Policies"]) > 0:
                policy = policies["Policies"][0]
                assert "PolicyName" in policy
                assert "Arn" in policy
        except json.JSONDecodeError:
            pytest.fail("list-policies should return valid JSON")
        except Exception as e:
            pytest.fail(f"Unexpected error listing policies: {e}")
    
    def test_script_file_overwrite_protection(self):
        """Test 10: Script should ask for confirmation before overwriting existing files."""
        # Create a dummy policy file with a real policy name that exists in AWS
        test_policy_path = os.path.join(self.test_output_dir, "lab_policy.json")
        original_content = '{"Version": "2012-10-17", "Statement": []}'
        with open(test_policy_path, "w") as f:
            f.write(original_content)
        
        assert os.path.exists(test_policy_path), "Test file should exist"
        
        # Try to download to the same location with "n" (no) response
        # Note: Script outputs to stderr, so we check both stdout and stderr
        result = self.run_script(
            args=["lab_policy", self.test_output_dir],
            input_text="n\n"
        )
        
        with open(test_policy_path, "r") as f:
            content = f.read()
        
        assert content == original_content, \
               "Original file should not be modified when user says no"
        
        assert result.returncode == 0, \
               "Script should exit successfully when download is cancelled"


class TestAWSCLIIntegration:
    """AWS CLI integration tests."""
    
    def test_sts_get_caller_identity(self):
        """Verify STS GetCallerIdentity works."""
        result = subprocess.run(
            ["aws", "sts", "get-caller-identity", "--output", "json"],
            capture_output=True,
            text=True
        )
        
        assert result.returncode == 0, "STS GetCallerIdentity should succeed"
        
        identity = json.loads(result.stdout)
        assert identity["Account"].isdigit(), "Account should be numeric"
        assert len(identity["Account"]) == 12, "Account ID should be 12 digits"
        assert identity["Arn"].startswith("arn:aws:iam::"), "ARN should have correct format"
    
    def test_iam_list_policies(self):
        """Verify IAM ListPolicies works."""
        result = subprocess.run(
            ["aws", "iam", "list-policies", "--scope", "Local", "--max-items", "1"],
            capture_output=True,
            text=True
        )
        
        assert result.returncode == 0, "IAM ListPolicies should succeed"
        
        response = json.loads(result.stdout)
        assert "Policies" in response, "Response should contain Policies"
        
        if len(response["Policies"]) > 0:
            policy = response["Policies"][0]
            assert "PolicyName" in policy, "Policy should have PolicyName"
            assert "Arn" in policy, "Policy should have Arn"
            assert "DefaultVersionId" in policy, "Policy should have DefaultVersionId"
    
    def test_jq_installed(self):
        """Verify jq is installed."""
        result = subprocess.run(
            ["jq", "--version"],
            capture_output=True,
            text=True
        )
        
        assert result.returncode == 0, "jq should be installed"
        assert "jq" in result.stdout, "Should return jq version"
    
    def test_jq_json_parsing(self):
        """Verify jq can parse AWS CLI JSON output."""
        aws_result = subprocess.run(
            ["aws", "sts", "get-caller-identity"],
            capture_output=True,
            text=True
        )
        
        jq_result = subprocess.run(
            ["jq", "-r", ".Account"],
            input=aws_result.stdout,
            capture_output=True,
            text=True
        )
        
        assert jq_result.returncode == 0, "jq should successfully parse AWS output"
        assert jq_result.stdout.strip().isdigit(), "Should extract Account ID"
        assert len(jq_result.stdout.strip()) == 12, "Account ID should be 12 digits"


def test_repository_structure():
    """Verify repository has correct structure."""
    repo_root = Path(__file__).parent.parent
    
    # Check required files exist
    assert (repo_root / "download_policy.sh").exists(), "Script should exist"
    assert (repo_root / "README.md").exists(), "README should exist"
    assert (repo_root / ".gitignore").exists(), ".gitignore should exist"
    assert (repo_root / "requirements.txt").exists(), "requirements.txt should exist"
    
    gitignore_content = (repo_root / ".gitignore").read_text()
    assert "credentials" in gitignore_content, ".gitignore should exclude credentials"
    assert ".aws/" in gitignore_content, ".gitignore should exclude .aws directory"
    assert "*.pem" in gitignore_content, ".gitignore should exclude SSH keys"


def test_packages_file_format():
    """Verify requirements.txt has necessary dependencies."""
    repo_root = Path(__file__).parent.parent
    requirements_file = repo_root / "requirements.txt"
    
    content = requirements_file.read_text()
    
    assert "pytest" in content.lower(), "requirements.txt should include pytest"
    assert "#" in content, "requirements.txt should have comments"


if __name__ == "__main__":
    pytest.main([__file__, "-v", "--tb=short"])
