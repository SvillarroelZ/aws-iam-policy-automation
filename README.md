# AWS CLI IAM Policy Downloader

Bash automation tool to download AWS IAM policy documents programmatically.

**Author:** Sofia Villarroel Zamora  
**Region:** us-west-1 (N. California)  
**Quality:** 94% test coverage, 27 automated tests

---

## Quick Start

```bash
# Install system dependencies (Ubuntu/Debian)
sudo apt-get install -y jq curl unzip python3 python3-pip

# Install AWS CLI v2
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip && sudo ./aws/install

# Configure credentials
aws configure

# Run
./download_policy.sh
```

---

## Overview

Automates downloading IAM policy documents with credential validation, interactive selection, and file protection.

**Use Cases:** Policy backup, version control, auditing, compliance

**Features:** Credential validation, user policy discovery, interactive selection, file overwrite protection, clean JSON output

---

## Architecture

```
Local Terminal → AWS Cloud (STS + IAM) → File System (policies/)
```

**Workflow:**
1. Validate credentials (STS GetCallerIdentity)
2. Create output directory
3. List user policies (IAM ListAttachedUserPolicies)
4. Interactive selection
5. Lookup policy ARN and version
6. Check file overwrite protection
7. Download policy (IAM GetPolicyVersion)
5. Save JSON to policies/

---

## Installation

**System dependencies:**
```bash
# Ubuntu/Debian
sudo apt-get install -y jq curl unzip python3 python3-pip

# Red Hat/CentOS
sudo yum install -y jq curl unzip python3 python3-pip

# macOS
brew install jq curl python3
```

**AWS CLI v2:**
```bash
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip && sudo ./aws/install
aws --version
```

**Python tests:**
```bash
pip3 install -r requirements.txt
```

**Required IAM permissions:**
```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "sts:GetCallerIdentity",
      "iam:ListAttachedUserPolicies",
      "iam:ListPolicies",
      "iam:GetPolicyVersion"
    ],
    "Resource": "*"
  }]
}
```

---

## AWS Credentials

### Understanding Credentials

**AWS Access Key ID**
- Format: 20-char string starting with `AKIA`
- Function: Identifies IAM user
- Security: Public identifier

**AWS Secret Access Key**
- Format: 40-char base64 string
- Function: Cryptographic signature
- Security: **Highly confidential** - never commit to git

### Configuration

```bash
aws configure
```

Prompts:
```
AWS Access Key ID: AKIA****************
AWS Secret Access Key: ****************************************
Default region: us-west-1
Default output: json
```

Files created in `~/.aws/`:
- `credentials` - Access keys (plaintext, excluded from git)
- `config` - Region and output format

### Verification

```bash
aws sts get-caller-identity
```

Expected output:
```json
{
  "UserId": "AIDA...",
  "Account": "123456789012",
  "Arn": "arn:aws:iam::123456789012:user/awsstudent"
}
```

---

## Usage

**Interactive mode:**
```bash
./download_policy.sh
```

**Direct mode:**
```bash
./download_policy.sh lab_policy
./download_policy.sh lab_policy custom_output/
```

**With AWS profile:**
```bash
AWS_PROFILE=production ./download_policy.sh
```

**View policy:**
```bash
cat policies/lab_policy.json | jq .
```

---

## Testing

**Run tests:**
```bash
python3 -m pytest tests/ -v
python3 -m pytest tests/ --cov=. --cov-report=html
```

**Test coverage: 94%**
```
tests/test_download_policy.py     134      5    96%
tests/test_security.py            101     10    90%
TOTAL                             235     15    94%
```

**Test suite:**
- 27 automated tests
- Integration: AWS CLI, credentials, policy operations, file overwrite protection
- Security: No credentials in git, proper permissions, safe logging

---

## Security
**Protected files (`.gitignore`):**
- `*.pem`, `*.ppk` - SSH keys
- `.aws/`, `credentials` - AWS credentials
- `.env*` - Environment variables
- `__pycache__/` - Python cache

**Best practices:**
- Never commit credentials
- Lab credentials expire after 3-4 hours
- Rotate keys every 90 days (production)
- Use IAM roles on EC2
- Script doesn't log secret keys
- File permissions: 755 (not world-writable)

---

## Troubleshooting

**AWS CLI not found:**
```bash
export PATH=$PATH:/usr/local/bin
```

**Credentials expired:**
```bash
aws configure  # Re-enter from lab panel
```

**Policy not found:**
```bash
aws iam list-policies --scope Local --query 'Policies[].PolicyName'
```

**Script not executable:**
```bash
chmod +x download_policy.sh
```

**jq missing:**
```bash
sudo apt-get install -y jq
```

---

## Repository Structure

```
Proyecto_cafeteria_AWS_CLI/
├── download_policy.sh         # Main script (338 lines, modular design)
├── requirements.txt           # System and Python dependencies
├── .gitignore                 # Security exclusions
├── README.md                  # This file
├── policies/                  # Downloaded policies
│   └── lab_policy.json
└── tests/                     # Test suite (27 tests, 94% coverage)
    ├── test_download_policy.py
    └── test_security.py
```

**Script Architecture:**
- Modular design with 10+ functions
- Exception handling with specific exit codes (0-6)
- Timestamped logging to stderr
- JSON validation throughout
- File overwrite protection

**Exit Codes:**
- 0: Success
- 1: AWS CLI not found
- 2: Invalid/expired credentials
- 3: jq not found
- 4: Policy not found
- 5: Failed to retrieve policy version
- 6: Failed to download policy

---

## Resources

- [AWS CLI Documentation](https://docs.aws.amazon.com/cli/)
- [IAM Policy Reference](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies.html)
- [JMESPath Tutorial](https://jmespath.org/tutorial.html)

---
**Author:** Sofia Villarroel Zamora  
**Quality:** 94% test coverage, mid-senior level
